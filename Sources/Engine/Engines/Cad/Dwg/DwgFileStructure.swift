// The DWG file structure (ACadSharp 3.8.0 FileHeaders, DwgSectionDefinition, the LZ77 decompressors of R2004 and
// R2007 and the Reed-Solomon de-interleaving): where each section's pages are and how they are stored.

import Foundation

extension ACad {
    /// `DwgSectionDefinition`.
    enum DwgSectionDefinition {
        static let acDbObjects = "AcDb:AcDbObjects"
        static let acDsPrototype = "AcDb:AcDsPrototype_1b"
        static let appInfo = "AcDb:AppInfo"
        static let auxHeader = "AcDb:AuxHeader"
        static let classes = "AcDb:Classes"
        static let fileDepList = "AcDb:FileDepList"
        static let handles = "AcDb:Handles"
        static let header = "AcDb:Header"
        static let objFreeSpace = "AcDb:ObjFreeSpace"
        static let preview = "AcDb:Preview"
        static let revHistory = "AcDb:RevHistory"
        static let summaryInfo = "AcDb:SummaryInfo"
        static let template = "AcDb:Template"

        static let endSentinels: [String: [UInt8]] = [
            header: [0x30, 0x84, 0xE0, 0xDC, 0x02, 0x21, 0xC7, 0x56, 0xA0, 0x83, 0x97, 0x47, 0xB1, 0x92, 0xCC, 0xA0],
            classes: [0x72, 0x5E, 0x3B, 0x47, 0x3B, 0x56, 0x07, 0x3A, 0x3F, 0x23, 0x0B, 0xA0, 0x18, 0x30, 0x49, 0x75],
            preview: [0xE0, 0xDA, 0x92, 0xF8, 0x2B, 0xC9, 0xD7, 0xD7, 0x62, 0xA8, 0x35, 0xC0, 0x62, 0xBB, 0xEF, 0xD4],
        ]

        static let startSentinels: [String: [UInt8]] = [
            header: [0xCF, 0x7B, 0x1F, 0x23, 0xFD, 0xDE, 0x38, 0xA9, 0x5F, 0x7C, 0x68, 0xB8, 0x4E, 0x6D, 0x33, 0x5F],
            classes: [0x8D, 0xA1, 0xC4, 0xB8, 0xC4, 0xA9, 0xF8, 0xC5, 0xC0, 0xDC, 0xF4, 0x5F, 0xE7, 0xCF, 0xB6, 0x8A],
            preview: [0x1F, 0x25, 0x6D, 0x07, 0xD4, 0x36, 0x28, 0x28, 0x9D, 0x57, 0xCA, 0x3F, 0x9D, 0x44, 0x10, 0x2B],
        ]

        /// `GetSectionLocatorByName`: the R13–R15 record number of a section.
        static func sectionLocator(_ name: String) -> Int? {
            switch name {
            case header: return 0
            case classes: return 1
            case handles: return 2
            case objFreeSpace: return 3
            case template: return 4
            case auxHeader: return 5
            default: return nil
            }
        }
    }

    /// `DwgSectionLocatorRecord`.
    final class DwgSectionLocatorRecord {
        var number: Int?
        var seeker: Int64 = 0
        var size: Int64 = 0

        init(_ number: Int? = nil, seeker: Int64 = 0, size: Int64 = 0) {
            self.number = number
            self.seeker = seeker
            self.size = size
        }
    }

    /// `DwgLocalSectionMap`: one page of a section.
    final class DwgLocalSectionMap {
        var compression: Int32 = 2
        var isEmpty = false
        var offset: UInt64 = 0
        var compressedSize: UInt64 = 0
        var pageNumber: Int32 = 0
        var decompressedSize: UInt64 = 0
        var seeker: Int64 = 0
        var size: Int64 = 0
        var checksum: UInt64 = 0
        var crc: UInt64 = 0
        var pageSize: Int64 = 0
        var oda: UInt32 = 0
        var sectionMap: Int32 = 0
    }

    /// `DwgSectionDescriptor`.
    final class DwgSectionDescriptor {
        let pageType: Int64 = 0x4163_043B
        var name = ""
        var compressedSize: UInt64 = 0
        var pageCount: Int32 = 0
        var decompressedSize: UInt64 = 0x7400
        private(set) var compressedCode: Int32 = 2
        var isCompressed: Bool { compressedCode == 2 }
        var sectionId: Int32 = 0
        var encrypted: Int32 = 0
        var hashCode: UInt64?
        var encoding: UInt64?
        var localSections: [DwgLocalSectionMap] = []

