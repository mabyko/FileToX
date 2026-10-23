// Ports of Filee.Engines/Infrastructure/EngineVersions.cs, EngineDownloads.cs (data part), CopyVersions.cs and
// ProgressEstimate.cs. Version labels for Settings → Engines, the pinned engine list (engines.json) used for install
// guidance, and the rising progress estimate for engines that report nothing while they work.

import Foundation

public enum EngineVersions {
    /// Version of this Swift engine host (reported in `hello` and for built-in engines).
    public static let hostVersion = "0.2.0"

    /// "FileToX 0.2.0" — for engines built into the host (Filee's "Filee 1.8.1").
    public static let builtIn = "FileToX \(hostVersion)"

    /// "ImageIO (macOS 27.0.1)" — for engines backed by a system framework.
    public static func system(_ framework: String) -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion == 0 ? "" : ".\(version.patchVersion)"
        return "\(framework) (macOS \(version.majorVersion).\(version.minorVersion)\(patch))"
    }

    /// The version engines.json pins for a bundled or downloaded component ("0.8.6"), or nil.
    public static func component(_ componentId: String) -> String? { EngineDownloads.components[componentId]?.version }
}

/// One download from engines.json.
public struct EngineComponent: Sendable, Equatable {
    public let id: String
    public let version: String
    public let url: String
    public let sha256: String
    public let size: Int64
    /// Archive format: zip, tar.gz, tar.xz, dmg, msi, oxt or conda.
    public let kind: String
}

/// A set of components installed together, and the engines (converter ids) it provides.
public struct EnginePackage: Sendable, Equatable {
    public let id: String
    public let components: [String]
    public let installedSize: Int64
    public let converterIds: [String]
}

public enum EngineDownloads {
    public static let runtimeIdentifier = EngineEnvironment.runtimeIdentifier

    public static let components: [String: EngineComponent] = componentsForRuntime(runtimeIdentifier)

    /// Packages offered in Settings → Engines. rhwp and 7-Zip are not listed: they are small and bundled.
    public static let packages: [EnginePackage] = [
        EnginePackage(id: "libreoffice", components: ["libreoffice"], installedSize: 1_265_000_000, converterIds: ["libreoffice"]),
        EnginePackage(id: "pandoc", components: ["pandoc"], installedSize: 236_000_000, converterIds: ["pandoc"]),
        EnginePackage(id: "ghostscript", components: ["ghostscript"], installedSize: 31_000_000, converterIds: ["ghostscript"]),
        EnginePackage(id: "ffmpeg", components: ["ffmpeg"], installedSize: 272_000_000, converterIds: ["ffmpeg"]),
        EnginePackage(id: "calibre", components: ["calibre"], installedSize: 663_000_000, converterIds: ["calibre"]),
    ]

    public static func downloadSize(_ package: EnginePackage) -> Int64 {
        package.components.reduce(0) { $0 + (components[$1]?.size ?? 0) }
    }

    public static func canDownload(_ package: EnginePackage) -> Bool {
        !package.components.isEmpty && package.components.allSatisfy { components[$0] != nil }
    }

    public static func unavailableReason(_ package: EnginePackage) -> String? {
        if canDownload(package) { return nil }
        switch package.id {
        case "ffmpeg": return "Install FFmpeg with Homebrew (brew install ffmpeg), then check again or select its bin folder."
        case "ghostscript": return "Install Ghostscript with Homebrew (brew install ghostscript), then check again or select its bin folder."
        default: return "No Filee download is available for \(runtimeIdentifier). Install \(package.id) for this Mac and select its program or .app folder."
        }
    }

    /// Packages whose download is smaller than this (bytes) are suggested.
    public static let suggestLimit: Int64 = 60_000_000

    public static func isSuggested(_ package: EnginePackage) -> Bool {
        canDownload(package) && downloadSize(package) < suggestLimit && package.id != "ghostscript"
    }

