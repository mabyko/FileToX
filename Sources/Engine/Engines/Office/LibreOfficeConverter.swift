// Port of Filee.Engines/Office/LibreOfficeConverter.cs. ProcessRunner owns timeouts and process-tree cancellation.
import Foundation

final class LibreOfficeConverter: Converter {
    private static let writer = ["docx", "doc", "odt", "rtf"], calc = ["xlsx", "xls", "ods", "csv"],
        impress = ["pptx", "ppt", "odp"]
    private static let writerImport = ["dot", "wps", "wpd", "lwp", "abw", "pages", "sdw"],
        calcImport = ["et", "numbers", "sdc"], impressImport = ["key", "dps", "sda"], impressGraphics = ["cgm"],
        draw = ["pub", "cdr", "vsd", "odg", "emf", "wmf"]
    private let environment: EngineEnvironment
    private let profiles = ProfilePool()
    private let stateLock = NSLock()
    private var soffice: String?, hasHwpFilter = false
    private var currentEdges: [ConversionEdge] = []
    let id = "libreoffice", displayName = "LibreOffice", maxParallelism = 2
    var edges: [ConversionEdge] { stateLock.withLock { currentEdges } }
    init(_ environment: EngineEnvironment) {
        self.environment = environment
        locate()
    }
    func status() -> EngineStatus {
        locate()
        let (exe, hwp) = stateLock.withLock { (soffice, hasHwpFilter) }
        guard let exe else { return .unavailable("engine.reason.not_installed") }
        if !EngineEnvironment.usesBundledCopy("libreoffice") {
            return .available(detail: exe, version: hwp ? "H2Orestart" : nil)
        }
        return .available(
            detail: exe,
            version: (EngineVersions.component("libreoffice") ?? "")
                + (hwp ? " · H2Orestart \(EngineVersions.component("h2orestart") ?? "")" : ""))
    }
    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        guard let exe = stateLock.withLock({ soffice }) else { throw ConversionError("LibreOffice was not found.") }
        let slot = try await profiles.take()
        do {
            let outDir = FilePath.combine(
                step.workDirectory,
                "lo-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)))
            try FileManager.default.createDirectoryIfNeeded(outDir)
            progress?(0.1)
            let estimate = ProgressEstimate.start(progress, typical: 4)
            let result: ProcessResult
            do {
                result = try await run(
                    exe, slot,
                    Self.filterFor(
                        step.from, step.to, step.preset.document.pdfA, FormatRegistry.extensionOf(step.inputPath)),
                    outDir, step.inputPath)
                estimate.stop()
            } catch {
                estimate.stop()
                throw error
            }
            let produced = try FileManager.default.contentsOfDirectory(atPath: outDir).map {
                FilePath.combine(outDir, $0)
            }.first { path in
                FileManager.default.fileExists(path)
                    && ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
                        > 0
            }
            guard let produced else {
                throw ConversionError(
                    "LibreOffice produced no output (exit \(result.exitCode)). \(result.standardError.trimmingCharacters(in:.whitespacesAndNewlines))"
                )
            }
            guard let target = try step.output.allocate(step.to) else {
                await profiles.put(slot)
                return []
            }
            if FileManager.default.fileExists(target) { try FileManager.default.removeItem(atPath: target) }
            try FileManager.default.moveItem(atPath: produced, toPath: target)
            progress?(1)
            await profiles.put(slot)
            return [target]
        } catch {
            await profiles.put(slot)
            throw error
        }
    }
    func warmUpAsync() async throws -> Int {
        locate()
        guard let exe = stateLock.withLock({ soffice }), !(0..<2).allSatisfy(isPrepared) else { return 0 }
        var prepared = 0
        var held: Int?
        do {
            for _ in 0..<2 {
                let slot = try await profiles.take()
                if let previous = held { await profiles.put(previous) }
                held = slot
                if isPrepared(slot) { continue }
                let folder = FilePath.combine(
                    FileManager.default.temporaryDirectory.path,
                    "filee-warmup-"
                        + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)))
                do {
                    try FileManager.default.createDirectoryIfNeeded(folder)
                    let input = FilePath.combine(folder, "warmup.txt")
                    try Task.checkCancellation()
                    try Data("Filee".utf8).write(to: URL(fileURLWithPath: input))
                    _ = try await run(exe, slot, Self.filterFor("txt", "pdf", false), folder, input)
                    prepared += 1
                    try? FileManager.default.removeItem(atPath: folder)
                } catch {
                    try? FileManager.default.removeItem(atPath: folder)
                    throw error
                }
            }
            if let held { await profiles.put(held) }
            return prepared
        } catch {
            if let held { await profiles.put(held) }
            throw error
        }
    }
    private func profileDirectory(_ slot: Int) -> String {
        FilePath.combine(environment.dataDirectory, "libreoffice-profiles", "worker-\(slot)")
    }
    private func isPrepared(_ slot: Int) -> Bool {
        FileManager.default.directoryExists(FilePath.combine(profileDirectory(slot), "user"))
    }
    private func run(_ exe: String, _ slot: Int, _ filter: String, _ outDir: String, _ input: String) async throws
        -> ProcessResult
    {
        let profile = profileDirectory(slot)
        try FileManager.default.createDirectoryIfNeeded(profile)
        var args = [
            "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck", "--nofirststartwizard",
            "-env:UserInstallation="
                + URL(fileURLWithPath: profile).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        ]
        if var jre = EngineEnvironment.findBundled("jre") {
            if FileManager.default.directoryExists(FilePath.combine(jre, "Contents", "Home")) {
                jre = FilePath.combine(jre, "Contents", "Home")
            }
            args.append("-env:UNO_JAVA_JFW_JREHOME=" + URL(fileURLWithPath: jre, isDirectory: true).absoluteString)
        }
        args += ["--convert-to", filter, "--outdir", outDir, input]
        return try await ProcessRunner.run(exe, args, timeout: 180)
    }
    static func filterFor(_ from: String, _ to: String, _ pdfA: Bool, _ ext: String? = nil) -> String {
        let family = familyOf(from, ext)
        switch to {
        case "pdf":
            return "pdf:\(family)_pdf_Export"
                + (pdfA ? ":{\"SelectPdfVersion\":{\"type\":\"long\",\"value\":\"2\"}}" : "")
        case "docx": return "docx:MS Word 2007 XML"
        case "doc": return "doc:MS Word 97"
        case "odt": return "odt"
        case "rtf": return "rtf:Rich Text Format"
        case "txt": return "txt:Text (encoded):UTF8"
        case "html": return family == "calc" ? "html:HTML (StarCalc)" : "html:HTML (StarWriter)"
        case "xlsx": return "xlsx:Calc MS Excel 2007 XML"
        case "xls": return "xls:MS Excel 97"
        case "ods": return "ods"
        case "csv": return "csv:Text - txt - csv (StarCalc):44,34,76"
        case "pptx": return "pptx:Impress MS PowerPoint 2007 XML"
        case "ppt": return "ppt:MS PowerPoint 97"
        case "odp": return "odp"
        case "odg": return family == "impress" ? "odg:impress8_draw" : "odg:draw8"
        case "svg", "png": return "\(to):\(family)_\(to)_Export"
        default: return to
        }
    }
    private static func familyOf(_ from: String, _ ext: String?) -> String {
        if from == "sda" { return ext?.lowercased() == "sda" ? "draw" : "impress" }
        if (calc + calcImport).contains(from) { return "calc" }
        if (impress + impressImport + impressGraphics).contains(from) { return "impress" }
        return draw.contains(from) ? "draw" : "writer"
    }
    private static func buildEdges(_ hwp: Bool) -> [ConversionEdge] {
        var edges: [ConversionEdge] = []
        func add(_ sources: [String], _ targets: [String], _ cost: Int = 25) {
            for s in sources { for t in targets where s != t { edges.append(ConversionEdge(s, t, cost)) } }
        }
        add(writer, writer + ["pdf", "txt", "html"])
        add(calc, calc + ["pdf", "html"])
        add(impress, impress + ["pdf"])
        add(["txt", "html"], ["docx", "odt", "pdf"], 28)
        add(writerImport, writer + ["pdf", "txt", "html"])
        add(calcImport, calc + ["pdf", "html"])
        add(impressImport, impress + ["pdf"])
        add(impressGraphics + draw, ["pdf", "odg", "svg", "png"])
        if hwp { add(["hwp", "hwpx"], ["pdf", "docx", "odt", "rtf"], 31) }
        return edges
    }
    private func locate() {
        let exe =
            EngineEnvironment.ownProgram("libreoffice", "soffice.exe") ?? EngineEnvironment.bundledProgram(
                "libreoffice", "soffice.exe") ?? EngineEnvironment.systemProgram("libreoffice", "soffice.exe")
        let hwp = exe.map(Self.hasH2Orestart) ?? false
        stateLock.withLock {
            soffice = exe
            hasHwpFilter = hwp
            currentEdges = Self.buildEdges(hwp)
        }
    }
    private static func hasH2Orestart(_ soffice: String) -> Bool {
        let root = URL(fileURLWithPath: soffice).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().path
        for sub in ["share/uno_packages", "share/extensions", "Resources/uno_packages", "Resources/extensions"] {
            let dir = FilePath.combine(root, sub)
            if let enumerator = FileManager.default.enumerator(atPath: dir) {
                for case let path as String in enumerator where FilePath.fileName(path).contains("H2Orestart") {
                    return true
                }
            }
        }
        return false
    }
    // Cancellation-safe FIFO permits: cancellation removes a waiter before a returned profile can be reused.
    private actor ProfilePool {
        struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Int, Error>
        }
        var free = [1, 0], waiting: [Waiter] = []
        func take() async throws -> Int {
            try Task.checkCancellation()
            if let slot = free.popLast() { return slot }
            let id = UUID()
            return try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { continuation in
                        waiting.append(Waiter(id: id, continuation: continuation))
                    }
                }, onCancel: { Task { await self.cancel(id) } })
        }
        func put(_ slot: Int) {
            if waiting.isEmpty { free.append(slot) } else { waiting.removeFirst().continuation.resume(returning: slot) }
        }
        func cancel(_ id: UUID) {
            if let index = waiting.firstIndex(where: { $0.id == id }) {
                waiting.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }
}
