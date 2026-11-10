// ACadSharp 3.8.0 `DwgReader` with Filee's configuration (failsafe, summary info read, proxy graphics ignored):
// the file header of R13–R2018 files, the section streams (plain, R2004 paged and compressed, R2007 Reed-Solomon
// encoded), and the order in which the sections are read and the document built.

import Foundation

extension ACad {
    final class DwgReader {
        private let file: DwgStream
        private(set) var fileHeader: DwgFileHeader!
        private var builder: DwgDocumentBuilder!
        private let document = Document(createDefaults: false)
        /// `CadReaderBase._encoding`: .NET's `Encoding.Default` until the file header names the code page.
        private var encoding: String.Encoding = .utf8
        private var readerNotifications: [String] = []

        init(data: Data) {
            file = DwgStream([UInt8](data))
        }

        /// Warnings and errors of the reading (`OnNotification`), for the log.
        var notifications: [String] { readerNotifications + (builder?.notifications ?? []) }

        func notify(_ message: String) { readerNotifications.append(message) }

        /// `DwgReader.Read`.
        func read() throws -> Document {
            fileHeader = try readFileHeader()
            builder = DwgDocumentBuilder(version: fileHeader.version, document: document)
            document.summaryInfo = try readSummaryInfo()
            document.header = try readHeader()
            document.header.document = document
            try readClasses()
            // readAppInfo only reads in ACadSharp's TEST builds.
            try readDsPrototype1b()
            try readObjects()
            try readAuxHeader()
            try builder.buildDwgDocument()
            return document
        }

        /// `ReadHeader`.
        private func readHeader() throws -> CadHeader {
            let header = CadHeader()
            header.codePage = CodePages.name(codePage: fileHeader.drawingCodePage)
            let reader = try sectionStream(DwgSectionDefinition.header)
            let headerReader = DwgHeaderReader(fileHeader.version, reader, header)
            let handles = try headerReader.read(fileHeader.maintenanceVersion)
            readerNotifications += headerReader.notifications
            builder.headerHandles = handles
            return header
        }

        /// `ReadSummaryInfo`.
        private func readSummaryInfo() throws -> SummaryInfo {
            // Older versions than 2004 don't have summary info in their file.
            if fileHeader.version < .ac1018 { return SummaryInfo() }
            guard let reader = try sectionStreamIfPresent(DwgSectionDefinition.summaryInfo) else { return SummaryInfo() }
            let summaryReader = try DwgSummaryInfoReader(fileHeader.version, reader)
            let summary = summaryReader.read()
            readerNotifications += summaryReader.notifications
            return summary
        }

        // ───────────────────────── File header ─────────────────────────