        init(_ name: String = "") { self.name = name }

        /// The `CompressedCode` setter: only 1 and 2 are valid (`throw new Exception()`).
        func setCompressedCode(_ value: Int32) throws {
            guard value == 1 || value == 2 else { throw DwgError("Exception of type 'System.Exception' was thrown.") }
            compressedCode = value
        }
    }

    /// `Dwg21CompressedMetadata`.
    struct Dwg21CompressedMetadata {
        var headerSize: UInt64 = 0x70
        var fileSize: UInt64 = 0
        var pagesMapCrcCompressed: UInt64 = 0
        var pagesMapCorrectionFactor: UInt64 = 0
        var pagesMapCrcSeed: UInt64 = 0
        var map2Offset: UInt64 = 0
        var map2Id: UInt64 = 0
        var pagesMapOffset: UInt64 = 0
        var pagesMapId: UInt64 = 0
        var header2offset: UInt64 = 0
        var pagesMapSizeCompressed: UInt64 = 0
        var pagesMapSizeUncompressed: UInt64 = 0
        var pagesAmount: UInt64 = 0
        var pagesMaxId: UInt64 = 0
        var unknow0x20: UInt64 = 32
        var unknow0x40: UInt64 = 64
        var pagesMapCrcUncompressed: UInt64 = 0
        var unknown0xF800: UInt64 = 0xF800
        var unknown4: UInt64 = 4
        var unknown1: UInt64 = 1
        var sectionsAmount: UInt64 = 0
        var sectionsMapCrcUncompressed: UInt64 = 0
        var sectionsMapSizeCompressed: UInt64 = 0
        var sectionsMap2Id: UInt64 = 0
        var sectionsMapId: UInt64 = 0
        var sectionsMapSizeUncompressed: UInt64 = 0
        var sectionsMapCrcCompressed: UInt64 = 0
        var sectionsMapCorrectionFactor: UInt64 = 0
        var sectionsMapCrcSeed: UInt64 = 0
        var streamVersion: UInt64 = 393_472
        var crcSeed: UInt64 = 0
        var crcSeedEncoded: UInt64 = 0
        var randomSeed: UInt64 = 0
        var headerCRC64: UInt64 = 0
    }

    /// `DwgFileHeader` with the AC15 / AC18 / AC21 variants in one class.
    final class DwgFileHeader {
        static let ac15EndSentinel: [UInt8] = [0x95, 0xA0, 0x4E, 0x28, 0x99, 0x82, 0x1A, 0xE5, 0x5E, 0x41, 0xE0, 0x5F,
                                               0x9D, 0x3A, 0x4D, 0x00]

        let version: Version
        var previewAddress: Int64 = -1
        var maintenanceVersion: Int32 = 0
        /// Windows code page of the drawing (`CadUtils.GetCodePage`), 0 when unknown.
        var drawingCodePage = 0

        // AC15
        var records: [Int: DwgSectionLocatorRecord] = [:]

        // AC18
        var dwgVersion: UInt8 = 0
        var appReleaseVersion: UInt8 = 0
        var summaryInfoAddr: Int64 = 0
        var securityType: Int64 = 0
        var vbaProjectAddr: Int64 = 0
        var rootTreeNodeGap: Int32 = 0
        var gapArraySize: UInt32 = 0
        var crcSeed: UInt32 = 0
        var lastPageId: Int32 = 0
        var lastSectionAddr: UInt64 = 0
        var secondHeaderAddr: UInt64 = 0
        var gapAmount: UInt32 = 0
        var sectionAmount: UInt32 = 0
        var sectionPageMapId: UInt32 = 0
        var pageMapAddress: UInt64 = 0
        var sectionMapId: UInt32 = 0
        var sectionArrayPageSize: UInt32 = 0
        var rightGap: Int32 = 0
        var leftGap: Int32 = 0
        /// Section descriptors by name (a `Dictionary`: adding a name twice throws).
        private(set) var descriptors: [String: DwgSectionDescriptor] = [:]

        // AC21
        var compressedMetadata = Dwg21CompressedMetadata()

