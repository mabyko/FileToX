#!/usr/bin/env python3
"""Build small, reproducible-content fixtures locally; record every failed recipe."""
import argparse
import bz2
import copy
import gzip
import io
import json
import lzma
import os
from pathlib import Path
import shutil
import struct
import sys
import tarfile
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hostwire import Host, add_host_arguments, own_copies, write_json
from fingerprint import command, sha256

EPOCH = 1577836800
KOREAN = "FileToX sample\n안녕하세요. 한글 변환 시험입니다.\nSecond line: café, 12345.\n"


def png(path, width=96, height=64, alpha=True):
    rows = b"".join(b"\0" + b"".join(bytes([x*255//width, y*255//height, (x+y)*3 % 256] +
                   ([64 + x*191//width] if alpha else [])) for x in range(width)) for y in range(height))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag+data))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8,
                     6 if alpha else 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def zip_write(path, entries):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_host_arguments(parser)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    root = args.out.resolve()
    root.mkdir(parents=True, exist_ok=False)
    samples = root / "samples"
    samples.mkdir()
    manifest = {"schema": 1, "samples": [], "attempts": [], "epoch": EPOCH,
                "determinism": "Fixed source content, archive headers and file mtimes. Native/host encoders may embed volatile IDs or dates; recorded hashes pin this capture."}

    def save():
        write_json(root / "manifest.json", manifest)

    def add(path, fmt, provenance):
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError("Recipe produced no nonempty file")
        os.utime(path, (EPOCH, EPOCH))
        item = {"id": path.name, "path": path.relative_to(root).as_posix(), "formatId": fmt,
                "sha256": sha256(path), "size": path.stat().st_size, "provenance": provenance}
        manifest["samples"].append(item)
        save()
        return path

    def attempt(name, action):
        try:
            value = action()
            manifest["attempts"].append({"recipe": name, "state": "ok"})
            return value
        except Exception as error:
            manifest["attempts"].append({"recipe": name, "state": "failed", "detail": str(error)})
            print(f"SKIP {name}: {str(error)[:180]}", flush=True)
        finally:
            save()

    def text(name, content, fmt=None, encoding="utf-8"):
        path = samples / name
        path.write_bytes(content.encode(encoding))
        return add(path, fmt or path.suffix[1:], {"tool": "python", "encoding": encoding})

    image = samples / "한글 image.png"
    png(image)
    add(image, "png", {"tool": "python", "recipe": "RGBA gradient 96x64"})
    second = samples / "second.png"
    png(second, 64, 96, alpha=False)
    add(second, "png", {"tool": "python", "recipe": "RGB gradient 64x96"})
    width, height = 96, 64
    rgb = b"".join(bytes([x*255//width, y*255//height, 128]) for y in range(height) for x in range(width))
    ppm = samples / "gradient.ppm"
    ppm.write_bytes(f"P6\n{width} {height}\n255\n".encode() + rgb)
    add(ppm, "ppm", {"tool": "python", "recipe": "P6 RGB"})
    bgr = b"".join(rgb[i:i+3][::-1] for i in range(0, len(rgb), 3))
    tga = samples / "gradient.tga"
    tga.write_bytes(struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 24, 32) + bgr)
    add(tga, "tga", {"tool": "python", "recipe": "uncompressed top-origin TGA"})
    bmp = samples / "gradient.bmp"
    bmp.write_bytes(b"BM" + struct.pack("<IHHI", 54+len(bgr), 0, 0, 54) +
                    struct.pack("<IiiHHIIiiII", 40, width, -height, 1, 24, 0, len(bgr), 3780, 3780, 0, 0) + bgr)
    add(bmp, "bmp", {"tool": "python", "recipe": "24-bit BMP, 96 DPI"})
    txt = text("한글 문서.txt", KOREAN)
    text("cp949.txt", KOREAN.replace("café", "cafe"), encoding="cp949")
    text("utf16.txt", KOREAN, encoding="utf-16")
    text("book.md", "# FileToX sample\n\n안녕하세요. **Bold** and *italic*.\n\n| Name | Value |\n|---|---|\n| 한국 | 42 |\n")
    text("page.html", '<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><title>FileToX sample</title></head><body><h1>안녕하세요</h1><p>FileToX sample <b>bold</b> text.</p></body></html>')
    text("page.rst", "FileToX sample\n==============\n\n안녕하세요. **Bold** text.\n")
    text("page.tex", "\\documentclass{article}\n\\begin{document}\nFileToX sample. 안녕하세요. \\textbf{Bold}.\n\\end{document}\n")
    text("table.csv", "Name,Value,Note\n한국,42,hello\nFileToX,17,world\n")
    text("table.tsv", "Name\tValue\tNote\n한국\t42\thello\nFileToX\t17\tworld\n")
    text("drawing.svg", '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="64"><rect width="96" height="64" fill="#3478f6"/><circle cx="48" cy="32" r="20" fill="#ffcc00"/><text x="5" y="15" font-size="10">FileToX</text></svg>')
    text("drawing.dxf", "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nLINE\n8\n0\n10\n0\n20\n0\n30\n0\n11\n100\n21\n100\n31\n0\n0\nCIRCLE\n8\n0\n10\n50\n20\n50\n30\n0\n40\n20\n0\nENDSEC\n0\nEOF\n")
    text("message.eml", "From: sample@example.invalid\nTo: reader@example.invalid\nSubject: FileToX sample\nDate: Wed, 01 Jan 2020 00:00:00 +0000\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n" + KOREAN)
    text("book.fb2", '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><genre>prose</genre><author><first-name>FileToX</first-name><last-name>Sample</last-name></author><book-title>FileToX sample</book-title><lang>ko</lang></title-info><document-info><author><nickname>FileToX</nickname></author><date>2020-01-01</date><id>filetox-sample</id><version>1.0</version></document-info></description><body><section><title><p>FileToX</p></title><p>안녕하세요. Conversion sample.</p></section></body></FictionBook>')
    presentation = samples / "slides.pptx"
    zip_write(presentation, {
        "[Content_Types].xml": '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>',
        "_rels/.rels": '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>',
        "ppt/presentation.xml": '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
        "ppt/_rels/presentation.xml.rels": '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>',
        "ppt/slides/slide1.xml": '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>FileToX sample 안녕하세요</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'})
    add(presentation, "pptx", {"tool": "python", "recipe": "minimal OOXML presentation, one text slide"})
    text("notes.unknownext", "Unknown input retained in combined archives.", "unknown")
    folder = samples / "folder"
    folder.mkdir()
    (folder / "inside.txt").write_text(KOREAN, encoding="utf-8")
    manifest["samples"].append({"id": "folder", "path": "samples/folder", "formatId": "folder",
                                "entries": [{"path": "inside.txt", "sha256": sha256(folder / "inside.txt")}],
                                "provenance": {"tool": "python"}})

    for fmt in ("jpg", "tiff", "heic", "gif", "jp2", "psd", "ico", "icns", "avif"):
        def sips(fmt=fmt):
            path = samples / ("sips." + fmt)
            command(["/usr/bin/sips", "-s", "format", "jpeg" if fmt == "jpg" else fmt, image, "--out", path])
            return add(path, fmt, {"tool": "sips", "source": image.name, "format": fmt})
        attempt("sips " + fmt, sips)
    for fmt in ("docx", "odt", "rtf", "doc", "html", "webarchive"):
        def textutil(fmt=fmt):
            path = samples / ("textutil." + fmt)
            command(["/usr/bin/textutil", "-convert", fmt, "-encoding", "UTF-8", "-output", path, txt])
            return add(path, fmt, {"tool": "textutil", "source": txt.name, "format": fmt})
        attempt("textutil " + fmt, textutil)
    for fmt in ("ttf", "otf"):
        def font(fmt=fmt):
            candidates = sorted(Path("/System/Library/Fonts").rglob("*." + fmt))
            if not candidates:
                raise RuntimeError("No system font with this extension")
            src = min(candidates, key=lambda p: (p.stat().st_size, str(p)))
            path = samples / ("font." + fmt)
            shutil.copyfile(src, path)
            return add(path, fmt, {"tool": "copy", "source": str(src)})
        attempt("system font " + fmt, font)

    payload = {"hello.txt": KOREAN.encode(), "folder/data.csv": (samples / "table.csv").read_bytes()}
    path = samples / "archive.zip"
    zip_write(path, payload)
    add(path, "zip", {"tool": "python", "recipe": "fixed ZIP headers"})
    path = samples / "comic.cbz"
    zip_write(path, {"001.png": image.read_bytes(), "002.png": second.read_bytes()})
    add(path, "cbz", {"tool": "python", "recipe": "two-page comic ZIP"})
    tarbytes = io.BytesIO()
    with tarfile.open(fileobj=tarbytes, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in sorted(payload.items()):
            info = tarfile.TarInfo(name)
            info.size, info.mtime, info.mode = len(data), EPOCH, 0o644
            archive.addfile(info, io.BytesIO(data))
    tar_data = tarbytes.getvalue()
    encoders = {"tar": tar_data, "tgz": gzip.compress(tar_data, mtime=0), "tbz2": bz2.compress(tar_data),
                "txz": lzma.compress(tar_data), "gz": gzip.compress(KOREAN.encode(), mtime=0),
                "bz2": bz2.compress(KOREAN.encode()), "xz": lzma.compress(KOREAN.encode()),
                "lzma": lzma.compress(KOREAN.encode(), format=lzma.FORMAT_ALONE)}
    for fmt, data in encoders.items():
        path = samples / ("archive." + fmt)
        path.write_bytes(data)
        add(path, fmt, {"tool": "python", "recipe": "fixed compressed bytes"})

    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    for fmt, options in [("mp4", ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=12", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"]),
                         ("mp3", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-c:a", "libmp3lame"]),
                         ("wav", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-c:a", "pcm_s16le"])]:
        def media(fmt=fmt, options=options):
            path = samples / ("tone." + fmt)
            command([ffmpeg, "-nostdin", "-v", "error", *options, "-t", "1", "-fflags", "+bitexact", "-flags:a", "+bitexact", "-map_metadata", "-1", path])
            return add(path, fmt, {"tool": "ffmpeg", "arguments": options, "duration": 1})
        attempt("ffmpeg " + fmt, media)

    with Host(args.host, copies=own_copies(args), stderr_path=root / "host.stderr.log") as host:
        manifest["catalog"] = host.call("catalog.get")
        library = host.call("library.get")
        template = library["presets"][0]
        def derive(source, target, stem="derived"):
            path = samples / source
            if not path.exists():
                raise RuntimeError("Missing dependency " + source)
            selection = host.call("selection.resolve", paths=[str(path)])
            if not any(t["formatId"] == target and t["available"] for t in selection["targets"]):
                raise RuntimeError("Route unavailable")
            preset = copy.deepcopy(template)
            preset.update(id="corpus-derive", name="Corpus", targetFormat=target)
            preset["output"].update(location="customFolder", customFolder=str(root / "derived-work"), fileNamePattern="{name}")
            result = host.convert([path], preset=preset, timeout=120)
            outputs = [Path(o["path"]) for f in result["files"] for o in f.get("outputs", []) if not o["isDirectory"]]
            if result["state"] != "completed" or not outputs:
                raise RuntimeError(json.dumps(result["files"], ensure_ascii=False))
            dest = samples / (stem + "." + target)
            shutil.copyfile(outputs[0], dest)
            # Keep engine-created media beside derived sources when it exists.
            for sidecar in outputs[0].parent.glob(outputs[0].stem + "_files"):
                shutil.copytree(sidecar, samples / sidecar.name, dirs_exist_ok=True)
            return add(dest, target, {"tool": "host-wire-v1", "source": source, "targetFormat": target,
                                      "sourceSha256": sha256(path)})

        recipes = [("textutil.docx", "pdf"), ("book.md", "epub"), ("table.csv", "xlsx"),
                   ("table.csv", "ods"), ("table.csv", "xls"), (txt.name, "hwpx"),
                   ("derived.hwpx", "hwp"), ("drawing.svg", "pdf"), ("drawing.svg", "svgz"),
                   ("drawing.dxf", "dwg"), ("drawing.dxf", "svg"),
                   *[(image.name, fmt) for fmt in ("webp", "jxl", "psd", "psb", "tga", "icns", "avif")],
                   *[("font.ttf", fmt) for fmt in ("woff", "woff2", "eot")],
                   *[("textutil.docx", fmt) for fmt in ("docm", "dotx", "dotm")],
                   *[("derived.xlsx", fmt) for fmt in ("xlsm", "xltx")],
                   *[("slides.pptx", fmt) for fmt in ("pptm", "potx", "ppsx", "odp", "ppt")],
                   *[("book.md", fmt) for fmt in ("mobi", "azw3", "htmlz", "txtz", "lit", "lrf", "pdb", "pml", "rb", "snb", "tcr")],
                   *[("archive.zip", fmt) for fmt in ("7z", "tgz", "tbz2", "txz")]]
        recipes += [("tone.mp4", fmt) for fmt in ("mov", "mkv", "webm", "avi", "m4v", "flv", "wmv", "mpg", "ts", "m2ts", "3gp", "3g2", "ogv", "vob", "mxf", "dv")]
        recipes += [("tone.wav", fmt) for fmt in ("flac", "aiff", "m4a", "m4b", "aac", "opus", "ogg", "wma", "ac3", "au", "caf", "weba", "mka", "mp2", "voc", "amr")]
        for source, target in recipes:
            attempt(source + " → " + target, lambda s=source, t=target: derive(s, t, "vector" if s == "drawing.svg" and t == "pdf" else "derived"))
        def multipage():
            result = host.convert([image, second], presetId="merge-pdf")
            outputs = [Path(o["path"]) for f in result["files"] for o in f.get("outputs", [])]
            if result["state"] != "completed" or not outputs:
                raise RuntimeError(str(result))
            path = samples / "two-pages.pdf"
            shutil.move(outputs[0], path)
            return add(path, "pdf", {"tool": "host-wire-v1", "presetId": "merge-pdf", "sources": [image.name, second.name]})
        attempt("two-page PDF", multipage)
    manifest["samples"].sort(key=lambda s: s["id"])
    manifest["summary"] = {"samples": len(manifest["samples"]),
                           "formats": len({s["formatId"] for s in manifest["samples"]}),
                           "failedRecipes": sum(a["state"] == "failed" for a in manifest["attempts"])}
    save()
    print(json.dumps(manifest["summary"]), flush=True)


if __name__ == "__main__":
    main()
