import Foundation

struct FfmpegCapabilities {
    let encoders: Set<String>
    let muxers: Set<String>

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: String, capabilities: Self)] = [:]

    static func read(_ executable: String) async throws -> Self {
        try Task.checkCancellation()
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(modified)|\(attributes[.size] ?? "")|\(attributes[.systemFileNumber] ?? "")"
        if let hit = lock.withLock({ cache[path] }), hit.stamp == stamp { return hit.capabilities }

        func listing(_ option: String) async throws -> String {
            let result = try await ProcessRunner.run(path, ["-hide_banner", option], timeout: 10)
            guard result.exitCode == 0 else {
                throw ConversionError("Could not inspect FFmpeg \(option) (exit code \(result.exitCode)).")
            }
            return result.standardOutput
        }
        let encoders = try await listing("-encoders")
        let muxers = try await listing("-muxers")
        let result = parse(encoders: encoders, muxers: muxers)
        guard !result.encoders.isEmpty, !result.muxers.isEmpty else {
            throw ConversionError("FFmpeg did not report its encoders and output formats.")
        }
        try Task.checkCancellation()
        lock.withLock { cache[path] = (stamp, result) }
        return result
    }

    static func parse(encoders: String, muxers: String) -> Self {
        func names(_ text: String, encoder: Bool) -> Set<String> {
            Set(text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, fields[1] != "=" else { return [] }
                let flags = fields[0]
                guard encoder ? (flags.count == 6 && "VAS".contains(flags.first!))
                    : (flags.count <= 3 && flags.contains("E")) else { return [] }
                return fields[1].split(separator: ",").map(String.init)
            })
        }
        return Self(encoders: names(encoders, encoder: true), muxers: names(muxers, encoder: false))
    }

    func validate(_ passes: [FfmpegPass], target: String) throws {
        var requiredEncoders = Set<String>(), requiredMuxers = Set<String>()
        for pass in passes {
            for (option, value) in zip(pass.arguments, pass.arguments.dropFirst()) {
                if ["-c:v", "-c:a"].contains(option), value != "copy" { requiredEncoders.insert(value) }
                if option == "-f" { requiredMuxers.insert(value) }
            }
        }
        let missingEncoders = requiredEncoders.subtracting(encoders).sorted()
        let missingMuxers = requiredMuxers.subtracting(muxers).sorted()
        guard !missingEncoders.isEmpty || !missingMuxers.isEmpty else { return }
        var details: [String] = []
        if !missingEncoders.isEmpty { details.append("encoders: " + missingEncoders.joined(separator: ", ")) }
        if !missingMuxers.isEmpty { details.append("output formats: " + missingMuxers.joined(separator: ", ")) }
        throw ConversionError("This FFmpeg build cannot write \(target.uppercased()). Missing \(details.joined(separator: "; ")). Choose an FFmpeg build with these features in the engine settings.")
    }
}