        /// `DwgFileHeader.CreateFileHeader`.
        init(_ version: Version) throws {
            switch version {
            case .unknown: throw CadNotSupportedError(version: nil)
            case .mc0_0, .ac1_2, .ac1_4, .ac1_50, .ac2_10, .ac1002, .ac1003, .ac1004, .ac1006, .ac1009:
                throw CadNotSupportedError(version: version)
            default: self.version = version
            }
        }

        func addDescriptor(_ descriptor: DwgSectionDescriptor) throws {
            guard descriptors[descriptor.name] == nil else { throw DwgError.duplicateKey(descriptor.name) }
            descriptors[descriptor.name] = descriptor
        }

        func addRecord(_ number: Int, _ record: DwgSectionLocatorRecord) throws {
            guard records[number] == nil else { throw DwgError.duplicateKey(number) }
            records[number] = record
        }

        func record(_ number: Int) throws -> DwgSectionLocatorRecord {
            guard let record = records[number] else { throw DwgError.keyNotFound(number) }
            return record
        }
    }

    /// `DwgLZ77AC18Decompressor`: the LZ77 variant of R2004+ pages. Reads like a `Stream`: bytes past the end are
    /// 0xFF (`(byte)ReadByte()`), short reads leave the previous buffer content.
    enum DwgLZ77AC18Decompressor {
        static func decompress(_ compressed: DwgStream, _ decompressedSize: Int64) throws -> DwgStream {
            let output = try DwgStream.create(decompressedSize)
            try decompressToDest(compressed, output)
            try output.seek(0)
            return output
        }

        static func decompressToDest(_ src: DwgStream, _ dst: DwgStream) throws {
            var tempBuf = [UInt8](repeating: 0, count: 128)
            func byte() -> Int { let b = src.readByte(); return b < 0 ? 0xFF : b }

            var opcode1 = byte()
            if opcode1 > 0x11 {
                opcode1 = try copy(opcode1 - 17, src, dst, &tempBuf)
            }
            if opcode1 & 0xF0 == 0 {
                opcode1 = try copy(literalCount(opcode1, src) + 3, src, dst, &tempBuf)
            }
            while opcode1 != 0x11 {
                var compOffset = 0
                var compressedBytes = 0
                if opcode1 < 0x10 || opcode1 >= 0x40 {
                    compressedBytes = (opcode1 >> 4) - 1
                    let opcode2 = byte()
                    compOffset = (((opcode1 >> 2) & 3) | (opcode2 << 2)) + 1
                } else if opcode1 < 0x20 {
                    compressedBytes = readCompressedBytes(opcode1, 0b0111, src)
                    compOffset = (opcode1 & 8) << 11
                    opcode1 = twoByteOffset(&compOffset, 0x4000, src)
                } else {
                    compressedBytes = readCompressedBytes(opcode1, 0b0001_1111, src)
                    opcode1 = twoByteOffset(&compOffset, 1, src)
                }
                // A zero or negative offset only comes from a truncated page; C# would loop forever or throw.
                guard compOffset > 0 else { throw DwgError.endOfStream }

                let position = dst.position
                if tempBuf.count < compressedBytes { tempBuf = [UInt8](repeating: 0, count: compressedBytes) }
                try dst.seek(position - compOffset)
                let count = min(compressedBytes, compOffset)
                guard count >= 0 else { throw DwgError("Non-negative number required. (Parameter 'count')") }
                let chunk = dst.read(count)
                tempBuf.replaceSubrange(0..<chunk.count, with: chunk)
                try dst.seek(position)
                while compressedBytes > 0 {
                    try dst.write(tempBuf[0..<min(compressedBytes, compOffset)])
                    compressedBytes -= compOffset
                }

                var litCount = opcode1 & 3
                if litCount == 0 {
                    opcode1 = byte()
                    if opcode1 & 0b1111_0000 == 0 {
                        litCount = literalCount(opcode1, src) + 3
                    }
                }
                if litCount > 0 {
                    opcode1 = try copy(litCount, src, dst, &tempBuf)
                }
            }
        }

        private static func copy(_ count: Int, _ src: DwgStream, _ dst: DwgStream, _ tempBuf: inout [UInt8]) throws -> Int {
            guard count >= 0 else { throw DwgError("Non-negative number required. (Parameter 'count')") }
            if tempBuf.count < count { tempBuf = [UInt8](repeating: 0, count: count) }
            let chunk = src.read(count)
            tempBuf.replaceSubrange(0..<chunk.count, with: chunk)
            try dst.write(tempBuf[0..<count])
            let b = src.readByte()
            return b < 0 ? 0xFF : b
        }