    /// The components engines.json pins for a runtime ("win-x64" is the top-level list, others under "platforms").
    public static func componentsForRuntime(_ runtime: String) -> [String: EngineComponent] {
        guard let url = ResourceBundle.url(forResource: "engines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let list: [String: Any]?
        if runtime == "win-x64" { list = root["components"] as? [String: Any] }
        else { list = ((root["platforms"] as? [String: Any])?[runtime] as? [String: Any])?["components"] as? [String: Any] }
        var result: [String: EngineComponent] = [:]
        for (name, value) in list ?? [:] {
            guard let entry = value as? [String: Any], let version = entry["version"] as? String, let url = entry["url"] as? String,
                  let sha = entry["sha256"] as? String, let size = (entry["size"] as? NSNumber)?.int64Value,
                  let kind = entry["kind"] as? String else { continue }
            result[name] = EngineComponent(id: name, version: version, url: url, sha256: sha, size: size, kind: kind)
        }
        return result
    }
}

/// Versions of engine copies FileToX didn't install (the user's own, or one found on the Mac) compared with the
/// version Filee is tested with (engines.json). Older copies work; Settings only recommends an update.
public enum CopyVersions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Int, Int)?] = [:]

    /// The tested version (major, minor), from engines.json (the Windows list when macOS has no download).
    public static func expected(_ id: String) -> (Int, Int)? {
        parse(EngineVersions.component(id) ?? EngineDownloads.componentsForRuntime("win-x64")[id]?.version)
    }

    /// The version of the copy in `folder` (major, minor), or nil when it can't be told. Cached per program and file time.
    public static func installed(_ id: String, folder: String) -> (Int, Int)? {
        guard let program = EngineEnvironment.ownCopyPrograms[id]?.first.map({ FilePath.combine(folder, $0) }),
              FileManager.default.fileExists(program) else { return nil }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: program)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(program)|\(stamp)"
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let version = parseVersion(id, read(id, program))
        lock.withLock { cache[key] = .some(version) }
        return version
    }

    /// True when the copy is older (major.minor) than the version Filee is tested with.
    public static func isOutdated(_ id: String, folder: String) -> Bool {
        guard let installed = installed(id, folder: folder), let expected = expected(id) else { return false }
        return installed < expected
    }

    /// The version in a program's version output.
    static func parseVersion(_ id: String, _ text: String) -> (Int, Int)? {
        let pattern = switch id {
        case "ffmpeg": #"ffmpeg version n?(\d+)\.(\d+)"#
        case "pandoc": #"(?m)^pandoc(?:\.exe)? (\d+)\.(\d+)"#
        case "calibre": #"calibre (\d+)\.(\d+)"#
        case "libreoffice": #"(?:MsiProductVersion=|LibreOffice\s+)(\d+)\.(\d+)"#
        default: #"(?m)^\s*(\d+)\.(\d+)"#
        }
        return firstPair(pattern, in: text)
    }

    private static func parse(_ text: String?) -> (Int, Int)? { firstPair(#"(?m)^\s*(\d+)\.(\d+)"#, in: text ?? "") }

    private static func firstPair(_ pattern: String, in text: String) -> (Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let major = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
              let minor = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else { return nil }
        return (major, minor)
    }

    private static func read(_ id: String, _ program: String) -> String {
        let arguments = id == "ffmpeg" ? ["-hide_banner", "-version"] : ["--version"]
        return (try? ProcessRunner.runBlocking(program, arguments, timeout: 10))
            .map { $0.standardOutput + "\n" + $0.standardError } ?? ""
    }
}

/// Reports a rising progress estimate until stopped: quickly at first, ever slower towards `to`, so the progress
/// ring never sits still at 0 % while an engine reports nothing.
public final class ProgressEstimate: @unchecked Sendable {
    private let timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var stopped = false

    private init(progress: ProgressHandler?, typical: TimeInterval, from: Double, to: Double) {
        guard let progress else { timer = nil; return }
        let started = Date()
        let seconds = max(0.1, typical)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
        self.timer = timer
        timer.setEventHandler { [weak self] in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            progress(Self.value(elapsed: Date().timeIntervalSince(started), typical: seconds, from: from, to: to))
        }
        timer.resume()
    }

    /// Starts reporting. `typical` is the usual duration: after it the estimate has covered about 63 % of the way.
    public static func start(_ progress: ProgressHandler?, typical: TimeInterval, from: Double = 0.1, to: Double = 0.9) -> ProgressEstimate {
        ProgressEstimate(progress: progress, typical: typical, from: from, to: to)
    }

    /// The estimate after `elapsed` seconds.
    static func value(elapsed: Double, typical: Double, from: Double, to: Double) -> Double {
        from + (to - from) * (1 - exp(-max(0, elapsed) / typical))
    }

    /// Stops reporting (Filee's Dispose). Safe to call more than once.
    public func stop() {
        lock.withLock { stopped = true }
        timer?.cancel()
    }

    deinit { timer?.cancel() }
}

/// Resources of the engine (i18n, engines.json, templates): the SwiftPM module bundle or, in the Xcode-built helper,
/// the helper app's Resources folder.
public enum ResourceBundle {
    public static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: Marker.self)
        #endif
    }()

    private final class Marker {}

    public static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory.map { "Resources/" + $0 } ?? "Resources")
    }

    public static func data(_ name: String, _ ext: String, subdirectory: String? = nil) -> Data? {
        url(forResource: name, withExtension: ext, subdirectory: subdirectory).flatMap { try? Data(contentsOf: $0) }
    }
}
