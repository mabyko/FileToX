// ACadSharp 3.8.0 `DwgStreamWriterBase` with the overrides of `DwgStreamWriterAC15` … `DwgStreamWriterAC24`, and the
// `DwgMergedStreamWriter` that splits an object into its data, text and handle streams.
// shortcut: only the AC1024+ behaviour (`DwgStreamWriterAC24`) is ported, the version Filee writes; port the
// AC12–AC21 overrides if older output versions are ever needed.

import Foundation

extension ACad {
    /// `IDwgStreamWriter`.
    protocol DwgBitWriter: AnyObject {
        var main: DwgStreamWriter { get }
        var positionInBits: Int { get }
        var savedPositionInBits: Int { get }
        func handleReference(_ type: DwgReferenceType, _ handle: UInt64)
        func resetStream()
        func savePositionForSize()
        func write2RawDouble(_ value: XY)
        func write2BitDouble(_ value: XY)
        func write3BitDouble(_ value: XYZ)
        func writeBit(_ value: Bool)
        func write2Bits(_ value: UInt8)
        func writeBitDouble(_ value: Double)
        func write2BitDoubleWithDefault(_ def: XY, _ value: XY)
        func write3BitDoubleWithDefault(_ def: XYZ, _ value: XYZ)
        func writeBitDoubleWithDefault(_ def: Double, _ value: Double)
        func writeBitExtrusion(_ value: XYZ)
        func writeBitLong(_ value: Int32)
        func writeBitLongLong(_ value: Int64)
        func writeBitShort(_ value: Int16)
        func writeBitThickness(_ value: Double)
        func writeByte(_ value: UInt8)
        func writeBytes(_ bytes: [UInt8])
        func writeCmColor(_ value: Color)
        func writeEnColor(_ color: Color, _ transparency: Transparency, _ isBookColor: Bool)
        func writeDateTime(_ value: CadDateTime)
        func write8BitJulianDate(_ value: CadDateTime)
        func writeInt(_ value: Int32)
        func writeObjectType(_ value: Int16)
        func writeRawDouble(_ value: Double)
        func writeRawLong(_ value: Int64)
        func writeRawShort(_ value: Int16)
        func writeRawUShort(_ value: UInt16)
        func writeSpearShift() throws
        func writeTimeSpan(_ value: CadTimeSpan)
        func writeVariableText(_ value: String?)
        func writeTextUnicode(_ value: String?) throws
    }

    /// `DwgStreamWriterAC24`.
    final class DwgStreamWriter: DwgBitWriter {
        let stream: DwgMemoryStream
        private(set) var bitShift = 0
        private var lastByte: UInt8 = 0

        init(_ stream: DwgMemoryStream) {
            self.stream = stream
        }

        var main: DwgStreamWriter { self }
        var positionInBits: Int { stream.position * 8 + bitShift }
        let savedPositionInBits = 0

        // ───────── Raw values (`StreamIO.Write` goes to the stream directly, the bit shift is ignored) ─────────

        func writeInt(_ value: Int32) { stream.write(DwgLE.bytes(value)) }

        // ───────── Bit-aligned values ─────────

        func writeObjectType(_ value: Int16) {
            if value <= 255 {
                write2Bits(0)
                writeByte(UInt8(truncatingIfNeeded: value))
            } else if value >= 0x1F0 && value <= 0x2EF {
                write2Bits(1)
                writeByte(UInt8(truncatingIfNeeded: value - 0x1F0))
            } else {
                write2Bits(2)
                writeBytes(DwgLE.bytes(value))
            }
        }

        func writeRawLong(_ value: Int64) { writeBytes(DwgLE.bytes(Int32(truncatingIfNeeded: value))) }

        func writeBytes(_ bytes: [UInt8]) { writeBytes(bytes, 0, bytes.count) }

        func writeBytes(_ arr: [UInt8], _ initialIndex: Int, _ length: Int) {
            if bitShift == 0 {
                stream.write(arr[initialIndex..<(initialIndex + length)])
                return
            }
            let num = 8 - bitShift
            for j in initialIndex..<(initialIndex + length) {
                let b = arr[j]
                stream.writeByte(lastByte | (b >> bitShift))
                lastByte = b << num
            }
        }

