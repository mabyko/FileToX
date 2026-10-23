import Foundation

public enum SettingsMigrations {
    public static func apply(_ settings: inout AppSettings) {
        func insert(_ id: String, _ before: String) {
            if !settings.enginePriority.contains(id) { settings.enginePriority.insert(id, at: settings.enginePriority.firstIndex(of: before) ?? settings.enginePriority.count) }
        }
        if settings.schemaVersion < 2 { insert("pandoc-hwpx", "hancom"); insert("pandoc", "libreoffice") }
        if settings.schemaVersion < 3 {
            if let i = settings.enginePriority.firstIndex(of: "hancom") { settings.enginePriority.remove(at: i) }
            if let i = settings.enginePriority.firstIndex(of: "pandoc-hwpx") { settings.enginePriority[i] = "hwpx-writer" }
        }
        if settings.schemaVersion < 4 { insert("markdown", "hwpx-writer") }
        if settings.schemaVersion < 5 { if let i = settings.enginePriority.firstIndex(of: "word") { settings.enginePriority.remove(at: i) }; insert("spreadsheet", "hwpx-writer") }
        if settings.schemaVersion < 6 {
            insert("ooxml", "hwpx-writer")
            for id in ["docx-writer", "pdf-text", "email", "vector", "icns", "font", "cad", "archive", "ebook", "ffmpeg"] { insert(id, "pandoc") }
            for id in ["ghostscript", "calibre"] { insert(id, "libreoffice") }
        }
        if settings.triggers.isEmpty { settings.triggers = TriggerGesture.defaults() }
        settings.schemaVersion = AppSettings.currentSchemaVersion
    }
    public static func applyToLibrary(_ from: Int, _ presets: inout [Preset], _ profiles: inout [ToolbarProfile]) -> Bool {
        var changed = false
        func append(_ new: [Preset]) { for p in new where !presets.contains(where: { $0.id == p.id }) { presets.append(p); changed = true } }
        func filtered(_ profile: ToolbarProfile) -> ToolbarProfile { var p = profile; let ids = Set(presets.map(\.id)); p.presetIds = p.presetIds.filter(ids.contains); return p }
        if from < 4 && !profiles.contains(where: { $0.id == "text" || (!$0.isFallback && $0.extensions.contains { $0.caseInsensitiveCompare("md") == .orderedSame }) }) {
            profiles.insert(filtered(BuiltInData.textProfile()), at: profiles.firstIndex(where: \.isFallback) ?? profiles.count); changed = true
        }
        if from < 5 {
            append(BuiltInData.spreadsheetPresets())
            var insertAt = profiles.firstIndex { $0.id == "office" }.map { $0 + 1 } ?? profiles.firstIndex(where: \.isFallback) ?? profiles.count
            for split in [BuiltInData.spreadsheetProfile(), BuiltInData.presentationProfile()] where !profiles.contains(where: { $0.id == split.id }) {
                if let office = profiles.firstIndex(where: { $0.id == "office" }) {
                    let count = profiles[office].extensions.count
                    profiles[office].extensions.removeAll { split.extensions.contains($0) }
                    changed = changed || count != profiles[office].extensions.count
                }
                if profiles.contains(where: { p in !p.isFallback && p.extensions.contains { e in split.extensions.contains { $0.caseInsensitiveCompare(e) == .orderedSame } } }) { continue }
                profiles.insert(filtered(split), at: min(insertAt, profiles.count)); insertAt += 1; changed = true
            }
            if let pdf = profiles.firstIndex(where: { $0.id == "pdf" }) {
                let count = profiles[pdf].presetIds.count; profiles[pdf].presetIds.removeAll { ["to-docx", "to-hwpx", "to-txt"].contains($0) }; changed = changed || count != profiles[pdf].presetIds.count
            }
        }
        if from < 6 {
            append(BuiltInData.catalogPresets())
            var claimed = Set(profiles.filter { !$0.isFallback }.flatMap(\.extensions).map { $0.lowercased() })
            let defaults = BuiltInData.createProfiles()
            for i in profiles.indices where !profiles[i].isFallback {
                if let d = defaults.first(where: { $0.id == profiles[i].id }) {
                    for ext in d.extensions where claimed.insert(ext.lowercased()).inserted { profiles[i].extensions.append(ext); changed = true }
                }
            }
            var insertAt = profiles.firstIndex { $0.id == "text" }.map { $0 + 1 } ?? profiles.firstIndex(where: \.isFallback) ?? profiles.count
            for var p in BuiltInData.catalogProfiles() where !profiles.contains(where: { $0.id == p.id }) {
                p.extensions = p.extensions.filter { claimed.insert($0.lowercased()).inserted }
                if p.extensions.isEmpty { continue }
                profiles.insert(filtered(p), at: min(insertAt, profiles.count)); insertAt += 1; changed = true
            }
            if offer(presets, &profiles, "pdf", "to-docx", "to-jpg") { changed = true }
            if offer(presets, &profiles, profiles.first(where: \.isFallback)?.id ?? "mixed", "zip-all", "merge-pdf") { changed = true }
        }
        if from < 7 {
            append(BuiltInData.hwpPresets())
            for (profile, preset, after) in [("pdf", "to-md", "to-txt"), ("pdf", "to-epub", "to-md"), ("pdf", "to-hwp", "to-hwpx"), ("office", "to-hwp", "to-hwpx"), ("office", "to-png", "to-epub"), ("hwp", "to-hwp", "to-hwpx"), ("hwp", "to-jpg", "to-png"), ("hwp", "to-epub", "to-md"), ("spreadsheets", "to-hwp", "to-hwpx"), ("presentations", "to-hwp", "to-hwpx"), ("text", "to-hwp", "to-hwpx"), ("ebooks", "to-hwp", "to-hwpx")] {
                if offer(presets, &profiles, profile, preset, after) { changed = true }
            }
        }
        if from < 8 { for i in presets.indices where presets[i].output.location == .sameFolder { presets[i].output.location = .default; changed = true } }
        return changed
    }
    private static func offer(_ presets: [Preset], _ profiles: inout [ToolbarProfile], _ profile: String, _ preset: String, _ after: String?) -> Bool {
        guard let i = profiles.firstIndex(where: { $0.id == profile }), !profiles[i].presetIds.contains(preset), profiles[i].presetIds.count < ToolbarProfile.maxSlices, presets.contains(where: { $0.id == preset }) else { return false }
        let index = after.flatMap { profiles[i].presetIds.firstIndex(of: $0) }.map { $0 + 1 } ?? profiles[i].presetIds.count
        profiles[i].presetIds.insert(preset, at: index); return true
    }
}