        private func readFileHeader() throws -> DwgFileHeader {
            try file.seek(0)
            // `ReadString(6, Encoding.ASCII)`: bytes above 0x7F decode as '?'.
            let tag = String(decoding: Array(file.read(6)).map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
            guard tag.utf8.count == 6 else { throw DwgError.endOfStream }
            let header = try DwgFileHeader(Version.fromDwgName(tag))
            let reader = try DwgStreamReader(header.version, file)
            switch header.version {
            case .ac1012, .ac1014, .ac1015: try readFileHeaderAC15(header, reader)
            case .ac1018, .ac1024, .ac1027, .ac1032: try readFileHeaderAC18(header, reader)
            case .ac1021: try readFileHeaderAC21(header, reader)
            default: break
            }
            return header
        }

        /// `readFileHeaderAC15` (R13–R15).
        private func readFileHeaderAC15(_ header: DwgFileHeader, _ reader: DwgStreamReader) throws {
            _ = try reader.readBytes(7)
            header.previewAddress = Int64(try reader.readInt())
            _ = try reader.readBytes(2)
            header.drawingCodePage = CodePages.codePage(dwgIndex: Int(try reader.readShort()))
            encoding = CodePages.listedEncoding(header.drawingCodePage)
            let nRecords = Int(try reader.readRawLong())
            if nRecords > 0 {
                for _ in 0..<nRecords {
                    let record = DwgSectionLocatorRecord()
                    record.number = Int(try reader.readByte())
                    record.seeker = try reader.readRawLong()
                    record.size = try reader.readRawLong()
                    try header.addRecord(record.number!, record)
                }
            }
            // RS: CRC for BOF to this point.
            _ = try reader.resetShift()
            _ = try reader.readSentinel()
        }

        /// `readFileHeaderAC18` (R2004, R2010+).
        private func readFileHeaderAC18(_ header: DwgFileHeader, _ reader: DwgStreamReader) throws {
            try readFileMetaData(header, reader)

            // 0x80, 0x6C bytes of encrypted data.
            let data = DwgStream(DwgDecoding.decryptHeader(try reader.readBytes(0x6C)))
            _ = try reader.readBytes(20)

            let fileId = DwgText.windows1252(Array(data.read(12)))
            if fileId != "AcFssFcAJMB\0" {
                notify("File validation failed, id should be : AcFssFcAJMB\0, but is : \(fileId)")
            }
            func int32() throws -> Int32 {
                let b = Array(data.read(4))
                guard b.count == 4 else { throw DwgError.endOfStream }
                return Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            }
            func uint64() throws -> UInt64 {
                let b = Array(data.read(8))
                guard b.count == 8 else { throw DwgError.endOfStream }
                return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << UInt64(8 * $1) }
            }
            _ = try int32()
            _ = try int32()
            _ = try int32()
            header.rootTreeNodeGap = try int32()
            header.leftGap = try int32()
            header.rightGap = try int32()
            _ = try int32()
            header.lastPageId = try int32()
            header.lastSectionAddr = try uint64()
            header.secondHeaderAddr = try uint64()
            header.gapAmount = UInt32(bitPattern: try int32())
            header.sectionAmount = UInt32(bitPattern: try int32())
            _ = try int32()
            _ = try int32()
            _ = try int32()
            header.sectionPageMapId = UInt32(bitPattern: try int32())
            header.pageMapAddress = try uint64() &+ 256
            header.sectionMapId = UInt32(bitPattern: try int32())
            header.sectionArrayPageSize = UInt32(bitPattern: try int32())
            header.gapArraySize = UInt32(bitPattern: try int32())
            header.crcSeed = UInt32(bitPattern: try int32())

            // Page map of the file.
            try reader.setPosition(Int(truncatingIfNeeded: Int64(bitPattern: header.pageMapAddress)))
            var decompressedSize = try pageHeaderDecompressedSize(reader)
            let records = DwgStreamReaderIO(try DwgLZ77AC18Decompressor.decompress(file, decompressedSize))
            var total: Int32 = 0x100
            while records.position < records.length {
                let record = DwgSectionLocatorRecord()
                record.number = Int(try records.int32())
                record.size = Int64(try records.int32())
                if record.number! >= 0 {
                    record.seeker = Int64(total)
                    try header.addRecord(record.number!, record)
                } else {
                    // A gap: parent, left, right, 0x00.
                    for _ in 0..<4 { _ = try records.int32() }
                }
                total &+= Int32(truncatingIfNeeded: record.size)
            }

            // Data section map.
            try reader.setPosition(Int(try header.record(Int(Int32(bitPattern: header.sectionMapId))).seeker))
            decompressedSize = try pageHeaderDecompressedSize(reader)
            let map = DwgStreamReaderIO(try DwgLZ77AC18Decompressor.decompress(file, decompressedSize))
            let ndescriptions = try map.int32()
            _ = try map.int32()
            _ = try map.int32()
            _ = try map.int32()
            _ = try map.int32()
            if ndescriptions > 0 {
                for _ in 0..<ndescriptions {
                    let descriptor = DwgSectionDescriptor()
                    descriptor.compressedSize = try map.uint64()
                    descriptor.pageCount = try map.int32()
                    descriptor.decompressedSize = UInt64(bitPattern: Int64(try map.int32()))
                    _ = try map.int32()
                    try descriptor.setCompressedCode(try map.int32())
                    descriptor.sectionId = try map.int32()
                    descriptor.encrypted = try map.int32()
                    descriptor.name = DwgText.windows1252(try map.bytes(64)).components(separatedBy: "\0")[0]

                    var decompressSizeCounter: UInt64 = 0
                    if descriptor.pageCount > 0 {
                        for _ in 0..<descriptor.pageCount {
                            let local = DwgLocalSectionMap()
                            local.pageNumber = try map.int32()
                            local.compressedSize = UInt64(bitPattern: Int64(try map.int32()))
                            local.offset = try map.uint64()
                            // Zero pages fill gaps in the offsets.
                            while decompressSizeCounter < local.offset {
                                let empty = DwgLocalSectionMap()
                                empty.isEmpty = true
                                empty.offset = decompressSizeCounter
                                empty.compressedSize = 0
                                empty.decompressedSize = descriptor.decompressedSize
                                descriptor.localSections.append(empty)
                                decompressSizeCounter &+= descriptor.decompressedSize
                            }
                            local.decompressedSize = descriptor.decompressedSize
                            local.seeker = try header.record(Int(local.pageNumber)).seeker
                            descriptor.localSections.append(local)
                            decompressSizeCounter &+= local.decompressedSize
                        }
                    }
                    guard descriptor.decompressedSize != 0 else { throw DwgError("Attempted to divide by zero.") }
                    let sizeLeft = UInt32(truncatingIfNeeded: descriptor.compressedSize % descriptor.decompressedSize)
                    if sizeLeft > 0, let last = descriptor.localSections.last {
                        last.decompressedSize = UInt64(sizeLeft)
                    }
                    try header.addDescriptor(descriptor)
                }
            }
        }