        func writeBitShort(_ value: Int16) {
            if value == 0 {
                write2Bits(2)
            } else if value > 0 && value < 256 {
                write2Bits(1)
                writeByte(UInt8(value))
            } else if value == 256 {
                write2Bits(3)
            } else {
                write2Bits(0)
                writeByte(UInt8(truncatingIfNeeded: value))
                writeByte(UInt8(truncatingIfNeeded: value >> 8))
            }
        }

        func writeBitDouble(_ value: Double) {
            if value == 0.0 {
                write2Bits(2)
                return
            }
            if value == 1.0 {
                write2Bits(1)
                return
            }
            write2Bits(0)
            writeBytes(DwgLE.bytes(value))
        }

        func writeBitLong(_ value: Int32) {
            if value == 0 {
                write2Bits(2)
                return
            }
            if value > 0 && value < 256 {
                write2Bits(1)
                writeByte(UInt8(value))
                return
            }
            write2Bits(0)
            writeByte(UInt8(truncatingIfNeeded: value))
            writeByte(UInt8(truncatingIfNeeded: value >> 8))
            writeByte(UInt8(truncatingIfNeeded: value >> 16))
            writeByte(UInt8(truncatingIfNeeded: value >> 24))
        }

        func writeBitLongLong(_ value: Int64) {
            var size: UInt8 = 0
            var hold = UInt64(bitPattern: value)
            while hold != 0 {
                hold >>= 8
                size += 1
            }
            write3Bits(size)
            hold = UInt64(bitPattern: value)
            for _ in 0..<size {
                writeByte(UInt8(hold & 0xFF))
                hold >>= 8
            }
        }

        /// `DwgStreamWriterAC21.WriteVariableText`: UTF-16 code units.
        func writeVariableText(_ value: String?) {
            guard let value, !value.isEmpty else {
                writeBitShort(0)
                return
            }
            let units = Array(value.utf16)
            writeBitShort(Int16(truncatingIfNeeded: units.count))
            writeBytes(units.flatMap { DwgLE.bytes($0) })
        }

        /// `DwgStreamWriterAC21.WriteTextUnicode`: the terminator goes to the stream directly.
        func writeTextUnicode(_ value: String?) throws {
            guard let value else { throw DxfWriteError.nullReference }
            let units = Array(value.utf16)
            writeRawShort(Int16(truncatingIfNeeded: units.count + 1))
            writeBytes(units.flatMap { DwgLE.bytes($0) })
            stream.writeByte(0)
            stream.writeByte(0)
        }

        func write2Bits(_ value: UInt8) {
            if bitShift < 6 {
                lastByte |= value << (6 - bitShift)
                bitShift += 2
            } else if bitShift == 6 {
                lastByte |= value
                stream.writeByte(lastByte)
                resetShift()
            } else {
                lastByte |= value >> 1
                stream.writeByte(lastByte)
                lastByte = value << 7
                bitShift = 1
            }
        }

        func writeBit(_ value: Bool) {
            if bitShift < 7 {
                if value { lastByte |= 1 << (7 - bitShift) }
                bitShift += 1
                return
            }
            if value { lastByte |= 1 }
            stream.writeByte(lastByte)
            resetShift()
        }

        func writeByte(_ value: UInt8) {
            if bitShift == 0 {
                stream.writeByte(value)
                return
            }
            let shift = 8 - bitShift
            stream.writeByte(lastByte | (value >> bitShift))
            lastByte = value << shift
        }

        private func resetShift() {
            bitShift = 0
            lastByte = 0
        }

        func writeDateTime(_ value: CadDateTime) {
            let j = value.dwgJulian
            writeBitLong(j.jdate)
            writeBitLong(j.milliseconds)
        }

        /// `WriteTimeSpan`: the `Days` and `Milliseconds` components.
        func writeTimeSpan(_ value: CadTimeSpan) {
            writeBitLong(Int32(truncatingIfNeeded: value.ticks / CadDateTime.ticksPerDay))
            writeBitLong(Int32(truncatingIfNeeded: (value.ticks / CadDateTime.ticksPerMillisecond) % 1000))
        }