        private static func literalCount(_ code: Int, _ src: DwgStream) -> Int {
            var lowbits = code & 0b1111
            if lowbits == 0 {
                var lastByte = src.readByte()
                if lastByte < 0 { lastByte = 0xFF }
                while lastByte == 0 {
                    lowbits += 0xFF
                    lastByte = src.readByte()
                    if lastByte < 0 { lastByte = 0xFF }
                }
                lowbits += 0xF + lastByte
            }
            return lowbits
        }

        private static func readCompressedBytes(_ opcode1: Int, _ validBits: Int, _ compressed: DwgStream) -> Int {
            var compressedBytes = opcode1 & validBits
            if compressedBytes == 0 {
                var lastByte = compressed.readByte()
                if lastByte < 0 { lastByte = 0xFF }
                while lastByte == 0 {
                    compressedBytes += 0xFF
                    lastByte = compressed.readByte()
                    if lastByte < 0 { lastByte = 0xFF }
                }
                compressedBytes += lastByte + validBits
            }
            return compressedBytes + 2
        }

        /// Note the bytes are not cast here: -1 at the end of the stream.
        private static func twoByteOffset(_ offset: inout Int, _ addedValue: Int, _ stream: DwgStream) -> Int {
            let firstByte = stream.readByte()
            offset |= firstByte >> 2
            offset |= stream.readByte() << 6
            offset += addedValue
            return firstByte
        }
    }

    /// `DwgLZ77AC21Decompressor`: the LZ77 variant of R2007 pages. Indexes outside the arrays throw like .NET's
    /// `IndexOutOfRangeException`.
    final class DwgLZ77AC21Decompressor {
        private var length: UInt32 = 0
        private var opCode: UInt32 = 0
        private var sourceIndex: UInt32 = 0
        private var sourceOffset: UInt32 = 0

        private static let outOfRange = DwgError("Index was outside the bounds of the array.")

        func decompress(_ source: [UInt8], _ initialOffset: UInt32, _ length: UInt32, _ buffer: inout [UInt8]) throws {
            sourceOffset = 0
            self.length = 0
            sourceIndex = initialOffset
            opCode = UInt32(try at(source, sourceIndex))
            var destIndex: UInt32 = 0
            let endIndex = sourceIndex &+ length
            sourceIndex &+= 1
            if sourceIndex >= endIndex { return }
            if opCode & 240 == 32 {
                sourceIndex &+= 3
                self.length = UInt32(try at(source, sourceIndex &- 1)) & 7
            }
            while sourceIndex < endIndex {
                try nextIndex(source, &buffer, &destIndex)
                if sourceIndex >= endIndex { break }
                destIndex = try copyDecompressedChunks(source, endIndex, &buffer, destIndex)
            }
        }

        private func at(_ a: [UInt8], _ i: UInt32) throws -> UInt8 {
            guard Int(i) < a.count else { throw DwgLZ77AC21Decompressor.outOfRange }
            return a[Int(i)]
        }

        private func set(_ a: inout [UInt8], _ i: UInt32, _ v: UInt8) throws {
            guard Int(i) < a.count else { throw DwgLZ77AC21Decompressor.outOfRange }
            a[Int(i)] = v
        }

        private func copy1b(_ src: [UInt8], _ s: UInt32, _ dst: inout [UInt8], _ d: UInt32) throws {
            try set(&dst, d, try at(src, s))
        }

        private func copy2b(_ src: [UInt8], _ s: UInt32, _ dst: inout [UInt8], _ d: UInt32) throws {
            try set(&dst, d, try at(src, s &+ 1))
            try set(&dst, d &+ 1, try at(src, s))
        }

        private func copy3b(_ src: [UInt8], _ s: UInt32, _ dst: inout [UInt8], _ d: UInt32) throws {
            try set(&dst, d, try at(src, s &+ 2))
            try set(&dst, d &+ 1, try at(src, s &+ 1))
            try set(&dst, d &+ 2, try at(src, s))
        }

        private func copy4b(_ src: [UInt8], _ s: UInt32, _ dst: inout [UInt8], _ d: UInt32) throws {
            for k in 0..<UInt32(4) { try set(&dst, d &+ k, try at(src, s &+ k)) }
        }