        /// `getPageHeaderData`: the decompressed size of a system page.
        private func pageHeaderDecompressedSize(_ reader: DwgStreamReader) throws -> Int64 {
            _ = try reader.readRawLong()
            let decompressedSize = try reader.readRawLong()
            _ = try reader.readRawLong()
            _ = try reader.readRawLong()
            _ = try reader.readRawLong()
            return decompressedSize
        }

        /// `readFileHeaderAC21` (R2007).
        private func readFileHeaderAC21(_ header: DwgFileHeader, _ reader: DwgStreamReader) throws {
            try readFileMetaData(header, reader)

            // 0x3D8 bytes Reed-Solomon (255, 239) encoded with a factor of 3.
            let compressedData = try reader.readBytes(0x400)
            var decodedData = [UInt8](repeating: 0, count: 3 * 239)
            try DwgDecoding.reedSolomon(compressedData, &decodedData, 3, 239)

            let comprLen = Int32(bitPattern: UInt32(decodedData[24]) | UInt32(decodedData[25]) << 8
                | UInt32(decodedData[26]) << 16 | UInt32(decodedData[27]) << 24)
            var buffer = [UInt8](repeating: 0, count: 0x110)
            if comprLen < 0 {
                throw DwgError.notImplemented
            } else {
                try DwgLZ77AC21Decompressor().decompress(decodedData, 32, UInt32(comprLen), &buffer)
            }
            let d = DwgStreamReaderIO(DwgStream(buffer))
            var m = Dwg21CompressedMetadata()
            m.headerSize = try d.uint64()
            m.fileSize = try d.uint64()
            m.pagesMapCrcCompressed = try d.uint64()
            m.pagesMapCorrectionFactor = try d.uint64()
            m.pagesMapCrcSeed = try d.uint64()
            m.map2Offset = try d.uint64()
            m.map2Id = try d.uint64()
            m.pagesMapOffset = try d.uint64()
            m.pagesMapId = try d.uint64()
            m.header2offset = try d.uint64()
            m.pagesMapSizeCompressed = try d.uint64()
            m.pagesMapSizeUncompressed = try d.uint64()
            m.pagesAmount = try d.uint64()
            m.pagesMaxId = try d.uint64()
            m.unknow0x20 = try d.uint64()
            m.unknow0x40 = try d.uint64()
            m.pagesMapCrcUncompressed = try d.uint64()
            m.unknown0xF800 = try d.uint64()
            m.unknown4 = try d.uint64()
            m.unknown1 = try d.uint64()
            m.sectionsAmount = try d.uint64()
            m.sectionsMapCrcUncompressed = try d.uint64()
            m.sectionsMapSizeCompressed = try d.uint64()
            m.sectionsMap2Id = try d.uint64()
            m.sectionsMapId = try d.uint64()
            m.sectionsMapSizeUncompressed = try d.uint64()
            m.sectionsMapCrcCompressed = try d.uint64()
            m.sectionsMapCorrectionFactor = try d.uint64()
            m.sectionsMapCrcSeed = try d.uint64()
            m.streamVersion = try d.uint64()
            m.crcSeed = try d.uint64()
            m.crcSeedEncoded = try d.uint64()
            m.randomSeed = try d.uint64()
            m.headerCRC64 = try d.uint64()
            header.compressedMetadata = m

            // Page map.
            let pages = DwgStreamReaderIO(DwgStream(try pageBuffer(m.pagesMapOffset, m.pagesMapSizeCompressed,
                                                                   m.pagesMapSizeUncompressed, m.pagesMapCorrectionFactor, 0xEF)))
            var offset: Int64 = 0
            while pages.position < pages.length {
                let size = try pages.int64()
                let id = try pages.int64()
                // Math.Abs(long.MinValue) throws OverflowException.
                guard id != Int64.min else { throw DwgError("Negating the minimum value of a twos complement number is invalid.") }
                let number = Int(Int32(truncatingIfNeeded: abs(id)))
                try header.addRecord(number, DwgSectionLocatorRecord(number, seeker: Int64(Int32(truncatingIfNeeded: offset)),
                                                                      size: Int64(Int32(truncatingIfNeeded: size))))
                offset &+= size
            }

            // Section map.
            let sectionsSeeker = try header.record(Int(Int32(truncatingIfNeeded: Int64(bitPattern: m.sectionsMapId)))).seeker
            let sections = DwgStreamReaderIO(DwgStream(try pageBuffer(UInt64(bitPattern: sectionsSeeker), m.sectionsMapSizeCompressed,
                                                                      m.sectionsMapSizeUncompressed, m.sectionsMapCorrectionFactor, 239)))
            while sections.position < sections.length {
                let section = DwgSectionDescriptor()
                section.compressedSize = try sections.uint64()
                section.decompressedSize = try sections.uint64()
                section.encrypted = Int32(truncatingIfNeeded: try sections.uint64())
                section.hashCode = try sections.uint64()
                let sectionNameLength = Int(Int32(truncatingIfNeeded: try sections.int64()))
                _ = try sections.uint64()
                section.encoding = try sections.uint64()
                section.pageCount = Int32(truncatingIfNeeded: try sections.uint64())
                if sectionNameLength > 0 {
                    section.name = DwgText.decode(try sections.bytes(sectionNameLength), .utf16LittleEndian)
                        .replacingOccurrences(of: "\0", with: "")
                }
                var currentOffset: UInt64 = 0
                if section.pageCount > 0 {
                    for _ in 0..<section.pageCount {
                        let page = DwgLocalSectionMap()
                        page.offset = try sections.uint64()
                        page.size = try sections.int64()
                        page.pageNumber = Int32(truncatingIfNeeded: try sections.int64())
                        page.decompressedSize = try sections.uint64()
                        page.compressedSize = try sections.uint64()
                        page.checksum = try sections.uint64()
                        page.crc = try sections.uint64()
                        if currentOffset < page.offset {
                            let empty = DwgLocalSectionMap()
                            empty.isEmpty = true
                            empty.offset = currentOffset
                            empty.compressedSize = 0
                            empty.decompressedSize = page.offset &- currentOffset
                            section.localSections.append(empty)
                        }
                        section.localSections.append(page)
                        currentOffset = page.offset &+ page.decompressedSize
                    }
                }
                if sectionNameLength > 0 { try header.addDescriptor(section) }
            }
        }

