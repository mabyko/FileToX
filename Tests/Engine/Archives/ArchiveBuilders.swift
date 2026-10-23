// Port of tests/Filee.Engines.Tests/ArchiveBuilders.cs: builds archive test inputs in code: folder trees with Korean
// names, ZIPs (ZipWriter), TARs (a small ustar writer), ALZ and EGG files written per their format documentation (see
// AlzReader / EggReader), lzip files, and raw bzip2 / LZMA streams taken from what the bundled 7-Zip writes. Also the
// test side of the job queue: an output allocator with Filee's naming rules and the "Extract" / "Zip all" presets.

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FileToXEngineKit

enum ArchiveBuilders {
    /// A fixed modification time (local) for checking that times survive.
    static let knownTime: Date = ZipReader.dosCalendar.date(from: DateComponents(year: 2021, month: 5, day: 6, hour: 7, minute: 8, second: 10))!

    /// Creates `name` below `parent` with a Korean file name, a nested folder with a Korean name, an empty folder, and a
    /// file with `knownTime`.
    @discardableResult
    static func makeTree(_ parent: String, _ name: String) throws -> String {
        let root = FilePath.combine(parent, name)
        try FileManager.default.createDirectoryIfNeeded(FilePath.combine(root, "docs", "보고서"))
        try FileManager.default.createDirectoryIfNeeded(FilePath.combine(root, "empty"))
        try write(FilePath.combine(root, "readme.txt"), "Filee archive test\n")
        try write(FilePath.combine(root, "한글 문서.txt"), "안녕하세요, archive 文件")
        try write(FilePath.combine(root, "docs", "보고서", "data.csv"), "a,b\n1,2\n")
        try noise(200_000, 7).write(to: URL(fileURLWithPath: FilePath.combine(root, "docs", "noise.bin")))
        try ArchiveFiles.setModificationDate(FilePath.combine(root, "readme.txt"), knownTime)
        return root
    }