        func write8BitJulianDate(_ value: CadDateTime) {
            let j = value.dwgJulian
            writeRawLong(Int64(j.jdate))
            writeRawLong(Int64(j.milliseconds))
        }

        /// `DwgStreamWriterAC18.WriteCmColor`.
        func writeCmColor(_ value: Color) {
            writeBitShort(0)
            var arr = [UInt8](repeating: 0, count: 4)
            if value.isTrueColor {
                arr[2] = value.r
                arr[1] = value.g
                arr[0] = value.b
                arr[3] = 0b1100_0010
            } else if value.isByLayer {
                arr[3] = 0b1100_0000
            } else {
                arr[3] = 0b1100_0011
                arr[0] = UInt8(truncatingIfNeeded: value.index)
            }
            writeBitLong(Int32(bitPattern: UInt32(arr[0]) | UInt32(arr[1]) << 8 | UInt32(arr[2]) << 16 | UInt32(arr[3]) << 24))
            writeByte(0)
        }

        /// `DwgStreamWriterAC18.WriteEnColor(color, transparency, isBookColor)`.
        func writeEnColor(_ color: Color, _ transparency: Transparency, _ isBookColor: Bool) {
            var size: UInt16 = 0
            if color.isByBlock && transparency.isByLayer && !isBookColor {
                writeBitShort(0)
                return
            }
            if !transparency.isByLayer { size |= 0b10_0000_0000_0000 }
            if isBookColor {
                size |= 0x4000
                size |= 0x8000
            } else if color.isTrueColor {
                size |= 0x8000
            } else {
                size |= UInt16(bitPattern: color.index)
            }
            writeBitShort(Int16(bitPattern: size))
            if color.isTrueColor {
                writeBitLong(Int32(bitPattern: UInt32(color.b) | UInt32(color.g) << 8 | UInt32(color.r) << 16 | 0b1100_0010 << 24))
            }
            if !transparency.isByLayer {
                writeBitLong(Transparency.toAlphaValue(transparency))
            }
        }

        func write2BitDouble(_ value: XY) {
            writeBitDouble(value.x)
            writeBitDouble(value.y)
        }

        func write3BitDouble(_ value: XYZ) {
            writeBitDouble(value.x)
            writeBitDouble(value.y)
            writeBitDouble(value.z)
        }

        func write2RawDouble(_ value: XY) {
            writeRawDouble(value.x)
            writeRawDouble(value.y)
        }

        func writeRawShort(_ value: Int16) { writeBytes(DwgLE.bytes(value)) }
        func writeRawUShort(_ value: UInt16) { writeBytes(DwgLE.bytes(value)) }
        func writeRawDouble(_ value: Double) { writeBytes(DwgLE.bytes(value)) }

        func handleReference(_ type: DwgReferenceType, _ handle: UInt64) {
            let b = type.rawValue << 4
            if handle == 0 {
                writeByte(b)
                return
            }
            var count = 0
            var hold = handle
            while hold != 0 {
                hold >>= 8
                count += 1
            }
            writeByte(b | UInt8(count))
            for i in stride(from: count - 1, through: 0, by: -1) {
                writeByte(UInt8(truncatingIfNeeded: handle >> UInt64(8 * i)))
            }
        }

        func writeSpearShift() {
            if bitShift > 0 {
                for _ in bitShift..<8 { writeBit(false) }
            }
        }

        /// `DwgStreamWriterAC15.WriteBitThickness`.
        func writeBitThickness(_ thickness: Double) {
            if thickness == 0.0 {
                writeBit(true)
                return
            }
            writeBit(false)
            writeBitDouble(thickness)
        }

        /// `DwgStreamWriterAC15.WriteBitExtrusion`.
        func writeBitExtrusion(_ normal: XYZ) {
            if normal == XYZ.axisZ {
                writeBit(true)
                return
            }
            writeBit(false)
            write3BitDouble(normal)
        }

        func write2BitDoubleWithDefault(_ def: XY, _ value: XY) {
            writeBitDoubleWithDefault(def.x, value.x)
            writeBitDoubleWithDefault(def.y, value.y)
        }

        func write3BitDoubleWithDefault(_ def: XYZ, _ value: XYZ) {
            writeBitDoubleWithDefault(def.x, value.x)
            writeBitDoubleWithDefault(def.y, value.y)
            writeBitDoubleWithDefault(def.z, value.z)
        }

