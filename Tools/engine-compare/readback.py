"""Independent readback of formerly opaque outputs; no FileToX/Calibre conversions.

PalmDOC/MOBI, RocketBook, SNB and LRF are decoded here from their containers.
DOC uses Apple's importer; LIT uses ConvertLIT; DWG uses LibreDWG. External
executables must be supplied with SHA-256 pins. All work is private and bounded.
"""
import base64
import bz2
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import resource
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from inspection_process import bounded_command

FORMATS = {".azw3", ".mobi", ".pdb", ".rb", ".snb", ".lrf", ".lit", ".doc", ".dwg"}
LIMIT = 64 * 1024 * 1024
COUNT_LIMIT = 4096


class Unavailable(ValueError):
    pass


def take(data, at, size):
    if at < 0 or size < 0 or size > LIMIT or at > len(data) - size:
        raise ValueError("Truncated or over-limit binary range")
    return data[at:at + size]


def unpack(fmt, data, at=0):
    return struct.unpack(fmt, take(data, at, struct.calcsize(fmt)))


def inflate(data, expected=None, codec="zlib", limit=LIMIT):
    if expected is not None and not 0 <= expected <= limit: raise ValueError("Decoded size exceeds inspection limit")
    decoder = zlib.decompressobj() if codec == "zlib" else bz2.BZ2Decompressor()
    result = decoder.decompress(data, limit + 1)
    if len(result) > limit or not decoder.eof: raise ValueError("Truncated or over-limit compressed stream")
    if decoder.unused_data: raise ValueError("Trailing data after compressed stream")
    if expected is not None and len(result) != expected: raise ValueError("Decoded length does not match container")
    return result


def text(data, codec="utf-8"):
    return data.decode(codec)  # Never mask corrupt encoded text with replacement characters.


def image_type(data):
    for magic, mime in ((b"\xff\xd8\xff", "image/jpeg"), (b"\x89PNG\r\n\x1a\n", "image/png"),
                        (b"GIF8", "image/gif"), (b"BM", "image/bmp"), (b"II*\0", "image/tiff"),
                        (b"MM\0*", "image/tiff")):
        if data.startswith(magic): return mime
    return None


def result(reader, coverage, limits=()):
    return {"reader": reader, "coverage": coverage, "limits": list(limits),
            "textParts": {}, "structure": {}, "pictures": [], "opaqueParts": {}}


def picture(out, name, data):
    mime = image_type(data)
    if not mime: raise Unavailable("Unsupported embedded image encoding: " + name)
    out["pictures"].append({"name": name, "mediaType": mime, "data": base64.b64encode(data).decode("ascii")})


