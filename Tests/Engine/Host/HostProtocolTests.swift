import XCTest
@testable import FileToXEngineKit

final class HostProtocolTests: XCTestCase {
    func testProtocolErrorsCatalogSelectionRevisionSourceProtectionAndOrdering() throws {
        let d = CoreTempDir(); try FileManager.default.createDirectoryIfNeeded(d.path + "/core")
        let leftover = d.path + "/files/.filee-out-0123abcd", bystander = d.path + "/files/keep-me"
        try FileManager.default.createDirectoryIfNeeded(leftover); try FileManager.default.createDirectoryIfNeeded(bystander)
        try d.file("core/staging.journal",leftover + "\n" + bystander + "\n")
        let host = try HostChild(d.path); defer { host.close() }
        let hello = try host.event("hello"); XCTAssertEqual(hello["protocol"] as? Int,1); XCTAssertEqual(hello["dataDir"] as? String,d.path + "/core"); XCTAssertEqual(hello["fileeCommit"] as? String,EngineHostMain.fileeCommit)
        XCTAssertFalse(FileManager.default.directoryExists(leftover)); XCTAssertTrue(FileManager.default.directoryExists(bystander))
        let second = try HostChild(d.path); XCTAssertEqual(try second.event("fatal")["code"] as? String,"data_locked"); second.close()
        for (id,line,code) in [(nil,"{not json","bad_request"),("u",#"{"v":1,"id":"u","method":"nope","params":{}}"#,"unknown_method"),("p",#"{"v":1,"id":"p","method":"catalog.get"}"#,"bad_request"),("w",#"{"v":2,"id":"w","method":"catalog.get","params":{}}"#,"bad_request")] as [(String?,String,String)] { XCTAssertEqual(try host.errorCode(id,line),code) }
        XCTAssertEqual(try host.errorCode(nil,"{\"pad\":\"" + String(repeating:"x",count:WireJson.maxLine + 10) + "\"}"),"bad_request")
        try host.input.fileHandleForWriting.write(contentsOf:Data([0xff,10])); try host.wait { $0.contains { hostObject($0["error"])["message"] as? String == "The line is not UTF-8." } }
        let catalog = try host.call("catalog.get"); XCTAssertEqual(hostObjects(catalog["formats"]).count,172); XCTAssertTrue(hostObjects(catalog["engines"]).contains { $0["id"] as? String == "fake" })
        let source = try d.file("files/a.txt","original"), unknown = try d.file("files/x.unknownext","?")
        let selection = try host.call("selection.resolve",["paths":[source,unknown,d.path + "/missing.txt",bystander]])
        XCTAssertEqual(selection["formats"] as? [String],["txt"]); XCTAssertEqual((selection["unknown"] as? [String])?.count,2); XCTAssertEqual(hostObjects(selection["rejected"]).count,1)
        let md = hostObjects(selection["targets"]).first { $0["formatId"] as? String == "md" }!
        XCTAssertEqual(md["available"] as? Bool,true); XCTAssertEqual(md["runnableCount"] as? Int,1)
        XCTAssertNotNil(hostObjects(selection["targets"]).first { $0["formatId"] as? String == "png" }?["reasonKey"])
        XCTAssertTrue(hostObjects(selection["tools"]).contains { $0["presetId"] as? String == "zip-all" })
        XCTAssertEqual(hostObjects(selection["slices"]).first { $0["presetId"] as? String == "zip-all" }?["runnableCount"] as? Int,0)
        let library = try host.call("library.get")
        var saved = try host.call("library.save",["baseRevision":1,"presets":library["presets"]!,"profiles":library["profiles"]!])
        XCTAssertEqual(saved["revision"] as? Int,2); XCTAssertTrue(hostEqual(saved["presets"]!,library["presets"]!))
        let stale = String(decoding:try JSONSerialization.data(withJSONObject:["v":1,"id":"c","method":"settings.save","params":["baseRevision":1,"settings":library["settings"]!]]),as:UTF8.self)
        XCTAssertEqual(try host.errorCode("c",stale),"conflict")
        var settings = hostObject(library["settings"]); settings["engineOwnCopies"] = ["pandoc":""]
        saved = try host.call("settings.save",["baseRevision":2,"settings":settings]); XCTAssertTrue(hostObject(hostObject(saved["settings"])["engineOwnCopies"]).isEmpty)
        try FileManager.default.createSymbolicLink(atPath:d.path + "/alias",withDestinationPath:d.path + "/files")
        var preset = hostObjects(library["presets"])[0]; preset["targetFormat"] = "*"
        var output = hostObject(preset["output"]); output["location"] = "customFolder"; output["customFolder"] = d.path + "/alias"; output["conflict"] = "overwrite"; preset["output"] = output
        let jobId = try host.call("job.start",["paths":[source],"preset":preset])["jobId"] as! String
        let finished = try host.event("job.finished",jobId:jobId)
        XCTAssertEqual(hostObjects(finished["files"])[0]["errorKey"] as? String,"error.output_is_source"); XCTAssertEqual((finished["retrySources"] as? [String])?.count,1); XCTAssertEqual(try d.read("files/a.txt"),"original")
        let count = 1000, before = host.messages.count
        for i in 0..<count { try host.request("j\(i)","job.start",["paths":[source],"targetFormat":"md"]) }
        try host.wait(120) { $0.dropFirst(before).filter { $0["event"] as? String == "job.finished" }.count >= count }
        var responded = Set<String>(), done = Set<String>()
        for line in host.messages.dropFirst(before) {
            if let id = hostObject(line["result"])["jobId"] as? String { XCTAssertTrue(responded.insert(id).inserted) }
            else if ["job.updated","job.finished"].contains(line["event"] as? String ?? ""), let id = hostObject(line["data"])["jobId"] as? String {
                XCTAssertTrue(responded.contains(id)); XCTAssertFalse(done.contains(id))
                if line["event"] as? String == "job.finished" { XCTAssertTrue(done.insert(id).inserted) }
            }
        }
        XCTAssertEqual(responded.count,count); XCTAssertEqual(done.count,count)
        let history = try host.call("history.get"); XCTAssertEqual(hostObjects(history["entries"]).count,200); XCTAssertTrue((hostObjects(history["entries"])[0]["finishedAt"] as? String)?.contains("T") == true)
        XCTAssertEqual(try d.read("files/a.txt"),"original"); XCTAssertTrue(d.leftovers().isEmpty)
        XCTAssertEqual(host.invalid,0)
        host.close(); XCTAssertTrue(host.stderrText.contains("native-noise-without-newline"))
    }
    func testLiveLanguageSettingsAndRawLibraryNamesSurviveRestart() throws {
        let d = CoreTempDir(), png = try d.file("image.png","fixture")
        let host = try HostChild(d.path,language:nil); defer { host.close() }; _ = try host.event("hello")
        var library = try host.call("library.get"), settings = hostObject(library["settings"])
        XCTAssertEqual(settings["language"] as? String,"en"); XCTAssertEqual(hostObject(settings["theme"])["accent"] as? String,"#3478F6")
        settings["language"] = "ja"; var theme = hostObject(settings["theme"]); theme["accent"] = "#C4603A"; settings["theme"] = theme
        library = try host.call("settings.save",["baseRevision":1,"settings":settings])
        var selection = try host.call("selection.resolve",["paths":[png]])
        XCTAssertTrue(hostObjects(selection["slices"]).contains { $0["displayName"] as? String == "サイズを半分に" })
        let tools = hostObjects(selection["tools"]), options = hostObjects(selection["presetOptions"])
        XCTAssertTrue(tools.contains { $0["presetId"] as? String == "half-size" }); XCTAssertTrue(tools.contains { $0["presetId"] as? String == "grayscale" }); XCTAssertLessThanOrEqual(tools.count,12); XCTAssertFalse(tools.contains { $0["presetId"] as? String == "mp4-720" }); XCTAssertEqual(options.count,hostObjects(library["presets"]).count)
        XCTAssertTrue(options.contains { $0["presetId"] as? String == "to-mp4" }); XCTAssertFalse(tools.first { $0["presetId"] as? String == "half-size" }?["reasonKey"] is NSNull)
        var presets = hostObjects(library["presets"]), profiles = hostObjects(library["profiles"])
        presets[presets.firstIndex { $0["id"] as? String == "half-size" }!]["name"] = "My preset 이름 テスト"; profiles[0]["name"] = "My profile プロファイル"
        library = try host.call("library.save",["baseRevision":library["revision"]!,"presets":presets,"profiles":profiles])
        let expectedPresets = library["presets"]!, expectedProfiles = library["profiles"]!
        for language in ["ko","en","ja"] {
            settings = hostObject(library["settings"]); settings["language"] = language
            library = try host.call("settings.save",["baseRevision":library["revision"]!,"settings":settings])
            let catalog = try host.call("catalog.get")
            XCTAssertEqual(hostObjects(catalog["formats"]).first { $0["id"] as? String == "folder" }?["displayName"] as? String,Localizer(language)["format.folder"])
            XCTAssertTrue(hostEqual(expectedPresets,library["presets"]!)); XCTAssertTrue(hostEqual(expectedProfiles,library["profiles"]!))
        }
        selection = try host.call("selection.resolve",["paths":[png]])
        XCTAssertEqual(hostObjects(selection["slices"]).first { $0["presetId"] as? String == "half-size" }?["displayName"] as? String,"My preset 이름 テスト")
        host.close()
        let restart = try HostChild(d.path,language:nil); defer { restart.close() }; _ = try restart.event("hello")
        let persisted = try restart.call("library.get")
        XCTAssertEqual(hostObject(persisted["settings"])["language"] as? String,"ja"); XCTAssertEqual(hostObject(hostObject(persisted["settings"])["theme"])["accent"] as? String,"#C4603A")
        XCTAssertTrue(hostEqual(expectedPresets,persisted["presets"]!)); XCTAssertTrue(hostEqual(expectedProfiles,persisted["profiles"]!))
    }
}
