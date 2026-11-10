// ACadSharp 3.8.0 `DwgFileHeaderWriterAC18` (with `DwgFileHeaderWriterBase`): the R2004+ file layout ACadSharp
// writes for AC1018 and AC1024–AC1032. Each section is cut into pages of its page size, compressed with LZ77 and
// written with a masked page header; then the section map, the page map and the file header (twice) follow.

import Foundation

extension ACad {
    final class DwgFileHeaderWriter {
        private let stream: DwgMemoryStream
        private let document: Document
        private let compressor = DwgLZ77AC18Compressor()
        /// `FileHeader.Descriptors` in insertion order.
        private var descriptors: [DwgSectionDescriptor] = []
        private var localSectionsMaps: [DwgLocalSectionMap] = []

        // `DwgFileHeaderAC18` values.
        private var rootTreeNodeGap: Int32 = 0
        private var leftGap: Int32 = 0
        private var rightGap: Int32 = 0
        private var gapArraySize: UInt32 = 0
        private var lastPageId: Int32 = 0
        private var lastSectionAddr: UInt64 = 0
        private var secondHeaderAddr: UInt64 = 0
        private var gapAmount: UInt32 = 0
        private var sectionAmount: UInt32 = 0
        private var sectionPageMapId: UInt32 = 0
        private var pageMapAddress: UInt64 = 0
        private var sectionMapId: UInt32 = 0
        private var sectionArrayPageSize: UInt32 = 0

        let fileHeaderSize = 0x100
        let handleSectionOffset = 0

        init(_ stream: DwgMemoryStream, _ document: Document) {
            self.stream = stream
            self.document = document
            // File header info
            for _ in 0..<fileHeaderSize { stream.writeByte(0) }
        }

        private func descriptor(_ name: String) throws -> DwgSectionDescriptor {
            guard let d = descriptors.first(where: { $0.name == name }) else { throw DwgError.keyNotFound(name) }
            return d
        }

        func addSection(_ name: String, _ section: DwgMemoryStream, _ isCompressed: Bool, _ decompsize: Int = 0x7400) throws {
            let descriptor = DwgSectionDescriptor(name)
            // `Dictionary.Add`
            guard !descriptors.contains(where: { $0.name == name }) else { throw DwgError.duplicateKey(name) }
            descriptors.append(descriptor)
            descriptor.decompressedSize = UInt64(decompsize)
            descriptor.compressedSize = UInt64(section.length)
            try descriptor.setCompressedCode(isCompressed ? 2 : 1)

            let pageSize = Int(descriptor.decompressedSize)
            let nlocalSections = section.length / pageSize
            let buffer = section.bytes
            var offset = 0
            for _ in 0..<nlocalSections {
                try createLocalSection(descriptor, buffer, pageSize, offset, pageSize, isCompressed)
                offset += pageSize
            }
            let spearBytes = section.length % pageSize
            if spearBytes > 0 && !buffer[offset..<(offset + spearBytes)].allSatisfy({ $0 == 0 }) {
                try createLocalSection(descriptor, buffer, pageSize, offset, spearBytes, isCompressed)
            }
        }

        func writeFile() throws {
            sectionArrayPageSize = UInt32(localSectionsMaps.count + 2)
            sectionPageMapId = sectionArrayPageSize
            sectionMapId = sectionArrayPageSize - 1
            try writeDescriptors()
            try writeRecords()
            try writeFileMetaData()
        }

        private func applyCompression(_ buffer: [UInt8], _ decompressedSize: Int, _ offset: Int, _ totalSize: Int,
                                      _ isCompressed: Bool) throws -> DwgMemoryStream {
            let result = DwgMemoryStream()
            var holder = Array(buffer[offset..<(offset + totalSize)])
            holder.append(contentsOf: repeatElement(0, count: decompressedSize - totalSize))
            if isCompressed {
                try compressor.compress(holder, 0, decompressedSize, result)
            } else {
                result.write(holder)
            }
            return result
        }

