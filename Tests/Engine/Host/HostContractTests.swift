import XCTest
@testable import FileToXEngineKit

final class HostContractTests: XCTestCase {
    func testLocalizationAndJapaneseCoverageAndPlaceholders() throws {
        XCTAssertNotEqual(Localizer("ko")["error.no_route"],Localizer("en")["error.no_route"])
        for code in ["zh-CN","zh-TW","zh"] { XCTAssertEqual(Localizer(code).language,"zh-CN") }
        for code: String? in ["fr","auto",nil," ","ja-unknown","jaunknown"] { XCTAssertEqual(Localizer.resolve(code),"en") }
        let ja = Localizer("ja-JP"), en = Localizer("en")
        XCTAssertEqual(ja.language,"ja"); XCTAssertEqual(ja["preset.half_size"],"サイズを半分に"); XCTAssertEqual(ja["presets.same_as_source"],"元のファイルと同じ形式"); XCTAssertEqual(ja["app.tagline"],en["app.tagline"])
        XCTAssertEqual(Localizer("ko")["no.such.key"],"no.such.key"); XCTAssertTrue(en.format("engine.reason.needs_package","Pandoc").contains("Pandoc")); XCTAssertFalse(en.displayName(BuiltInData.createPresets()[0]).hasPrefix("preset."))
        let english = try FileeJson.decode([String:String].self,from:XCTUnwrap(ResourceBundle.data("en","json",subdirectory:"i18n")))
        let japanese = try FileeJson.decode([String:String].self,from:XCTUnwrap(ResourceBundle.data("ja","json",subdirectory:"i18n")))
        let prefixes = ["error.","engine.","engines.","preset.","profile.","format.","donut.","toast.","common."]
        for key in english.keys where prefixes.contains(where:key.hasPrefix) || key == "presets.same_as_source" { XCTAssertNotNil(japanese[key],key) }
        let regex = try NSRegularExpression(pattern:#"\{\d+[^}]*\}"#)
        func placeholders(_ s: String) -> [String] { regex.matches(in:s,range:NSRange(location:0,length:s.utf16.count)).map { (s as NSString).substring(with:$0.range) }.sorted() }
        for (key,value) in japanese { if let english = english[key] { XCTAssertEqual(placeholders(value),placeholders(english),key) } }
        var changes = 0; ja.languageChanged = { changes += 1 }; ja.setLanguage("ja"); ja.setLanguage("ko"); XCTAssertEqual(changes,1)
    }
    func testFileToXDefaultsMigrationMarker() throws {
        let d = CoreTempDir(), store = UserDataStore(d.path); try store.load(); try EngineHostMain.applyDefaults(store)
        XCTAssertEqual(store.settings.language,"en"); XCTAssertEqual(store.settings.theme.accent,"#3478F6")
        store.settings.language = "ko"; store.settings.theme.accent = "#7F77DD"; try store.saveSettings(); try store.load(); try EngineHostMain.applyDefaults(store)
        XCTAssertEqual(store.settings.language,"ko"); XCTAssertEqual(store.settings.theme.accent,"#7F77DD")
        store.settings.language = "auto"; store.settings.theme.accent = "#C4603A"; try store.saveSettings(); try store.load(); try EngineHostMain.applyDefaults(store)
        XCTAssertEqual(store.settings.language,"en"); XCTAssertEqual(store.settings.theme.accent,"#C4603A")
        let old = UserDataStore(d.path + "/old"); try old.load(); old.settings.language = "ko"; try old.saveSettings(); try EngineHostMain.applyDefaults(old)
        XCTAssertEqual(old.settings.language,"ko"); XCTAssertEqual(old.settings.theme.accent,"#3478F6")
    }
    func testStrictCodecsAllBuiltInsAndMutations() throws {
        for preset in BuiltInData.createPresets() {
            let node = try WireJson.toNode(preset)
            let decoded = try WireJson.readStrict(Preset.self,node,"preset"); XCTAssertEqual(decoded,preset)
            XCTAssertTrue(hostEqual(node,try WireJson.toNode(decoded)))
        }
        let profiles = BuiltInData.createProfiles(); XCTAssertEqual(try WireJson.readStrict([ToolbarProfile].self,WireJson.toNode(profiles),"profiles"),profiles)
        var s = AppSettings(), rule = WatchRule(); rule.folder = "/tmp/w"; rule.renames = [.init(kind:.regex,find:"a",replace:"b")]; s.watchFolders = [rule]
        XCTAssertEqual(try WireJson.readStrict(AppSettings.self,WireJson.toNode(s),"settings"),s)
        let original = hostObject(try WireJson.toNode(Preset()))
        XCTAssertTrue(hostObject(original["image"])["dpi"] is NSNull)
        let mutations: [(inout [String:Any]) -> Void] = [
            { $0.removeValue(forKey:"targetFormat") },
            { var image = hostObject($0["image"]); image.removeValue(forKey:"quality"); $0["image"] = image },
            { $0["surprise"] = 1 },
            { var image = hostObject($0["image"]); image["surprise"] = 1; $0["image"] = image },
            { $0["image"] = NSNull() }, { $0["name"] = NSNull() },
            { var o = hostObject($0["output"]); o["conflict"] = 1; $0["output"] = o },
            { var o = hostObject($0["output"]); o["conflict"] = "explode"; $0["output"] = o },
            { var o = hostObject($0["output"]); o["renames"] = [NSNull()]; $0["output"] = o },
            { var image = hostObject($0["image"]); image["quality"] = "90"; $0["image"] = image }
        ]
        for mutation in mutations {
            var node = original; mutation(&node)
            XCTAssertThrowsError(try WireJson.readStrict(Preset.self,node,"preset")) { XCTAssertEqual(($0 as? WireException)?.code,"bad_request") }
        }
        var node = original, image = hostObject(node["image"]); image["icoSizes"] = [16,256,32]; node["image"] = image
        XCTAssertEqual(try WireJson.readStrict(Preset.self,node,"preset").image.icoSizes,[16,256,32])
        var rename = hostObject(try WireJson.toNode(RenameStep())); rename["isBlank"] = "ignored getter input"
        XCTAssertTrue(try WireJson.readStrict(RenameStep.self,rename,"rename").isBlank)
        var settings = hostObject(try WireJson.toNode(s)); settings["engineOwnCopies"] = ["pandoc":NSNull()]
        XCTAssertThrowsError(try WireJson.readStrict(AppSettings.self,settings,"settings"))
    }
    func testStrictWireGrammarIntegerBoundsAndOutputLimit() throws {
        for text in ["{\"x\":1,}", "[1,]", "{/*comment*/\"x\":1}", String(repeating:"[",count:65) + "0" + String(repeating:"]",count:65)] { XCTAssertThrowsError(try WireJson.parse(Data(text.utf8))) }
        XCTAssertNil(WireJson.integer(NSNumber(value:2147483648 as Int64)))
        var node = hostObject(try WireJson.toNode(Preset())), image = hostObject(node["image"])
        for invalid: NSNumber in [NSNumber(value:90.0), NSNumber(value:2147483648 as Int64), NSNumber(value:true)] {
            image["quality"] = invalid; node["image"] = image
            XCTAssertThrowsError(try WireJson.readStrict(Preset.self,node,"preset"))
        }
        let pipe = Pipe(), wire = WireWriter(pipe.fileHandleForWriting.fileDescriptor)
        XCTAssertFalse(wire.send(["blob":String(repeating:"x",count:WireJson.maxLine)]))
        wire.response("large",["blob":String(repeating:"x",count:WireJson.maxLine)]); wire.complete(2)
        let response = hostObject(try JSONSerialization.jsonObject(with:pipe.fileHandleForReading.availableData))
        XCTAssertEqual(response["id"] as? String,"large"); XCTAssertEqual(hostObject(response["error"])["code"] as? String,"internal")
        let fatalPipe = Pipe(), fatalWriter = WireWriter(fatalPipe.fileHandleForWriting.fileDescriptor)
        fatalWriter.fatal("message_too_large","oversized job.finished"); fatalWriter.complete(2)
        let fatal = hostObject(try JSONSerialization.jsonObject(with:fatalPipe.fileHandleForReading.availableData))
        XCTAssertEqual(fatal["event"] as? String,"fatal"); XCTAssertEqual(hostObject(fatal["data"])["code"] as? String,"message_too_large")
        XCTAssertEqual(Localizer("en").format("{{{0}}}","ok"),"{ok}")
        XCTAssertEqual(Localizer("en").format("{1}","ok"),"{1}")
    }
    func testDotNetEscapingPreservesUnicodeAndMatchesBaseline() throws {
        let value = "이름😀 &< >'\"+`=/\\\t\n"
        let encoded = String(decoding: try FileeJson.encode(["name":value]), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#"\uC774\uB984\uD83D\uDE00 \u0026\u003C \u003E\u0027\u0022\u002B\u0060=/"#))
        XCTAssertEqual(try FileeJson.decode([String:String].self,from:Data(encoded.utf8))["name"],value)
    }
    func testOptedInWriterChunksOversizedMessagesWithoutChangingContentOrOrder() throws {
        let d = CoreTempDir(), path = try d.file("wire", "")
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? output.close() }
        let writer = WireWriter(output.fileDescriptor, chunkedOutput: true)
        XCTAssertFalse(writer.send(["blob": String(repeating: "x", count: WireWriter.maxMessage)]))
        let text = String(repeating: "한글😀", count: 250_000)
        let large: [String: Any] = ["v": 1, "event": "job.finished", "data": ["jobId": "large", "text": text]]
        let expected = EngineJsonEscaping.encode(try JSONSerialization.data(withJSONObject: large, options: [.withoutEscapingSlashes]))
        XCTAssertGreaterThan(expected.count, WireJson.maxLine)
        XCTAssertTrue(writer.send(large))
        writer.response("next", ["ready": true])
        writer.complete(10)
        let lines = try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10)
        XCTAssertGreaterThan(lines.count, 2)
        var assembled = Data(), id: String?
        for line in lines.dropLast() {
            XCTAssertLessThanOrEqual(line.count + 1, WireJson.maxLine)
            let frame = hostObject(try JSONSerialization.jsonObject(with: Data(line)))
            XCTAssertEqual(frame["v"] as? Int, 1)
            let chunk = hostObject(frame["chunk"])
            XCTAssertEqual(chunk["offset"] as? Int, assembled.count)
            XCTAssertEqual(chunk["total"] as? Int, expected.count + 1)
            if id == nil { id = try XCTUnwrap(chunk["id"] as? String) }
            XCTAssertEqual(chunk["id"] as? String, id)
            assembled.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(chunk["bytes"] as? String))))
        }
        XCTAssertEqual(assembled, expected + Data([10]))
        let restored = hostObject(try JSONSerialization.jsonObject(with: assembled))
        XCTAssertEqual(hostObject(restored["data"])["text"] as? String, text)
        let next = hostObject(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.last))))
        XCTAssertEqual(next["id"] as? String, "next")
    }
    func testValidationRangesAndPaths() throws {
        try Validation.library(BuiltInData.createPresets(),BuiltInData.createProfiles()); try Validation.settings(AppSettings())
        var japanese = AppSettings(); japanese.language = "ja"; try Validation.settings(japanese)
        let invalid: [Preset] = [corePreset("heic"),corePreset("png") { $0.image.quality = 0 },corePreset("png") { $0.image.dpi = 10 },corePreset("png") { $0.output.customFolder = "relative" },corePreset("png") { $0.output.renames = [.init(kind:.regex,find:"(")] }]
        for p in invalid { XCTAssertThrowsError(try Validation.preset(p)) { XCTAssertEqual(($0 as? WireException)?.code,"invalid_input") } }
        for paths in [["relative.txt"],["/a\0b"],[]] { XCTAssertThrowsError(try Validation.paths(paths)) }
        XCTAssertEqual(try Validation.paths(["/a","/b","/a"]),["/a","/b"])
        XCTAssertEqual(try Validation.paths(["/a","/A","/a"]),["/a","/A"])
        XCTAssertTrue(Validation.isTarget("folder")); XCTAssertTrue(Validation.isTarget("*")); XCTAssertTrue(Validation.isTarget("pdf"))
    }
    func testStagingJournalDoesNotDeleteSymlinksOrUnrelatedPaths() throws {
        let d = CoreTempDir(); try FileManager.default.createDirectoryIfNeeded(d.path + "/keep")
        let symlink = d.path + "/.filee-out-0123abcd"
        try FileManager.default.createSymbolicLink(atPath:symlink,withDestinationPath:d.path + "/keep")
        try d.file("journal",symlink + "\n" + d.path + "/keep\nrelative/.filee-out-0123abcd\n")
        try StagingJournal(d.path + "/journal").cleanUp()
        XCTAssertTrue(FileManager.default.directoryExists(symlink)); XCTAssertTrue(FileManager.default.directoryExists(d.path + "/keep"))
    }
}
