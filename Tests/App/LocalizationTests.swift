import AppKit
import SwiftUI
import XCTest
@testable import FileToX

final class LocalizationTests: XCTestCase {
    func testEnglishIsDefaultAndUnsupportedLanguageFallsBack() {
        XCTAssertEqual(AppLanguage.supported(nil), .english)
        XCTAssertEqual(AppLanguage.supported("auto"), .english)
        XCTAssertEqual(AppLanguage.supported("unknown"), .english)
        XCTAssertEqual(AppLanguage.supported("ko-KR"), .korean)
        XCTAssertEqual(AppLanguage.supported("ja_JP"), .japanese)
    }

    func testEveryLanguageContainsTheSameNonemptyResourceKeys() throws {
        let english = try table(.english)
        XCTAssertGreaterThan(english.count, 200)
        for language in AppLanguage.allCases {
            let localized = try table(language)
            XCTAssertEqual(Set(localized.keys), Set(english.keys), language.rawValue)
            XCTAssertTrue(localized.values.allSatisfy { !$0.isEmpty })
        }
        XCTAssertEqual(Localization.text("정보", language: .english), "About")
        XCTAssertEqual(Localization.text("정보", language: .korean), "정보")
        XCTAssertEqual(Localization.text("정보", language: .japanese), "情報")
    }

    func testEngineReasonKeysAreLocalizedInEveryLanguage() throws {
        // The engine host reports unavailable engines with these keys; the UI must never show them raw.
        for language in AppLanguage.allCases {
            let localized = try table(language)
            for key in ["engine.reason.not_installed", "engine.reason.error", "engine.reason.unsupported_platform"] {
                XCTAssertNotNil(localized[key], "\(language.rawValue): \(key)")
            }
        }
    }

    func testMissingTranslationFallsBackToEnglishAndUnknownTextIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filetox-locale-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let english = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        try #""fallback.key" = "English fallback";"#.write(to: english.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(Localization.text("fallback.key", language: .japanese, bundle: bundle), "English fallback")
        XCTAssertEqual(Localization.text("FFmpeg: raw diagnostic", language: .japanese, bundle: bundle), "FFmpeg: raw diagnostic")
    }

    func testRadialSingleFileTitleInEveryLanguage() {
        for (language, expected) in [(AppLanguage.english, "1 file"), (.korean, "파일 1개"), (.japanese, "1個のファイル")] {
            XCTAssertEqual(Localization.text("파일 1개", language: language), expected)
        }
    }

    @MainActor
    func testProgressFormattingEscapesLiteralPercentInEveryLanguage() {
        let previous = Localization.shared.language
        defer { Localization.shared.language = previous }
        for (language, expected) in [(AppLanguage.english, "2 files · 50%"), (.korean, "파일 2개 · 50%"), (.japanese, "2個のファイル · 50%")] {
            Localization.shared.language = language
            XCTAssertEqual(L("파일 %@개 · %@%", "2", "50"), expected)
        }
    }

    @MainActor
    func testColorPickerRoundTripUsesOpaqueSRGBHexAndTealDefault() {
        XCTAssertEqual(ThemeAccent.defaultHex, "#3478F6")
        for hex in ["#3478F6", "#12AB34", "#000000", "#FFFFFF", "#FF007A"] {
            XCTAssertEqual(ThemeAccent.hex(color: ThemeAccent.color(hex: hex)), hex)
        }
        XCTAssertEqual(ThemeAccent.hex(color: ThemeAccent.color(hex: "invalid")), ThemeAccent.defaultHex)
        XCTAssertEqual(ThemeAccent.hex(color: ThemeAccent.foreground(on: .white)), "#000000")
        XCTAssertEqual(ThemeAccent.hex(color: ThemeAccent.foreground(on: .black)), "#FFFFFF")
    }

    func testUserPresetNamesStayUnchangedWhileBuiltInNameKeysTranslate() {
        let named = JSONValue.object(["name": .string("내 사진 / My photos / 私の写真"), "nameKey": .string("preset.half_size"), "image": .object(["quality": .number(83)])])
        let builtIn = JSONValue.object(["name": .string(""), "nameKey": .string("preset.half_size")])
        for language in AppLanguage.allCases {
            XCTAssertEqual(Localization.libraryName(named, language: language), "내 사진 / My photos / 私の写真")
            XCTAssertEqual(Localization.libraryName(builtIn, language: language), Localization.text("preset.half_size", language: language))
        }
        XCTAssertEqual(named["image"]?["quality"]?.int, 83)
        XCTAssertNotEqual(Localization.libraryName(builtIn, language: .japanese), Localization.libraryName(builtIn, language: .english))
    }

    private func table(_ language: AppLanguage) throws -> [String: String] {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
        let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
