// Port of Filee.Engines.Tests/EbookBuilders.cs; inputs are generated in the tests, never package resources.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FileToXEngineKit

enum EbookBuilders {
    static func picture(_ width: Int, _ height: Int, _ jpeg: Bool = false) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError("test picture") }
        return data as Data
    }
    static func epub(_ folder: String, _ name: String = "소설.epub") throws -> String {
        let path = FilePath.combine(folder, name), zip = try ZipWriter(path: path)
        try zip.add("mimetype", text: "application/epub+zip", level: .noCompression)
        try zip.add("META-INF/container.xml", text: #"""
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""#)
        try zip.add("OEBPS/content.opf", text: #"""
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">urn:uuid:12345678-1234-1234-1234-123456789012</dc:identifier>
    <dc:title>별빛 이야기</dc:title>
    <dc:creator>김작가</dc:creator>
    <dc:language>ko</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="Styles/book.css" media-type="text/css"/>
    <item id="c1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="Text/ch%203.xhtml" media-type="application/xhtml+xml"/>
    <item id="pic" href="Images/pic.png" media-type="image/png"/>
    <item id="cover" href="Images/cover.png" media-type="image/png" properties="cover-image"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="c3"/>
  </spine>
</package>
"""#)
        try zip.add("OEBPS/nav.xhtml", text: #"""
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>목차</title></head>
<body><nav epub:type="toc"><ol><li><a href="Text/ch1.xhtml">1장</a></li></ol></nav></body></html>
"""#)
        try zip.add("OEBPS/toc.ncx", text: #"""
<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>별빛</text></docTitle>
<navMap><navPoint id="n1" playOrder="1"><navLabel><text>1장</text></navLabel><content src="Text/ch1.xhtml"/></navPoint></navMap></ncx>
"""#)
        try zip.add("OEBPS/Text/ch1.xhtml", text: #"""
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title/><link rel="stylesheet" type="text/css" href="../Styles/book.css"/></head>
<body>
<h1>첫 번째 장</h1>
<p>밤하늘에 <b>별</b>이 <i>반짝</i>였다. <span class="loud">크게</span> 외쳤다.</p>
<p class="centre">가운데 문단</p>
<p>주석은 <a href="ch%203.xhtml#note1">여기</a>를 보세요.</p>
<div id="empty"/>
<p>빈 div 다음 문단</p>
</body></html>
"""#)
        try zip.add("OEBPS/Text/ch2.xhtml", text: #"""
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>둘</title></head>
<body>
<h1>두 번째 장</h1>
<p>그림이 있는 장입니다.</p>
<p><img src="../Images/pic.png" alt="그림"/></p>
<table><tr><th>이름</th><th>값</th></tr><tr><td>별</td><td>42</td></tr></table>
</body></html>
"""#)
        try zip.add("OEBPS/Text/ch 3.xhtml", text: #"""
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>셋</title></head>
<body>
<h1>세 번째 장</h1>
<p id="note1">주석 내용입니다.</p>
<ul><li>목록 하나</li><li>목록 둘</li></ul>
</body></html>
"""#)
        try zip.add("OEBPS/Styles/book.css", text: ".loud { font-weight: bold } p.centre { text-align: center } body { color: #333 }")
        try zip.add("OEBPS/Images/pic.png", data: picture(160, 90), level: .noCompression)
        try zip.add("OEBPS/Images/cover.png", data: picture(300, 450), level: .noCompression)
        try zip.close(); return path
    }
    static func fb2(_ folder: String) throws -> String {
        let cover = try picture(120, 180).base64EncodedString()
        let xml = """
<?xml version="1.0" encoding="windows-1251"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
 <description>
  <title-info>
   <genre>prose_classic</genre>
   <author><first-name>Лев</first-name><last-name>Толстой</last-name></author>
   <book-title>Война и мир</book-title>
   <lang>ru</lang>
   <coverpage><image l:href="#cover.png"/></coverpage>
  </title-info>
 </description>
 <body>
  <title><p>Война и мир</p></title>
  <section>
   <title><p>Глава первая</p></title>
   <p>Первый <strong>абзац</strong> и <emphasis>курсив</emphasis>.<a l:href="#n1" type="note">[1]</a></p>
   <empty-line/>
   <poem><stanza><v>Строка стиха один</v><v>Строка стиха два</v></stanza></poem>
   <section>
    <title><p>Подглава</p></title>
    <p>Текст подглавы.</p>
   </section>
  </section>
  <section>
   <title><p>Глава вторая</p></title>
   <cite><p>Цитата из книги.</p></cite>
   <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
  </section>
 </body>
 <body name="notes">
  <section id="n1"><title><p>1</p></title><p>Текст примечания.</p></section>
 </body>
 <binary id="cover.png" content-type="image/png">\(cover)</binary>
</FictionBook>
"""
        let path = FilePath.combine(folder, "voina.fb2")
        let bytes = xml.data(using: TextEncodings.encoding(codePage: 1251)!)!
        try bytes.write(to: URL(fileURLWithPath: path)); return path
    }
    struct MobiOptions {
        var compression = 2
        var encryption = 0
        var cover: Int?
        var title = "Mobi Title"
        var author = "Mobi Author"
    }
    static func mobi(_ text: Data, _ pictures: [Data] = [], _ options: MobiOptions = MobiOptions()) -> Data {
        var records = [Data()]
        for offset in stride(from: 0, to: text.count, by: 4096) {
            let chunk = text.subdata(in: offset..<min(offset + 4096, text.count))
            records.append((options.compression == 2 ? palmDocCompress(chunk) : chunk) + Data([0, 0, 0x82]))
        }
        let textRecords = records.count - 1, firstImage = pictures.isEmpty ? -1 : records.count
        records += pictures
        var huff = -1
        if options.compression == 17480 { huff = records.count; records += [identityHuff(), identityCdic()] }
        records.append(Data([0xE9, 0x8E, 0x0D, 0x0A]))
        records[0] = record0(text.count, textRecords, firstImage, huff, options)
        return palmDb(options.title, "BOOKMOBI", records)
    }
    private static func record0(_ textLength: Int, _ textRecords: Int, _ firstImage: Int, _ huff: Int, _ options: MobiOptions) -> Data {
        var exth = [(100, Data(options.author.utf8)), (503, Data(options.title.utf8)), (524, Data("en".utf8))]
        if let cover = options.cover { exth.append((201, bigEndian(cover))) }
        let length = 12 + exth.reduce(0) { $0 + 8 + $1.1.count }, padding = (4 - length % 4) % 4
        var exthBytes = Data("EXTH".utf8) + bigEndian(length + padding) + bigEndian(exth.count)
        for (type, data) in exth { exthBytes += bigEndian(type) + bigEndian(8 + data.count) + data }
        exthBytes += Data(repeating: 0, count: padding)
        var header = Data(repeating: 0, count: 16 + 0xE8)
        func u16(_ offset: Int, _ value: Int) { BinaryPrimitives.writeUInt16BigEndian(&header, offset, UInt16(truncatingIfNeeded: value)) }
        func u32(_ offset: Int, _ value: Int) { BinaryPrimitives.writeUInt32BigEndian(&header, offset, UInt32(truncatingIfNeeded: value)) }
        u16(0, options.compression); u32(4, textLength); u16(8, textRecords); u16(10, 4096); u16(12, options.encryption)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        u32(0x14, 0xE8); u32(0x18, 2); u32(0x1C, 65001); u32(0x20, 0x1234); u32(0x24, 6)
        for offset in stride(from: 0x28, through: 0x4C, by: 4) { u32(offset, -1) }
        u32(0x50, textRecords + 1)
        let name = Data(options.title.utf8)
        u32(0x54, header.count + exthBytes.count); u32(0x58, name.count); u32(0x5C, 9); u32(0x68, 6)
        u32(0x6C, firstImage); u32(0x70, max(0, huff)); u32(0x74, huff < 0 ? 0 : 2); u32(0x80, 0x40)
        u32(0xA4, -1); u32(0xA8, -1); u16(0xC0, 1); u16(0xC2, textRecords); u32(0xC4, 1); u32(0xC8, -1); u32(0xD0, -1); u16(0xF2, 3)
        return header + exthBytes + name + Data(repeating: 0, count: 4)
    }
    static func palmDb(_ name: String, _ typeCreator: String, _ records: [Data]) -> Data {
        var header = Data(repeating: 0, count: 78 + records.count * 8 + 2)
        let nameBytes = Data(name.replacingOccurrences(of: " ", with: "_").utf16.map { $0 <= 127 ? UInt8($0) : 63 }.prefix(31))
        header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        header.replaceSubrange(60..<68, with: Data(typeCreator.utf8))
        BinaryPrimitives.writeUInt16BigEndian(&header, 76, UInt16(records.count))
        var offset = header.count
        for i in records.indices {
            BinaryPrimitives.writeUInt32BigEndian(&header, 78 + i * 8, UInt32(offset))
            BinaryPrimitives.writeUInt32BigEndian(&header, 78 + i * 8 + 4, UInt32(i * 2) & 0x00FFFFFF)
            offset += records[i].count
        }
        return records.reduce(header, +)
    }
    static func palmDocCompress(_ data: Data) -> Data {
        let input = [UInt8](data)
        var output: [UInt8] = [], i = 0
        while i < input.count {
            var bestLength = 0, bestDistance = 0
            for distance in 0..<min(2047, i) {
                let distance = distance + 1
                var length = 0
                while length < 10 && i + length < input.count && input[i + length] == input[i - distance + length] { length += 1 }
                if length > bestLength { bestLength = length; bestDistance = distance }
            }
            if bestLength >= 3 {
                let pair = 0x8000 | (bestDistance << 3) | (bestLength - 3)
                output += [UInt8(pair >> 8), UInt8(truncatingIfNeeded: pair)]; i += bestLength; continue
            }
            let c = input[i]
            if c == 32 && i + 1 < input.count && (0x40...0x7F).contains(input[i + 1]) { output.append(input[i + 1] ^ 0x80); i += 2 }
            else if c == 0 || (9...0x7F).contains(c) { output.append(c); i += 1 }
            else {
                var run: [UInt8] = []
                while i < input.count && run.count < 8 && ((1...8).contains(input[i]) || input[i] >= 0x80) { run.append(input[i]); i += 1 }
                output.append(UInt8(run.count)); output += run
            }
        }
        return Data(output)
    }
    static func identityHuff() -> Data {
        var huff = Data(repeating: 0, count: 24 + 256 * 4 + 64 * 4)
        huff.replaceSubrange(0..<4, with: Data("HUFF".utf8))
        BinaryPrimitives.writeUInt32BigEndian(&huff, 4, 24); BinaryPrimitives.writeUInt32BigEndian(&huff, 8, 24); BinaryPrimitives.writeUInt32BigEndian(&huff, 12, 24 + 256 * 4)
        for b in 0..<256 { BinaryPrimitives.writeUInt32BigEndian(&huff, 24 + b * 4, (UInt32(2 * b) << 8) | 0x80 | 8) }
        return huff
    }
    static func identityCdic() -> Data {
        var cdic = Data(repeating: 0, count: 16 + 256 * 2 + 256 * 3)
        cdic.replaceSubrange(0..<4, with: Data("CDIC".utf8))
        BinaryPrimitives.writeUInt32BigEndian(&cdic, 4, 16); BinaryPrimitives.writeUInt32BigEndian(&cdic, 8, 256); BinaryPrimitives.writeUInt32BigEndian(&cdic, 12, 8)
        for b in 0..<256 {
            let offset = 256 * 2 + b * 3
            BinaryPrimitives.writeUInt16BigEndian(&cdic, 16 + b * 2, UInt16(offset))
            BinaryPrimitives.writeUInt16BigEndian(&cdic, 16 + offset, 0x8001); cdic[16 + offset + 2] = UInt8(b)
        }
        return cdic
    }
    static func printReplica(_ pdf: Data) -> Data {
        var text = Data("%MOP".utf8) + bigEndian(1) + bigEndian(1) + bigEndian(20) + bigEndian(pdf.count)
        text.append(pdf)
        return mobi(text, [], MobiOptions(compression: 1, title: "Replica"))
    }
    private static func bigEndian(_ value: Int) -> Data { var result = Data(repeating: 0, count: 4); BinaryPrimitives.writeUInt32BigEndian(&result, 0, UInt32(truncatingIfNeeded: value)); return result }
    static let comicPages = [("chapter/page1.png", 200, 300), ("chapter/page2.jpg", 220, 330), ("chapter/page10.png", 240, 360)]
    static func cbz(_ folder: String) throws -> String {
        let path = FilePath.combine(folder, "만화.cbz"), zip = try ZipWriter(path: path)
        for (name, width, height) in comicPages { try zip.add(name, data: picture(width, height, name.hasSuffix(".jpg")), level: .noCompression) }
        try zip.add("__MACOSX/chapter/._page1.png", data: Data([0, 1, 2])); try zip.add("ComicInfo.xml", text: "<ComicInfo/>")
        try zip.close(); return path
    }
}
