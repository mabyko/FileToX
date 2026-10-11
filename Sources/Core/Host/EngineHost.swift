import Foundation
import Darwin

struct HostLineBuffer {
    static let maximumLength = 4 * 1024 * 1024
    private(set) var remainder = Data()

    mutating func append(_ data: Data) throws -> [Data] {
        remainder.append(data)
        var lines: [Data] = []
        while let newline = remainder.firstIndex(of: 10) {
            guard remainder.distance(from: remainder.startIndex, to: newline) <= Self.maximumLength else {
                throw HostError(code: "protocol_error", message: "엔진 응답이 허용 크기를 넘었습니다.")
            }
            var line = Data(remainder[..<newline])
            if line.last == 13 { line.removeLast() }
            lines.append(line)
            remainder.removeSubrange(...newline)
        }
        guard remainder.count <= Self.maximumLength else {
            throw HostError(code: "protocol_error", message: "엔진 응답이 허용 크기를 넘었습니다.")
        }
        return lines
    }
}

actor EngineHost {
    private struct WireMessage: Decodable {
        let v: Int
        let id: String?
        let event: String?
        let result: JSONValue?
        let error: HostWireError?
        let data: JSONValue?
    }
    private struct HostWireError: Decodable { let code: String; let message: String }
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let timeout: Task<Void, Never>
    }
    private let executableURL: URL
    private let dataDirectory: URL
    private let writer = DispatchQueue(label: "filetox.host.stdin")
    private let stream: AsyncStream<HostEvent>
    private let eventsContinuation: AsyncStream<HostEvent>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var runID = UUID()
    private var hello: HostHello?
    private var handshakeWaiters: [CheckedContinuation<HostHello, any Error>] = []
    private var handshakeTimeout: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var lineBuffer = HostLineBuffer()
    private var stderr = Data()
    private var shuttingDown = false
    private var restartTask: Task<Void, Never>?
    private var recentFailures: [Date] = []
    private var cancelTimeouts: [String: Task<Void, Never>] = [:]
    private var finishedJobIDs: [String] = []

    init(executableURL: URL? = nil, dataDirectory: URL? = nil) {
        self.executableURL = executableURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine")
        self.dataDirectory = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileToX", isDirectory: true)
        let pair = AsyncStream<HostEvent>.makeStream()
        stream = pair.stream
        eventsContinuation = pair.continuation
    }

    func events() -> AsyncStream<HostEvent> { stream }
    func diagnostics() -> String { String(decoding: stderr, as: UTF8.self) }

    func start() async throws -> HostHello {
        if let hello { return hello }
        guard !shuttingDown else { throw HostError(code: "shutdown", message: "변환 엔진이 종료 중입니다.") }
        if process == nil { try launch() }
        return try await withCheckedThrowingContinuation { handshakeWaiters.append($0) }
    }

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw HostError(code: "host_missing", message: "변환 엔진을 찾을 수 없습니다. 앱을 다시 빌드하세요.")
        }
        for directory in ["core", "engines", "tmp"] {
            try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let core = dataDirectory.appendingPathComponent("core").path
        let engines = dataDirectory.appendingPathComponent("engines").path
        let temporary = dataDirectory.appendingPathComponent("tmp").path
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["--data", core, "--engines", engines]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary + "/"
        child.environment = environment
        let stdin = Pipe(), stdout = Pipe(), errors = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = errors
        runID = UUID()
        let generation = runID
        lineBuffer = HostLineBuffer()
        stderr = Data()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errorOutput = errors.fileHandleForReading
        process = child
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try child.run() }
        catch {
            process = nil
            try? input?.close(); try? output?.close(); try? errorOutput?.close()
            input = nil; output = nil; errorOutput = nil
            throw error
        }
        let stdoutDescriptor = dup(stdout.fileHandleForReading.fileDescriptor)
        let stderrDescriptor = dup(errors.fileHandleForReading.fileDescriptor)
        guard stdoutDescriptor >= 0, stderrDescriptor >= 0 else {
            if stdoutDescriptor >= 0 { close(stdoutDescriptor) }
            if stderrDescriptor >= 0 { close(stderrDescriptor) }
            failHost(HostError.interrupted, restart: false)
            throw HostError.interrupted
        }
        _ = fcntl(stdoutDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrDescriptor, F_SETFD, FD_CLOEXEC)
        Task.detached { [weak self] in
            defer { close(stdoutDescriptor) }
            do {
                while true {
                    let data = try Self.readChunk(stdoutDescriptor, length: 65536)
                    await self?.receive(data, generation: generation)
                    if data.isEmpty { return }
                }
            } catch { await self?.readFailed(generation: generation) }
        }
        Task.detached { [weak self] in
            defer { close(stderrDescriptor) }
            do {
                while true {
                    let data = try Self.readChunk(stderrDescriptor, length: 4096)
                    if data.isEmpty { return }
                    await self?.recordStderr(data, generation: generation)
                }
            } catch { /* Closing pipes during shutdown also ends this reader. */ }
        }
        handshakeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.handshakeExpired(generation: generation)
        }
    }

    // FileHandle.read(upToCount:) waits to fill its buffer; the protocol needs each available pipe chunk.
    private nonisolated static func readChunk(_ descriptor: Int32, length: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, length) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return Data(bytes.prefix(count))
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == runID, process != nil else { return }
        guard !data.isEmpty else {
            failHost(HostError.interrupted, restart: !shuttingDown)
            return
        }
        do {
            for line in try lineBuffer.append(data) {
                let message = try JSONDecoder.hostDecoder().decode(WireMessage.self, from: line)
                guard message.v == 1, (message.id != nil) != (message.event != nil) else { throw HostError.interrupted }
                if let id = message.id {
                    guard hello != nil, (message.result != nil) != (message.error != nil),
                          let request = pending.removeValue(forKey: id) else { throw HostError.interrupted }
                    request.timeout.cancel()
                    if let error = message.error {
                        request.continuation.resume(throwing: HostError(code: error.code, message: error.message))
                    } else if let result = message.result {
                        request.continuation.resume(returning: result)
                    }
                } else if let event = message.event, let payload = message.data {
                    switch event {
                    case "hello":
                        let value = try decode(HostHello.self, from: payload)
                        guard hello == nil, value.protocol == 1,
                              value.fileeCommit == "21fdd05ef7181b032ed83ec895cc9bbc4b198985" else {
                            throw HostError(code: "version_mismatch", message: "앱과 변환 엔진 버전이 맞지 않습니다.")
                        }
                        hello = value
                        handshakeTimeout?.cancel(); handshakeTimeout = nil
                        let waiters = handshakeWaiters; handshakeWaiters = []
                        waiters.forEach { $0.resume(returning: value) }
                        eventsContinuation.yield(.hello(value))
                    case "job.updated", "job.finished":
                        guard hello != nil else { throw HostError.interrupted }
                        let job = try decode(HostJob.self, from: payload)
                        if event == "job.finished" {
                            cancelTimeouts.removeValue(forKey: job.jobId)?.cancel()
                            finishedJobIDs.append(job.jobId)
                            if finishedJobIDs.count > 200 { finishedJobIDs.removeFirst() }
                        }
                        eventsContinuation.yield(event == "job.updated" ? .updated(job) : .finished(job))
                    case "fatal":
                        let text = payload["message"]?.string ?? payload["code"]?.string ?? "변환 엔진을 시작하지 못했습니다."
                        eventsContinuation.yield(.fatal(text))
                        failHost(HostError(code: "host_fatal", message: text), restart: false)
                        return
                    default: throw HostError(code: "protocol_error", message: "알 수 없는 엔진 이벤트입니다.")
                    }
                } else { throw HostError.interrupted }
            }
        } catch {
            failHost((error as? HostError) ?? HostError(code: "protocol_error", message: "변환 엔진 응답을 읽지 못했습니다."), restart: !shuttingDown)
        }
    }

    private func recordStderr(_ data: Data, generation: UUID) {
        guard generation == runID else { return }
        stderr.append(data)
        if stderr.count > 32768 { stderr.removeFirst(stderr.count - 32768) }
    }
    private func readFailed(generation: UUID) {
        guard generation == runID, process != nil else { return }
        failHost(HostError.interrupted, restart: !shuttingDown)
    }
    private func handshakeExpired(generation: UUID) {
        guard generation == runID, hello == nil, process != nil else { return }
        failHost(HostError(code: "timeout", message: "변환 엔진 시작 시간이 초과됐습니다."), restart: false)
    }
    private func requestExpired(_ id: String, generation: UUID) {
        guard generation == runID, pending[id] != nil else { return }
        failHost(HostError(code: "timeout", message: "변환 엔진 응답 시간이 초과됐습니다."), restart: !shuttingDown)
    }

    private func failHost(_ error: HostError, restart: Bool) {
        let wasReady = hello != nil
        if let process, process.isRunning {
            if kill(-process.processIdentifier, SIGKILL) != 0 { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
        hello = nil
        handshakeTimeout?.cancel(); handshakeTimeout = nil
        try? input?.close(); try? output?.close(); try? errorOutput?.close()
        input = nil; output = nil; errorOutput = nil
        let waiters = handshakeWaiters; handshakeWaiters = []
        waiters.forEach { $0.resume(throwing: error) }
        let requests = pending; pending = [:]
        for request in requests.values { request.timeout.cancel(); request.continuation.resume(throwing: error) }
        cancelTimeouts.values.forEach { $0.cancel() }; cancelTimeouts = [:]
        if !shuttingDown { eventsContinuation.yield(.interrupted(error.localizedDescription)) }
        guard restart, wasReady else { return }
        recentFailures = recentFailures.filter { Date().timeIntervalSince($0) < 60 }
        recentFailures.append(Date())
        guard recentFailures.count <= 3 else { return }
        let delay = 1 << (recentFailures.count - 1)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            _ = try? await self?.start()
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder.hostDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private func request<T: Decodable & Sendable>(_ type: T.Type, method: String, params: [String: JSONValue] = [:]) async throws -> T {
        _ = try await start()
        try Task.checkCancellation()
        let id = UUID().uuidString
        let body = JSONValue.object(["v": .number(1), "id": .string(id), "method": .string(method), "params": .object(params)])
        var data = try JSONEncoder().encode(body)
        guard data.count <= HostLineBuffer.maximumLength else { throw HostError(code: "request_too_large", message: "한 번에 선택한 파일이 너무 많습니다.") }
        data.append(10)
        let payload = data
        let generation = runID
        let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.requestExpired(id, generation: generation)
            }
            pending[id] = Pending(continuation: continuation, timeout: timeout)
            guard let input else { failHost(HostError.interrupted, restart: false); return }
            writer.async { [weak self] in
                do { try input.write(contentsOf: payload) }
                catch { Task { await self?.readFailed(generation: generation) } }
            }
        }
        do { return try decode(type, from: result) }
        catch {
            let failure = HostError(code: "protocol_error", message: "변환 엔진의 응답 형식이 앱과 맞지 않습니다.")
            failHost(failure, restart: !shuttingDown)
            throw failure
        }
    }

    func catalog() async throws -> HostCatalog { try await request(HostCatalog.self, method: "catalog.get") }
    func resolve(paths: [String]) async throws -> HostSelection {
        try await request(HostSelection.self, method: "selection.resolve", params: ["paths": .array(paths.map(JSONValue.string))])
    }
    func startJob(paths: [String], presetId: String? = nil, targetFormat: String? = nil, preset: JSONValue? = nil) async throws -> String {
        struct Accepted: Decodable, Sendable { let jobId: String }
        var params: [String: JSONValue] = ["paths": .array(paths.map(JSONValue.string))]
        if let presetId { params["presetId"] = .string(presetId) }
        if let targetFormat { params["targetFormat"] = .string(targetFormat) }
        if let preset { params["preset"] = preset }
        return try await request(Accepted.self, method: "job.start", params: params).jobId
    }
    func cancel(jobId: String) async throws {
        _ = try await request(JSONValue.self, method: "job.cancel", params: ["jobId": .string(jobId)])
        guard !finishedJobIDs.contains(jobId), cancelTimeouts[jobId] == nil else { return }
        let generation = runID
        cancelTimeouts[jobId] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.cancellationExpired(jobId: jobId, generation: generation)
        }
    }
    private func cancellationExpired(jobId: String, generation: UUID) {
        guard generation == runID, cancelTimeouts[jobId] != nil else { return }
        failHost(HostError(code: "cancel_timeout", message: "취소에 응답하지 않는 엔진을 종료했습니다. 다른 대기 작업도 중단됐습니다."), restart: !shuttingDown)
    }
    func history() async throws -> [HostHistory] {
        struct History: Decodable, Sendable { let entries: [HostHistory] }
        return try await request(History.self, method: "history.get").entries
    }
    func clearHistory() async throws { _ = try await request(JSONValue.self, method: "history.clear") }
    func library() async throws -> HostLibrary { try await request(HostLibrary.self, method: "library.get") }
    func saveLibrary(baseRevision: Int, presets: [JSONValue], profiles: [JSONValue]) async throws -> HostLibrary {
        try await request(HostLibrary.self, method: "library.save", params: ["baseRevision": .number(Double(baseRevision)), "presets": .array(presets), "profiles": .array(profiles)])
    }
    func saveSettings(baseRevision: Int, settings: JSONValue) async throws -> HostLibrary {
        try await request(HostLibrary.self, method: "settings.save", params: ["baseRevision": .number(Double(baseRevision)), "settings": settings])
    }
    func shutdown() async {
        shuttingDown = true
        restartTask?.cancel(); restartTask = nil
        try? input?.close(); input = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process != nil { failHost(HostError(code: "shutdown", message: "변환 엔진을 종료했습니다."), restart: false) }
        eventsContinuation.finish()
    }
}
