// Port of Filee.Engines.Tests/EmlTests.cs: e-mail (.eml) → HTML / TXT / ZIP of the attachments. Korean charsets
// (EUC-KR, ISO-2022-KR) in headers and bodies, quoted-printable and base64, the HTML part with an inline picture
// ("cid:") and attachments with RFC 2231 file names. Messages are written in the test, byte for byte like Filee's.
// Plus focused checks of the MIME parsing ported from MimeKit (values measured with MimeKit 4.18 on .NET 10).

import Foundation
import XCTest
@testable import FileToXEngineKit

final class EmlTests: XCTestCase {
    private var folder: String!

    override func setUpWithError() throws { folder = try MarkupTestSupport.newFolder() }
    override func tearDownWithError() throws { FileManager.default.removeIfPresent(folder) }

    private static let report = Data("%PDF-1.4 fake report".utf8)

    private static let eucKr = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(51949)))

    private static func encodedWord(_ text: String, _ charset: String) -> String {
        "=?\(charset)?B?\(text.data(using: eucKr)!.base64EncodedString())?="
    }

    private static func base64Lines(_ data: Data) -> String {
        let text = data.base64EncodedString()
        return stride(from: 0, to: text.count, by: 76).map { start -> String in
            let from = text.index(text.startIndex, offsetBy: start)
            return String(text[from..<(text.index(from, offsetBy: 76, limitedBy: text.endIndex) ?? text.endIndex)])
        }.joined(separator: "\r\n")
    }

    /// Quoted-printable of EUC-KR text (every non-ASCII byte as =XX).
    private static func quotedPrintable(_ text: String) -> String {
        var result = ""
        var column = 0
        for byte in text.data(using: eucKr)! {
            let piece = (33...126).contains(byte) && byte != UInt8(ascii: "=") ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
            if column + piece.count > 72 {
                result += "=\r\n"
                column = 0
            }
            result += piece
            column += piece.count
        }
        return result
    }

    /// multipart/mixed: multipart/related (multipart/alternative text + HTML in EUC-KR, an inline PNG) and two
    /// attachments, one with an RFC 2231 UTF-8 file name.
    private func message() throws -> String {
        let png = MarkupTestSupport.png(16, 16, red: 0, green: 128, blue: 128)
        let html = "<html><head><style>p { color: #C00000; }</style></head><body><p>안녕하세요. 자료를 보냅니다.</p>" +
            "<img src=\"cid:logo@filee\" alt=\"logo\"><script>alert('x')</script></body></html>"
        let eml = [
            "From: \(Self.encodedWord("보낸이", "EUC-KR")) <sender@example.com>",
            "To: receiver@example.com, \"Second\" <second@example.com>",
            "Cc: other@example.com",
            "Subject: \(Self.encodedWord("회의 자료", "EUC-KR"))",
            "Date: Thu, 01 Oct 2026 09:30:00 +0900",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"mixed\"",
            "",
            "--mixed",
            "Content-Type: multipart/related; boundary=\"related\"",
            "",
            "--related",
            "Content-Type: multipart/alternative; boundary=\"alt\"",
            "",
            "--alt",
            "Content-Type: text/plain; charset=euc-kr",
            "Content-Transfer-Encoding: base64",
            "",
            Self.base64Lines("안녕하세요. 자료를 보냅니다.\r\n둘째 줄".data(using: Self.eucKr)!),
            "--alt",
            "Content-Type: text/html; charset=euc-kr",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            Self.quotedPrintable(html),
            "--alt--",
            "--related",
            "Content-Type: image/png",
            "Content-ID: <logo@filee>",
            "Content-Transfer-Encoding: base64",
            "",
            Self.base64Lines(png),
            "--related--",
            "--mixed",
            "Content-Type: application/pdf; name=\"report.pdf\"",
            "Content-Disposition: attachment; filename*=UTF-8''%EB%B3%B4%EA%B3%A0%EC%84%9C.pdf",
            "Content-Transfer-Encoding: base64",
            "",
            Self.base64Lines(Self.report),
            "--mixed",
            "Content-Type: text/plain; charset=utf-8; name=\"notes.txt\"",
            "Content-Disposition: attachment; filename=\"notes.txt\"",
            "",
            "memo",
            "--mixed--",
            "",
        ].joined(separator: "\r\n")
        let path = FilePath.combine(folder, "회의.eml")
        try Data(eml.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func convert(_ input: String, _ target: String) async throws -> String {
        let outputs = try await EmlConverter().convert(
            ConversionStep(inputPath: input, from: "eml", to: target, preset: Preset(), output: FolderOutput(input), workDirectory: folder),
            progress: nil)
        return try XCTUnwrap(outputs.first)
    }

    private func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    func testEmlToHtmlShowsHeadersAndTheHtmlBodyWithInlinePictures() async throws {
        let html = try read(try await convert(try message(), "html"))

        XCTAssertTrue(html.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(html.contains("<title>회의 자료</title>"))
        XCTAssertTrue(html.contains("<th>From</th><td>보낸이 &lt;sender@example.com&gt;</td>"))
        XCTAssertTrue(html.contains("<th>To</th><td>receiver@example.com, Second &lt;second@example.com&gt;</td>"))
        XCTAssertTrue(html.contains("<th>Date</th><td>2026-10-01 09:30:00 +09:00</td>"))
        XCTAssertTrue(html.contains("<th>Attachments</th><td>보고서.pdf, notes.txt</td>"))
        XCTAssertTrue(html.contains("<p>안녕하세요. 자료를 보냅니다.</p>"))
        XCTAssertTrue(html.contains("p { color: #C00000; }"), "the message's own style sheet")
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
        XCTAssertFalse(html.contains("cid:"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testEmlToTextAndAttachmentsToZip() async throws {
        let eml = try message()

        let textPath = try await convert(eml, "txt")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: textPath))
        XCTAssertEqual(Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF], "UTF-8 with BOM")
        let text = try read(textPath).replacingOccurrences(of: "\u{FEFF}", with: "")
        XCTAssertTrue(text.hasPrefix("From: 보낸이 <sender@example.com>\r\n"))
        XCTAssertTrue(text.contains("Subject: 회의 자료\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n안녕하세요. 자료를 보냅니다.\r\n둘째 줄\r\n"))

        let zip = try ZipReader(path: try await convert(eml, "zip"))
        XCTAssertEqual(zip.entries.map(\.name), ["보고서.pdf", "notes.txt"])
        XCTAssertEqual(try zip.data(named: "보고서.pdf"), Self.report)
    }

    func testIso2022KrAndPlainTextMessages() async throws {
        // ISO-2022-KR bytes as .NET's encoder (code page 50225) writes "한글 제목" and "본문 <첫 줄>\r\n둘째 줄".
        let subject = "=?ISO-2022-KR?B?\(Data(hex: "1B2429430E4751315B0F200E412638710F").base64EncodedString())?="
        let body = String(decoding: Data(hex: "1B2429430E3A3B392E0F203C0E43390F200E41590F3E0D0A0E355142300F200E41590F"), as: UTF8.self)
        let path = FilePath.combine(folder, "old.eml")
        try Data("From: old@example.com\r\nSubject: \(subject)\r\nContent-Type: text/plain; charset=ISO-2022-KR\r\nContent-Transfer-Encoding: 7bit\r\n\r\n\(body)\r\n".utf8)
            .write(to: URL(fileURLWithPath: path))

        let html = try read(try await convert(path, "html"))
        XCTAssertTrue(html.contains("<title>한글 제목</title>"))
        XCTAssertTrue(html.replacingOccurrences(of: "\r\n", with: "\n").contains("<pre class=\"filee-mail-text\">본문 &lt;첫 줄&gt;\n둘째 줄"))
        XCTAssertFalse(html.contains("Attachments"))

        // No attachments: a clear error instead of an empty ZIP.
        do {
            _ = try await convert(path, "zip")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("no attachments"), error.localizedDescription)
        }
    }

    // MARK: MIME details (expected values measured with MimeKit 4.18 / .NET 10)

    private func load(_ text: String) throws -> EmlMessage { try EmlMessage.parse(Array(text.utf8)) }

    func testEncodedWordsJoinAcrossWhiteSpaceAndSplitCharacters() throws {
        // A UTF-8 character split over two Q words, B and Q words, and text around them.
        let message = try load("Subject: a =?utf-8?q?Caf=C3?= =?utf-8?q?=A9_cr=C3=A8me?=  b =?iso-8859-1?B?6Q==?=\r\n\r\n")
        XCTAssertEqual(message.subject, "a Café crème  b é")
    }

    func testRawEightBitHeadersFallBackToCp949() throws {
        var bytes = Array("Subject: ".utf8)
        bytes += Array("똠방각하".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(949))))!)
        bytes += Array("\r\n\r\nbody".utf8)
        XCTAssertEqual(try EmlMessage.parse(bytes).subject, "똠방각하")
    }

    func testDotNetEucKrDecodingKeepsItsQuirks() {
        // .NET's EUC-KR (51949) has no CP949 extensions: 똠 (8C 63) becomes U+008C and "c"; a lone lead byte is "?".
        XCTAssertEqual(EmlCharsets.decode([0xB6, 0xCB, 0x8C, 0x63, 0xB0][...], codePage: 51949), "똥\u{008C}c?")
        XCTAssertEqual(EmlCharsets.codePage("ks_c_5601-1987"), 51949)
        XCTAssertEqual(EmlCharsets.codePage("cp949"), 949)
        XCTAssertEqual(EmlCharsets.decode([0xA2, 0xE6][...], codePage: 949), "€")
    }

    func testRfc2231ContinuationsAndCharsets() throws {
        let raw = Array(" attachment;\r\n filename*0*=UTF-8''%ED%95%9C%EA%B8%80%20;\r\n filename*1*=%ED%8C%8C%EC%9D%BC;\r\n filename*2=\".txt\"\r\n".utf8)
        XCTAssertEqual(EmlMime.parseContentDisposition(raw)?.fileName, "한글 파일.txt")
    }

    func testAddressListsWithGroupsCommentsAndUnquotedCommas() throws {
        let message = try load("To: Team: a@example.com, \"Name, With Comma\" <c@example.com>;, (only a comment) d@example.com,\r\n" +
            " e@example.com (Eve Example), Last First, x@example.com\r\nFrom: \"Doe, John\" <john@example.com> (work)\r\n\r\n")
        // "Last First" is no address (MimeKit skips it); groups are flattened.
        XCTAssertEqual(message.mailboxes("To").map { "\($0.name)|\($0.address)" },
                       ["|a@example.com", "Name, With Comma|c@example.com", "|d@example.com", "Eve Example|e@example.com", "|x@example.com"])
        XCTAssertEqual(message.mailboxes("From"), [EmlMime.Mailbox(name: "Doe, John", address: "john@example.com")])
    }

    func testDatesParseLikeMimeKit() throws {
        func date(_ text: String) throws -> String { try load("Date: \(text)\r\n\r\n").date.formatted }
        XCTAssertEqual(try date("Thu, 01 Oct 2026 09:30:00 +0900"), "2026-10-01 09:30:00 +09:00")
        XCTAssertEqual(try date("1 Oct 2026 09:30 +0900"), "2026-10-01 09:30:00 +09:00")
        XCTAssertEqual(try date("Thu, 01 Oct 26 09:30:00 GMT"), "2026-10-01 09:30:00 +00:00")
        XCTAssertEqual(try date("Thu, 01 Oct 2026 09:30:00 PM -0530"), "2026-10-01 21:30:00 -05:30")
        XCTAssertEqual(try date("Thu, 31 Feb 2026 10:00:00 +0000"), "0001-01-01 00:00:00 +00:00", "an impossible date is MinValue")
    }

    func testQuotedPrintableBase64AndFlowedText() throws {
        XCTAssertEqual(EmlMime.decodeQuotedPrintable(Array("a=\r\nb =3D =ZZ =4".utf8)[...]), Array("ab = =ZZ ".utf8))
        XCTAssertEqual(EmlMime.decodeBase64(Array("7JW I!\r\n64WV".utf8)[...]), Array("안녕".utf8))
        XCTAssertEqual(EmlMime.flowedToText("one \r\ntwo\r\n> a \r\n> b\r\n", deleteSpace: false), "one two\n> a b\n")
    }

    func testAttachedMessagesAreWrittenBackWithUnixLineBreaks() throws {
        let message = try load("Subject: outer\r\nContent-Type: multipart/mixed; boundary=\"o\"\r\n\r\n--o\r\nContent-Type: message/rfc822\r\n\r\n" +
            "Subject: inner\r\nContent-Type: text/plain\r\n\r\nline 1\r\nline 2\r\n--o--\r\n")
        let attached = try XCTUnwrap(EmlConverter.attachments(message).first)
        XCTAssertEqual(attached.name, "inner.eml")
        var bytes: [UInt8] = []
        (attached.entity as? EmlMessagePart)?.message?.write(to: &bytes)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Subject: inner\nContent-Type: text/plain\n\nline 1\nline 2")
    }

    func testMalformedMessagesFailWithMimeKitsMessages() {
        XCTAssertThrowsError(try EmlMessage.parse([])) { XCTAssertEqual($0.localizedDescription, "End of stream.") }
        XCTAssertThrowsError(try load("Not a header line\r\n\r\nbody")) { XCTAssertEqual($0.localizedDescription, "Failed to parse message headers.") }
        XCTAssertNoThrow(try load("From someone Thu Oct  1 09:30:00 2026\r\nSubject: mbox\r\n\r\nbody"))
    }

    func testDotNetHtmlAndUriHelpers() {
        XCTAssertEqual(MarkupConvert.htmlEncode("<a> & \" ' \u{00A0}é©\u{00FF}\u{0100}한😀"),
                       "&lt;a&gt; &amp; &quot; &#39; &#160;&#233;&#169;&#255;\u{0100}한&#128512;")
        XCTAssertEqual(EmlConverter.htmlDecode("&lt;&nbsp;&eacute;&hellip;&#65;&#x42;&#xD800;&bogus;&amp;amp;&NotEqualTilde;&apos;"),
                       "<\u{00A0}é…AB&#xD800;&bogus;&amp;&NotEqualTilde;'")
        XCTAssertEqual(MarkupConvert.unescapeDataString("a%20b%E2%82%AC%E2%82x%41%zz%"), "a b€%E2%82xA%zz%")
    }
}

/// Allocates `<input folder>/<input name>.<ext>`, like the default output rule.
private final class FolderOutput: OutputAllocator {
    let input: String
    init(_ input: String) { self.input = input }

    func allocate(_ extension: String, suffix: String?) throws -> String? {
        FilePath.combine(FilePath.directoryName(input) ?? "", FilePath.fileNameWithoutExtension(input) + (suffix ?? "") + "." + `extension`)
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
