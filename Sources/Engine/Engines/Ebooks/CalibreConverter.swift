// Port of Filee.Engines/Ebooks/CalibreConverter.cs.
import Foundation

public final class CalibreConverter: Converter {
    static let inputs = ["lit", "lrf", "chm", "pdb", "pml", "rb", "snb", "tcr", "oeb"]
    static let outputs = ["mobi", "azw3", "lit", "lrf", "pml", "rb", "snb", "tcr"]
    private var executable: String?
    public let id = "calibre"
    public let displayName = "Calibre"
    public let maxParallelism = 2
    public let edges = inputs.map { ConversionEdge($0, "epub", 20) } + outputs.map { ConversionEdge("epub", $0, 20) }
    public init() {}

    public func status() -> EngineStatus {
        executable = Self.locate()
        return executable.map { .available(detail: $0, version: EngineEnvironment.usesBundledCopy("calibre") ? EngineVersions.component("calibre") : nil) } ?? .unavailable("engine.reason.not_installed")
    }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        guard let executable = executable ?? Self.locate() else { throw ConversionError("Calibre is not installed.") }
        let work = try EbookFiles.newFolder(step.workDirectory, "calibre")
        var input = step.inputPath
        if !input.lowercased().hasSuffix(".opf") {
            input = FilePath.combine(work, "input." + (step.from == "oeb" ? "zip" : step.from))
            try FileManager.default.copyItem(atPath: step.inputPath, toPath: input)
            if step.from == "pml" { try PmlPackage.copyInputImages(step.inputPath, beside: input) }
        }
        let temp = FilePath.combine(work, "output." + (step.to == "pml" ? "pmlz" : step.to))
        var environment = ["CALIBRE_OVERRIDE_LANG": "en", "PYTHONIOENCODING": "utf-8"]
        for (key, name) in [("CALIBRE_CONFIG_DIRECTORY", "config"), ("CALIBRE_CACHE_DIRECTORY", "cache"), ("CALIBRE_TEMP_DIR", "temp")] {
            let folder = FilePath.combine(work, name)
            try FileManager.default.createDirectoryIfNeeded(folder); environment[key] = folder
        }
        progress?(0.02)
        let rawText = FilePath.combine(work, "tcr-text.bin")
        let folder = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent().path
        let debug = FilePath.combine(folder, "calibre-debug")
        guard FileManager.default.isExecutableFile(atPath: debug) else {
            let operation = step.to == "tcr" ? "Safe TCR output" : "E-book style preservation"
            throw ConversionError("\(operation) requires calibre-debug beside ebook-convert. Select a complete Calibre installation in Settings.")
        }
        let script = FilePath.combine(work, "convert.py")
        try Data(Self.conversionScript.utf8).write(to: URL(fileURLWithPath: script))
        var arguments = ["-e", script, "--", input, temp]
        if step.to == "tcr" { arguments.append(rawText) }
        let result = try await ProcessRunner.run(debug, arguments, timeout: 600, workingDirectory: work, environment: environment, onOutput: { Self.reportProgress($0, progress) })
        guard result.exitCode == 0, FileManager.default.fileExists(temp) else {
            let output = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.standardOutput : result.standardError
            throw ConversionError("Calibre failed (exit \(result.exitCode)). \(Self.lastLines(output))")
        }
        if step.to == "tcr" {
            let text = try Data(contentsOf: URL(fileURLWithPath: rawText))
            let encoded = try TcrWriter.encode(text)
            try encoded.write(to: URL(fileURLWithPath: temp))
        }
        let pml = step.to == "pml" ? try PmlPackage.unpack(temp, in: work) : nil
        try Task.checkCancellation()
        guard let output = try step.output.allocate(step.to) else { return [] }
        if let pml { try PmlPackage.publish(pml, to: output) }
        else { try EbookFiles.replace(temp, output) }
        progress?(1)
        return [output]
    }
    // shortcut: Calibre's CSS transform drops non-spine styles; remove this child-only patch when upstream preserves them.
    static let conversionScript = """
    import sys
    from calibre.ebooks.oeb.base import OEB_DOCS, XHTML
    from calibre.ebooks.oeb.transforms.flatcss import CSSFlattener
    from calibre.ebooks.conversion.cli import main

    original_flatten = CSSFlattener.flatten_spine
    def flatten_linked_documents(self):
        extra = [item for item in self.oeb.manifest.values()
                 if item not in self.items and item.media_type in OEB_DOCS
                 and hasattr(item.data, 'find') and item.data.find(XHTML('body')) is not None]
        if extra:
            items, stylizers = self.items, self.stylizers
            self.items = extra
            self.stylize_spine()
            self.stylizers.update(stylizers)
            self.items = items + extra
        return original_flatten(self)
    CSSFlattener.flatten_spine = flatten_linked_documents

    source, target, *raw = sys.argv[1:]
    arguments = ['ebook-convert', source, target]
    if source.endswith('.pml'):
        from glob import escape
        from calibre.ebooks.conversion.plugins.pml_input import PMLInput
        original_images = PMLInput.get_images
        def pml_images(self, stream=None, tdir=None, top_level=False):
            # Upstream treats brackets in the working directory as glob patterns.
            return original_images(self, stream, escape(tdir) if tdir is not None else None, top_level)
        PMLInput.get_images = pml_images
    if target.endswith('.pmlz'):
        arguments.append('--full-image-depth')
        import calibre.ebooks.pml.pmlml as pml
        original_code = pml.unipmlcode
        def checked_code(char):
            code = original_code(char)
            if code == '?':
                if ord(char) <= 0xffff and not 0xd800 <= ord(char) <= 0xdfff:
                    return chr(92) + 'U%04x' % ord(char)
                raise ValueError('PML cannot represent U+%04X. Choose EPUB to preserve this text.' % ord(char))
            # Calibre's PML reader accepts lowercase hex digits only.
            return code[:2] + code[2:].lower()
        pml.unipmlcode = checked_code
        original_clean = pml.PMLMLizer.clean_text
        def clean_pml(self, text):
            # Calibre treats U+00C2 as a stray UTF-8 byte and removes it, although it is a valid PML character.
            return original_clean(self, text.replace(chr(0xc2), chr(92) + 'a194'))
        pml.PMLMLizer.clean_text = clean_pml
    if raw:
        from pathlib import Path
        import calibre.ebooks.compression.tcr as tcr
        def capture(data):
            Path(raw[0]).write_bytes(data)
            return b''
        tcr.compress = capture
    raise SystemExit(main(arguments))
    """
    static func reportProgress(_ line: String, _ progress: ProgressHandler?) {
        if let progress, let match = EbookRegex.matches(#"^\s*(\d{1,3})%\s"#, line).first, let percent = Int(EbookRegex.group(match, line, 1)) {
            progress(Double(min(100, max(0, percent))) / 100 * 0.95)
        }
    }
    static func lastLines(_ output: String) -> String {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
    }
    static func locate() -> String? {
        EngineEnvironment.ownProgram("calibre", "ebook-convert.exe") ?? EngineEnvironment.bundledProgram("calibre", "ebook-convert.exe") ?? EngineEnvironment.systemProgram("calibre", "ebook-convert.exe")
    }
}