        /// `readFileMetaData`: the R2004+ metadata before the encrypted header.
        private func readFileMetaData(_ header: DwgFileHeader, _ reader: DwgStreamReader) throws {
            try reader.advance(5)
            header.maintenanceVersion = Int32(try reader.readByte())
            try reader.advance(1)
            header.previewAddress = try reader.readRawLong()
            header.dwgVersion = try reader.readByte()
            header.appReleaseVersion = try reader.readByte()
            header.drawingCodePage = CodePages.codePage(dwgIndex: Int(try reader.readShort()))
            encoding = CodePages.listedEncoding(header.drawingCodePage)
            reader.encoding = encoding
            try reader.advance(3)
            header.securityType = try reader.readRawLong()
            _ = try reader.readRawLong()
            header.summaryInfoAddr = try reader.readRawLong()
            header.vbaProjectAddr = try reader.readRawLong()
            _ = try reader.readRawLong()
            _ = try reader.readRawLong()
            try reader.advance(80)
        }

        // ───────────────────────── Section streams ─────────────────────────

        /// `decryptDataSection`: the header of a data page, XOR-ed with a mask of its position.
        private func decryptDataSection(_ section: DwgLocalSectionMap, _ reader: DwgStreamReader) throws {
            let secMask = Int64(Int32(bitPattern: 0x4164_536B ^ UInt32(truncatingIfNeeded: reader.position)))
            _ = try reader.readRawLong() ^ secMask
            _ = try reader.readRawLong() ^ secMask
            section.compressedSize = UInt64(bitPattern: try reader.readRawLong() ^ secMask)
            section.pageSize = try reader.readRawLong() ^ secMask
            let startOffset = try reader.readRawLong() ^ secMask
            let checksum = try reader.readRawLong() ^ secMask
            section.offset = UInt64(bitPattern: checksum &+ startOffset)
            section.checksum = UInt64(UInt32(truncatingIfNeeded: try reader.readRawLong() ^ secMask))
            section.oda = UInt32(truncatingIfNeeded: try reader.readRawLong() ^ secMask)
        }

