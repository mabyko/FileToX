// The small DWG section writers of ACadSharp 3.8.0: classes, the handle map, the aux header, the (empty) preview
// and the app info.

import Foundation

extension ACad {
    /// `DwgClassesWriter`.
    final class DwgClassesWriter: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.classes }
        private let output: DwgMemoryStream
        private let sectionStream = DwgMemoryStream()
        private let document: Document

        init(_ output: DwgMemoryStream, _ document: Document) {
            self.output = output
            self.document = document
            super.init(document.header.version)
        }

        func write() throws {
            let w = DwgMergedStreamWriter(sectionStream)
            // R2007+
            w.savePositionForSize()
            let maxClassNumber = document.classes.map(\.classNumber).max() ?? 0
            // R2004+: BS max class number, RC 0, RC 0, B true
            w.writeBitShort(maxClassNumber)
            w.writeByte(0)
            w.writeByte(0)
            w.writeBit(true)
            for c in document.classes {
                w.writeBitShort(c.classNumber)
                w.writeBitShort(Int16(truncatingIfNeeded: c.proxyFlags))
                w.writeVariableText(c.applicationName)
                w.writeVariableText(c.cppClassName)
                w.writeVariableText(c.dxfName)
                w.writeBit(c.wasZombie)
                w.writeBitShort(c.itemClassId)
                // R2004+
                w.writeBitLong(c.instanceCount)
                w.writeBitLong(Int32(c.dwgVersion))
                w.writeBitLong(Int32(c.maintenanceVersion))
                w.writeBitLong(0)
                w.writeBitLong(0)
            }
            try w.writeSpearShift()
            writeSizeAndCrc()
        }

        private func writeSizeAndCrc() {
            output.write(DwgSectionDefinition.startSentinels[sectionName]!)
            var data: [UInt8] = DwgLE.bytes(Int32(truncatingIfNeeded: sectionStream.length))
            let header = document.header
            if header.version >= .ac1024 && header.maintenanceVersion > 3 || header.version > .ac1027 {
                data += DwgLE.bytes(Int32(0))
            }
            data += sectionStream.bytes
            output.write(data)
            output.write(DwgLE.bytes(DwgCrc.crc8(0xC0C1, data)))
            output.write(DwgSectionDefinition.endSentinels[sectionName]!)
            // R2004+: 8 unknown bytes
            output.write([UInt8](repeating: 0, count: 8))
        }
    }

    /// `DwgHandleWriter`: the handle → offset map in sections of at most 2032 bytes, each with a CRC.
    final class DwgHandleWriter: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.handles }
        private let stream: DwgMemoryStream
        private let handleMap: [(UInt64, Int64)]

        init(_ version: Version, _ stream: DwgMemoryStream, _ map: [UInt64: Int64]) {
            self.stream = stream
            handleMap = map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            super.init(version)
        }

        func write(_ sectionOffset: Int = 0) throws {
            var array = [UInt8](repeating: 0, count: 10)
            var array2 = [UInt8](repeating: 0, count: 5)
            var offset: UInt64 = 0
            var initialLoc: Int64 = 0
            var lastPosition = stream.position
            stream.writeByte(0)
            stream.writeByte(0)
            for (key, value) in handleMap {
                var handleOff = key &- offset
                let lastLoc = value + Int64(sectionOffset)
                var locDiff = lastLoc - initialLoc
                var offsetSize = Self.modularShortToValue(handleOff, &array)
                var locSize = Self.signedModularShortToValue(Int32(truncatingIfNeeded: locDiff), &array2)
                if stream.position - lastPosition + (offsetSize + locSize) > 2032 {
                    processPosition(lastPosition)
                    offset = 0
                    initialLoc = 0
                    lastPosition = stream.position
                    stream.writeByte(0)
                    stream.writeByte(0)
                    handleOff = key &- offset
                    guard handleOff != 0 else { throw DwgError("Exception of type 'System.Exception' was thrown.") }
                    locDiff = lastLoc - initialLoc
                    offsetSize = Self.modularShortToValue(handleOff, &array)
                    locSize = Self.signedModularShortToValue(Int32(truncatingIfNeeded: locDiff), &array2)
                }
                stream.write(array[0..<offsetSize])
                stream.write(array2[0..<locSize])
                offset = key
                initialLoc = lastLoc
            }
            processPosition(lastPosition)
            lastPosition = stream.position
            stream.writeByte(0)
            stream.writeByte(0)
            processPosition(lastPosition)
        }

        private static func modularShortToValue(_ value: UInt64, _ arr: inout [UInt8]) -> Int {
            var value = value
            var i = 0
            while value >= 0b1000_0000 {
                arr[i] = UInt8(value & 0b111_1111) | 0b1000_0000
                i += 1
                value >>= 7
            }
            arr[i] = UInt8(value)
            return i + 1
        }

        private static func signedModularShortToValue(_ value: Int32, _ arr: inout [UInt8]) -> Int {
            var value = value
            var i = 0
            if value < 0 {
                value = 0 &- value
                while value >= 64 {
                    arr[i] = UInt8(truncatingIfNeeded: (UInt32(bitPattern: value) & 0x7F) | 0x80)
                    i += 1
                    value >>= 7
                }
                arr[i] = UInt8(truncatingIfNeeded: UInt32(bitPattern: value) | 0x40)
                return i + 1
            }
            while value >= 0b100_0000 {
                arr[i] = UInt8(truncatingIfNeeded: (UInt32(bitPattern: value) & 0x7F) | 0x80)
                i += 1
                value >>= 7
            }
            arr[i] = UInt8(truncatingIfNeeded: value)
            return i + 1
        }

        private func processPosition(_ pos: Int) {
            let diff = UInt16(truncatingIfNeeded: stream.position - pos)
            let streamPos = stream.position
            stream.position = pos
            stream.writeByte(UInt8(diff >> 8))
            stream.writeByte(UInt8(diff & 0xFF))
            stream.position = streamPos
            let crc = DwgCrc.crc8(0xC0C1, stream.bytes[pos...])
            stream.writeByte(UInt8(crc >> 8))
            stream.writeByte(UInt8(crc & 0xFF))
        }
    }

    /// `DwgAuxHeaderWriter`.
    final class DwgAuxHeaderWriter: DwgSectionIO {
        override var sectionName: String { DwgSectionDefinition.auxHeader }
        private let header: CadHeader
        private let writer: DwgStreamWriter

        init(_ stream: DwgMemoryStream, _ header: CadHeader) {
            self.header = header
            writer = DwgStreamWriter(stream)
            super.init(header.version)
        }

        func write() {
            let w = writer
            let versionCode = Int16(header.version.dwgCode)
            w.writeByte(0xFF)
            w.writeByte(0x77)
            w.writeByte(0x01)
            w.writeRawShort(versionCode)
            writeMaintenanceVersion()
            // RL: Number of saves (starts at 1), RL: -1
            w.writeRawLong(1)
            w.writeRawLong(-1)
            // RS: Number of saves part 1, part 2
            w.writeRawShort(1)
            w.writeRawShort(0)
            w.writeRawLong(0)
            w.writeRawShort(versionCode)
            writeMaintenanceVersion()
            w.writeRawShort(versionCode)
            writeMaintenanceVersion()
            w.writeRawShort(0x5)
            w.writeRawShort(2195)
            w.writeRawShort(5)
            w.writeRawShort(2195)
            w.writeRawShort(0)
            w.writeRawShort(1)
            for _ in 0..<5 { w.writeRawLong(0) }
            w.write8BitJulianDate(header.createDateTime)
            w.write8BitJulianDate(header.updateDateTime)
            // RL: HANDSEED if < 0x7fffffff, otherwise -1.
            w.writeRawLong(header.handleSeed <= 0x7FFF_FFFF ? Int64(header.handleSeed) : -1)
            // RL : Educational plot stamp
            w.writeRawLong(0)
            w.writeRawShort(0)
            w.writeRawShort(1)
            w.writeRawLong(0)
            w.writeRawLong(0)
            w.writeRawLong(0)
            // RL: Number of saves
            w.writeRawLong(1)
            for _ in 0..<4 { w.writeRawLong(0) }
            if r2018Plus {
                w.writeRawShort(0)
                w.writeRawShort(0)
                w.writeRawShort(0)
            }
        }

        private func writeMaintenanceVersion() {
            if version > .ac1027 {
                writer.writeRawLong(Int64(header.maintenanceVersion))
            } else {
                writer.writeRawShort(header.maintenanceVersion)
            }
        }
    }

    /// `DwgPreviewWriter.Write()`: an empty preview (Filee never sets `DwgWriter.Preview`).
    enum DwgPreviewWriter {
        static func write(_ stream: DwgMemoryStream) {
            let w = DwgStreamWriter(stream)
            w.writeBytes(DwgSectionDefinition.startSentinels[DwgSectionDefinition.preview]!)
            // overall size RL, images present RC
            w.writeRawLong(1)
            w.writeByte(0)
            w.writeBytes(DwgSectionDefinition.endSentinels[DwgSectionDefinition.preview]!)
        }
    }

    /// `DwgAppInfoWriter`.
    enum DwgAppInfoWriter {
        /// `Assembly.GetExecutingAssembly().GetName().Version` of ACadSharp 3.8.0.
        static var assemblyVersion = "3.8.0.0"

        static func write(_ stream: DwgMemoryStream) throws {
            let w = DwgStreamWriter(stream)
            let version = assemblyVersion
            let empty = [UInt8](repeating: 0, count: 16)
            w.writeInt(3)
            try w.writeTextUnicode("AppInfoDataList")
            w.writeInt(3)
            w.writeBytes(empty)
            try w.writeTextUnicode(version)
            w.writeBytes(empty)
            try w.writeTextUnicode("This is a comment from ACadSharp")
            w.writeBytes(empty)
            try w.writeTextUnicode("<ProductInformation name =\"ACadSharp\" build_version=\"\(version)\" registry_version=\"\(version)\" install_id_string=\"ACadSharp\" registry_localeID=\"1033\"/>")
        }
    }
}

extension ACad.Version {
    /// The `ACadVersion` enum value (AC1032 = 33 …), as the aux header writes it.
    var dwgCode: Int {
        switch self {
        case .ac1012: return 19
        case .ac1014: return 21
        case .ac1015: return 23
        case .ac1018: return 25
        case .ac1021: return 27
        case .ac1024: return 29
        case .ac1027: return 31
        case .ac1032: return 33
        default: return -1
        }
    }
}
