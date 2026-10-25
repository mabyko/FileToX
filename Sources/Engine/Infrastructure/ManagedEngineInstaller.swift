import Foundation
import CryptoKit
import Darwin

struct EngineInstallFailure: LocalizedError {
    let key: String
    let detail: String
    var errorDescription: String? { detail }
    init(_ key: String, _ detail: String) { self.key = key; self.detail = detail }
}

struct EngineInstallStatus: Codable, Sendable {
    let id: String
    let version: String?
    let downloadSize: Int64
    let installedSize: Int64
    let canDownload: Bool
    let guidanceKey: String?
    var state = "idle"
    var bytesReceived: Int64 = 0
    var errorKey: String?
    var errorDetail: String?
    var isActive: Bool { ["queued", "downloading", "verifying", "installing", "cancelling"].contains(state) }
}

/// Owns only new installations. Existing directories (including incomplete or manually supplied copies) are never replaced.
final class ManagedEngineInstaller: @unchecked Sendable {
    typealias Download = @Sendable (EngineComponent, String, @escaping @Sendable (Int64) -> Void) async throws -> Void
    typealias Run = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult
    private let root: String
    private let components: [String: EngineComponent]
    private let download: Download
    private let run: Run
    private let lock = NSLock()
    private var statuses: [String: EngineInstallStatus] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var stopped = false