        /// `getPageBuffer` (R2007 system pages): Reed-Solomon decoded, then LZ77 decompressed.
        private func pageBuffer(_ pageOffset: UInt64, _ compressedSize: UInt64, _ uncompressedSize: UInt64,
                                _ correctionFactor: UInt64, _ blockSize: Int) throws -> [UInt8] {
            let v = compressedSize &+ 7
            let v1 = v & 0b1111_1111_1111_1111_1111_1111_1111_1000
            let totalSize = UInt32(truncatingIfNeeded: v1 &* correctionFactor)
            let factor = Int(Int32(truncatingIfNeeded: Int64(totalSize) + Int64(blockSize) - 1)) / blockSize
            let length = factor * 255
            guard length >= 0 else { throw DwgError("Arithmetic operation resulted in an overflow.") }
            var buffer = [UInt8](repeating: 0, count: length)
            try file.seek(Int(truncatingIfNeeded: Int64(bitPattern: 0x480 &+ pageOffset)))
            let read = file.read(length)
            buffer.replaceSubrange(0..<read.count, with: read)
            guard Int32(bitPattern: totalSize) >= 0 else { throw DwgError("Arithmetic operation resulted in an overflow.") }
            var compressedData = [UInt8](repeating: 0, count: Int(totalSize))
            try DwgDecoding.reedSolomon(buffer, &compressedData, factor, blockSize)
            guard uncompressedSize <= 0x7FFF_FFC7 else { throw DwgError("Array dimensions exceeded supported range.") }
            var decompressed = [UInt8](repeating: 0, count: Int(uncompressedSize))
            try DwgLZ77AC21Decompressor().decompress(compressedData, 0, UInt32(truncatingIfNeeded: compressedSize), &decompressed)
            return decompressed
        }

        /// `getSectionBuffer15`: the file itself, at the section's seeker.
        private func sectionBuffer15(_ name: String) throws -> DwgStream? {
            guard let locator = DwgSectionDefinition.sectionLocator(name) else { return nil }
            guard let record = fileHeader.records[locator] else { return nil }
            try file.seek(Int(record.seeker))
            return file
        }

