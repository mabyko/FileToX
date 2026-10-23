import XCTest
@testable import FileToXEngineKit

final class ProfileSelectorTests: XCTestCase {
    private func p(_ id: String, _ extensions: [String] = [], mixed: Bool = false) -> ToolbarProfile { var p = ToolbarProfile(); p.id = id; p.extensions = extensions; p.isFallback = mixed; return p }
    func testBuiltInsAndEverySelectionFallback() {
        let built = BuiltInData.createProfiles()
        for (expected,files) in [("images",["a.jpg","b.PNG"]),("pdf",["a.pdf"]),("archives",["a.tar.gz","b.zip"]),("video",["a.MP4","b.mkv"]),("text",["notes.md","readme.txt"]),("mixed",["a.jpg","b.docx"]),("mixed",["a.xyz"]),("mixed",[])] { XCTAssertEqual(ProfileSelector.select(built,files)?.id,expected) }
        XCTAssertNil(ProfileSelector.select([],["a.jpg"]))
        XCTAssertEqual(ProfileSelector.detectFormats(["a.jpg","b.JPG","x.xyz","a.pdf"]).map(\.id),["jpg","pdf"])
    }
    func testLimitedMixedNormalPrecedenceAndOrdering() {
        var profiles = [p("images",["jpg","png"]),p("pdf",["pdf"]),p("mixed",mixed:true),p("scans",["JPG","png","Pdf"],mixed:true)]
        func pick(_ files: [String]) -> String? { ProfileSelector.select(profiles,files)?.id }
        XCTAssertEqual(pick(["a.jpg","b.pdf"]),"scans"); XCTAssertEqual(pick(["a.jpg","b.png","c.pdf"]),"scans")
        XCTAssertEqual(pick(["a.jpg","b.pdf","c.docx"]),"mixed"); XCTAssertEqual(pick(["a.jpg","b.JPG"]),"images"); XCTAssertEqual(pick(["/folder/","a.jpg"]),"mixed")
        profiles.insert(p("mine",["jpg","pdf"]),at:0); XCTAssertEqual(pick(["a.jpg","b.pdf"]),"mine")
        profiles = [p("broad",["jpg","png","pdf","docx"],mixed:true),p("narrow",["jpg","pdf"],mixed:true)]
        XCTAssertEqual(pick(["a.jpg","b.pdf"]),"broad"); profiles.reverse(); XCTAssertEqual(pick(["a.jpg","b.pdf"]),"narrow")
        profiles = [p("mixed",mixed:true),p("images",["jpg"]),p("pdf",["pdf"]),p("scans",["jpg","pdf"],mixed:true)]
        XCTAssertEqual(pick(["A.Jpg","b.PDF"]),"scans")
    }
    func testCompoundUnknownAndEmptyProfilesAndCatchAll() {
        var profiles = [p("archives",["zip","tar.gz"]),p("images",["png"]),p("mixed",mixed:true),p("backup",["tar.gz","png"],mixed:true)]
        XCTAssertEqual(ProfileSelector.select(profiles,["site.tar.gz","logo.png"])?.id,"backup"); XCTAssertEqual(ProfileSelector.select(profiles,["site.gz","logo.png"])?.id,"mixed")
        profiles = [p("new"),p("images",["jpg"]),p("mixed",mixed:true),p("raw-and-sidecar",["jpg","xmp"],mixed:true)]
        XCTAssertEqual(ProfileSelector.select(profiles,["a.jpg"])?.id,"images"); XCTAssertEqual(ProfileSelector.select(profiles,["a.xyz"])?.id,"mixed")
        XCTAssertEqual(ProfileSelector.select(profiles,["a.jpg","a.xmp"])?.id,"raw-and-sidecar"); XCTAssertEqual(ProfileSelector.select(profiles,["a.xmp"])?.id,"raw-and-sidecar")
        profiles = [p("images",["jpg"]),p("scans",["jpg","pdf"],mixed:true),p("mixed",mixed:true),p("second",mixed:true)]
        XCTAssertEqual(ProfileSelector.catchAll(profiles)?.id,"mixed")
        profiles.removeAll { $0.id == "mixed" || $0.id == "second" }; XCTAssertEqual(ProfileSelector.select(profiles,["a.jpg","b.docx"])?.id,"scans")
        profiles.removeAll( where: \.isFallback); XCTAssertEqual(ProfileSelector.select(profiles,["a.jpg","b.docx"])?.id,"images")
    }
}