        private func createLocalSection(_ descriptor: DwgSectionDescriptor, _ buffer: [UInt8], _ decompressedSize: Int,
                                        _ offset: Int, _ totalSize: Int, _ isCompressed: Bool) throws {
            let descriptorStream = try applyCompression(buffer, decompressedSize, offset, totalSize, isCompressed)
            writeMagicNumber()
            // Save position for the local section
            let position = stream.position
            let localMap = DwgLocalSectionMap()
            localMap.offset = UInt64(offset)
            localMap.seeker = Int64(position)
            localMap.pageNumber = Int32(localSectionsMaps.count + 1)
            localMap.oda = DwgCheckSum.calculate(0, descriptorStream.bytes, 0, descriptorStream.length)
            let compressDiff = DwgCheckSum.compressionCalculator(descriptorStream.length)
            localMap.compressedSize = UInt64(descriptorStream.length)
            localMap.decompressedSize = UInt64(totalSize)
            localMap.pageSize = Int64(localMap.compressedSize) + 32 + Int64(compressDiff)
            localMap.checksum = 0

            var checkSum = dataSection(descriptor, localMap, Int32(truncatingIfNeeded: descriptor.pageType))
            localMap.checksum = UInt64(DwgCheckSum.calculate(localMap.oda, checkSum, 0, checkSum.count))
            checkSum = dataSection(descriptor, localMap, Int32(truncatingIfNeeded: descriptor.pageType))
            applyMask(&checkSum, 0, checkSum.count)
            stream.write(checkSum)
            stream.write(descriptorStream.bytes)
            if isCompressed {
                stream.write(DwgCheckSum.magicSequence[0..<compressDiff])
            } else if compressDiff != 0 {
                throw DwgError("Exception of type 'System.Exception' was thrown.")
            }
            if localMap.pageNumber > 0 { descriptor.pageCount += 1 }
            localMap.size = Int64(stream.position - position)
            descriptor.localSections.append(localMap)
            localSectionsMaps.append(localMap)
        }

        private func writeFileMetaData() throws {
            secondHeaderAddr = UInt64(stream.position)
            let header = fileHeaderBytes()
            stream.write(header)
            stream.position = 0
            // `Encoding.ASCII.GetBytes(VersionString)`, 6 bytes.
            stream.write(Array(document.header.versionString.utf8.map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }.prefix(6)))
            // 5 bytes of 0x00
            stream.write([UInt8](repeating: 0, count: 5))
            // 0x0B 1 Maintenance release version
            stream.writeByte(UInt8(truncatingIfNeeded: document.header.maintenanceVersion))
            // 0x0C 1 Byte 0x00, 0x01, or 0x03
            stream.writeByte(3)
            // 0x0D 4 Preview address(long), points to the image page + page header size(0x20).
            stream.write(DwgLE.bytes(UInt32(truncatingIfNeeded: Int32(truncatingIfNeeded: try firstSeeker(DwgSectionDefinition.preview)) + 0x20)))
            // 0x11 1 Dwg version (Acad version that writes the file)
            stream.writeByte(33)
            // 0x12 1 Application maintenance release version
            stream.writeByte(UInt8(truncatingIfNeeded: document.header.maintenanceVersion))
            // 0x13 2 Codepage
            stream.write(DwgLE.bytes(fileCodePage()))
            // 0x15 3 3 0x00 bytes
            stream.write([UInt8](repeating: 0, count: 3))
            // 0x18 4 SecurityType; 0x1C 4 Unknown long
            stream.write(DwgLE.bytes(Int32(0)))
            stream.write(DwgLE.bytes(Int32(0)))
            // 0x20 4 Summary info Address in stream
            stream.write(DwgLE.bytes(UInt32(truncatingIfNeeded: Int32(truncatingIfNeeded: try firstSeeker(DwgSectionDefinition.summaryInfo)) + 0x20)))
            // 0x24 4 VBA Project Addr(0 if not present)
            stream.write(DwgLE.bytes(UInt32(0)))
            // 0x28 4 0x00000080
            stream.write(DwgLE.bytes(Int32(0x80)))
            // 0x2C 4 App info Address in stream
            stream.write(DwgLE.bytes(UInt32(truncatingIfNeeded: Int32(truncatingIfNeeded: try firstSeeker(DwgSectionDefinition.appInfo)) + 0x20)))
            // 0x30 80 0x00 bytes
            stream.write([UInt8](repeating: 0, count: 80))
            stream.write(header)
            stream.write(DwgCheckSum.magicSequence[236..<256])
        }

        private func firstSeeker(_ name: String) throws -> Int64 {
            let d = try descriptor(name)
            guard let first = d.localSections.first else { throw DwgError("Index was out of range. Must be non-negative and less than the size of the collection. (Parameter 'index')") }
            return first.seeker
        }

