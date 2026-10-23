#!/usr/bin/env python3
"""Generate large, deterministic inputs for Tools/engine-bench/bench.py (no network, no external tools)."""
import argparse, io, pathlib, random, subprocess, zipfile

def pdf(path, pages=200):
    objs = []
    def add(s): objs.append(s); return len(objs)
    font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    ids = []
    for i in range(pages):
        lines = "".join(f"BT /F1 11 Tf 40 {800 - 14 * j} Td (Page {i} line {j} lorem ipsum dolor sit amet consectetur) Tj ET\n" for j in range(50))
        c = add(f"<< /Length {len(lines)} >>\nstream\n{lines}endstream")
        ids.append(add(f"<< /Type /Page /Parent PARENT 0 R /MediaBox [0 0 612 842] /Contents {c} 0 R /Resources << /Font << /F1 {font} 0 R >> >> >>"))
    pages_obj = add(f"<< /Type /Pages /Kids [{' '.join(f'{p} 0 R' for p in ids)}] /Count {len(ids)} >>")
    objs = [o.replace("PARENT", str(pages_obj)) for o in objs]
    cat = add(f"<< /Type /Catalog /Pages {pages_obj} 0 R >>")
    out = io.BytesIO(); out.write(b"%PDF-1.4\n"); offs = []
    for i, o in enumerate(objs, 1):
        offs.append(out.tell()); out.write(f"{i} 0 obj\n{o}\nendobj\n".encode())
    x = out.tell(); out.write(f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode())
    for o in offs: out.write(f"{o:010d} 00000 n \n".encode())
    out.write(f"trailer\n<< /Size {len(objs) + 1} /Root {cat} 0 R >>\nstartxref\n{x}\n%%EOF\n".encode())
    path.write_bytes(out.getvalue())

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=pathlib.Path, required=True)
    p.add_argument("--seed-png", type=pathlib.Path, help="Small PNG upscaled with sips to 6000x4000 (big.png)")
    a = p.parse_args(); B = a.out; B.mkdir(parents=True, exist_ok=True); rnd = random.Random(2)
    pdf(B / "big.pdf")
    with zipfile.ZipFile(B / "big.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for i in range(2000): z.writestr(f"dir{i % 20}/file{i}.txt", f"line {i} of file {i}\n" * 200)
    ents = "".join(f"0\nLINE\n8\n0\n10\n{rnd.uniform(0, 1000):.3f}\n20\n{rnd.uniform(0, 1000):.3f}\n30\n0\n11\n{rnd.uniform(0, 1000):.3f}\n21\n{rnd.uniform(0, 1000):.3f}\n31\n0\n" for _ in range(50000))
    (B / "big.dxf").write_text("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" + ents + "0\nENDSEC\n0\nEOF\n")
    with zipfile.ZipFile(B / "big.epub", "w") as z:
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        items = "".join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(300))
        spine = "".join(f'<itemref idref="c{i}"/>' for i in range(300))
        z.writestr("OEBPS/content.opf", f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:1</dc:identifier><dc:title>Big</dc:title><dc:language>en</dc:language></metadata><manifest>{items}</manifest><spine>{spine}</spine></package>')
        for i in range(300):
            body = "".join(f"<p>Chapter {i} paragraph {j} lorem ipsum dolor sit amet, consectetur adipiscing elit sed do eiusmod tempor.</p>" for j in range(80))
            z.writestr(f"OEBPS/c{i}.xhtml", f'<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>C{i}</title></head><body><h1>Chapter {i}</h1>{body}</body></html>')
    with zipfile.ZipFile(B / "big.docx", "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
        z.writestr("_rels/.rels", '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
        paras = "".join(f"<w:p><w:r><w:t>Paragraph {i} lorem ipsum dolor sit amet consectetur adipiscing elit</w:t></w:r></w:p>" for i in range(5000))
        z.writestr("word/document.xml", f'<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{paras}</w:body></w:document>')
    words = "markdown parser performance swift table list emphasis link image code block quote heading footnote".split()
    md = []
    for i in range(6000):
        md.append(f"## Heading {i}\n" + " ".join(rnd.choice(words) for _ in range(60)) + f" **bold** _em_ `code` [link](https://example.com/{i}) ![img](p{i}.png)[^{i}]\n")
        md.append("- item one\n- item two\n  - nested *three*\n\n| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n\n> quote line\n\n```swift\nlet x = 1\n```\n\n[^%d]: note\n\n" % i)
    (B / "big.md").write_text("".join(md))
    if a.seed_png:
        subprocess.run(["sips", "-z", "4000", "6000", str(a.seed_png), "--out", str(B / "big.png")], check=True, capture_output=True)
    for f in sorted(B.iterdir()): print(f"{f.stat().st_size / 1e6:8.2f} MB  {f.name}")

if __name__ == "__main__":
    main()
