import Foundation
import Darwin

public enum EngineHostMain {
    public static let fileeCommit = "21fdd05ef7181b032ed83ec895cc9bbc4b198985"
    public static func run(_ arguments: [String]) -> Int32 {
        if arguments.contains("--selftest") { return EngineHostSelfTest.run() }
        // Isolate before framework/engine initialization: even native writes to fd 1 belong on stderr.
        let output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3), input = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
        guard output >= 0 && input >= 0 && dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return 1 }
        let devNull = open("/dev/null", O_RDWR)
        guard devNull >= 0 && dup2(devNull, STDIN_FILENO) >= 0 else { return 1 }
        close(devNull); _ = setpgid(0, 0); signal(SIGPIPE, SIG_IGN)
        let wire = WireWriter(output, chunkedOutput: arguments.contains("--chunked-output"))
        defer { close(input); close(output) }
        do { return try serve(arguments, wire, input) }
        catch { wire.event("fatal", ["code": "internal", "message": error.localizedDescription]); wire.complete(2); return 1 }
    }
    static func applyDefaults(_ store: UserDataStore) throws {
        let marker = FilePath.combine(store.directory, ".filetox-defaults-v1"), first = !FileManager.default.fileExists(FilePath.combine(store.directory, ".filetox-defaults-v1"))
        var changed = false
        if store.settings.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.settings.language.caseInsensitiveCompare("auto") == .orderedSame { store.settings.language = "en"; changed = true }
        if first && store.settings.theme.accent.caseInsensitiveCompare("#7F77DD") == .orderedSame { store.settings.theme.accent = "#3478F6"; changed = true }
        if changed { try store.saveSettings() }
        if first { try Data("1\n".utf8).write(to: URL(fileURLWithPath: marker)) }
    }
    private static func serve(_ args: [String], _ wire: WireWriter, _ input: Int32) throws -> Int32 {
        func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
        let support = FilePath.combine(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path, "FileToX")
        let data = option("--data") ?? FilePath.combine(support, "core")
        let engines = option("--engines") ?? FilePath.combine(FilePath.directoryName(data)!, "engines")
        let temp = option("--tmp") ?? FilePath.combine(FilePath.directoryName(data)!, "tmp")
        for dir in [data, engines, temp] {
            guard FilePath.isFullyQualified(dir) else { throw ConversionError("Not an absolute path: \(dir)") }
            try FileManager.default.createDirectoryIfNeeded(dir)
        }
        setenv("TMPDIR", temp.hasSuffix("/") ? temp : temp + "/", 1)
        let lockFile = open(FilePath.combine(data, ".lock"), O_RDWR | O_CREAT | O_CLOEXEC, 0o666)
        guard lockFile >= 0 else { throw ConversionError(String(cString: strerror(errno))) }
        defer { close(lockFile) }
        if flock(lockFile, LOCK_EX | LOCK_NB) != 0 { wire.event("fatal", ["code": "data_locked", "message": data]); wire.complete(2); return 3 }
        let journal = StagingJournal(FilePath.combine(data, "staging.journal")); try journal.cleanUp()
        EngineEnvironment.downloadRoot = engines
        let store = UserDataStore(data); try store.load(); try applyDefaults(store)
        let language = option("--lang"), loc = Localizer(language ?? store.settings.language)
        let converters = args.contains("--fake-engines") ? FakeEngines.create() : EngineRegistry.createAll(EngineEnvironment(dataDirectory: data))
        let host = Host(wire, store, converters, loc, languageFixed: language != nil, onStaging: journal.append)
        let stop = HostStopFlag()
        wire.broken = { stop.set() }
        wire.event("hello", ["protocol": 1, "hostVersion": EngineVersions.hostVersion, "fileeCommit": fileeCommit, "rid": EngineEnvironment.runtimeIdentifier, "dataDir": data])
        host.startWatching()
        let reader = WireReader(input); reader.shouldStop = { stop.value }
        while !stop.value, let line = try reader.readLine() {
            switch line {
            case .oversized: wire.error(nil, "bad_request", "The line is longer than \(WireJson.maxLine) bytes.")
            case .invalidUTF8: wire.error(nil, "bad_request", "The line is not UTF-8.")
            case .text(let text): if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dispatch(host, wire, text) }
            }
        }
        let done = DispatchSemaphore(value: 0)
        Task { await host.cancelAll(5); done.signal() }
        _ = done.wait(timeout: .now() + 5.1)
        wire.complete(2)
        return 0
    }
    static func dispatch(_ host: Host, _ wire: WireWriter, _ line: String) {
        var id: String?
        do {
            guard let request = try WireJson.parse(Data(line.utf8)) as? [String: Any] else { throw WireException("bad_request", "A request is a JSON object.") }
            id = request["id"] as? String
            guard id != nil else { throw WireException("bad_request", "id must be a string.") }
            guard WireJson.integer(request["v"]) == 1 else { throw WireException("bad_request", "v must be 1.") }
            guard let method = request["method"] as? String else { throw WireException("bad_request", "method must be a string.") }
            guard let params = request["params"] as? [String: Any] else { throw WireException("bad_request", "params must be an object.") }
            if let result = try host.handle(id, method, params) { wire.response(id, result) }
        } catch let e as WireException { wire.error(id, e.code, e.message) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == 3840 { wire.error(id, "bad_request", e.localizedDescription) }
        catch { wire.error(id, "internal", error.localizedDescription) }
    }
}
private final class HostStopFlag: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    var value: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
