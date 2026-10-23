// Port of Filee.Engines/Infrastructure/ProcessRunner.cs: runs command line engines (LibreOffice, rhwp, 7-Zip, ...)
// with a timeout, cancellation and captured output.
//
// posix_spawn instead of Foundation.Process: the child gets /dev/null as stdin, inherits no other descriptor than its
// output pipes (POSIX_SPAWN_CLOEXEC_DEFAULT keeps the host's protocol pipe and lock file out of soffice & co.) and
// stays in the host's process group, so the app can still stop everything at once. A timeout or task cancellation
// kills the whole process tree, like .NET's Process.Kill(entireProcessTree: true).

import Darwin
import Foundation

/// Result of an external process.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

/// The tool ran longer than its time limit and was stopped.
public struct ProcessTimeoutError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public enum ProcessRunner {
    /// Starts `executable` with `arguments` (no shell), waits for it and returns its exit code and output.
    /// - Parameters:
    ///   - workingDirectory: defaults to the executable's folder (as Filee does).
    ///   - environment: variables added to (or replacing) the host's environment.
    ///   - onOutput: called with every line of standard output and error as it arrives (e.g. to parse progress).
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let child = try SpawnedProcess(executable: executable, arguments: arguments,
                                       workingDirectory: workingDirectory ?? FilePath.directoryName(executable) ?? "/",
                                       environment: environment, onOutput: onOutput)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + max(0, timeout))
        timer.setEventHandler { child.stop(reason: .timeout) }
        timer.resume()
        defer { timer.cancel() }

        let status = await withTaskCancellationHandler {
            await child.exitStatus()
        } onCancel: {
            child.stop(reason: .cancelled)
        }
        let (stdout, stderr) = child.drainOutput()
        switch child.stopReason {
        case .cancelled: throw CancellationError()
        case .timeout:
            if Task.isCancelled { throw CancellationError() }
            throw ProcessTimeoutError(message: "\(FilePath.fileName(executable)) did not finish within \(Int(timeout.rounded())) s.")
        case nil:
            return ProcessResult(exitCode: status, standardOutput: stdout, standardError: stderr)
        }
    }

    /// Synchronous variant for engine status probes (`--version`, filter lists), which run outside Swift concurrency.
    public static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let child = try SpawnedProcess(executable: executable, arguments: arguments,
                                       workingDirectory: workingDirectory ?? FilePath.directoryName(executable) ?? "/",
                                       environment: environment, onOutput: nil)
        let status = child.waitBlocking(timeout: timeout)
        let (stdout, stderr) = child.drainOutput()
        if child.stopReason != nil {
            throw ProcessTimeoutError(message: "\(FilePath.fileName(executable)) did not finish within \(Int(timeout.rounded())) s.")
        }
        return ProcessResult(exitCode: status, standardOutput: stdout, standardError: stderr)
    }

    /// Kills `pid` and every process below it (children first collected, then all signalled).
    public static func killTree(_ pid: pid_t) {
        var victims: [pid_t] = []
        var pending = [pid]
        while let next = pending.popLast() {
            victims.append(next)
            pending.append(contentsOf: childProcesses(of: next))
        }
        for victim in victims { kill(victim, SIGKILL) }
    }

    static func childProcesses(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            // libproc returns the number of pids (not bytes) for this call.
            let count = Int(buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) })
            guard count > 0 else { return [] }
            if count < capacity { return Array(buffer.prefix(count)).filter { $0 > 0 } }
            capacity *= 4
        }
    }
}

/// One running child process with its two output pipes.
private final class SpawnedProcess: @unchecked Sendable {
    enum StopReason { case timeout, cancelled }

    private let pid: pid_t
    private let lock = NSLock()
    private var reason: StopReason?
    private var exited = false
    private var status: Int32 = 0
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private let output: OutputCollector
    private let errors: OutputCollector
    private let readers = DispatchGroup()
    private let exitSignal = DispatchSemaphore(value: 0)

    var stopReason: StopReason? { lock.withLock { reason } }

    init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]?,
         onOutput: (@Sendable (String) -> Void)?) throws {
        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal handling in the child (the host ignores SIGPIPE).
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment ?? [:] { merged[key] = value }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard result == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ConversionError("Could not start \(executable): \(String(cString: strerror(result))).")
        }
        pid = child
        output = OutputCollector(descriptor: outPipe[0], onLine: onOutput)
        errors = OutputCollector(descriptor: errPipe[0], onLine: onOutput)
        for collector in [output, errors] {
            readers.enter()
            Thread.detachNewThread { [readers] in
                collector.readToEnd()
                readers.leave()
            }
        }
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
            let code: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            let resumed = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
                exited = true
                status = code
                defer { waiters = [] }
                return waiters
            }
            exitSignal.signal()
            resumed.forEach { $0.resume(returning: code) }
        }
    }

    func waitBlocking(timeout: TimeInterval) -> Int32 {
        if exitSignal.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            stop(reason: .timeout)
            exitSignal.wait()
        }
        return lock.withLock { status }
    }

    func exitStatus() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Int32? in
                if exited { return status }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    func stop(reason stop: StopReason) {
        let alive = lock.withLock { () -> Bool in
            guard !exited, reason == nil else { return false }
            reason = stop
            return true
        }
        if alive { ProcessRunner.killTree(pid) }
    }

    /// Waits for both pipes to reach EOF (a stray grandchild holding them gets 5 s) and returns the text.
    func drainOutput() -> (String, String) {
        _ = readers.wait(timeout: .now() + 5)
        return (output.text, errors.text)
    }
}

/// Reads one pipe to EOF, splitting lines on "\n", "\r\n" and "\r" like .NET's line reader.
private final class OutputCollector: @unchecked Sendable {
    private let descriptor: Int32
    private let onLine: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var collected = ""
    private var pending = Data()
    private var lastWasCR = false

    init(descriptor: Int32, onLine: (@Sendable (String) -> Void)?) {
        self.descriptor = descriptor
        self.onLine = onLine
    }

    var text: String { lock.withLock { collected } }

    func readToEnd() {
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            consume(buffer[0..<count])
        }
        if !pending.isEmpty { emit(pending) }
    }

    private func consume(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            switch byte {
            case 10:
                if lastWasCR { lastWasCR = false; continue }
                emit(pending); pending.removeAll(keepingCapacity: true)
            case 13:
                emit(pending); pending.removeAll(keepingCapacity: true)
                lastWasCR = true
                continue
            default:
                pending.append(byte)
            }
            lastWasCR = false
        }
    }

    private func emit(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        lock.withLock { collected += text + "\n" }
        onLine?(text)
    }
}