        /// `getSectionBuffer18`: the pages decompressed into one fixed-size stream.
        func sectionBuffer18(_ name: String) throws -> DwgStream? {
            guard let descriptor = fileHeader.descriptors[name] else { return nil }
            let capacity = Int64(bitPattern: descriptor.decompressedSize) &* Int64(descriptor.localSections.count)
            let stream = try DwgStream.create(capacity)
            for section in descriptor.localSections {
                if section.isEmpty {
                    let count = Int(Int32(truncatingIfNeeded: Int64(bitPattern: section.decompressedSize)))
                    if count > 0 { try stream.write([UInt8](repeating: 0, count: count)) }
                } else {
                    let reader = try DwgStreamReader(fileHeader.version, file)
                    try reader.setPosition(Int(section.seeker))
                    try decryptDataSection(section, reader)
                    if descriptor.isCompressed {
                        try DwgLZ77AC18Decompressor.decompressToDest(file, stream)
                    } else {
                        let count = Int(Int32(truncatingIfNeeded: Int64(bitPattern: section.compressedSize)))
                        guard count >= 0 else { throw DwgError("Arithmetic operation resulted in an overflow.") }
                        var buffer = [UInt8](repeating: 0, count: count)
                        let read = file.read(count)
                        buffer.replaceSubrange(0..<read.count, with: read)
                        try stream.write(buffer)
                    }
                }
            }
            try stream.seek(0)
            return stream
        }

        /// `getSectionBuffer21`.
        private func sectionBuffer21(_ name: String) throws -> DwgStream? {
            guard let section = fileHeader.descriptors[name] else { return nil }
            var totalLength: UInt64 = 0
            for page in section.localSections { totalLength &+= page.decompressedSize }
            let stream = try DwgStream.create(Int64(bitPattern: totalLength))
            for page in section.localSections {
                if page.isEmpty {
                    let count = Int(Int32(truncatingIfNeeded: Int64(bitPattern: page.decompressedSize)))
                    if count > 0 { try stream.write([UInt8](repeating: 0, count: count)) }
                    continue
                }
                let pageData = try fileHeader.record(Int(page.pageNumber))
                try file.seek(Int(pageData.seeker + 0x480))
                let size = Int(Int32(truncatingIfNeeded: pageData.size))
                guard size >= 0 else { throw DwgError("Arithmetic operation resulted in an overflow.") }
                var pageBytes = [UInt8](repeating: 0, count: size)
                let read = file.read(size)
                pageBytes.replaceSubrange(0..<read.count, with: read)
                if section.encoding == 4 {
                    let v = page.compressedSize &+ 7
                    let v1 = v & 0b1111_1111_1111_1111_1111_1111_1111_1000
                    let alignedPageSize = Int(Int32(truncatingIfNeeded: Int64(bitPattern: (v1 &+ 251 &- 1) / 251)))
                    var arr = [UInt8](repeating: 0, count: max(0, alignedPageSize * 251))
                    try DwgDecoding.reedSolomon(pageBytes, &arr, alignedPageSize, 251)
                    pageBytes = arr
                }
                if page.compressedSize != page.decompressedSize {
                    guard page.decompressedSize <= 0x7FFF_FFC7 else { throw DwgError("Array dimensions exceeded supported range.") }
                    var arr = [UInt8](repeating: 0, count: Int(page.decompressedSize))
                    try DwgLZ77AC21Decompressor().decompress(pageBytes, 0, UInt32(truncatingIfNeeded: page.compressedSize), &arr)
                    pageBytes = arr
                }
                let count = Int(Int32(truncatingIfNeeded: Int64(bitPattern: page.decompressedSize)))
                guard count >= 0, count <= pageBytes.count else {
                    throw DwgError("Offset and length were out of bounds for the array or count is greater than the number of elements from index to the end of the source collection.")
                }
                try stream.write(pageBytes[0..<count])
            }
            try stream.seek(0)
            return stream
        }