/// Calibre writes PMLZ; standalone PML keeps its PNGs in a sibling <book>_img directory.
enum PmlPackage {
    private static func imageFolder(_ pml: String) -> String {
        FilePath.combine(FilePath.directoryName(pml)!, FilePath.fileNameWithoutExtension(pml) + "_img")
    }

    private static func imageNames(_ data: Data) throws -> Set<String> {
        let text = TextEncodings.decodeText(data)
        let names = Set(EbookRegex.matches(#"(?<!\\)(?:\\\\)*\\m\s*=\s*"([^"]*)""#, text).map { EbookRegex.group($0, text, 1) })
        guard names.allSatisfy(safeImageName) else {
            throw ConversionError("PML image references must use ASCII letters, digits, underscores, hyphens or dots, cannot start with a dot, and must end in lowercase .png.")
        }
        return names
    }

    private static func safeImageName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
            && name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
            && FilePath.extension(name) == ".png"
    }

    static func copyInputImages(_ source: String, beside input: String) throws {
        let names = try imageNames(Data(contentsOf: URL(fileURLWithPath: source)))
        let candidates = [imageFolder(source), FilePath.combine(FilePath.directoryName(source)!, "images")]
        func validDirectory(_ folder: String) throws -> Bool {
            guard FileManager.default.directoryExists(folder) else { return false }
            guard try FileManager.default.attributesOfItem(atPath: folder)[.type] as? FileAttributeType == .typeDirectory else {
                throw ConversionError("PML image folders cannot be symbolic links.")
            }
            return true
        }
        let destination = imageFolder(input)
        func copyImage(_ path: String, _ name: String) throws {
            try Task.checkCancellation()
            guard (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else {
                throw ConversionError("PML image is missing or is not a regular file: \(name)")
            }
            try FileManager.default.createDirectoryIfNeeded(destination)
            try FileManager.default.copyItem(atPath: path, toPath: FilePath.combine(destination, name))
        }
        if !names.isEmpty {
            // Prefer the book's own folder, and require every referenced picture before copying anything.
            guard let directory = try candidates.first(where: { folder in
                guard try validDirectory(folder) else { return false }
                return names.allSatisfy { name in
                    (try? FileManager.default.attributesOfItem(atPath: FilePath.combine(folder, name))[.type] as? FileAttributeType) == .typeRegular
                }
            }) else { throw ConversionError("PML's companion image folder is missing or does not contain every referenced PNG.") }
            for name in names.sorted() { try copyImage(FilePath.combine(directory, name), name) }
        }
        // PML's conventional cover is metadata even when the body never references it.
        if !FileManager.default.fileExists(atPath: FilePath.combine(destination, "cover.png")) {
            for folder in candidates {
                let cover = FilePath.combine(folder, "cover.png")
                guard FileManager.default.fileExists(atPath: cover), try validDirectory(folder) else { continue }
                try copyImage(cover, "cover.png")
                break
            }
        }
    }

    static func unpack(_ archive: String, in work: String) throws -> String {
        let zip = try ZipReader(path: archive)
        var seen = Set<String>()
        for entry in zip.entries {
            let name = entry.name
            let image = name.hasPrefix("index_img/") && safeImageName(String(name.dropFirst("index_img/".count)))
            guard !entry.isSymbolicLink, !entry.isEncrypted, seen.insert(name.lowercased()).inserted,
                  name == "index.pml" || name == "index_img/" || image else {
                throw ConversionError("Calibre produced an invalid PML package entry: \(name)")
            }
        }
        guard let entry = zip.entry(named: "index.pml") else { throw ConversionError("Calibre's PML package has no index.pml.") }
        let text = try zip.data(for: entry)
        for image in try imageNames(text) where zip.entry(named: "index_img/" + image) == nil {
            throw ConversionError("Calibre's PML package is missing an image: \(image)")
        }
        let folder = try EbookFiles.newFolder(work, "pml")
        try EbookFiles.extract(zip, folder)
        return FilePath.combine(folder, "index.pml")
    }

    static func publish(_ pml: String, to output: String) throws {
        let images = imageFolder(pml)
        if FileManager.default.directoryExists(images), !(try FileManager.default.contentsOfDirectory(atPath: images)).isEmpty {
            try FileManager.default.copyItem(atPath: images, toPath: imageFolder(output))
        }
        try Task.checkCancellation()
        try EbookFiles.replace(pml, output)
    }
}