class Markup(HTMLParser):
    """Preserve markup/links exactly while comparing only character data as text."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.events, self.strings = [], []

    def event(self, *values):
        if len(self.events) >= 100_000: raise ValueError("Markup event limit")
        self.events.append(list(values))

    def handle_starttag(self, tag, attrs): self.event("start", tag, sorted(attrs, key=lambda pair: pair[0]))
    def handle_startendtag(self, tag, attrs): self.event("empty", tag, sorted(attrs, key=lambda pair: pair[0]))
    def handle_endtag(self, tag): self.event("end", tag)
    def handle_comment(self, value): self.event("comment", value)
    def handle_decl(self, value): self.event("declaration", value)
    def handle_pi(self, value): self.event("instruction", value)
    def unknown_decl(self, value): self.event("unknown-declaration", value)
    def handle_data(self, value):
        self.event("text", len(self.strings))
        self.strings.append(value)


def markup(out, name, value):
    parser = Markup(); parser.feed(value); parser.close()
    out["textParts"][name] = "".join(parser.strings)
    out["structure"].setdefault("markup", {})[name] = parser.events


def package(out, files):
    if not files or len(files) > COUNT_LIMIT: raise ValueError("Empty or over-limit document package")
    if sum(len(v) for v in files.values()) > LIMIT: raise ValueError("Decoded package exceeds byte limit")
    out["structure"]["entries"] = sorted(files)
    for name, data in sorted(files.items()):
        if image_type(data): picture(out, name, data)
        elif Path(name).suffix.lower() in (".html", ".htm", ".xhtml", ".xml", ".opf", ".ncx", ".css", ".snbc", ".snbf", ".info", ".txt"):
            value = text(data)
            if Path(name).suffix.lower() in (".css", ".info", ".txt"):
                out["textParts"][name] = value
                if Path(name).suffix.lower() in (".css", ".info"): out["structure"][name] = value
            else:
                if Path(name).suffix.lower() in (".xml", ".opf", ".ncx", ".snbc", ".snbf"): ET.fromstring(value)
                markup(out, name, value)
        else:
            out["opaqueParts"][name] = hashlib.sha256(data).hexdigest()
    if out["opaqueParts"]: out["limits"].append("Unrecognized package parts remain exact decoded-byte checks: " + ", ".join(out["opaqueParts"]))
    return out


def palmdoc(data, limit=LIMIT):
    out, at = bytearray(), 0
    while at < len(data):
        code = data[at]; at += 1
        if 1 <= code <= 8:
            out.extend(take(data, at, code)); at += code
        elif code < 128: out.append(code)
        elif code >= 192: out.extend((32, code ^ 128))
        else:
            word = (code << 8) | take(data, at, 1)[0]; at += 1
            distance, size = (word & 0x3FFF) >> 3, (word & 7) + 3
            if not 0 < distance <= len(out): raise ValueError("Invalid PalmDOC back-reference")
            for _ in range(size): out.append(out[-distance])
        if len(out) > limit: raise ValueError("PalmDOC decoded output exceeds inspection limit")
    return bytes(out)


def palm(data, extension):
    count, = unpack(">H", data, 76)
    if not 1 <= count <= COUNT_LIMIT: raise ValueError("Invalid Palm database record count")
    offsets = [unpack(">I", data, 78 + i * 8)[0] for i in range(count)] + [len(data)]
    if offsets[0] < 78 + count * 8 or any(a >= b for a, b in zip(offsets, offsets[1:])):
        raise ValueError("Invalid Palm database record offsets")
    records = [take(data, a, b - a) for a, b in zip(offsets, offsets[1:])]
    header = records[0]
    signature = take(data, 60, 8)
    if signature not in (b"TEXtREAd", b"BOOKMOBI"):
        raise Unavailable("Palm database type is not PalmDOC/MOBI: " + signature.hex())
    compression, _, length, ntext, record_size, position = unpack(">HHIHHI", header)
    if compression not in (1, 2): raise Unavailable("Unsupported PalmDOC/MOBI compression: " + str(compression))
    if signature == b"BOOKMOBI" and unpack(">H", header, 12)[0]: raise Unavailable("Encrypted MOBI is not inspected")
    if length > LIMIT or not 0 < ntext < count: raise ValueError("Invalid PalmDOC text length/count")
    out = result("independent-PalmDOC-MOBI-record-reader-v1", ["decoded text/markup", "embedded raster images", "record structure and metadata"],
                 ["No reflow/layout rendering; non-image index/resources are checked as decoded record bytes."])
    flags, codec, first_image, version = 0, "cp1252", count, None
    if signature == b"BOOKMOBI":
        if take(header, 16, 4) != b"MOBI": raise ValueError("Missing MOBI header")
        header_size, = unpack(">I", header, 20)
        take(header, 16, header_size)
        encoding, = unpack(">I", header, 28)
        if encoding not in (65001, 1252): raise Unavailable("Unsupported MOBI text encoding: " + str(encoding))
        codec = "utf-8" if encoding == 65001 else "cp1252"
        first_image, = unpack(">I", header, 108)
        first_image = count if first_image == 0xFFFFFFFF else first_image
        if not ntext < first_image <= count: raise ValueError("Invalid MOBI resource offset")
        if header_size >= 228: flags, = unpack(">H", header, 242)
        version, = unpack(">I", header, 104)
        out["structure"]["mobiVersion"] = version
        meta_at = 16 + header_size
        if header_size >= 116 and unpack(">I", header, 128)[0] & 0x40:
            if take(header, meta_at, 4) != b"EXTH": raise ValueError("Missing MOBI EXTH metadata")
            exth_size, number = unpack(">II", header, meta_at + 4)
            exth = take(header, meta_at, exth_size)
            if number > COUNT_LIMIT: raise ValueError("MOBI metadata count limit")
            at, entries = 12, []
            for _ in range(number):
                tag, size = unpack(">II", exth, at)
                if size < 8: raise ValueError("Invalid MOBI metadata record")
                value = take(exth, at + 8, size - 8); at += size
                entries.append([tag, value.hex()])
            out["structure"]["exth"] = entries
        title_at, title_size = unpack(">II", header, 84)
        out["textParts"]["title"] = text(take(header, title_at, title_size), codec)
    chunks = []
    total = 0
    for record in records[1:ntext + 1]:
        end, bits = len(record), flags >> 1
        while bits:
            if bits & 1:
                value, consumed = 0, 0
                for shift in range(0, 28, 7):
                    byte = take(record, end - consumed - 1, 1)[0]; consumed += 1
                    value |= (byte & 127) << shift
                    if byte & 128: break
                if not consumed <= value <= end: raise ValueError("Invalid MOBI trailing record")
                end -= value
            bits >>= 1
        if flags & 1: end -= (take(record, end - 1, 1)[0] & 3) + 1
        payload = take(record, 0, end)
        payload = palmdoc(payload, LIMIT - total) if compression == 2 else payload
        total += len(payload)
        if total > LIMIT: raise ValueError("MOBI decoded text byte limit")
        chunks.append(payload)
    payload = b"".join(chunks)
    if len(payload) != length: raise ValueError("PalmDOC/MOBI text length mismatch")
    decoded_records = set()
    if version == 8:
        fdst, flow_count = unpack(">II", header, 192)
        if flow_count > 1:
            if not ntext < fdst < count or flow_count > COUNT_LIMIT: raise ValueError("Invalid KF8 flow record/count")
            record = records[fdst]
            if take(record, 0, 4) != b"FDST": raise ValueError("Missing KF8 FDST record")
            start, number = unpack(">II", record, 4)
            if start < 12 or number != flow_count: raise ValueError("Invalid KF8 FDST header")
            flows = [unpack(">II", record, start + i * 8) for i in range(number)]
            if flows[0][0] or flows[-1][1] != len(payload) or any(a > b for a, b in flows) or any(a[1] != b[0] for a, b in zip(flows, flows[1:])):
                raise ValueError("KF8 flow ranges do not cover the decoded text")
            out["structure"]["flows"] = flows
            out["structure"]["auxiliaryFlows"] = {str(i): text(take(payload, a, b - a), codec) for i, (a, b) in enumerate(flows) if i}
            payload = take(payload, 0, flows[0][1])
            decoded_records.add(fdst)
        out["coverage"].append("KF8 FDST flow boundaries and auxiliary styles")
        out["limits"].append("KF8 skeleton/fragment/TOC index records remain exact-byte checks; no reconstructed spine or reflow rendering.")
    value = text(payload, codec)
    if signature == b"BOOKMOBI": markup(out, "content", value)
    else: out["textParts"]["content"] = value
    out["structure"].update({"databaseNameHex": take(data, 0, 32).hex(), "databaseType": signature.decode("ascii"), "textRecords": ntext, "recordCount": count,
                             "recordSize": record_size, "encoding": codec, "firstResource": first_image})
    if signature == b"TEXtREAd": out["structure"]["readingPosition"] = position
    for index, record in enumerate(records[ntext + 1:], ntext + 1):
        if index in decoded_records: continue
        if image_type(record): picture(out, str(index), record)
        else: out["opaqueParts"][str(index)] = hashlib.sha256(record).hexdigest()
    return out


def rocketbook(data):
    if take(data, 0, 14) != b"\xb0\x0c\xb0\x0c\x02\0NUVO\0\0\0\0": raise ValueError("Invalid RocketBook header")
    toc, size = unpack("<II", data, 24)
    if size != len(data): raise ValueError("RocketBook file size mismatch")
    count, = unpack("<I", data, toc)
    if not 0 < count <= COUNT_LIMIT: raise ValueError("RocketBook entry count limit")
    files, kinds, total = {}, {}, 0
    for index in range(count):
        at = toc + 4 + index * 44
        name = text(take(data, at, 32).split(b"\0", 1)[0])
        size, offset, flags = unpack("<III", data, at + 32)
        payload = take(data, offset, size)
        if name in files: raise ValueError("Duplicate RocketBook entry")
        if flags == 8:
            chunks, expected = unpack("<II", payload)
            if not 0 < chunks <= COUNT_LIMIT: raise ValueError("RocketBook chunk count limit")
            lengths = unpack("<" + "I" * chunks, payload, 8)
            pos, decoded = 8 + chunks * 4, bytearray()
            for length in lengths:
                decoded.extend(inflate(take(payload, pos, length), limit=LIMIT - total - len(decoded))); pos += length
            if pos != len(payload) or len(decoded) != expected: raise ValueError("RocketBook compressed length mismatch")
            payload = bytes(decoded)
        elif flags not in (0, 1, 2): raise Unavailable("Unsupported RocketBook entry flags")
        if name.lower().endswith((".html", ".htm", ".info")):
            payload = text(payload, "cp1252").encode("utf-8")
        total += len(payload)
        if total > LIMIT: raise ValueError("RocketBook decoded byte limit")
        files[name], kinds[name] = payload, flags & ~8
    out = package(result("independent-RocketBook-container-reader-v1", ["HTML text/structure", "embedded images", "entry metadata"], ["No layout rendering."]), files)
    out["structure"]["entryFlags"] = kinds
    return out


def snb(data):
    magic, rev, sig, reserved, count, fat_size, fat_compressed, binary_size, plain_size, reserved2 = unpack(">8s9I", data)
    if magic != b"SNBP000B" or rev != 0x8000 or sig != 0xA3A3A3 or reserved or reserved2:
        raise ValueError("Invalid SNB header")
    if not 0 < count <= COUNT_LIMIT or binary_size + plain_size > LIMIT: raise ValueError("SNB count/byte limit")
    fat = inflate(take(data, 44, fat_compressed), fat_size)
    tail_size, tail_at, tail_magic = unpack(">II8s", data, len(data) - 16)
    if tail_magic != magic or tail_at + tail_size != len(data) - 16: raise ValueError("Invalid SNB tail")
    binary_blocks, plain_blocks = (binary_size + 32767) // 32768, (plain_size + 32767) // 32768
    blocks = binary_blocks + plain_blocks
    tail = inflate(take(data, tail_at, tail_size), blocks * 4 + count * 8)
    offsets = list(unpack(">" + "I" * blocks, tail)) + [tail_at]
    if offsets and (offsets[0] != 44 + fat_compressed or any(a >= b for a, b in zip(offsets, offsets[1:]))):
        raise ValueError("Invalid SNB block offsets")
    binary = take(data, 44 + fat_compressed, binary_size)
    plain = bytearray()
    for index in range(binary_blocks, blocks):
        block = take(data, offsets[index], offsets[index + 1] - offsets[index])
        expected = min(32768, plain_size - len(plain))
        plain.extend(block if len(block) == expected else inflate(block, expected, "bz2"))
    if len(plain) != plain_size: raise ValueError("SNB plain stream length mismatch")
    names = take(fat, count * 12, len(fat) - count * 12)
    files, positions = {}, {False: 0, True: 0}
    for index in range(count):
        flags, name_at, size = unpack(">III", fat, index * 12)
        end = names.find(b"\0", name_at)
        if end < 0: raise ValueError("Unterminated SNB file name")
        name = text(take(names, name_at, end - name_at))
        if name in files: raise ValueError("Duplicate SNB file name")
        if flags not in (0x01000000, 0x41000000): raise Unavailable("Unsupported SNB entry flags")
        compressed = flags == 0x41000000
        stream = plain if compressed else binary
        block, offset = unpack(">II", tail, blocks * 4 + index * 8)
        logical = positions[compressed]
        if block != logical // 32768 + (binary_blocks if compressed else 0) or offset != logical % 32768:
            raise ValueError("SNB entry block reference mismatch")
        files[name] = bytes(take(stream, logical, size)); positions[compressed] += size
    if positions[False] != binary_size or positions[True] != plain_size: raise ValueError("Unassigned SNB payload bytes")
    return package(result("independent-SNB-container-reader-v1", ["XML text/structure", "embedded images", "all entry names and block references"], ["No layout rendering."]), files)


# LRF tag widths are format constants, not engine writer code. Variable fields
# are consumed with their lengths; unknown tags fail closed instead of scanning.
LRF_WIDTHS = {size: set(int(x, 16) for x in tags.split()) for size, tags in {
    0: "01 05 06 4d 62 63 64 65 66 67 68 69 6a 6b 6e 71 72 81 82 a2 a6 a8 a9 aa ab ac ad ae b1 b2 b3 b4 b5 b6 b7 b8 b9 ba bb bc bd be c1 c2 c4 c7 c9 d2 d6",
    2: "0d 0e 11 12 13 14 15 19 1a 1b 1c 1d 1e 21 22 23 24 25 26 27 28 2a 2b 2c 2e 31 32 33 35 36 38 39 3a 3c 3d 3e 41 42 46 47 48 51 52 54 56 57 58 5e 61 6d 75 76 77 79 7a c3 c5 c6 c8 ca cc d4 da db dc dd f1 f4",
    4: "02 03 04 07 08 09 0a 17 18 2d 34 37 44 45 4b 4c 53 5b 7b 7c a1 a7 d8 f2 f3 f5 f6 f7 f8",
    6: "00 29 f9", 8: "49 4a 6c d9", 10: "73", 12: "4e d1", 14: "d7"
}.items()}
LRF_WIDTH = {tag: size for size, tags in LRF_WIDTHS.items() for tag in tags}


def lrf_tag(data, at):
    tag, = unpack("<H", data, at); at += 2
    if tag >> 8 != 0xF5: raise ValueError("Invalid LRF tag")
    code = tag & 255
    if code == 0x78:
        if unpack("<H", data, at + 4)[0] != 0xF516: raise ValueError("Invalid LRF emphasis font tag")
        nested, _, end = lrf_tag(data, at + 4)
        if nested != 0x16: raise ValueError("Invalid LRF emphasis font tag")
        size = end + 2 - at
    elif code in (0x16, 0x55, 0x59, 0x5A, 0x5D, 0x0B, 0x5C):
        size, = unpack("<H", data, at); at += 2
        if code in (0x0B, 0x5C): size *= 4
    elif code in LRF_WIDTH: size = LRF_WIDTH[code]
    else: raise Unavailable(f"Unsupported LRF tag: {tag:04x}")
    payload = take(data, at, size)
    return code, payload, at + size


def lrf(data):
    if take(data, 0, 8) != b"L\0R\0F\0\0\0": raise ValueError("Invalid LRF header")
    version, key = unpack("<HH", data, 8)
    if version <= 800: raise Unavailable("LRF header version <=800 is not covered")
    count, table = unpack("<QQ", data, 16)
    if not 0 < count <= COUNT_LIMIT: raise ValueError("LRF object count limit")
    info_size, thumb_type, thumb_size, info_decoded = unpack("<HHII", data, 76)
    metadata = inflate(take(data, 88, info_size - 4), info_decoded)
    out = result("independent-LRF-object-reader-v1", ["UTF-16 text and all parsed control tags", "object graph/styles/page geometry", "embedded images"],
                 ["No Sony device layout rendering; embedded fonts/sounds remain decoded-byte checks."])
    ET.fromstring(metadata)
    markup(out, "metadata", text(metadata))
    if thumb_size: picture(out, "thumbnail", take(data, 84 + info_size, thumb_size))
    out["structure"]["device"] = {"binding": data[36], "dpi": unpack("<H", data, 38)[0], "width": unpack("<H", data, 42)[0],
                                    "height": unpack("<H", data, 44)[0], "depth": data[46]}
    out["structure"]["root"] = unpack("<I", data, 12)[0]
    objects, total = {}, len(metadata) + thumb_size
    for index in range(count):
        identifier, offset, size, reserved = unpack("<IIII", data, table + index * 16)
        obj = take(data, offset, size)
        code, payload, at = lrf_tag(obj, 0)
        if code != 0 or unpack("<I", payload)[0] != identifier or str(identifier) in objects:
            raise ValueError("Invalid or duplicate LRF object")
        kind, = unpack("<H", payload, 4)
        tags, stream_size, flags, stream_seen = [], None, None, False
        while at < len(obj):
            code, payload, at = lrf_tag(obj, at)
            if code == 4: stream_size, = unpack("<I", payload)
            elif code == 0x54: flags, = unpack("<H", payload)
            elif code == 5:
                if stream_size is None or flags is None or stream_seen: raise ValueError("Invalid LRF stream header")
                stream_seen = True
                stream = take(obj, at, stream_size); at += stream_size
                if take(obj, at, 2) != b"\x06\xf5": raise ValueError("Missing LRF stream end")
                at += 2
                if flags & 0x200:
                    xor = (len(stream) % (key & 255)) + 15 if 0 < key & 255 <= 240 else 0
                    amount = min(len(stream), 1024) if kind in (0x11, 0x17, 0x19) else len(stream)
                    stream = bytes(value ^ xor for value in stream[:amount]) + stream[amount:]
                if flags & 0x100: stream = inflate(stream[4:], unpack("<I", stream)[0], limit=LIMIT - total)
                total += len(stream)
                if total > LIMIT: raise ValueError("LRF decoded byte limit")
                if kind == 0x11: picture(out, f"object:{identifier}", stream)
                elif kind in (0x17, 0x19): out["opaqueParts"][str(identifier)] = hashlib.sha256(stream).hexdigest()
                elif kind == 0x1E:
                    entries, = unpack("<I", stream)
                    if entries > COUNT_LIMIT: raise ValueError("LRF TOC entry count limit")
                    base = pos = (entries + 1) * 4
                    toc = []
                    for entry in range(entries):
                        if unpack("<I", stream, (entry + 1) * 4)[0] != pos - base: raise ValueError("LRF TOC offset mismatch")
                        page, refobj, length = unpack("<IIH", stream, pos); pos += 10
                        name = f"object:{identifier}:toc:{entry}"
                        out["textParts"][name] = text(take(stream, pos, length), "utf-16-le"); pos += length
                        toc.append([page, refobj, name])
                    if pos != len(stream): raise ValueError("LRF TOC trailing data")
                    tags.append(["toc", toc])
                else:
                    content, pos = [], 0
                    while pos < len(stream):
                        tag, operand, pos = lrf_tag(stream, pos)
                        if tag == 0xCC and kind in (0x0A, 0x1D):
                            length, = unpack("<H", operand)
                            name = f"object:{identifier}:text:{len(content)}"
                            out["textParts"][name] = text(take(stream, pos, length), "utf-16-le"); pos += length
                            content.append([tag, name])
                        else: content.append([tag, operand.hex()])
                    tags.append(["stream", flags & ~0x300, content])
            else: tags.append([code, payload.hex()])
        if not tags or tags[-1][0] != 1: raise ValueError("Missing LRF object end")
        objects[str(identifier)] = {"type": kind, "tags": tags}
    out["structure"]["objects"] = objects
    return out


def tool(config, name):
    entry = config.get(name)
    if not entry: raise Unavailable("Provide a pinned " + name + " in --semantic-tools")
    path = Path(entry["path"])
    if not path.is_absolute() or not path.is_file(): raise Unavailable("Reader path is not an existing absolute file: " + name)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != entry.get("sha256"): raise Unavailable("Reader SHA-256 mismatch: " + name)
    return str(path)


def external(args, folder, config):
    # The outer supervisor owns timeout/output/process-tree limits; this child and
    # all native descendants share its group and resource limits.
    profile = '(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (subpath ' + json.dumps(str(folder)) + '))'
    if "sdkDenialProfile" in config:
        profile += Path(tool(config, "sdkDenialProfile")).read_text().replace("(version 1)", "")
    stdout, stderr = folder / "reader.stdout", folder / "reader.stderr"
    with stdout.open("wb") as output, stderr.open("wb") as error:
        run = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, *map(str, args)], stdout=output, stderr=error)
    if stdout.stat().st_size + stderr.stat().st_size > LIMIT: raise ValueError("Native reader output limit")
    if run.returncode: raise Unavailable(f"{Path(args[0]).name} failed with exit {run.returncode}: " + stderr.read_text(errors="replace")[-1000:])
    return stdout.read_bytes()


def lit(path, config, folder):
    program = tool(config, "convertlit")
    output = folder / "extracted"; output.mkdir()
    log = external([program, path, str(output) + "/"], folder, config)
    if b"but with errors" in log or b"WARNING" in log or b"ERROR" in log: raise Unavailable("ConvertLIT reported an incomplete extraction")
    files, size = {}, 0
    for item in sorted(output.rglob("*")):
        if item.is_symlink(): raise ValueError("Reader emitted a symlink")
        if item.is_file():
            size += item.stat().st_size
            if size > LIMIT or len(files) >= COUNT_LIMIT: raise ValueError("Reader extracted output limit")
            files[item.relative_to(output).as_posix()] = item.read_bytes()
    return package(result("ConvertLIT-1.8-independent-LIT-extractor", ["expanded HTML/OPF and links", "embedded images", "all package entries"], ["No browser/layout rendering; DRM5 unsupported."]), files)


def dwg(path, config, folder):
    data = json.loads(external([tool(config, "dwgread"), "-O", "JSON", path], folder, config))
    if not data.get("OBJECTS"): raise Unavailable("LibreDWG did not decode any objects")
    diagnostics = (folder / "reader.stderr").read_text(errors="replace").strip()
    if diagnostics != "SUCCESS": raise Unavailable("LibreDWG did not report a clean complete read: " + diagnostics[-1000:])
    uninspected = []
    for obj in data["OBJECTS"]:
        if not (obj.get("entity") or obj.get("object")):
            uninspected.append({"handle": obj.get("handle"), "type": obj.get("entity") or obj.get("object"),
                                "reason": "Undecoded object type"})
    pending = [("", data)]
    while pending:
        location, value = pending.pop()
        if isinstance(value, dict):
            for key, child in value.items():
                if key in ("unknown_bits", "unknown_rest") and child:
                    uninspected.append({"path": location + "/" + key, "handle": value.get("handle"),
                                        "type": value.get("object") or value.get("entity"),
                                        "bits": value.get("num_unknown_bits", len(child) * 4)})
                elif isinstance(child, (dict, list)): pending.append((location + "/" + key, child))
        elif isinstance(value, list): pending.extend((location + "/" + str(i), x) for i, x in enumerate(value))
    out = result("LibreDWG-independent-DWG-reader", ["decoded entity/object fields, coordinates, text, layers and references", "header variables"], ["No CAD raster rendering; listed unknown fields are compared as raw decoded values only."])
    out["uninspected"] = uninspected
    out["structure"] = data
    return out


def inspect(path, config, folder):
    if path.stat().st_size > LIMIT: raise ValueError("Binary input exceeds inspection byte limit")
    ext = path.suffix.lower()
    if ext == ".doc":
        out = json.loads(external([tool(config, "native"), "doc", path], folder, config))
    elif ext == ".lit": out = lit(path, config, folder)
    elif ext == ".dwg": out = dwg(path, config, folder)
    else:
        data = path.read_bytes()
        if ext in (".azw3", ".mobi", ".pdb"): out = palm(data, ext)
        elif ext == ".rb": out = rocketbook(data)
        elif ext == ".snb": out = snb(data)
        elif ext == ".lrf": out = lrf(data)
        else: raise Unavailable("Unsupported binary format")
    out["inspectionVersion"] = 1
    return out


def readback(path, config=None):
    from fingerprint import ensure_native, sha256
    config = dict(config or {})
    if path.suffix.lower() == ".doc":
        binary = ensure_native().resolve()
        config["native"] = {"path": str(binary), "sha256": sha256(binary)}
    with tempfile.TemporaryDirectory(prefix="filetox-readback-") as scratch:
        folder = Path(scratch)
        settings = folder / "tools.json"; settings.write_text(json.dumps(config))
        output = bounded_command([sys.executable, "-I", "-B", Path(__file__).resolve(), "--child", path.resolve(), settings], cwd=folder, scratch=folder, watch=folder)
        return json.loads(output)


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "--child": raise SystemExit("Internal binary readback: --child PATH TOOLS")
    resource.setrlimit(resource.RLIMIT_CPU, (55, 55))
    resource.setrlimit(resource.RLIMIT_FSIZE, (LIMIT, LIMIT))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))
    try:
        value = inspect(Path(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text()), Path.cwd())
    except Unavailable as error: value = {"error": {"kind": "unavailable", "message": str(error)}}
    except (ValueError, OSError, struct.error, ET.ParseError) as error:
        value = {"error": {"kind": "invalid", "message": str(error)}}
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))
