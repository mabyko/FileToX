import XCTest
@testable import FileToXEngineKit

final class UserDataStoreTests: XCTestCase {
    func testRoundTripsSettingsPresetsProfilesAndFlags() throws {
        let d = CoreTempDir(), store = UserDataStore(d.path); try store.load()
        store.settings.language = "ko"; store.settings.theme.accent = "#1D9E75"; store.settings.triggers[0].modifiers = [.alt,.shift]
        var p = corePreset("webp"); p.id = "mine"; p.name = "Mine"; p.image.quality = 42
        store.presets.append(p); store.profiles[0].presetIds.insert("mine",at:0); try store.saveSettings(); try store.saveLibrary()
        let reload = UserDataStore(d.path); try reload.load()
        XCTAssertEqual(reload.settings.language,"ko"); XCTAssertEqual(reload.settings.theme.accent,"#1D9E75"); XCTAssertEqual(reload.settings.triggers[0].modifiers,[.alt,.shift]); XCTAssertEqual(reload.findPreset("mine")?.image.quality,42); XCTAssertEqual(reload.profiles[0].presetIds.first,"mine")
        let json = try d.read("settings.json"); XCTAssertTrue(json.contains("\"Drag\"")); XCTAssertTrue(json.contains("Alt, Shift")); XCTAssertFalse(json.contains("reduceMotion"))
    }
    func testHistoryLimitDisabledClearAndTimestampPrecision() throws {
        let d = CoreTempDir(), store = UserDataStore(d.path); try store.load()
        for i in 0..<205 { var e = HistoryEntry(); e.jobId = String(i); try store.addHistory(e) }
        XCTAssertEqual(store.history.count,200); XCTAssertEqual(store.history.first?.jobId,"204")
        store.settings.keepHistory = false; try store.addHistory(HistoryEntry()); XCTAssertEqual(store.history.count,200)
        try store.clearHistory(); let reload = UserDataStore(d.path); try reload.load(); XCTAssertTrue(reload.history.isEmpty)
        for s in ["2026-10-11T21:10:09.752468+09:00","2026-10-11T21:10:09.7524687+09:00","2026-10-11T12:10:09Z"] {
            let stamp = try FileeJson.decode(EngineTimestamp.self,from:Data(("\"" + s + "\"").utf8))
            XCTAssertEqual(stamp.value,s); XCTAssertEqual(try JSONDecoder().decode(String.self,from:FileeJson.encode(stamp)),s)
        }
    }
    func testSchemaOneSettingsAndSchemaThreeTextMigrationOnce() throws {
        let d = CoreTempDir(); try d.file("settings.json",#"{ "schemaVersion": 1, "enginePriority": ["magick", "word", "hancom", "libreoffice"] }"#)
        let store = UserDataStore(d.path); try store.load()
        XCTAssertEqual(store.settings.enginePriority,["magick","markdown","spreadsheet","ooxml","hwpx-writer","docx-writer","pdf-text","email","vector","icns","font","cad","archive","ebook","ffmpeg","pandoc","ghostscript","calibre","libreoffice"])
        XCTAssertEqual(store.settings.schemaVersion,8)
        store.profiles.removeAll { $0.id == "text" }; store.settings.schemaVersion = 3; store.settings.enginePriority.removeAll { $0 == "markdown" }; try store.saveSettings(); try store.saveLibrary()
        let next = UserDataStore(d.path); try next.load()
        XCTAssertEqual(next.profiles.firstIndex { $0.id == "text" },next.profiles.firstIndex { $0.id == "mixed" }!.advanced(by:-1))
        XCTAssertTrue(next.profiles.first { $0.id == "text" }!.extensions.contains("md"))
        next.profiles.removeAll { $0.id == "text" }; try next.saveLibrary(); try next.load(); XCTAssertFalse(next.profiles.contains { $0.id == "text" })
    }
    func testSchemaFourOfficeSplitAndUserClaims() throws {
        var presets = BuiltInData.createPresets().filter { !["to-xlsx","to-csv"].contains($0.id) }
        var profiles = BuiltInData.createProfiles().filter { !["spreadsheets","presentations"].contains($0.id) }
        let office = profiles.firstIndex { $0.id == "office" }!
        profiles[office].extensions += ["xlsx","xls","ods","csv","pptx","ppt","odp"]
        XCTAssertTrue(SettingsMigrations.applyToLibrary(4,&presets,&profiles))
        XCTAssertEqual(profiles[office + 1].id,"spreadsheets"); XCTAssertEqual(profiles[office + 2].id,"presentations")
        XCTAssertFalse(profiles[office].extensions.contains("xlsx")); XCTAssertNotNil(presets.first { $0.id == "to-xlsx" }); XCTAssertFalse(profiles.first { $0.id == "pdf" }!.presetIds.contains("to-hwpx"))
        profiles = BuiltInData.createProfiles().filter { !["spreadsheets","presentations"].contains($0.id) }; var mine = ToolbarProfile(); mine.id = "mine"; mine.extensions = ["xlsx"]; profiles.insert(mine,at:0)
        _ = SettingsMigrations.applyToLibrary(4,&presets,&profiles)
        XCTAssertFalse(profiles.contains { $0.id == "spreadsheets" }); XCTAssertTrue(profiles.contains { $0.id == "presentations" }); XCTAssertEqual(profiles[0].extensions,["xlsx"])
        profiles = BuiltInData.createProfiles().filter { $0.id != "text" }; profiles[0].extensions.append("md")
        _ = SettingsMigrations.applyToLibrary(3,&presets,&profiles); XCTAssertFalse(profiles.contains { $0.id == "text" })
    }
    func testSchemaFiveCatalogMigrationAndMixedExtensionsDoNotClaim() {
        for mixed in [false,true] {
            let catalogIds = Set(BuiltInData.catalogProfiles().map(\.id)), presetIds = Set(BuiltInData.catalogPresets().map(\.id))
            var presets = BuiltInData.createPresets().filter { !presetIds.contains($0.id) }, profiles = BuiltInData.createProfiles().filter { !catalogIds.contains($0.id) }
            profiles[0].extensions = ["png","jpg"]
            var mine = ToolbarProfile(); mine.id = "mine"; mine.extensions = mixed ? ["mp3","jpg"] : ["mp3"]; mine.isFallback = mixed; if mixed { profiles.append(mine) } else { profiles.insert(mine,at:0) }
            let pdf = profiles.firstIndex { $0.id == "pdf" }!, fallback = profiles.firstIndex { $0.id == "mixed" }!
            profiles[pdf].presetIds.removeAll { $0 == "to-docx" }; profiles[fallback].presetIds.removeAll { $0 == "zip-all" }
            XCTAssertTrue(SettingsMigrations.applyToLibrary(5,&presets,&profiles))
            XCTAssertEqual(profiles.firstIndex { $0.id == "ebooks" },profiles.firstIndex { $0.id == "text" }! + 1)
            XCTAssertTrue(profiles.first { $0.id == "images" }!.extensions.contains("cr2"))
            XCTAssertEqual(profiles.first { $0.id == "audio" }!.extensions.contains("mp3"),mixed)
            XCTAssertTrue(profiles.first { $0.id == "audio" }!.extensions.contains("flac"))
            XCTAssertEqual(Array(profiles.first { $0.id == "pdf" }!.presetIds.prefix(3)),["to-png","to-jpg","to-docx"])
            XCTAssertTrue(profiles.first { $0.id == "mixed" }!.presetIds.contains("zip-all"))
            if !mixed { let all = profiles.flatMap(\.extensions); XCTAssertEqual(all.count,Set(all).count) }
        }
    }
    func testSchemaSixMissingOffersAndSevenDefaultLocationAreIdempotent() {
        var presets = BuiltInData.createPresets().filter { $0.id != "to-hwp" }, profiles = BuiltInData.createProfiles()
        for i in profiles.indices {
            profiles[i].presetIds.removeAll { $0 == "to-hwp" }
            if profiles[i].id == "pdf" { profiles[i].presetIds.removeAll { ["to-md","to-epub"].contains($0) } }
            if profiles[i].id == "office" { profiles[i].presetIds.removeAll { $0 == "to-png" } }
            if profiles[i].id == "hwp" { profiles[i].presetIds.removeAll { ["to-jpg","to-epub"].contains($0) } }
        }
        XCTAssertTrue(SettingsMigrations.applyToLibrary(6,&presets,&profiles))
        for p in BuiltInData.createProfiles() { XCTAssertEqual(profiles.first { $0.id == p.id }?.presetIds,p.presetIds) }
        XCTAssertFalse(SettingsMigrations.applyToLibrary(6,&presets,&profiles))
        for i in presets.indices where presets[i].output.location == .default { presets[i].output.location = .sameFolder }
        presets.append(corePreset("png") { $0.id = "mine"; $0.output.location = .customFolder; $0.output.customFolder = "/out" })
        XCTAssertTrue(SettingsMigrations.applyToLibrary(7,&presets,&profiles)); XCTAssertFalse(SettingsMigrations.applyToLibrary(7,&presets,&profiles))
        XCTAssertEqual(presets.first { $0.id == "to-png" }?.output.location,.default); XCTAssertEqual(presets.first { $0.id == "pdf-split" }?.output.location,.subfolder); XCTAssertEqual(presets.last?.output.location,.customFolder)
    }
    func testConsistencyImportExportCorruptFileAndReset() throws {
        let d = CoreTempDir(), store = UserDataStore(d.path); try store.load()
        var scans = ToolbarProfile(); scans.id = "scans"; scans.isFallback = true; scans.extensions = ["jpg","pdf"]
        store.profiles.append(scans); store.presets.append(corePreset("png") { $0.id = "shared" }); store.profiles[0].presetIds += ["missing","to-png"]
        try store.saveLibrary(); XCTAssertFalse(store.profiles[0].presetIds.contains("missing")); XCTAssertEqual(Set(store.profiles[0].presetIds).count,store.profiles[0].presetIds.count)
        try store.export(d.path + "/bundle.json")
        XCTAssertEqual(try FileeJson.decode(PresetBundle.self,from:Data(contentsOf:URL(fileURLWithPath:d.path + "/bundle.json"))).schemaVersion,1)
        let other = CoreTempDir(), target = UserDataStore(other.path); try target.load(); _ = try target.import(d.path + "/bundle.json")
        XCTAssertNotNil(target.findPreset("shared")); XCTAssertEqual(target.profiles.filter(\.isFallback).map(\.id),["mixed","scans"])
        XCTAssertEqual(ProfileSelector.select(target.profiles,["a.jpg","b.pdf"])?.id,"scans"); XCTAssertEqual(ProfileSelector.select(target.profiles,["a.jpg","b.docx"])?.id,"mixed")
        target.profiles.removeAll( where: \.isFallback); try target.saveLibrary(); XCTAssertEqual(target.profiles.filter(\.isFallback).map(\.id),["mixed"])
        try target.resetLibrary(); XCTAssertNil(target.findPreset("shared"))
        try d.file("presets.json","{ not json"); try store.load(); XCTAssertFalse(store.presets.isEmpty); XCTAssertTrue(FileManager.default.fileExists(d.path + "/presets.json.broken"))
        let data = Data("{ // comment\n \"language\": \"ko\", \"engineOwnCopies\": {}, }".utf8)
        XCTAssertEqual(try FileeJson.decode(AppSettings.self,from:data).language,"ko")
    }
}
final class DefaultOutputTests: XCTestCase {
    func testDefaultsOwnLocationsDatesAndPersistence() throws {
        XCTAssertEqual(Preset().output.location,.default)
        XCTAssertTrue(BuiltInData.createPresets().filter { $0.id != "pdf-split" }.allSatisfy { $0.output.location == .default })
        let p = corePreset("png") { $0.output.fileNamePattern = "{name}_x"; $0.output.conflict = .overwrite; $0.output.keepDates = true }
        var s = AppSettings(); var used = s.withDefaultOutput(p)
        XCTAssertEqual(used.output.location,.sameFolder); XCTAssertEqual(used.output.fileNamePattern,"{name}_x"); XCTAssertEqual(p.output.location,.default)
        s.defaultOutput.location = .customFolder; s.defaultOutput.customFolder = "/Converted"; used = s.withDefaultOutput(p)
        XCTAssertEqual(used.id,p.id); XCTAssertEqual(used.output.conflict,.overwrite); XCTAssertTrue(used.output.keepDates); XCTAssertEqual(used.output.customFolder,"/Converted")
        s.defaultOutput.location = .subfolder; s.defaultOutput.subfolderName = "out"; XCTAssertEqual(s.withDefaultOutput(p).output.subfolderName,"out")
        let own = corePreset("png") { $0.output.location = .sameFolder }
        XCTAssertEqual(s.withDefaultOutput(own),own); s.keepFileDates = true; XCTAssertTrue(s.withDefaultOutput(own).output.keepDates); XCTAssertFalse(own.output.keepDates)
        let d = CoreTempDir(), store = UserDataStore(d.path); try store.load(); store.settings = s; try store.saveSettings(); try store.load(); XCTAssertEqual(store.settings.defaultOutput,s.defaultOutput)
        let presets = BuiltInData.createPresets(), ids = Set(presets.map(\.id)); XCTAssertEqual(ids.count,presets.count)
        for profile in BuiltInData.createProfiles() { XCTAssertTrue(profile.presetIds.allSatisfy(ids.contains)) }
        XCTAssertEqual(BuiltInData.createProfiles().filter(\.isFallback).count,1)
        XCTAssertTrue(presets.allSatisfy { $0.targetFormat == "*" || FormatRegistry.find(id:$0.targetFormat) != nil })
    }
}