        private func copy8b(_ src: [UInt8], _ s: UInt32, _ dst: inout [UInt8], _ d: UInt32) throws {
            try copy4b(src, s, &dst, d)
            try copy4b(src, s &+ 4, &dst, d &+ 4)
        }

        private func copy16b(_ src: [UInt8], _ s: UInt32, _ dst: inout [UInt8], _ d: UInt32) throws {
            try copy8b(src, s &+ 8, &dst, d)
            try copy8b(src, s, &dst, d &+ 8)
        }

        /// The `_copyMethods` table (lengths 1 … 31).
        private func copyMethod(_ n: UInt32, _ src: [UInt8], _ s: UInt32, _ dst: inout [UInt8], _ d: UInt32) throws {
            switch n {
            case 1: try copy1b(src, s, &dst, d)
            case 2: try copy2b(src, s, &dst, d)
            case 3: try copy3b(src, s, &dst, d)
            case 4: try copy4b(src, s, &dst, d)
            case 5:
                try copy1b(src, s &+ 4, &dst, d); try copy4b(src, s, &dst, d &+ 1)
            case 6:
                try copy1b(src, s &+ 5, &dst, d); try copy4b(src, s &+ 1, &dst, d &+ 1); try copy1b(src, s, &dst, d &+ 5)
            case 7:
                try copy2b(src, s &+ 5, &dst, d); try copy4b(src, s &+ 1, &dst, d &+ 2); try copy1b(src, s, &dst, d &+ 6)
            case 8: try copy8b(src, s, &dst, d)
            case 9:
                try copy1b(src, s &+ 8, &dst, d); try copy8b(src, s, &dst, d &+ 1)
            case 10:
                try copy1b(src, s &+ 9, &dst, d); try copy8b(src, s &+ 1, &dst, d &+ 1); try copy1b(src, s, &dst, d &+ 9)
            case 11:
                try copy2b(src, s &+ 9, &dst, d); try copy8b(src, s &+ 1, &dst, d &+ 2); try copy1b(src, s, &dst, d &+ 10)
            case 12:
                try copy4b(src, s &+ 8, &dst, d); try copy8b(src, s, &dst, d &+ 4)
            case 13:
                try copy1b(src, s &+ 12, &dst, d); try copy4b(src, s &+ 8, &dst, d &+ 1); try copy8b(src, s, &dst, d &+ 5)
            case 14:
                try copy1b(src, s &+ 13, &dst, d); try copy4b(src, s &+ 9, &dst, d &+ 1)
                try copy8b(src, s &+ 1, &dst, d &+ 5); try copy1b(src, s, &dst, d &+ 13)
            case 15:
                try copy2b(src, s &+ 13, &dst, d); try copy4b(src, s &+ 9, &dst, d &+ 2)
                try copy8b(src, s &+ 1, &dst, d &+ 6); try copy1b(src, s, &dst, d &+ 14)
            case 16: try copy16b(src, s, &dst, d)
            case 17:
                try copy8b(src, s &+ 9, &dst, d); try copy1b(src, s &+ 8, &dst, d &+ 8); try copy8b(src, s, &dst, d &+ 9)
            case 18:
                try copy1b(src, s &+ 17, &dst, d); try copy16b(src, s &+ 1, &dst, d &+ 1); try copy1b(src, s, &dst, d &+ 17)
            case 19:
                try copy3b(src, s &+ 16, &dst, d); try copy16b(src, s, &dst, d &+ 3)
            case 20:
                try copy4b(src, s &+ 16, &dst, d); try copy8b(src, s &+ 8, &dst, d &+ 4); try copy8b(src, s, &dst, d &+ 12)
            case 21:
                try copy1b(src, s &+ 20, &dst, d); try copy4b(src, s &+ 16, &dst, d &+ 1)
                try copy8b(src, s &+ 8, &dst, d &+ 5); try copy8b(src, s, &dst, d &+ 13)
            case 22:
                try copy2b(src, s &+ 20, &dst, d); try copy4b(src, s &+ 16, &dst, d &+ 2)
                try copy8b(src, s &+ 8, &dst, d &+ 6); try copy8b(src, s, &dst, d &+ 14)
            case 23:
                try copy3b(src, s &+ 20, &dst, d); try copy4b(src, s &+ 16, &dst, d &+ 3)
                try copy8b(src, s &+ 8, &dst, d &+ 7); try copy8b(src, s, &dst, d &+ 15)
            case 24:
                try copy8b(src, s &+ 16, &dst, d); try copy16b(src, s, &dst, d &+ 8)
            case 25:
                try copy8b(src, s &+ 17, &dst, d); try copy1b(src, s &+ 16, &dst, d &+ 8); try copy16b(src, s, &dst, d &+ 9)
            case 26:
                try copy1b(src, s &+ 25, &dst, d); try copy8b(src, s &+ 17, &dst, d &+ 1)
                try copy1b(src, s &+ 16, &dst, d &+ 9); try copy16b(src, s, &dst, d &+ 10)
            case 27:
                try copy2b(src, s &+ 25, &dst, d); try copy8b(src, s &+ 17, &dst, d &+ 2)
                try copy1b(src, s &+ 16, &dst, d &+ 10); try copy16b(src, s, &dst, d &+ 11)
            case 28:
                try copy4b(src, s &+ 24, &dst, d); try copy8b(src, s &+ 16, &dst, d &+ 4)
                try copy8b(src, s &+ 8, &dst, d &+ 12); try copy8b(src, s, &dst, d &+ 20)
            case 29:
                try copy1b(src, s &+ 28, &dst, d); try copy4b(src, s &+ 24, &dst, d &+ 1)
                try copy8b(src, s &+ 16, &dst, d &+ 5); try copy8b(src, s &+ 8, &dst, d &+ 13); try copy8b(src, s, &dst, d &+ 21)
            case 30:
                try copy2b(src, s &+ 28, &dst, d); try copy4b(src, s &+ 24, &dst, d &+ 2)
                try copy8b(src, s &+ 16, &dst, d &+ 6); try copy8b(src, s &+ 8, &dst, d &+ 14); try copy8b(src, s, &dst, d &+ 22)
            case 31:
                try copy1b(src, s &+ 30, &dst, d); try copy4b(src, s &+ 26, &dst, d &+ 1)
                try copy8b(src, s &+ 18, &dst, d &+ 5); try copy8b(src, s &+ 10, &dst, d &+ 13)
                try copy8b(src, s &+ 2, &dst, d &+ 21); try copy2b(src, s, &dst, d &+ 29)
            default: throw DwgError("Object reference not set to an instance of an object.") // _copyMethods[0] is null
            }
        }

