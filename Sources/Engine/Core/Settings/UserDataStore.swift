import Foundation
import Darwin

public struct PresetBundle {
    public var schemaVersion = 1
    public var presets: [Preset] = []
    public var profiles: [ToolbarProfile] = []
    public init() {}
}
public final class UserDataStore {
    public static var defaultDirectory: String { FilePath.combine(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path, "Filee") }
    public let directory: String
    public var settings = AppSettings()
    public var presets = BuiltInData.createPresets()
    public var profiles = BuiltInData.createProfiles()
    public var history: [HistoryEntry] = []
    public var settingsChanged: (() -> Void)?, libraryChanged: (() -> Void)?, historyChanged: (() -> Void)?
    private let lock = NSRecursiveLock()
    public init(_ directory: String) { self.directory = directory }
    public func load() throws {
        try FileManager.default.createDirectoryIfNeeded(directory)
        settings = read("settings.json") ?? AppSettings()
        presets = read("presets.json") ?? BuiltInData.createPresets()
        profiles = read("profiles.json") ?? BuiltInData.createProfiles()
        history = read("history.json") ?? []
        let schema = settings.schemaVersion
        SettingsMigrations.apply(&settings)
        let changed = FileManager.default.fileExists(path("profiles.json")) && SettingsMigrations.applyToLibrary(schema, &presets, &profiles)
        ensureConsistency()
        if schema < AppSettings.currentSchemaVersion && FileManager.default.fileExists(path("settings.json")) { try write(path("settings.json"), settings) }
        if changed { try write(path("presets.json"), presets); try write(path("profiles.json"), profiles) }
    }
    public func saveSettings() throws { try write(path("settings.json"), settings); settingsChanged?() }
    public func saveLibrary() throws { ensureConsistency(); try write(path("presets.json"), presets); try write(path("profiles.json"), profiles); libraryChanged?() }
    public func addHistory(_ entry: HistoryEntry) throws {
        guard settings.keepHistory else { return }
        try lock.withLock { history.insert(entry, at: 0); if history.count > 200 { history.removeSubrange(200...) }; try write(path("history.json"), history) }
        historyChanged?()
    }
    public func clearHistory() throws { try lock.withLock { history.removeAll(); try write(path("history.json"), history) }; historyChanged?() }
    public func resetLibrary() throws { presets = BuiltInData.createPresets(); profiles = BuiltInData.createProfiles(); try saveLibrary() }
    public func findPreset(_ id: String) -> Preset? { presets.first { $0.id == id } }
    public func export(_ path: String) throws { var b = PresetBundle(); b.presets = presets; b.profiles = profiles; try write(path, b) }
    public func `import`(_ path: String) throws -> Int {
        let b = try FileeJson.decode(PresetBundle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for p in b.presets { presets.removeAll { $0.id == p.id }; presets.append(p) }
        for p in b.profiles { profiles.removeAll { $0.id == p.id }; profiles.append(p) }
        try saveLibrary(); return b.presets.count + b.profiles.count
    }
    func ensureConsistency() {
        let ids = Set(presets.map(\.id))
        for i in profiles.indices { var seen = Set<String>(); profiles[i].presetIds = Array(profiles[i].presetIds.filter { ids.contains($0) && seen.insert($0).inserted }.prefix(ToolbarProfile.maxSlices)) }
        if !profiles.contains(where: \.isFallback), var mixed = BuiltInData.createProfiles().first(where: \.isFallback) { mixed.presetIds = mixed.presetIds.filter(ids.contains); profiles.append(mixed) }
    }
    private func path(_ name: String) -> String { FilePath.combine(directory, name) }
    private func read<T: Decodable>(_ name: String) -> T? {
        let p = path(name)
        guard FileManager.default.fileExists(p) else { return nil }
        do { return try FileeJson.decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: p))) }
        catch { FileManager.default.removeIfPresent(p + ".broken"); try? FileManager.default.copyItem(atPath: p, toPath: p + ".broken"); return nil }
    }
    private func write<T: Encodable>(_ path: String, _ value: T) throws {
        try lock.withLock {
            try FileManager.default.createDirectoryIfNeeded(FilePath.directoryName(path) ?? directory)
            let temp = path + ".tmp"
            try FileeJson.encode(value).write(to: URL(fileURLWithPath: temp))
            guard Darwin.rename(temp, path) == 0 else { throw ConversionError(String(cString: strerror(errno))) }
        }
    }
}