        private func addSection(_ section: DwgLocalSectionMap) {
            section.pageNumber = Int32(localSectionsMaps.count + 1)
            localSectionsMaps.append(section)
        }

        /// Compress the local map section and write the checksum once is done.
        private func compressChecksum(_ section: DwgLocalSectionMap, _ data: [UInt8]) throws {
            section.decompressedSize = UInt64(data.count)
            let main = DwgMemoryStream()
            try compressor.compress(data, 0, data.count, main)
            section.compressedSize = UInt64(main.length)
            let holder = pageHeaderData(section)
            var checksum = DwgCheckSum.calculate(0, holder, 0, holder.count)
            checksum = DwgCheckSum.calculate(checksum, main.bytes, 0, main.length)
            section.checksum = UInt64(checksum)
            stream.write(pageHeaderData(section))
            stream.write(main.bytes)
        }

        private func setSeeker(_ map: Int32, _ data: [UInt8]) throws -> DwgLocalSectionMap {
            let holder = DwgLocalSectionMap()
            holder.sectionMap = map
            writeMagicNumber()
            holder.seeker = Int64(stream.position)
            try compressChecksum(holder, data)
            return holder
        }

        private func dataSection(_ descriptor: DwgSectionDescriptor, _ map: DwgLocalSectionMap, _ size: Int32) -> [UInt8] {
            var out: [UInt8] = []
            // 0x00 4 Section page type, since it’s always a data section: 0x4163043b
            out += DwgLE.bytes(size)
            // 0x04 4 Section number
            out += DwgLE.bytes(descriptor.sectionId)
            // 0x08 4 Data size (compressed)
            out += DwgLE.bytes(Int32(truncatingIfNeeded: map.compressedSize))
            // 0x0C 4 Page Size (decompressed)
            out += DwgLE.bytes(Int32(truncatingIfNeeded: map.pageSize))
            // 0x10 8 Start Offset (in the decompressed buffer)
            out += DwgLE.bytes(Int64(bitPattern: map.offset))
            // 0x18 4 Data Checksum
            out += DwgLE.bytes(UInt32(truncatingIfNeeded: map.checksum))
            // 0x1C 4 Unknown (ODA writes a 0)
            out += DwgLE.bytes(map.oda)
            return out
        }

        private func writeDescriptors() throws {
            var out: [UInt8] = []
            // 0x00 4 Number of section descriptions(NumDescriptions)
            out += DwgLE.bytes(Int32(descriptors.count))
            // 0x04 4 0x02 (long)
            out += DwgLE.bytes(Int32(2))
            // 0x08 4 0x00007400 (long)
            out += DwgLE.bytes(Int32(0x7400))
            // 0x0C 4 0x00 (long)
            out += DwgLE.bytes(Int32(0))
            // 0x10 4 Unknown (long), ODA writes NumDescriptions here.
            out += DwgLE.bytes(Int32(descriptors.count))
            for d in descriptors {
                out += DwgLE.bytes(d.compressedSize)
                out += DwgLE.bytes(d.pageCount)
                out += DwgLE.bytes(Int32(truncatingIfNeeded: d.decompressedSize))
                out += DwgLE.bytes(Int32(1))
                out += DwgLE.bytes(d.compressedCode)
                out += DwgLE.bytes(d.sectionId)
                out += DwgLE.bytes(d.encrypted)
                // 0x20 64 Section Name (Windows-1252)
                var nameArr = [UInt8](repeating: 0, count: 64)
                let bytes = Array(d.name.utf8) // section names are ASCII
                for i in 0..<min(bytes.count, nameArr.count) { nameArr[i] = bytes[i] }
                out += nameArr
                for localMap in d.localSections where localMap.pageNumber > 0 {
                    out += DwgLE.bytes(localMap.pageNumber)
                    out += DwgLE.bytes(Int32(truncatingIfNeeded: localMap.compressedSize))
                    out += DwgLE.bytes(localMap.offset)
                }
            }
            // Section map: 0x4163003b
            let sectionHolder = try setSeeker(0x4163_003B, out)
            let count = DwgCheckSum.compressionCalculator(stream.position - Int(sectionHolder.seeker))
            // Fill the gap
            stream.write(DwgCheckSum.magicSequence[0..<count])
            sectionHolder.size = Int64(stream.position) - sectionHolder.seeker
            addSection(sectionHolder)
        }

