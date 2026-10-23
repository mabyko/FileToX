"""Narrow container/metadata normalization, also usable on previously captured runs.

Payloads are never discarded: embedded images are returned for pixel comparison,
and TAR members keep their names, types, link targets and content digests.
"""
import base64
import hashlib
import re
import tarfile
import xml.etree.ElementTree as ET

UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
DC = "http://purl.org/dc/elements/1.1/"
OPF = "http://www.idpf.org/2007/opf"
NCX = "http://www.daisy.org/z3986/2005/ncx/"
FB2 = "http://www.gribuser.ru/xml/fictionbook/2.0"
ODF_META = "urn:oasis:names:tc:opendocument:xmlns:meta:1.0"


def xml_text(text, name="", pictures=None):
    """Canonical XML; only generated metadata fields have volatile values removed."""
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return text
    ids = {}

    def generated(value):
        if value not in ids:
            ids[value] = f"$UUID{len(ids) + 1}"
        return ids[value]

    for el in root.iter():
        if el.tag == f"{{{DC}}}identifier" and re.fullmatch("urn:uuid:" + UUID, el.text or ""):
            el.text = generated(el.text)
        if el.tag == f"{{{NCX}}}meta" and el.get("name") == "dtb:uid" and re.fullmatch("urn:uuid:" + UUID, el.get("content", "")):
            el.set("content", generated(el.get("content")))
        if name.lower() == "docprops/core.xml" and el.tag in (
                "{http://purl.org/dc/terms/}created", "{http://purl.org/dc/terms/}modified"):
            el.text = "$DATE"
        if name.lower() == "meta.xml" and el.tag in (f"{{{ODF_META}}}creation-date", f"{{{DC}}}date"):
            el.text = "$DATE"
        if name.lower() == "settings.xml" and el.tag == "{urn:oasis:names:tc:opendocument:xmlns:config:1.0}config-item" and el.get("{urn:oasis:names:tc:opendocument:xmlns:config:1.0}name") in ("Rsid", "RsidRoot"):
            if re.fullmatch(r"\d+", el.text or ""): el.text = generated(el.text)
        if el.tag == f"{{{OPF}}}meta" and el.get("property") == "dcterms:modified":
            el.text = "$DATE"
        # DrawingML field IDs are local identities, rather than user content.
        if el.tag == "{http://schemas.openxmlformats.org/drawingml/2006/main}fld" and re.fullmatch(r"\{" + UUID + r"\}", el.get("id", "")):
            el.set("id", generated(el.get("id")))
    if root.tag == f"{{{FB2}}}FictionBook":
        info = root.find(f"{{{FB2}}}description/{{{FB2}}}document-info")
        if info is not None:
            for el in info:
                if el.tag == f"{{{FB2}}}id" and re.fullmatch(UUID, el.text or ""):
                    el.text = generated(el.text)
                if el.tag == f"{{{FB2}}}date":
                    el.text = "$DATE"
                    if "value" in el.attrib: el.set("value", "$DATE")
        if pictures is not None:
            for el in root.findall(f"{{{FB2}}}binary"):
                data = base64.b64decode(re.sub(r"\s", "", el.text or ""), validate=True)
                pictures.append((el.get("content-type", ""), data))
                el.text = f"$IMAGE{len(pictures)}"

    def canonical(el):
        # Keep text/tails and element order, including runs and whitespace between words.
        return [el.tag, sorted(el.attrib.items()), el.text or "",
                [[canonical(child), child.tail or ""] for child in el]]

    import json
    return json.dumps(canonical(root), ensure_ascii=False, separators=(",", ":"))


def document_text(text, extension):
    pictures = []
    if extension == ".fb2":
        return xml_text(text, pictures=pictures), pictures
    if extension in (".html", ".htm", ".md"):
        def image(match):
            pictures.append((match[1].lower(), base64.b64decode(match[2], validate=True)))
            return f"data:{match[1].lower()};$IMAGE{len(pictures)}"
        text = re.sub(r"data:(image/[\w.+-]+);base64,([A-Za-z0-9+/=]+)", image, text)
    if extension == ".rtf":
        def image(match):
            pictures.append(("image/jpeg" if "jpegblip" in match[1] else "image/png", bytes.fromhex(match[2])))
            return match[1] + f" $IMAGE{len(pictures)}" + "}"
        # Filee/Pandoc emit a flat pict group with hex samples after the controls.
        text = re.sub(r"(\{\\pict(?:\\[a-z]+-?\d*\s*)+)\s*([0-9a-fA-F\s]+)\}", image, text)
    return text, pictures


def rst_dimensions(left, right):
    """Pandoc emits inches from quantized image DPI; use the PDF 1pt tolerance."""
    pattern = r":(width|height):\s*([0-9]+(?:\.[0-9]+)?)(in|pt|cm|mm)\b"
    groups = [list(re.finditer(pattern, value)) for value in (left, right)]
    if len(groups[0]) != len(groups[1]): return left, right, None
    scale = {"in": 72, "pt": 1, "cm": 72 / 2.54, "mm": 72 / 25.4}
    deltas = []
    for a, b in zip(*groups):
        if a[1] != b[1]: return left, right, None
        deltas.append(abs(float(a[2]) * scale[a[3]] - float(b[2]) * scale[b[3]]))
    if any(d > 1 for d in deltas): return left, right, None
    return re.sub(pattern, r":\1: $DIMENSION", left), re.sub(pattern, r":\1: $DIMENSION", right), deltas


def tar_entries(path):
    """Read through gzip/bzip2/xz and PAX headers without extracting to disk."""
    try:
        with tarfile.open(path, "r:*") as archive:
            entries = []
            for member in archive:
                entry = [member.name, member.type.decode("ascii"), member.linkname]
                if member.isfile():
                    stream = archive.extractfile(member)
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                    entry.append(digest.hexdigest())
                entries.append(entry)
            return sorted(entries)
    except tarfile.ReadError:
        return None


def generated_calibre_cover(data):
    """Only Calibre's explicit JPEG COM marker, never arbitrary image bytes."""
    if not data.startswith(b"\xff\xd8"): return False
    offset = 2
    while offset + 4 <= len(data) and data[offset] == 255:
        marker = data[offset + 1]
        if marker in (0xda, 0xd9): break
        size = int.from_bytes(data[offset + 2:offset + 4], "big")
        if size < 2 or offset + 2 + size > len(data): break
        if marker == 0xfe and data[offset + 4:offset + 2 + size].startswith(b"Generated cover: calibre "):
            return True
        offset += size + 2
    return False
