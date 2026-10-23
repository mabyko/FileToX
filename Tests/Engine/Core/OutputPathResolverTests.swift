import XCTest
@testable import FileToXEngineKit

final class OutputPathResolverTests: XCTestCase {
    func testPathsTokensCompoundExtensionsFoldersAndConflicts() throws {
        let d = CoreTempDir(), source = try d.file("photo.jpg")
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 14, minute: 5, second: 9))!
        let tokens = OutputPathResolver.Tokens(source, "PNG", 3, date)
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var r = OutputRule()
        XCTAssertEqual(OutputPathResolver.resolve(r,tokens,"png",exists:exists), d.path + "/photo.png")
        try d.file("photo.png")
        XCTAssertEqual(OutputPathResolver.resolve(r,tokens,"png",exists:exists), d.path + "/photo (2).png")
        r.conflict = .skip; XCTAssertNil(OutputPathResolver.resolve(r,tokens,"png",exists:exists))
        r.conflict = .overwrite; XCTAssertEqual(OutputPathResolver.resolve(r,tokens,"png",exists:exists), d.path + "/photo.png")
        for c in ConflictPolicy.allCases { r.conflict = c; XCTAssertEqual(OutputPathResolver.resolve(r,tokens,"jpg",exists:exists), d.path + "/photo (2).jpg"); r.fileNamePattern = "PHOTO"; XCTAssertEqual(OutputPathResolver.resolve(r,tokens,"jpg",exists:exists), d.path + "/PHOTO (2).jpg"); r.fileNamePattern = "{name}" }
        r.fileNamePattern = "{NAME}_{preset}_{date}_{time}_{ext}_{index}:?"
        XCTAssertEqual(FilePath.fileName(OutputPathResolver.resolve(r,tokens,"png",exists:{ _ in false })!), "photo_PNG_20260930_140509_jpg_3__.png")
        r = OutputRule(); r.location = .subfolder; r.subfolderName = "{name}"
        XCTAssertEqual(OutputPathResolver.resolve(r,tokens,"png",exists:exists,suffix:"_p1"), d.path + "/photo/photo_p1.png")
        r.location = .customFolder; r.customFolder = "/custom"
        XCTAssertEqual(OutputPathResolver.resolve(r,tokens,"png",exists:{ _ in false }), "/custom/photo.png")
        let backup = try d.file("backup.tar.gz")
        XCTAssertEqual(OutputPathResolver.resolve(OutputRule(), .init(backup,"ZIP",1), "zip", exists: exists), d.path + "/backup.zip")
        try FileManager.default.createDirectoryIfNeeded(d.path + "/photos")
        XCTAssertEqual(OutputPathResolver.resolve(OutputRule(), .init(d.path + "/photos.zip","Extract",1), "", exists: exists), d.path + "/photos (2)")
        XCTAssertEqual(OutputPathResolver.sanitize(" <>:\"/\\|?*\0. ", fallback: "fallback"), "__________")
        XCTAssertEqual(OutputPathResolver.sanitize("...", fallback: "fallback"), "fallback")
        XCTAssertEqual(OutputPathResolver.sanitize("👨‍👩‍👧‍👦", fallback: "fallback"), "👨‍👩‍👧‍👦")
    }
    func testEveryRenameKindAndInvalidPatterns() {
        let cases: [(RenameKind,String,String,String,String)] = [(.replace,"IMG_","Photo_","IMG_0412","Photo_0412"),(.remove,"_copy","","report_COPY","report"),(.prefix,"","2026_","report","2026_report"),(.suffix,"","_final","report","report_final"),(.spacesToUnderscores,"","","trip to  busan","trip_to_busan"),(.removeCopyNumber,"","","report (2)","report"),(.removeBrackets,"","","song [remix] (live)","song"),(.removeLeadingNumber,"","","01 - intro","intro"),(.removeSymbols,"","","invoice#12@acme!","invoice12acme"),(.removeSymbols,"","","보고서#1","보고서1"),(.lowercase,"","","Report_FINAL","report_final"),(.uppercase,"","","report","REPORT"),(.regex,#"(\d{4})(\d{2})(\d{2})"#,"$1-$2-$3","scan_20261011","scan_2026-10-11"),(.replace,"","x","report","report")]
        for (kind,find,replacement,name,expected) in cases { XCTAssertEqual(RenameStep(kind:kind,find:find,replace:replacement).apply(name),expected) }
        XCTAssertNotNil(OutputPathResolver.renameError("IMG_(")); XCTAssertNil(OutputPathResolver.renameError(""))
        XCTAssertEqual(OutputPathResolver.rename("IMG_0412","IMG_(","x"),"IMG_0412")
        XCTAssertEqual(OutputPathResolver.rename("IMG_0412",[.init(find:"img_",replace:"Photo "),.init(kind:.spacesToUnderscores)]),"Photo_0412")
        XCTAssertEqual(OutputPathResolver.rename("a", "(a)(b)?", "last$+end"), "lastend")
        XCTAssertEqual(OutputPathResolver.rename("ab", "(?<letter>a)(b)", "${letter}-$1-$2-$+"), "a-b-a-a")
        XCTAssertEqual(OutputPathResolver.rename("a", "(?<letter>a)(b)?", "$1-$2-$+"), "-a-a")
        let bad = String(repeating:"a",count:50) + "!", start = Date()
        XCTAssertEqual(OutputPathResolver.rename(bad,"(a+)+$","x"),bad); XCTAssertLessThan(Date().timeIntervalSince(start),2)
    }
    func testPageRangesAndFormatRegistry() {
        for (e,want) in [("",[0,1,2,3,4]),("2",[1]),("2-4",[1,2,3]),("4-",[3,4]),("-2",[0,1]),("5,1, 3",[0,2,4]),("4-2",[1,2,3]),("9-12",[0,1,2,3,4]),("x, 2",[1])] { XCTAssertEqual(PageRange.parse(e,pageCount:5),want) }
        for (p,id) in [("a.JPEG","jpg"),("b.tif","tiff"),("c.HWPX","hwpx"),(".md","md"),("clip.MP4","mp4"),("backup.tar.gz","tgz")] { XCTAssertEqual(FormatRegistry.detect(p)?.id,id) }
        XCTAssertNil(FormatRegistry.detect("README")); XCTAssertNil(FormatRegistry.detect("x.xyz"))
        XCTAssertEqual(FormatRegistry.extensionOf("notes.txt.gz"),"gz"); XCTAssertEqual(FormatRegistry.nameWithoutExtension("notes.txt.gz"),"notes.txt")
        let extensions = FormatRegistry.known.flatMap(\.extensions).map { $0.lowercased() }; XCTAssertEqual(extensions.count,Set(extensions).count)
    }
}
