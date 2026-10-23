"""Output inspection using stdlib and already-installed macOS tools."""
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "build/engine-compare/bin/inspect"
IMAGES = set("png jpg jpeg webp tiff tif bmp gif ico avif heic jxl jp2 psd psb tga ppm pgm pbm icns".split())
TEXT = set("txt md html htm rst tex csv tsv svg xml fb2 eml rtf ps eps dxf pml".split())
MEDIA = set("mp4 m4v mov mkv webm avi wmv flv mpg ts m2ts 3gp 3g2 ogv vob dv mxf mp3 m4a m4b aac wav flac ogg opus wma aiff ac3 amr au caf weba mka mp2 voc".split())
FONTS = {"ttf", "otf", "woff", "woff2", "eot"}
ARCHIVES = set("zip 7z rar tar tgz tbz2 txz gz bz2 xz lz lzma z jar cab cpio deb rpm dmg iso img lha arj alz egg".split())


def command(args, timeout=60, **kwargs):
    result = subprocess.run([str(x) for x in args], capture_output=True, timeout=timeout, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr.decode(errors='replace')[-2000:]}")
    return result.stdout


def ensure_native():
    source = Path(__file__).with_name("inspect.swift")
    if not NATIVE.exists() or NATIVE.stat().st_mtime < source.stat().st_mtime:
        NATIVE.parent.mkdir(parents=True, exist_ok=True)
        command(["/usr/bin/swiftc", "-O", str(source), "-o", str(NATIVE)], timeout=180)
    return NATIVE


def native(mode, *paths):
    return json.loads(command([ensure_native(), mode, *paths]))


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalized(text):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text)).strip()


def decode(data):
    codecs = ["utf-16"] if data.startswith((b"\xff\xfe", b"\xfe\xff")) else ["utf-8-sig", "cp949", "utf-16-le", "latin-1"]
    for codec in codecs:
        try:
            return data.decode(codec)
        except UnicodeError:
            pass
    return data.decode("utf-8", errors="replace")


def directory_entries(path):
    return [{"name": p.relative_to(path).as_posix(), "size": p.stat().st_size, "sha256": sha256(p)}
            for p in sorted(path.rglob("*")) if p.is_file()]


def zip_entries(path):
    entries, xml = [], {}
    with zipfile.ZipFile(path) as archive:
        for info in sorted(archive.infolist(), key=lambda i: i.filename):
            data = archive.read(info)
            entries.append({"name": info.filename, "size": info.file_size,
                            "sha256": hashlib.sha256(data).hexdigest()})
            if info.filename.lower().endswith((".xml", ".rels", ".opf", ".ncx", ".xhtml", ".html")) or info.filename == "mimetype":
                xml[info.filename] = normalized(decode(data))
    return {"entries": entries, "keyParts": xml}


def archive_entries(path, sevenzip):
    listing = command([sevenzip, "l", "-slt", "--", path]).decode("utf-8", errors="replace")
    # -slt header precedes the dashed divider; entry blocks follow it.
    body = listing.split("----------", 1)[-1]
    entries = []
    for block in re.split(r"\r?\n\s*\r?\n", body):
        fields = dict(line.split(" = ", 1) for line in block.splitlines() if " = " in line)
        if "Path" not in fields:
            continue
        name = fields["Path"].replace("\\", "/")
        folder = fields.get("Folder") == "+" or fields.get("Attributes", "").startswith("D")
        entry = {"name": name, "size": int(fields.get("Size", "0")), "directory": folder}
        if not folder:
            # No extraction to disk, even for hostile archive entry names.
            payload = command([sevenzip, "x", "-so", "-spd", "--", path, fields["Path"]])
            entry["sha256"] = hashlib.sha256(payload).hexdigest()
        entries.append(entry)
    return {"entries": sorted(entries, key=lambda e: e["name"])}


def sfnt_tables(data):
    if data[:4] in (b"\0\1\0\0", b"OTTO", b"true"):
        count = struct.unpack_from(">H", data, 4)[0]
        records = [struct.unpack_from(">4sIII", data, 12 + 16*i) for i in range(count)]
        tags = sorted(tag.decode("ascii", errors="replace") for tag, _, _, _ in records)
        maxp = next((data[offset:offset+length] for tag, _, offset, length in records if tag == b"maxp"), b"")
        return {"tableTags": tags, "glyphCount": struct.unpack_from(">H", maxp, 4)[0] if len(maxp) >= 6 else None}
    if data[:4] == b"wOFF":
        count = struct.unpack_from(">H", data, 12)[0]
        records = [struct.unpack_from(">4sIIII", data, 44 + 20*i) for i in range(count)]
        maxp = b""
        for tag, offset, size, original, _ in records:
            if tag == b"maxp":
                maxp = data[offset:offset+size]
                if size != original:
                    maxp = zlib.decompress(maxp)
        return {"tableTags": sorted(r[0].decode("ascii") for r in records),
                "glyphCount": struct.unpack_from(">H", maxp, 4)[0] if len(maxp) >= 6 else None}
    raise ValueError("Not an SFNT/WOFF font")