        /// ACadSharp writes the bytes of the default, not of the value (kept as is: readers then get the default).
        func writeBitDoubleWithDefault(_ def: Double, _ value: Double) {
            if def == value {
                write2Bits(0)
                return
            }
            let defBytes = DwgLE.bytes(def)
            let valueBytes = DwgLE.bytes(value)
            var first = 0
            var last = 7
            while last >= 0 && defBytes[last] == valueBytes[last] {
                first += 1
                last -= 1
            }
            if first >= 4 {
                write2Bits(1)
                writeBytes(defBytes, 0, 4)
            } else if first >= 2 {
                write2Bits(2)
                writeByte(defBytes[4])
                writeByte(defBytes[5])
                writeByte(defBytes[0])
                writeByte(defBytes[1])
                writeByte(defBytes[2])
                writeByte(defBytes[3])
            } else {
                write2Bits(3)
                writeBytes(defBytes)
            }
        }

        func resetStream() {
            stream.position = 0
            resetShift()
            stream.setLength(0)
        }

        func savePositionForSize() { writeRawLong(0) }

        func setPositionByFlag(_ pos: Int) {
            if pos >= 0x8000 {
                if pos >= 0x4000_0000 {
                    writeBytes(DwgLE.bytes(UInt16(truncatingIfNeeded: (pos >> 30) & 0xFFFF)))
                    writeBytes(DwgLE.bytes(UInt16(truncatingIfNeeded: ((pos >> 15) & 0x7FFF) | 0x8000)))
                } else {
                    writeBytes(DwgLE.bytes(UInt16(truncatingIfNeeded: (pos >> 15) & 0xFFFF)))
                }
                writeBytes(DwgLE.bytes(UInt16(truncatingIfNeeded: (pos & 0x7FFF) | 0x8000)))
            } else {
                writeBytes(DwgLE.bytes(UInt16(truncatingIfNeeded: pos)))
            }
        }

        func setPositionInBits(_ posInBits: Int) throws {
            let position = posInBits / 8
            bitShift = posInBits % 8
            stream.position = position
            if bitShift > 0 {
                let value = stream.readByte()
                guard value >= 0 else { throw DwgError.endOfStream }
                lastByte = UInt8(value)
            } else {
                lastByte = 0
            }
            stream.position = position
        }

        func writeShiftValue() {
            if bitShift > 0 {
                let position = stream.position
                let lastValue = stream.readByte()
                let currValue = lastByte | (UInt8(truncatingIfNeeded: lastValue) & (0b1111_1111 >> UInt8(bitShift)))
                stream.position = position
                stream.writeByte(currValue)
            }
        }

        private func write3Bits(_ value: UInt8) {
            writeBit(value & 4 != 0)
            writeBit(value & 2 != 0)
            writeBit(value & 1 != 0)
        }
    }

    /// `DwgMergedStreamWriter`.
    final class DwgMergedStreamWriter: DwgBitWriter {
        let main: DwgStreamWriter
        let textWriter: DwgStreamWriter
        let handleWriter: DwgStreamWriter
        private(set) var savedPositionInBits = 0
        private(set) var positionInBits = 0
        private var savedPosition = false

        init(_ main: DwgStreamWriter, _ textWriter: DwgStreamWriter, _ handleWriter: DwgStreamWriter) {
            self.main = main
            self.textWriter = textWriter
            self.handleWriter = handleWriter
        }

        /// `GetMergedWriter(AC1024+, stream)`.
        convenience init(_ stream: DwgMemoryStream) {
            self.init(DwgStreamWriter(stream), DwgStreamWriter(DwgMemoryStream()), DwgStreamWriter(DwgMemoryStream()))
        }

        func handleReference(_ type: DwgReferenceType, _ handle: UInt64) { handleWriter.handleReference(type, handle) }

        func resetStream() {
            main.resetStream()
            textWriter.resetStream()
            handleWriter.resetStream()
        }

        func savePositionForSize() {
            savedPosition = true
            positionInBits = main.positionInBits
            main.writeRawLong(0)
        }