        private func fileHeaderBytes() -> [UInt8] {
            var out: [UInt8] = Array("AcFssFcAJMB".utf8) + [0]
            out += DwgLE.bytes(Int32(0))
            out += DwgLE.bytes(Int32(0x6C))
            out += DwgLE.bytes(Int32(0x04))
            out += DwgLE.bytes(rootTreeNodeGap)
            out += DwgLE.bytes(leftGap)
            out += DwgLE.bytes(rightGap)
            out += DwgLE.bytes(Int32(1))
            out += DwgLE.bytes(lastPageId)
            out += DwgLE.bytes(lastSectionAddr)
            out += DwgLE.bytes(secondHeaderAddr)
            out += DwgLE.bytes(gapAmount)
            out += DwgLE.bytes(sectionAmount)
            out += DwgLE.bytes(Int32(0x20))
            out += DwgLE.bytes(Int32(0x80))
            out += DwgLE.bytes(Int32(0x40))
            out += DwgLE.bytes(sectionPageMapId)
            out += DwgLE.bytes(pageMapAddress &- 256)
            out += DwgLE.bytes(sectionMapId)
            out += DwgLE.bytes(sectionArrayPageSize)
            out += DwgLE.bytes(gapArraySize)
            // 0x68 4 CRC32 with seed zero, computed over the table including the 4 zero CRC bytes.
            let seed = DwgCrc.crc32(0, out + [0, 0, 0, 0])
            out += DwgLE.bytes(seed)
            // applyMagicSequence
            for i in out.indices { out[i] ^= DwgCheckSum.magicSequence[i] }
            return out
        }

        private func pageHeaderData(_ section: DwgLocalSectionMap) -> [UInt8] {
            var out: [UInt8] = []
            out += DwgLE.bytes(section.sectionMap)
            out += DwgLE.bytes(Int32(truncatingIfNeeded: section.decompressedSize))
            out += DwgLE.bytes(Int32(truncatingIfNeeded: section.compressedSize))
            out += DwgLE.bytes(section.compression)
            out += DwgLE.bytes(UInt32(truncatingIfNeeded: section.checksum))
            return out
        }

        private func writeRecords() throws {
            writeMagicNumber()
            // Section page map: 0x41630e3b
            let section = DwgLocalSectionMap()
            section.sectionMap = 0x4163_0E3B
            addSection(section)
            let counter = localSectionsMaps.count * 8
            section.seeker = Int64(stream.position)
            let size = counter + DwgCheckSum.compressionCalculator(counter)
            section.size = Int64(size)
            var out: [UInt8] = []
            for item in localSectionsMaps {
                // 0x00 4 Section page number, 0x04 4 Section size
                out += DwgLE.bytes(item.pageNumber)
                out += DwgLE.bytes(Int32(truncatingIfNeeded: item.size))
            }
            try compressChecksum(section, out)
            let last = localSectionsMaps[localSectionsMaps.count - 1]
            gapAmount = 0
            lastPageId = last.pageNumber
            lastSectionAddr = UInt64(bitPattern: last.seeker + Int64(size) - 256)
            sectionAmount = UInt32(localSectionsMaps.count)
            pageMapAddress = UInt64(bitPattern: section.seeker)
        }

        /// `getFileCodePage`.
        private func fileCodePage() -> UInt16 {
            let code = CodePages.codePage(name: document.header.codePage ?? "")
            let index = CodePages.dwgIndex(codePage: code)
            return index < 1 ? 30 : UInt16(index)
        }

        /// `applyMask`: XOR with 0x4164536B ^ the current stream position, 4 bytes at a time.
        private func applyMask(_ buffer: inout [UInt8], _ offset: Int, _ length: Int) {
            let bytes = DwgLE.bytes(Int32(0x4164_536B) ^ Int32(truncatingIfNeeded: stream.position))
            var offset = offset
            let diff = offset + length
            while offset < diff {
                for i in 0..<4 { buffer[offset + i] ^= bytes[i] }
                offset += 4
            }
        }

        /// `writeMagicNumber`: the loop bound is re-read every pass, which pads to a 32-byte boundary.
        private func writeMagicNumber() {
            var i = 0
            while i < stream.position % 0x20 {
                stream.writeByte(DwgCheckSum.magicSequence[i])
                i += 1
            }
        }
    }
}