    init(root: String = EngineEnvironment.downloadRoot, runtime: String = EngineEnvironment.runtimeIdentifier,
         components: [String: EngineComponent] = EngineDownloads.components,
         download: @escaping Download = { try await ManagedEngineInstaller.downloadArchive($0, to: $1, progress: $2) },
         run: @escaping Run = { try await ProcessRunner.run($0, $1, timeout: $2) }) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
        self.components = components; self.download = download; self.run = run
        for package in EngineDownloads.packages {
            let component = components[package.id]
            let supported = runtime == "osx-arm64" && Self.supportedArchitecture && component != nil &&
                ["pandoc", "calibre", "libreoffice"].contains(package.id)
            var status = EngineInstallStatus(id: package.id, version: component?.version,
                downloadSize: component?.size ?? 0, installedSize: package.installedSize, canDownload: supported,
                guidanceKey: supported ? nil : "engines.guidance.macos.\(package.id)")
            let target = FilePath.combine(self.root, package.id)
            if OutputCommit.exists(target) {
                status.state = !OutputCommit.isSymbolicLink(target) && EngineEnvironment.folderWithPrograms(package.id, target) != nil ? "installed" : "existing"
            }
            statuses[package.id] = status
        }
    }

    private static var supportedArchitecture: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    func snapshot() -> [EngineInstallStatus] { lock.withLock { EngineDownloads.packages.compactMap { statuses[$0.id] } } }
    var isActive: Bool { lock.withLock { !tasks.isEmpty } }

    func start(_ id: String) throws -> EngineInstallStatus {
        try lock.withLock {
            guard !stopped else { throw WireException("shutdown", "Engine installation is stopping.") }
            guard var status = statuses[id], let component = components[id], status.canDownload,
                  let package = EngineDownloads.packages.first(where: { $0.id == id }) else {
                throw WireException("download_unavailable", "No pinned download is available for this package and Mac.")
            }
            if tasks[id] != nil { return status }
            guard !["installed", "existing"].contains(status.state) else {
                throw WireException("engine_exists", "An engine directory already exists. It will not be replaced.")
            }
            status.state = "queued"; status.bytesReceived = 0; status.errorKey = nil; status.errorDetail = nil
            statuses[id] = status
            tasks[id] = Task.detached(priority: .utility) { [self] in
                do { try await install(package, component) }
                catch {
                    lock.withLock {
                        let failure = error as? EngineInstallFailure
                        statuses[id]?.state = failure?.key == "engines.error.detach" ? "failed" : Task.isCancelled ? "cancelled" : "failed"
                        statuses[id]?.errorKey = failure?.key ?? "engines.error.install"
                        statuses[id]?.errorDetail = error.localizedDescription
                    }
                }
                lock.withLock { tasks[id] = nil }
            }
            return status
        }
    }

    func cancel(_ id: String) throws -> EngineInstallStatus {
        try lock.withLock {
            guard var status = statuses[id] else { throw WireException("not_found", "Unknown engine package.") }
            if let task = tasks[id], status.isActive {
                status.state = "cancelling"; statuses[id] = status; task.cancel()
            }
            return status
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            for (id, task) in tasks { if statuses[id]?.isActive == true { statuses[id]?.state = "cancelling" }; task.cancel() }
        }
    }

    func shutdown() async {
        stop()
        let pending = lock.withLock { Array(tasks.values) }
        for task in pending { await task.value }
    }

    private func phase(_ id: String, _ state: String) throws {
        try lock.withLock {
            try Task.checkCancellation()
            statuses[id]?.state = state
        }
    }

    private func install(_ package: EnginePackage, _ component: EngineComponent) async throws {
        let fm = FileManager.default, id = package.id
        try Task.checkCancellation()
        guard component.id == id, component.size > 0, component.sha256.count == 64,
              component.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              URL(string: component.url)?.scheme == "https", ["zip", "dmg"].contains(component.kind) else {
            throw EngineInstallFailure("engines.error.package", "Invalid pinned package metadata.")
        }
        if !OutputCommit.exists(root) {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o022 == 0 else {
            throw EngineInstallFailure("engines.error.path", "The managed engine root must be an owned directory without shared write access or a symbolic link.")
        }
        let destination = FilePath.combine(root, id)
        guard !OutputCommit.exists(destination) else { throw EngineInstallFailure("engines.error.exists", "The existing engine directory was preserved.") }
        var template = Array(FilePath.combine(root, ".install-\(id)-XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let stage = String(cString: created), payload = FilePath.combine(stage, "payload")
        var retainMount = false
        defer { if !retainMount { try? fm.removeItem(atPath: stage) } }
        try fm.createDirectory(atPath: payload, withIntermediateDirectories: false)
        let archive = FilePath.combine(stage, "archive." + component.kind)
        try phase(id, "downloading")
        try await download(component, archive) { [weak self] bytes in
            guard let self else { return }
            self.lock.withLock { self.statuses[id]?.bytesReceived = min(max(0, bytes), component.size) }
        }
        try phase(id, "verifying")
        try Self.verify(archive, component)
        try phase(id, "installing")
        var installedPayload = payload
        if component.kind == "zip" {
            try Self.extractZip(archive, into: payload, limit: UInt64(package.installedSize) * 2)
            let children = try fm.contentsOfDirectory(atPath: payload)
            if children.count == 1 {
                let child = FilePath.combine(payload, children[0])
                if fm.directoryExists(child), !OutputCommit.isSymbolicLink(child) { installedPayload = child }
            }
        } else {
            do { try await extractDMG(archive, into: payload, package: id, stage: stage) }
            catch { retainMount = (error as? EngineInstallFailure)?.key == "engines.error.detach"; throw error }
        }
        try Self.validateTree(installedPayload)
        guard let requiredPrograms = EngineEnvironment.ownCopyPrograms[id],
              let folder = EngineEnvironment.folderWithPrograms(id, installedPayload) else {
            throw EngineInstallFailure("engines.error.program", "The package does not contain its required programs.")
        }
        let programs = requiredPrograms + (id == "calibre" ? ["calibre-debug"] : [])
        for name in programs {
            let program = FilePath.combine(folder, name)
            guard fm.isExecutableFile(atPath: program), Self.contained(program, in: installedPayload) else {
                throw EngineInstallFailure("engines.error.program", "The package program is missing or is not executable: \(name)")
            }
        }
        let probe = FilePath.combine(stage, "probe")
        try fm.createDirectory(atPath: probe, withIntermediateDirectories: false)
        let arguments = id == "libreoffice" ? ["-env:UserInstallation=" + URL(fileURLWithPath: probe).absoluteString, "--version"] : ["--version"]
        let result = try await ProcessRunner.run(FilePath.combine(folder, programs[0]), arguments, timeout: 20,
            environment: ["CALIBRE_CONFIG_DIRECTORY": probe, "CALIBRE_CACHE_DIRECTORY": probe, "CALIBRE_TEMP_DIR": probe,
                          "XDG_CACHE_HOME": probe, "XDG_CONFIG_HOME": probe])
        guard result.exitCode == 0, !(result.standardOutput + result.standardError).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineInstallFailure("engines.error.program", "The package program failed validation: \(result.standardError)")
        }
        try Data((component.sha256.lowercased() + "\n").utf8).write(to: URL(fileURLWithPath: FilePath.combine(installedPayload, ".filee-component")), options: .withoutOverwriting)
        try lock.withLock {
            try Task.checkCancellation()
            var current = stat()
            guard lstat(root, &current) == 0, current.st_dev == rootInfo.st_dev, current.st_ino == rootInfo.st_ino,
                  current.st_mode & S_IFMT == S_IFDIR else { throw EngineInstallFailure("engines.error.path", "The managed root changed during installation.") }
            try OutputCommit.move(installedPayload, destination, overwrite: false, sources: [])
            statuses[id]?.state = "installed"; statuses[id]?.bytesReceived = component.size
        }
        EngineEnvironment.forgetSystemCopies()
    }

    static func verify(_ path: String, _ component: EngineComponent) throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? input.close() }
        var hash = SHA256(), size: Int64 = 0
        while let bytes = try input.read(upToCount: 1 << 20), !bytes.isEmpty {
            try Task.checkCancellation()
            size += Int64(bytes.count)
            guard size <= component.size else { throw EngineInstallFailure("engines.error.size", "The package exceeds its pinned size.") }
            hash.update(data: bytes)
        }
        guard size == component.size else { throw EngineInstallFailure("engines.error.size", "The package is incomplete or has the wrong size.") }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == component.sha256.lowercased() else {
            throw EngineInstallFailure("engines.error.hash", "The package SHA-256 does not match its pin.")
        }
    }

    static func extractZip(_ archive: String, into root: String, limit: UInt64) throws {
        let zip = try ZipReader(path: archive), fm = FileManager.default
        var names = Set<String>(), size: UInt64 = 0
        guard zip.entries.count <= 100_000 else { throw EngineInstallFailure("engines.error.package", "Too many archive entries.") }
        for entry in zip.entries {
            try Task.checkCancellation()
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            let pathParts = entry.isDirectory ? Array(parts.dropLast()) : Array(parts)
            let mode = entry.unixMode.map { $0 & 0o170000 } ?? 0
            guard !pathParts.isEmpty, pathParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !entry.name.contains("\\"), !entry.name.contains(":"), !entry.name.unicodeScalars.contains(where: { $0.value < 32 }),
                  [0, 0o100000, 0o040000, 0o120000].contains(mode),
                  names.insert(pathParts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  entry.uncompressedSize <= limit - min(size, limit) else {
                throw EngineInstallFailure("engines.error.path", "Unsafe, duplicate or oversized archive entry: \(entry.name)")
            }
            size += entry.uncompressedSize
        }
        // Create links last so no archive entry can write through a link installed earlier.
        for entry in zip.entries where !entry.isSymbolicLink {
            try Task.checkCancellation()
            let path = FilePath.combine(root, entry.name)
            if entry.isDirectory { try fm.createDirectory(atPath: path, withIntermediateDirectories: true); continue }
            try fm.createDirectory(atPath: FilePath.directoryName(path)!, withIntermediateDirectories: true)
            let output = try FileHandle(forWritingTo: Self.createFile(path))
            do {
                try zip.read(entry) { bytes in try Task.checkCancellation(); try output.write(contentsOf: bytes) }
                try output.close()
            } catch { try? output.close(); throw error }
            try fm.setAttributes([.posixPermissions: Int(entry.unixMode.map { $0 & 0o777 } ?? 0o644)], ofItemAtPath: path)
        }
        for entry in zip.entries where entry.isSymbolicLink {
            try Task.checkCancellation()
            guard entry.uncompressedSize <= 4096, let target = String(data: try zip.data(for: entry), encoding: .utf8),
                  !target.hasPrefix("/"), !target.contains("\\"), !target.contains(":"), !target.contains("\0") else {
                throw EngineInstallFailure("engines.error.path", "Unsafe archive link: \(entry.name)")
            }
            let path = FilePath.combine(root, entry.name)
            let resolved = URL(fileURLWithPath: FilePath.combine(FilePath.directoryName(path)!, target)).resolvingSymlinksInPath().path
            guard contained(resolved, in: root), fm.fileExists(resolved) else {
                throw EngineInstallFailure("engines.error.path", "Archive links must point to files inside the package.")
            }
            try fm.createDirectory(atPath: FilePath.directoryName(path)!, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
        }
    }

    private static func createFile(_ path: String) throws -> URL {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        close(descriptor)
        return URL(fileURLWithPath: path)
    }

    private static func contained(_ path: String, in root: String) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/")
    }

    static func validateTree(_ root: String) throws {
        let fm = FileManager.default
        guard !OutputCommit.isSymbolicLink(root), let entries = fm.enumerator(atPath: root) else {
            throw EngineInstallFailure("engines.error.path", "The package root is not a directory.")
        }
        while let name = entries.nextObject() as? String {
            try Task.checkCancellation()
            let path = FilePath.combine(root, name)
            let attrs = try fm.attributesOfItem(atPath: path)
            guard let type = attrs[.type] as? FileAttributeType, [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(type) else {
                throw EngineInstallFailure("engines.error.path", "Special files are not allowed in engine packages.")
            }
            if type == .typeSymbolicLink {
                let target = try fm.destinationOfSymbolicLink(atPath: path)
                guard !target.hasPrefix("/"), contained(path, in: root), fm.fileExists(atPath: path) else {
                    throw EngineInstallFailure("engines.error.path", "A package link escapes its application or is broken: \(name)")
                }
            }
        }
    }

    private func extractDMG(_ archive: String, into payload: String, package: String, stage: String) async throws {
        guard let app = ["calibre": "calibre.app", "libreoffice": "LibreOffice.app"][package] else {
            throw EngineInstallFailure("engines.error.package", "Unsupported disk image package.")
        }
        let mount = FilePath.combine(stage, "mount")
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: false)
        let runner = run
        var failure: Error?
        // Let attach finish even after cancellation; otherwise a late mount can outlive its cleanup.
        do {
            let attached = try await Task.detached { try await runner("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, archive], 30) }.value
            guard attached.exitCode == 0 else { throw EngineInstallFailure("engines.error.install", attached.standardError) }
            try Task.checkCancellation()
            let source = FilePath.combine(mount, app)
            try Self.validateTree(source)
            let copied = try await run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", "--qtn", source, FilePath.combine(payload, app)], 120)
            guard copied.exitCode == 0 else { throw EngineInstallFailure("engines.error.install", copied.standardError) }
        } catch { failure = error }
        let detached = await Task.detached { () -> Bool in
            do {
                // Match the private image, including devices left attached when mounting failed.
                let devices = try await Self.attachedDevices(archive, run: runner)
                if devices.isEmpty { return true }
                for device in devices {
                    for arguments in [["detach", device], ["detach", "-force", device]] {
                        if let result = try? await runner("/usr/bin/hdiutil", arguments, 10), result.exitCode == 0 { break }
                    }
                }
                return try await Self.attachedDevices(archive, run: runner).isEmpty
            } catch {
                return false
            }
        }.value
        guard detached else { throw EngineInstallFailure("engines.error.detach", "Could not detach the disk image at \(mount). Its staging directory was retained.") }
        if let failure { throw failure }
        try Task.checkCancellation()
        let signature = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", FilePath.combine(payload, app)], 30)
        guard signature.exitCode == 0 else { throw EngineInstallFailure("engines.error.program", "Application signature validation failed: \(signature.standardError)") }
    }

    private static func attachedDevices(_ archive: String, run: Run) async throws -> [String] {
        let info = try await run("/usr/bin/hdiutil", ["info", "-plist"], 10)
        guard info.exitCode == 0,
              let plist = try PropertyListSerialization.propertyList(from: Data(info.standardOutput.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw EngineInstallFailure("engines.error.detach", "Could not inspect attached disk images.")
        }
        let path = URL(fileURLWithPath: archive).resolvingSymlinksInPath().path
        var devices = Set<String>()
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path == path else { continue }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard let device = entities.compactMap({ $0["dev-entry"] as? String }).first,
                  device.range(of: #"^/dev/disk[0-9]+(?:s[0-9]+)*$"#, options: .regularExpression) != nil else {
                throw EngineInstallFailure("engines.error.detach", "Could not identify the private image's device.")
            }
            devices.insert("/dev/disk" + device.dropFirst(9).prefix(while: \.isNumber))
        }
        return devices.sorted()
    }

    static func downloadArchive(_ component: EngineComponent, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { progress((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0) }
        timer.resume(); defer { timer.cancel() }
        var urls = [component.url]
        // Same official mirror and unchanged pin already vetted by Tools/fetch-optional-engines.py.
        if component.id == "calibre", component.version == "9.15.0",
           component.url == "https://github.com/kovidgoyal/calibre/releases/download/v9.15.0/calibre-9.15.0.dmg" {
            urls.append("https://download.calibre-ebook.com/9.15.0/calibre-9.15.0.dmg")
        }
        for (index, url) in urls.enumerated() {
            let result = try await ProcessRunner.run("/usr/bin/curl", ["--disable", "--fail", "--location", "--silent", "--show-error",
                "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "60",
                "--max-filesize", String(component.size), "--output", path, "--write-out", "%{http_code}", url], timeout: 3600)
            if result.exitCode == 0 { progress(component.size); return }
            if index + 1 < urls.count, result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "404" { continue }
            throw EngineInstallFailure("engines.error.download", "Download failed: \(result.standardError)")
        }
    }
}