def freetype_tables(path):
    # Run in a child process: macOS CoreText crashes on some valid WOFF2 files.
    import ctypes as c
    import ctypes.util
    candidates = [ctypes.util.find_library("freetype"),
                  "/opt/homebrew/opt/freetype/lib/libfreetype.6.dylib",
                  "/usr/local/opt/freetype/lib/libfreetype.6.dylib"]
    library_path = next((p for p in candidates if p and (not p.startswith("/") or Path(p).exists())), None)
    if not library_path: raise RuntimeError("Installed FreeType not found for WOFF2 inspection")
    ft = c.CDLL(library_path)
    ft.FT_Init_FreeType.argtypes = [c.POINTER(c.c_void_p)]
    ft.FT_New_Face.argtypes = [c.c_void_p, c.c_char_p, c.c_long, c.POINTER(c.c_void_p)]
    ft.FT_Sfnt_Table_Info.argtypes = [c.c_void_p, c.c_uint, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong)]
    ft.FT_Load_Sfnt_Table.argtypes = [c.c_void_p, c.c_ulong, c.c_long, c.POINTER(c.c_ubyte), c.POINTER(c.c_ulong)]
    ft.FT_Done_Face.argtypes = [c.c_void_p]
    ft.FT_Done_FreeType.argtypes = [c.c_void_p]
    library, face = c.c_void_p(), c.c_void_p()
    if ft.FT_Init_FreeType(c.byref(library)): raise RuntimeError("FreeType initialization failed")
    try:
        if ft.FT_New_Face(library, str(path).encode(), 0, c.byref(face)):
            raise RuntimeError("FreeType cannot decode this WOFF2 font")
        count = c.c_ulong()
        if ft.FT_Sfnt_Table_Info(face, 0, None, c.byref(count)) or count.value > 4096:
            raise RuntimeError("Invalid font table count")
        tags = []
        for index in range(count.value):
            tag, length = c.c_ulong(), c.c_ulong()
            if ft.FT_Sfnt_Table_Info(face, index, c.byref(tag), c.byref(length)):
                raise RuntimeError("Cannot read font table directory")
            tags.append(tag.value.to_bytes(4, "big").decode("ascii", errors="replace"))
        value, length = (c.c_ubyte * 2)(), c.c_ulong(2)
        if ft.FT_Load_Sfnt_Table(face, int.from_bytes(b"maxp", "big"), 4, value, c.byref(length)):
            raise RuntimeError("Cannot read maxp glyph count")
        return {"tableTags": sorted(tags), "glyphCount": int.from_bytes(bytes(value), "big")}
    finally:
        if face: ft.FT_Done_Face(face)
        ft.FT_Done_FreeType(library)


def font_tables(path):
    data = path.read_bytes()
    if data[:4] == b"wOF2":
        return json.loads(command([sys.executable, "-I", Path(__file__).resolve(), "--woff2", path]))
    if len(data) >= 82 and data[34:36] == b"LP":
        size, font_size, _, flags = struct.unpack_from("<IIII", data)
        if flags & 4 or size > len(data) or not 0 < font_size <= size - 82:
            raise ValueError("Unsupported or invalid compressed EOT")
        data = data[size-font_size:size]
        if flags & 0x10000000: data = bytes(b ^ 0x50 for b in data)
    return sfnt_tables(data)


def fingerprint(path, sevenzip=None):
    path = Path(path)
    if path.is_dir():
        return {"kind": "directory", "entries": directory_entries(path)}
    with path.open("rb") as stream:
        head = stream.read(32)
    result = {"size": path.stat().st_size, "sha256": sha256(path), "magic": head.hex()}
    ext = path.suffix.lower().lstrip(".")
    kind = ("pdf" if head.startswith(b"%PDF") else "image" if ext in IMAGES else
            "media" if ext in MEDIA else "font" if ext in FONTS else
            "archive" if ext in ARCHIVES else "zip" if zipfile.is_zipfile(path) else
            "text" if ext in TEXT or ext == "svgz" else "binary")
    result["kind"] = kind
    try:
        if kind in ("image", "pdf"):
            result["metadata"] = native(kind, path)
            if kind == "pdf":
                for page in result["metadata"]["pages"]:
                    page["text"] = normalized(page["text"])
        elif kind == "text":
            data = gzip.decompress(path.read_bytes()) if ext == "svgz" else path.read_bytes()
            result["text"] = normalized(decode(data))
        elif kind == "zip":
            result["metadata"] = zip_entries(path)
        elif kind == "archive":
            if zipfile.is_zipfile(path):
                result["metadata"] = zip_entries(path)
            elif sevenzip:
                result["metadata"] = archive_entries(path, sevenzip)
            else:
                raise RuntimeError("Provide --sevenzip to fingerprint non-ZIP archives")
        elif kind == "font":
            result["metadata"] = font_tables(path)
        elif kind == "media":
            probe = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
            data = json.loads(command([probe, "-v", "error", "-show_streams", "-show_format", "-of", "json", path]))
            result["metadata"] = {"duration": float(data.get("format", {}).get("duration", 0)),
                "streams": [{k: s.get(k) for k in ("codec_type", "codec_name", "width", "height", "sample_rate",
                                                  "channels", "sample_fmt", "pix_fmt", "r_frame_rate")}
                            for s in data["streams"]]}
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, struct.error, zipfile.BadZipFile) as error:
        result["inspectionError"] = str(error)
    return result


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--woff2":
        raise SystemExit("Internal inspector: --woff2 PATH")
    print(json.dumps(freetype_tables(Path(sys.argv[2]))))