        private func copy(_ src: [UInt8], _ srcIndex: UInt32, _ dst: inout [UInt8], _ dstIndex: UInt32, _ length: UInt32) throws {
            var s = srcIndex, d = dstIndex, n = length
            while n >= 32 {
                try copy4b(src, s &+ 24, &dst, d)
                try copy4b(src, s &+ 28, &dst, d &+ 4)
                try copy4b(src, s &+ 16, &dst, d &+ 8)
                try copy4b(src, s &+ 20, &dst, d &+ 12)
                try copy4b(src, s &+ 8, &dst, d &+ 16)
                try copy4b(src, s &+ 12, &dst, d &+ 20)
                try copy4b(src, s, &dst, d &+ 24)
                try copy4b(src, s &+ 4, &dst, d &+ 28)
                s &+= 32
                d &+= 32
                n -= 32
            }
            if n == 0 { return }
            try copyMethod(n, src, s, &dst, d)
        }

        private func copyBytes(_ dst: inout [UInt8], _ dstIndex: UInt32, _ length: UInt32, _ srcOffset: UInt32) throws {
            var initialIndex = dstIndex &- srcOffset
            let maxIndex = initialIndex &+ length
            var d = dstIndex
            while initialIndex < maxIndex {
                try set(&dst, d, try at(dst, initialIndex))
                d &+= 1
                initialIndex &+= 1
            }
        }

        private func copyDecompressedChunks(_ src: [UInt8], _ endIndex: UInt32, _ dst: inout [UInt8], _ destIndex: UInt32) throws -> UInt32 {
            var destIndex = destIndex
            length = 0
            opCode = UInt32(try at(src, sourceIndex))
            sourceIndex &+= 1
            try readInstructions(src)
            while true {
                try copyBytes(&dst, destIndex, length, sourceOffset)
                destIndex &+= length
                length = opCode & 0x07
                if length != 0 || sourceIndex >= endIndex { break }
                opCode = UInt32(try at(src, sourceIndex))
                sourceIndex &+= 1
                if opCode >> 4 == 0 { break }
                if opCode >> 4 == 15 { opCode &= 15 }
                try readInstructions(src)
            }
            return destIndex
        }