        func write2RawDouble(_ value: XY) { main.write2RawDouble(value) }
        func write2BitDouble(_ value: XY) { main.write2BitDouble(value) }
        func write3BitDouble(_ value: XYZ) { main.write3BitDouble(value) }
        func writeBit(_ value: Bool) { main.writeBit(value) }
        func write2Bits(_ value: UInt8) { main.write2Bits(value) }
        func writeBitDouble(_ value: Double) { main.writeBitDouble(value) }
        func write2BitDoubleWithDefault(_ def: XY, _ value: XY) { main.write2BitDoubleWithDefault(def, value) }
        func write3BitDoubleWithDefault(_ def: XYZ, _ value: XYZ) { main.write3BitDoubleWithDefault(def, value) }
        func writeBitDoubleWithDefault(_ def: Double, _ value: Double) { main.writeBitDoubleWithDefault(def, value) }
        func writeBitExtrusion(_ value: XYZ) { main.writeBitExtrusion(value) }
        func writeBitLong(_ value: Int32) { main.writeBitLong(value) }
        func writeBitLongLong(_ value: Int64) { main.writeBitLongLong(value) }
        func writeBitShort(_ value: Int16) { main.writeBitShort(value) }
        func writeBitThickness(_ value: Double) { main.writeBitThickness(value) }
        func writeByte(_ value: UInt8) { main.writeByte(value) }
        func writeBytes(_ bytes: [UInt8]) { main.writeBytes(bytes) }
        func writeBytes(_ bytes: [UInt8], _ offset: Int, _ length: Int) { main.writeBytes(bytes, offset, length) }
        /// The main writer is an AC18 writer, so this is `DwgStreamWriterAC18.WriteCmColor`.
        func writeCmColor(_ value: Color) { main.writeCmColor(value) }
        func writeEnColor(_ color: Color, _ transparency: Transparency, _ isBookColor: Bool) {
            main.writeEnColor(color, transparency, isBookColor)
        }
        func writeDateTime(_ value: CadDateTime) { main.writeDateTime(value) }
        func write8BitJulianDate(_ value: CadDateTime) { main.write8BitJulianDate(value) }
        func writeInt(_ value: Int32) { main.writeInt(value) }
        func writeObjectType(_ value: Int16) { main.writeObjectType(value) }
        func writeRawDouble(_ value: Double) { main.writeRawDouble(value) }
        func writeRawLong(_ value: Int64) { main.writeRawLong(value) }
        func writeRawShort(_ value: Int16) { main.writeRawShort(value) }
        func writeRawUShort(_ value: UInt16) { main.writeRawUShort(value) }
        func writeTimeSpan(_ value: CadTimeSpan) { main.writeTimeSpan(value) }
        func writeVariableText(_ value: String?) { textWriter.writeVariableText(value) }
        func writeTextUnicode(_ value: String?) throws { try textWriter.writeTextUnicode(value) }

        func writeSpearShift() throws {
            let mainSizeBits = main.positionInBits
            let textSizeBits = textWriter.positionInBits
            main.writeSpearShift()
            if savedPosition {
                var mainTextTotalBits = Int32(truncatingIfNeeded: mainSizeBits + textSizeBits + 1)
                if textSizeBits > 0 {
                    mainTextTotalBits += 16
                    if textSizeBits >= 0x8000 {
                        mainTextTotalBits += 16
                        if textSizeBits >= 0x4000_0000 { mainTextTotalBits += 16 }
                    }
                }
                try main.setPositionInBits(positionInBits)
                main.writeRawLong(Int64(mainTextTotalBits))
                main.writeShiftValue()
            }
            try main.setPositionInBits(mainSizeBits)
            if textSizeBits > 0 {
                textWriter.writeSpearShift()
                main.writeBytes(textWriter.stream.bytes)
                main.writeSpearShift()
                try main.setPositionInBits(mainSizeBits + textSizeBits)
                main.setPositionByFlag(textSizeBits)
                main.writeBit(true)
            } else {
                main.writeBit(false)
            }
            handleWriter.writeSpearShift()
            savedPositionInBits = main.positionInBits
            main.writeBytes(handleWriter.stream.bytes)
            main.writeSpearShift()
        }
    }
}
