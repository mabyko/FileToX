import Foundation

enum Validation {
    static let maxPaths = 10_000
    static func paths(_ paths: [String]) throws -> [String] {
        if paths.isEmpty { throw invalid("paths is empty.") }
        if paths.count > maxPaths { throw invalid("At most \(maxPaths) paths are accepted.") }
        var seen = Set<String>()
        return try paths.filter { p in
            if !p.hasPrefix("/") || p.contains("\0") { throw invalid("Not an absolute path: \(p)") }
            return seen.insert(FileSystemPaths.key(p)).inserted
        }
    }
    static func isTarget(_ format: String) -> Bool { format == BuiltInData.sameAsSource || format == FormatRegistry.folder || FormatRegistry.find(id: format)?.writable == true }
    static func preset(_ p: Preset) throws {
        if p.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw invalid("A preset needs an id.") }
        if !isTarget(p.targetFormat) { throw invalid("Preset \(p.id): \(p.targetFormat) is not a target format.") }
        func range(_ value: Int, _ min: Int, _ max: Int, _ name: String) throws { if value < min || value > max { throw invalid("Preset \(p.id): \(name) must be \(min)-\(max).") } }
        try range(p.image.quality, 1, 100, "image.quality"); try range(p.image.resizePercent, 1, 1000, "image.resizePercent"); try range(p.image.longEdge, 16, 20000, "image.longEdge")
        if let dpi = p.image.dpi { try range(dpi, 36, 2400, "image.dpi") }
        if p.image.icoSizes.contains(where: { $0 < 16 || $0 > 256 }) { throw invalid("Preset \(p.id): image.icoSizes must be 16-256.") }
        try range(p.pdf.renderDpi, 36, 1200, "pdf.renderDpi")
        if !p.pdf.marginMm.isFinite || p.pdf.marginMm < 0 || p.pdf.marginMm > 100 { throw invalid("Preset \(p.id): pdf.marginMm must be 0-100.") }
        if p.pdf.pageRange.contains(where: { !(($0.isASCII && $0.isNumber) || ",- ".contains($0)) }) { throw invalid("Preset \(p.id): pdf.pageRange may only hold digits, commas, dashes and spaces.") }
        try range(p.media.maxHeight, 0, 10000, "media.maxHeight"); try range(p.media.audioBitrateKbps, 0, 2000, "media.audioBitrateKbps"); try range(p.media.audioChannels, 0, 2, "media.audioChannels")
        if p.media.audioSampleRate != 0 { try range(p.media.audioSampleRate, 8000, 48000, "media.audioSampleRate") }
        try output(p.output, "Preset \(p.id)")
    }
    static func output(_ rule: OutputRule, _ owner: String) throws {
        if !rule.customFolder.isEmpty && !FilePath.isFullyQualified(rule.customFolder) { throw invalid("\(owner): output.customFolder must be an absolute path.") }
        try renames(rule.renames, owner)
    }
    static func renames(_ steps: [RenameStep], _ owner: String) throws { for step in steps where step.kind == .regex { if let error = OutputPathResolver.renameError(step.find) { throw invalid("\(owner): invalid regular expression: \(error)") } } }
    static func library(_ presets: [Preset], _ profiles: [ToolbarProfile]) throws {
        for p in presets { try preset(p) }
        try unique(presets.map(\.id), "preset"); try unique(profiles.map(\.id), "profile")
        for p in profiles {
            if p.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw invalid("A profile needs an id.") }
            if p.presetIds.count > ToolbarProfile.maxSlices { throw invalid("Profile \(p.id): at most \(ToolbarProfile.maxSlices) presets.") }
        }
    }
    static func settings(_ s: AppSettings) throws {
        if s.schemaVersion != AppSettings.currentSchemaVersion { throw invalid("settings.schemaVersion must be \(AppSettings.currentSchemaVersion).") }
        if s.language != "auto" && !Localizer.languages.contains(s.language) { throw invalid("Unknown language \(s.language).") }
        if s.defaultOutput.location == .default { throw invalid("settings.defaultOutput.location can't be default.") }
        if !s.defaultOutput.customFolder.isEmpty && !FilePath.isFullyQualified(s.defaultOutput.customFolder) { throw invalid("settings.defaultOutput.customFolder must be an absolute path.") }
        try unique(s.watchFolders.map(\.id), "watch rule")
        for rule in s.watchFolders { try watchRule(rule) }
        for path in s.engineOwnCopies.values where !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !FilePath.isFullyQualified(path) { throw invalid("settings.engineOwnCopies must hold absolute paths.") }
        }
    }
    static func watchRule(_ rule: WatchRule) throws {
        if rule.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw invalid("A watch rule needs an id.") }
        if rule.enabled && (rule.folder.isEmpty || rule.presetId.isEmpty) { throw invalid("Choose a folder and preset for an enabled watch rule.") }
        for path in [rule.folder, rule.outputFolder] where !path.isEmpty {
            if !FilePath.isFullyQualified(path) || path.contains("\0") { throw invalid("Watch folders must be absolute paths without null characters.") }
        }
        if !rule.folder.isEmpty && WatchFolderMonitor.contains(WatchFolderMonitor.canonical(rule.resolvedOutputFolder), WatchFolderMonitor.canonical(rule.folder)) {
            throw invalid("A watch output folder cannot be the input folder or its parent.")
        }
        for pattern in rule.include {
            if let error = FileNameFilter.validate(pattern) { throw invalid("Watch folder: invalid include pattern: \(error)") }
        }
        try renames(rule.renames, "Watch folder")
    }
    private static func unique(_ ids: [String], _ what: String) throws { var seen = Set<String>(); for id in ids where !seen.insert(id).inserted { throw invalid("Duplicate \(what) id \(id).") } }
    private static func invalid(_ message: String) -> WireException { WireException("invalid_input", message) }
}