        private func nextIndex(_ source: [UInt8], _ dest: inout [UInt8], _ index: inout UInt32) throws {
            if length == 0 { try readLiteralLength(source) }
            try copy(source, sourceIndex, &dest, index, length)
            sourceIndex &+= length
            index &+= length
        }

        private func readInstructions(_ buffer: [UInt8]) throws {
            switch opCode >> 4 {
            case 0:
                length = (opCode & 0xF) + 0x13
                sourceOffset = UInt32(try at(buffer, sourceIndex))
                sourceIndex &+= 1
                opCode = UInt32(try at(buffer, sourceIndex))
                sourceIndex &+= 1
                length = ((opCode >> 3) & 0x10) &+ length
                sourceOffset = ((opCode & 0x78) << 5) &+ 1 &+ sourceOffset
            case 1:
                length = (opCode & 0xF) + 3
                sourceOffset = UInt32(try at(buffer, sourceIndex))
                sourceIndex &+= 1
                opCode = UInt32(try at(buffer, sourceIndex))
                sourceIndex &+= 1
                sourceOffset = ((opCode & 248) << 5) &+ 1 &+ sourceOffset
            case 2:
                sourceOffset = UInt32(try at(buffer, sourceIndex))
                sourceIndex &+= 1
                sourceOffset = ((UInt32(try at(buffer, sourceIndex)) << 8) & 0xFF00) | sourceOffset
                sourceIndex &+= 1
                length = opCode & 7
                if opCode & 8 == 0 {
                    opCode = UInt32(try at(buffer, sourceIndex))
                    sourceIndex &+= 1
                    length = (opCode & 0xF8) &+ length
                } else {
                    sourceOffset &+= 1
                    length = (UInt32(try at(buffer, sourceIndex)) << 3) &+ length
                    sourceIndex &+= 1
                    opCode = UInt32(try at(buffer, sourceIndex))
                    sourceIndex &+= 1
                    length = ((opCode & 0xF8) << 8) &+ length &+ 0x100
                }
            default:
                length = opCode >> 4
                sourceOffset = opCode & 15
                opCode = UInt32(try at(buffer, sourceIndex))
                sourceIndex &+= 1
                sourceOffset = ((opCode & 0xF8) << 1) &+ sourceOffset &+ 1
            }
        }

        private func readLiteralLength(_ buffer: [UInt8]) throws {
            length = opCode &+ 8
            if length == 0x17 {
                var n = UInt32(try at(buffer, sourceIndex))
                sourceIndex &+= 1
                length &+= n
                if n == 0xFF {
                    repeat {
                        n = UInt32(try at(buffer, sourceIndex))
                        sourceIndex &+= 1
                        n |= UInt32(try at(buffer, sourceIndex)) << 8
                        sourceIndex &+= 1
                        length &+= n
                    } while n == 0xFFFF
                }
            }
        }
    }

    enum DwgDecoding {
        /// `reedSolomonDecoding`: de-interleaves `factor` blocks of `blockSize` bytes (no error correction).
        static func reedSolomon(_ encoded: [UInt8], _ buffer: inout [UInt8], _ factor: Int, _ blockSize: Int) throws {
            var index = 0
            var n = 0
            var length = buffer.count
            for _ in 0..<max(0, factor) {
                var cindex = n
                if n < encoded.count {
                    let size = min(length, blockSize)
                    length -= size
                    let offset = index + size
                    while index < offset {
                        guard index < buffer.count, cindex < encoded.count else {
                            throw DwgError("Index was outside the bounds of the array.")
                        }
                        buffer[index] = encoded[cindex]
                        index += 1
                        cindex += factor
                    }
                }
                n += 1
            }
        }

        /// `CRC32StreamHandler(byte[], seed)`: the R2004 file header data is XOR-ed with the MSVC `rand()` sequence.
        static func decryptHeader(_ bytes: [UInt8]) -> [UInt8] {
            var arr = bytes
            var randSeed: Int32 = 1
            for i in 0..<arr.count {
                randSeed = randSeed &* 0x343FD
                randSeed = randSeed &+ 0x269EC3
                arr[i] ^= UInt8(truncatingIfNeeded: randSeed >> 0x10)
            }
            return arr
        }
    }
}