    static func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }

    static func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }

    static func readText(_ path: String) throws -> String { String(decoding: try read(path), as: UTF8.self) }

    /// Relative path → SHA-256 of every file below `root`, and "dir/" for empty folders.
    static func snapshot(_ root: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let fm = FileManager.default
        for relative in try fm.subpathsOfDirectory(atPath: root) {
            let path = FilePath.combine(root, relative)
            if fm.directoryExists(path) {
                if try fm.contentsOfDirectory(atPath: path).isEmpty { result[relative + "/"] = "" }
            } else {
                result[relative] = SHA256.hash(data: try read(path)).map { String(format: "%02X", $0) }.joined()
            }
        }
        return result
    }

    /// Names in a folder, sorted ordinally (UTF-16).
    static func entries(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    /// Pseudo-random bytes (compress badly, like photos).
    static func noise(_ length: Int, _ seed: UInt64) -> Data {
        var generator = SplitMix(seed)
        return Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// Text that compresses well but not trivially (for multi-block bzip2).
    static func words(_ length: Int) -> Data {
        var generator = SplitMix(42)
        let words = ["파일", "변환", "archive", "Filee", "압축", "folder", "데이터", "zip", "문서", "7-Zip", "\n"]
        var bytes = Data()
        bytes.reserveCapacity(length + 32)
        while bytes.count < length { bytes.append(Data((words.randomElement(using: &generator)! + " ").utf8)) }
        return bytes.prefix(length)
    }

    /// A seeded generator (SplitMix64), so test data is the same on every run.
    struct SplitMix: RandomNumberGenerator {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // ───────── 7-Zip ─────────

    /// The bundled 7-Zip, or nil when engines/7zip is missing.
    static var sevenZipExe: String? { SevenZip.locate()?.executable }

    /// Runs 7-Zip with the given arguments and fails the test on an error.
    static func run7z(_ args: String...) async throws {
        let result = try await ProcessRunner.run(try XCTUnwrap(sevenZipExe), args, timeout: 120)
        XCTAssertEqual(result.exitCode, 0, "7z \(args.joined(separator: " ")): \(result.standardOutput) \(result.standardError)")
    }

    /// Standard bzip2 stream of `data` written by 7-Zip at level 9 ("BZh9", 900k blocks).
    static func bzip2(_ data: Data, _ workDir: String) async throws -> Data {
        let dir = FilePath.combine(workDir, "bz-" + ArchiveFiles.guid().prefix(6))
        try FileManager.default.createDirectoryIfNeeded(dir)
        let input = FilePath.combine(dir, "data.bin")
        try data.write(to: URL(fileURLWithPath: input))
        let output = FilePath.combine(dir, "data.bz2")
        try await run7z("a", "-tbzip2", "-mx9", "-mmt=off", output, input)
        return try read(output)
    }

    /// A raw LZMA stream (lc=3, lp=0, pb=2, 1 MiB dictionary) of `data`: 7-Zip writes it into a .7z without header
    /// compression, where the only packed stream starts at offset 32 and is as long as the "next header offset" of the
    /// signature header says.
    static func rawLzma(_ data: Data, endMarker: Bool, _ workDir: String) async throws -> Data {
        let dir = FilePath.combine(workDir, "lzma-" + ArchiveFiles.guid().prefix(6))
        try FileManager.default.createDirectoryIfNeeded(dir)
        let input = FilePath.combine(dir, "data.bin")
        try data.write(to: URL(fileURLWithPath: input))
        let output = FilePath.combine(dir, "data.7z")
        try await run7z("a", "-t7z", "-m0=LZMA:d=1m:lc=3:lp=0:pb=2" + (endMarker ? ":eos" : ""), "-mhc=off", "-mf=off", "-ms=off",
                        "-mmt=off", output, input)
        let archive = try read(output)
        let packedSize = Int(BinaryPrimitives.readInt64LittleEndian(archive, 12))
        return archive.subdata(in: 32..<(32 + packedSize))
    }

    /// An lzip member of `data` (see LzipReader).
    static func lzip(_ data: Data, _ workDir: String) async throws -> Data {
        let lzma = try await rawLzma(data, endMarker: true, workDir)
        let writer = BinaryWriter()
        writer.write(Data("LZIP".utf8))
        writer.write(UInt8(1))
        writer.write(UInt8(20)) // 2^20 = 1 MiB dictionary
        writer.write(lzma)
        writer.write(ArchiveCrc32.compute(data))
        writer.write(Int64(data.count))
        writer.write(Int64(6 + lzma.count + 20))
        return writer.data
    }

    /// Rewrites a standard bzip2 stream into ALZip's framing: no "BZh9", "DLZ\x01" instead of each block's magic, CRC
    /// and randomised bit, "DLZ\x02" instead of the end magic and combined CRC. Blocks are found by their 48-bit magic.
    static func toAlzBzip2(_ standard: Data) throws -> Data {
        XCTAssertEqual(standard.prefix(4), Data("BZh9".utf8))
        let bytes = [UInt8](standard)
        var bits = [Bool](repeating: false, count: bytes.count * 8)
        for i in 0..<bits.count { bits[i] = bytes[i >> 3] & (0x80 >> UInt8(i & 7)) != 0 }

        let blockMagic: UInt64 = 0x314159265359, endMagic: UInt64 = 0x177245385090
        func read48(_ at: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<48 { v = (v << 1) | (bits[at + i] ? 1 : 0) }
            return v
        }
        var output: [Bool] = []
        func write(_ value: UInt32, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { output.append((value >> UInt32(i)) & 1 != 0) }
        }

        var pos = 32
        while true {
            let magic = read48(pos)
            if magic == endMagic {
                write(0x444C5A02, 32)
                break
            }
            XCTAssertEqual(magic, blockMagic)
            write(0x444C5A01, 32)
            pos += 48 + 32 + 1
            var next = pos
            var window = read48(next)
            while window != blockMagic && window != endMagic {
                window = ((window << 1) | (bits[next + 48] ? 1 : 0)) & 0xFFFF_FFFF_FFFF
                next += 1
            }
            output.append(contentsOf: bits[pos..<next])
            pos = next
        }

        var result = [UInt8](repeating: 0, count: (output.count + 7) / 8)
        for (i, bit) in output.enumerated() where bit { result[i >> 3] |= 0x80 >> UInt8(i & 7) }
        return Data(result)
    }

    /// One entry of a test ALZ file. `method`: 0 store, 1 ALZ bzip2 (`packed` must be given), 2 deflate.
    struct AlzItem {
        var name: String
        var data: Data?
        var method = 0
        var packed: Data?
        var encrypted = false
    }

    /// Writes an ALZ archive; names are stored in CP949 like ALZip does.
    static func writeAlz(_ path: String, _ items: [AlzItem]) throws {
        let w = BinaryWriter()
        w.write(Data("ALZ\u{1}".utf8))
        w.write([0x0A, 0, 0, 0] as [UInt8])
        for item in items {
            let name = TextEncodings.encode(item.name, encoding: try XCTUnwrap(TextEncodings.encoding(codePage: 949)))
            let packed: Data = try item.data.map { data in
                switch item.method {
                case 0: data
                case 1: try XCTUnwrap(item.packed)
                default: try deflate(data)
                }
            } ?? Data()
            w.write(Data("BLZ\u{1}".utf8))
            w.write(UInt16(name.count))
            w.write(UInt8(item.data == nil ? 0x10 : 0x20))
            w.write(dosTime(knownTime))
            w.write(UInt8((item.data == nil ? 0x00 : 0x40) | (item.encrypted ? 1 : 0)))
            w.write(UInt8(0))
            if let data = item.data {
                w.write(UInt8(item.method))
                w.write(UInt8(0))
                w.write(ArchiveCrc32.compute(data))
                w.write(Int32(packed.count))
                w.write(Int32(data.count))
            }
            w.write(name)
            if item.encrypted { w.write(Data(count: 12)) }
            w.write(packed)
        }
        w.write(Data("CLZ\u{1}".utf8))
        w.write(Data(count: 12))
        w.write(Data("CLZ\u{2}".utf8))
        w.write(Data(count: 12))
        try w.data.write(to: URL(fileURLWithPath: path))
    }

    /// One block of a test EGG entry. `method`: 0 store, 1 deflate, 2 bzip2, 4 LZMA (`packed` given for 2 and 4).
    struct EggBlock {
        var data: Data
        var method: Int
        var packed: Data?
    }

    /// One entry of a test EGG file; no blocks for folders.
    struct EggItem {
        var name: String
        var folder: Bool
        var blocks: [EggBlock] = []
    }

    /// Writes an EGG archive (UTF-8 names, Windows file info with `knownTime`).
    static func writeEgg(_ path: String, _ items: [EggItem], solid: Bool = false) throws {
        let end: UInt32 = 0x08E28222
        let w = BinaryWriter()
        w.write(UInt32(0x41474745))
        w.write(UInt16(0x0100))
        w.write(UInt32(0x12345678))
        w.write(UInt32(0))
        if solid {
            w.write(UInt32(0x24E5A060))
            w.write(UInt8(0))
            w.write(UInt16(0))
        }
        w.write(end)

        var id: UInt32 = 0
        for item in items {
            w.write(UInt32(0x0A8590E3))
            w.write(id)
            id += 1
            w.write(Int64(item.blocks.reduce(0) { $0 + $1.data.count }))

            let name = Data(item.name.utf8)
            w.write(UInt32(0x0A8591AC))
            w.write(UInt8(0))
            w.write(UInt16(name.count))
            w.write(name)

            w.write(UInt32(0x2C86950B))
            w.write(UInt8(0))
            w.write(UInt16(9))
            w.write(Int64(knownTime.timeIntervalSince1970 * 10_000_000) + 116_444_736_000_000_000) // FILETIME
            w.write(UInt8(item.folder ? 0x10 : 0x20))
            w.write(end)

            for block in item.blocks {
                let packed = block.method == 0 ? block.data : block.method == 1 ? try deflate(block.data) : try XCTUnwrap(block.packed)
                w.write(UInt32(0x02B50C13))
                w.write(UInt8(block.method))
                w.write(UInt8(0))
                w.write(UInt32(block.data.count))
                w.write(UInt32(packed.count))
                w.write(ArchiveCrc32.compute(block.data))
                w.write(end)
                w.write(packed)
            }
        }
        w.write(end)
        try w.data.write(to: URL(fileURLWithPath: path))
    }

    /// EGG's LZMA block layout: ZIP's 4-byte LZMA header, 5 property bytes, raw data.
    static func eggLzma(_ rawLzma: Data) -> Data {
        Data([9, 20, 5, 0, 0x5D, 0x00, 0x00, 0x10, 0x00]) + rawLzma // version 9.20, 5 property bytes, 1 MiB dictionary
    }

    static func deflate(_ data: Data) throws -> Data { try Deflate.deflate(data, level: 6) }

    private static func dosTime(_ t: Date) -> UInt32 {
        let c = ZipReader.dosCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
        return UInt32((c.year! - 1980) << 25 | c.month! << 21 | c.day! << 16 | c.hour! << 11 | c.minute! << 5 | c.second! / 2)
    }

    // ───────── ZIP and TAR inputs ─────────

    /// ZipFile.CreateFromDirectory: every file and empty folder, optionally below the folder's own name.
    static func zipDirectory(_ directory: String, _ zip: String, level: ZipCompressionLevel = .optimal,
                             includeBaseDirectory: Bool) throws {
        let writer = try ZipWriter(path: zip)
        let base = includeBaseDirectory ? FilePath.fileName(directory) + "/" : ""
        for relative in try FileManager.default.subpathsOfDirectory(atPath: directory).sorted() {
            let path = FilePath.combine(directory, relative)
            if FileManager.default.directoryExists(path) {
                if try FileManager.default.contentsOfDirectory(atPath: path).isEmpty { try writer.addDirectory(base + relative + "/") }
            } else {
                try writer.add(base + relative, contentsOf: path, level: level)
            }
        }
        try writer.close()
    }

    /// One entry of a test TAR: regular file ("0"), folder ("5") or symbolic link ("2").
    struct TarItem {
        var name: String
        var type: Character = "0"
        var data = Data()
        var link = ""
        var mode = 0o644
    }

    /// A plain ustar archive (names up to 100 bytes) with the given entries and the two empty end records.
    static func tar(_ items: [TarItem]) -> Data {
        var archive = Data()
        for item in items {
            var block = Data(count: 512)
            func put(_ text: String, _ offset: Int) { block.replaceSubrange(offset..<offset + text.utf8.count, with: Data(text.utf8)) }
            func octal(_ value: Int, _ digits: Int) -> String {
                let text = String(value, radix: 8)
                return String(repeating: "0", count: digits - text.count) + text + "\0"
            }
            put(item.name, 0)
            put(octal(item.mode, 7), 100)
            put(octal(0, 7), 108)
            put(octal(0, 7), 116)
            put(octal(item.data.count, 11), 124)
            put(octal(Int(knownTime.timeIntervalSince1970), 11), 136)
            put("        ", 148)
            put(String(item.type), 156)
            put(item.link, 157)
            put("ustar\u{0}00", 257)
            let sum = block.reduce(0) { $0 + Int($1) }
            put(String(repeating: "0", count: 6 - String(sum, radix: 8).count) + String(sum, radix: 8) + "\0 ", 148)
            archive.append(block)
            archive.append(item.data)
            if item.data.count % 512 != 0 { archive.append(Data(count: 512 - item.data.count % 512)) }
        }
        return archive + Data(count: 1024)
    }

    /// TarFile.CreateFromDirectory without the base folder: every folder and file below `directory`.
    static func tar(directory: String) throws -> Data {
        var items: [TarItem] = []
        for relative in try FileManager.default.subpathsOfDirectory(atPath: directory).sorted() {
            let path = FilePath.combine(directory, relative)
            if FileManager.default.directoryExists(path) {
                items.append(TarItem(name: relative + "/", type: "5", mode: 0o755))
            } else {
                items.append(TarItem(name: relative, data: try read(path)))
            }
        }
        return tar(items)
    }

    /// gzip-compressed bytes (GZipStream).
    static func gzip(_ data: Data) throws -> Data { try Deflate.deflate(data, level: 1, windowBits: 31) }

    /// A 320×200 PNG gradient.
    static func png(_ folder: String, _ name: String) throws -> String {
        let width = 320, height = 200
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.6, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let path = FilePath.combine(folder, name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return path
    }

    // ───────── The job queue's part ─────────

    /// Filee's built-in "Extract" preset.
    static var extract: Preset {
        var preset = Preset()
        preset.targetFormat = FormatRegistry.folder
        return preset
    }

    /// Filee's built-in "Compress into one archive" preset (zip-all).
    static var zipAll: Preset {
        var preset = Preset()
        preset.targetFormat = "zip"
        preset.archive.combineIntoOne = true
        preset.output.fileNamePattern = "{name}_files"
        return preset
    }

    static func preset(_ target: String, level: ArchiveLevel = .normal, pattern: String = "{name}") -> Preset {
        var preset = Preset()
        preset.targetFormat = target
        preset.archive.level = level
        preset.output.fileNamePattern = pattern
        return preset
    }

    /// Output paths next to the source as Filee's OutputPathResolver names them ({name} pattern, conflict policy).
    final class Output: OutputAllocator {
        private let source: String
        private let rule: OutputRule
        private(set) var allocated: [String] = []

        init(_ source: String, _ rule: OutputRule) {
            self.source = source
            self.rule = rule
        }

        func allocate(_ extension: String, suffix: String?) throws -> String? {
            let dir = FilePath.directoryName(FilePath.fullPath(source)) ?? "/"
            let name = rule.fileNamePattern.replacingOccurrences(of: "{name}", with: FormatRegistry.nameWithoutExtension(source)) + (suffix ?? "")
            func path(_ base: String) -> String { FilePath.combine(dir, `extension`.isEmpty ? base : "\(base).\(`extension`)") }
            var candidate = path(name)
            if ArchiveFiles.exists(candidate) {
                switch rule.conflict {
                case .overwrite: break
                case .skip: return nil
                case .rename:
                    var n = 2
                    while ArchiveFiles.exists(path("\(name) (\(n))")) { n += 1 }
                    candidate = path("\(name) (\(n))")
                }
            }
            allocated.append(candidate)
            return candidate
        }
    }

    /// One conversion step as the job queue runs it (the step's format comes from the extension).
    static func convert(_ converter: Converter, _ source: String, _ preset: Preset, work: String,
                        progress: ProgressHandler? = nil) async throws -> [String] {
        let from = try XCTUnwrap(FormatRegistry.detect(source)?.id, "no format for \(source)")
        let step = ConversionStep(inputPath: source, from: from, to: preset.targetFormat, preset: preset,
                                  output: Output(source, preset.output), workDirectory: work)
        return try await converter.convert(step, progress: progress)
    }

    /// "Compress into one archive": one output named after the first file, as the job queue allocates it.
    static func combine(_ combiner: FileCombiner, _ sources: [String], _ preset: Preset, work: String) async throws -> String {
        let format = FormatRegistry.get(preset.targetFormat)
        let output = try XCTUnwrap(try Output(sources[0], preset.output).allocate(format.primaryExtension))
        try await combiner.combine(sources, into: output, format: format.id, preset: preset, workDirectory: work, progress: nil)
        return output
    }

    /// The cheapest route of at most three steps over `edges` (the planner, for one engine), or nil.
    static func route(_ from: String, _ to: String, _ edges: [ConversionEdge]) -> [ConversionEdge]? {
        var best: [ConversionEdge]?
        func walk(_ at: String, _ path: [ConversionEdge]) {
            if at == to, !path.isEmpty {
                if best == nil || path.reduce(0, { $0 + $1.cost }) < best!.reduce(0, { $0 + $1.cost }) { best = path }
                return
            }
            guard path.count < 3 else { return }
            for edge in edges where edge.from == at && !path.contains(where: { $0.from == edge.to }) { walk(edge.to, path + [edge]) }
        }
        walk(from, [])
        return best
    }

    /// Unpacks a ZIP with the foundation reader (Filee checked with .NET's ZipFile.ExtractToDirectory).
    static func unzip(_ zip: String, _ target: String) throws {
        let reader = try ZipReader(path: zip)
        for entry in reader.entries {
            let path = FilePath.combine(target, entry.name)
            if entry.isDirectory {
                try FileManager.default.createDirectoryIfNeeded(path)
                continue
            }
            try FileManager.default.createDirectoryIfNeeded(FilePath.directoryName(path)!)
            try reader.extract(entry, to: path)
            try ArchiveFiles.setModificationDate(path, entry.modificationDate)
        }
    }
}