        private func sectionStreamIfPresent(_ name: String) throws -> DwgStreamReader? {
            let stream: DwgStream?
            switch fileHeader.version {
            case .ac1012, .ac1014, .ac1015: stream = try sectionBuffer15(name)
            case .ac1018, .ac1024, .ac1027, .ac1032: stream = try sectionBuffer18(name)
            case .ac1021: stream = try sectionBuffer21(name)
            default: throw CadNotSupportedError(version: fileHeader.version)
            }
            guard let stream else { return nil }
            return try DwgStreamReader(fileHeader.version, stream, encoding: encoding)
        }

        /// `getSectionStream` where ACadSharp uses the result without a null check (a missing section then fails
        /// with a NullReferenceException).
        private func sectionStream(_ name: String) throws -> DwgStreamReader {
            guard let reader = try sectionStreamIfPresent(name) else {
                throw DwgError("Object reference not set to an instance of an object.")
            }
            return reader
        }

        // ───────────────────────── Sections ─────────────────────────

        private func readClasses() throws {
            let reader = DwgClassesReader(fileHeader.version, try sectionStream(DwgSectionDefinition.classes), fileHeader,
                                          document.classes)
            try reader.read()
            readerNotifications += reader.notifications
        }

        private func readDsPrototype1b() throws {
            guard let reader = try sectionStreamIfPresent(DwgSectionDefinition.acDsPrototype) else { return }
            let prototype = DwgPrototype1bReader(fileHeader.version, builder, reader)
            try prototype.read()
            readerNotifications += prototype.notifications
        }

        private func readHandles() throws -> [UInt64: Int64] {
            let reader = DwgHandleReader(fileHeader.version, try sectionStream(DwgSectionDefinition.handles))
            let handles = try reader.read()
            readerNotifications += reader.notifications
            return handles
        }

        private func readObjects() throws {
            let handles = try readHandles()
            let reader: DwgStreamReader
            if fileHeader.version <= .ac1015 {
                // Handles are absolute offsets in these versions.
                reader = try DwgStreamReader(fileHeader.version, file, encoding: encoding)
                try reader.setPosition(0)
            } else {
                reader = try sectionStream(DwgSectionDefinition.acDbObjects)
            }
            let queue = builder.headerHandles.handles.compactMap { $0 }
            let objectReader = try DwgObjectReader(fileHeader.version, builder, reader, queue, handles, document.classes)
            try objectReader.read()
        }

        private func readAuxHeader() throws {
            guard let reader = try sectionStreamIfPresent(DwgSectionDefinition.auxHeader) else { return }
            try DwgAuxHeaderReader(fileHeader.version, reader).read()
        }
    }

    /// The `StreamIO` reads ACadSharp does on plain decompressed buffers (little-endian, end-of-stream checked).
    final class DwgStreamReaderIO {
        let stream: DwgStream
        init(_ stream: DwgStream) { self.stream = stream }

        var position: Int { stream.position }
        var length: Int { stream.length }

        func bytes(_ count: Int) throws -> [UInt8] {
            let b = Array(stream.read(count))
            guard b.count == count else { throw DwgError.endOfStream }
            return b
        }

        func int32() throws -> Int32 {
            let b = try bytes(4)
            return Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        }

        func uint64() throws -> UInt64 {
            let b = try bytes(8)
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << UInt64(8 * $1) }
        }

        func int64() throws -> Int64 { Int64(bitPattern: try uint64()) }
    }
}

extension ACad.Version {
    /// `CadUtils.GetVersionFromName` for the DWG tag: `Enum.TryParse` of the upper-cased name with '.' as '_'.
    static func fromDwgName(_ name: String) -> ACad.Version {
        let key = name.replacingOccurrences(of: ".", with: "_").uppercased()
        return allCases.first { $0 != .unknown && String(describing: $0).uppercased() == key } ?? .unknown
    }
}

extension ACad.CodePages {
    /// `CadReaderBase.getListedEncoding`: `Encoding.GetEncoding(code)`, Windows-1252 when there is none.
    static func listedEncoding(_ codePage: Int) -> String.Encoding { encoding(codePage) }
}
