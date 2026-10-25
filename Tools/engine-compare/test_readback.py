#!/usr/bin/env python3
"""Focused independent-reader and process-bound regressions; no engine execution."""
import bz2
import copy
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from xml.etree.ElementTree import ParseError
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare import compare_output, pictures_equal
from inspection_process import bounded_command
from readback import LIMIT, inflate, palmdoc, palm, rocketbook, snb, lrf, lrf_tag, dwg, readback, tool, Unavailable


class ReadbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.thresholds = {"psnr": 30, "ssim": .95, "text": .95}

    def tearDown(self): self.tmp.cleanup()

    @staticmethod
    def pdb(payload, compressed=False):
        header = bytearray(96)
        header[60:68] = b"TEXtREAd"
        struct.pack_into(">H", header, 76, 2)
        struct.pack_into(">I", header, 78, 96)
        struct.pack_into(">I", header, 86, 112)
        encoded = b"\xc1" if compressed else payload
        return bytes(header) + struct.pack(">HHIHHI", 2 if compressed else 1, 0, len(payload), 1, 4096, 0) + encoded

    def test_palmdoc_literal_backreference_space_and_malformed_sequences(self):
        self.assertEqual(palmdoc(b"abc\x80\x18\xc1\x03\x01\x02\x03"), b"abcabc A\x01\x02\x03")
        for data in (b"\x08abc", b"\x80", b"\x80\0", b"\x80\x08"):
            with self.subTest(data=data), self.assertRaises(ValueError): palmdoc(data)
        with self.assertRaisesRegex(ValueError, "limit"): palmdoc(b"abc\x80\x1f", limit=4)

    def test_palm_readback_checks_text_independently_of_compression(self):
        for compressed in (False, True):
            value = palm(self.pdb(b" A", compressed), ".pdb")
            self.assertEqual(value["textParts"]["content"], " A")
            self.assertEqual(value["structure"]["textRecords"], 1)
        a, b = self.root / "a.pdb", self.root / "b.pdb"
        name = b"Same title".ljust(32, b"\0")
        a.write_bytes(name + self.pdb(b" A")[32:]); b.write_bytes(name + self.pdb(b" A", True)[32:])
        old = {"kind": "binary", "sha256": "same"}
        status, _, metrics = compare_output(old, old, a, b, self.thresholds)
        self.assertEqual(status, "PASS")
        self.assertEqual(metrics["readback"]["textRatios"]["content"], 1)
        b.write_bytes(self.pdb(b"lost text"))
        self.assertEqual(compare_output(old, old, a, b, self.thresholds)[0], "FAIL")
        b.write_bytes(b"bad")
        self.assertEqual(compare_output(old, old, a, b, self.thresholds)[0], "FAIL")
        self.assertEqual(compare_output(old, old, b, a, self.thresholds)[0], "WARN")

    def test_palm_database_name_changes_fail_with_identical_body(self):
        names = [name.ljust(32, b"\0") for name in (b"Original title", b"Different title")]
        for extension, data in ((".pdb", self.pdb(b" A")), (".mobi", self.mobi(b"<p> A</p>")),
                                (".azw3", self.mobi(b"<p> A</p>", version=8))):
            with self.subTest(extension=extension):
                paths = [self.root / (side + extension) for side in ("left", "right")]
                for path, name in zip(paths, names): path.write_bytes(name + data[32:])
                fingerprints = [{"kind": "binary", "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths]
                status, reasons, metrics = compare_output(*fingerprints, *paths, self.thresholds)
                self.assertEqual(status, "FAIL")
                self.assertIn("Decoded document structure or metadata changed", reasons)
                self.assertEqual(metrics["readback"]["textRatios"]["content"], 1)
                self.assertEqual([metrics["readback"]["structure"][side]["databaseNameHex"] for side in ("baseline", "candidate")],
                                 [name.hex() for name in names])

    def test_palm_offsets_and_declared_lengths_are_validated(self):
        for offset, value in ((78, 1), (86, 96), (100, LIMIT + 1)):
            data = bytearray(self.pdb(b"content")); struct.pack_into(">I", data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError): palm(bytes(data), ".pdb")
        data = bytearray(self.pdb(b"text")); struct.pack_into(">I", data, 108, 3)
        self.assertEqual(palm(bytes(data), ".pdb")["structure"]["readingPosition"], 3)

    @staticmethod
    def png(color):
        def chunk(kind, payload):
            return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress((b"\0" + bytes(color) * 2) * 2)) + chunk(b"IEND", b""))

    @staticmethod
    def mobi(payload, picture=None, version=6):
        header = bytearray(248)
        struct.pack_into(">HHIHHI", header, 0, 1, 0, len(payload), 1, 4096, 0)
        header[16:20] = b"MOBI"
        struct.pack_into(">I", header, 20, 232)
        struct.pack_into(">I", header, 28, 65001)
        struct.pack_into(">I", header, 36, version)
        struct.pack_into(">I", header, 104, version)
        struct.pack_into(">II", header, 84, 271, 5)
        struct.pack_into(">I", header, 108, 2 if picture else 0xffffffff)
        struct.pack_into(">I", header, 128, 0x40)
        header += b"EXTH" + struct.pack(">IIII", 23, 1, 100, 11) + b"Me!Title"
        records = [header, payload] + ([picture] if picture else [])
        database = bytearray(78 + len(records) * 8 + 2)
        database[60:68] = b"BOOKMOBI"
        struct.pack_into(">H", database, 76, len(records))
        at = len(database)
        for i, record in enumerate(records):
            struct.pack_into(">I", database, 78 + i * 8, at); at += len(record)
        return bytes(database) + b"".join(records)

    def test_kf8_flow_table_separates_styles_from_book_text_and_validates_ranges(self):
        html, css = b"<p>Book text</p>", b"p {color: red}"
        fdst = b"FDST" + struct.pack(">IIIIII", 12, 2, 0, len(html), len(html), len(html) + len(css))
        data = bytearray(self.mobi(html + css, fdst, 8))
        header, = struct.unpack_from(">I", data, 78)
        struct.pack_into(">II", data, header + 192, 2, 2)
        value = palm(bytes(data), ".azw3")
        self.assertEqual(value["textParts"]["content"], "Book text")
        self.assertEqual(value["structure"]["auxiliaryFlows"]["1"], css.decode())
        self.assertEqual(value["opaqueParts"], {})
        struct.pack_into(">I", data, len(data) - 4, len(html) + len(css) - 1)
        with self.assertRaisesRegex(ValueError, "flow ranges"): palm(bytes(data), ".azw3")

    def test_mobi_azw3_links_images_and_metadata_are_read_independently(self):
        for version in (6, 8):
            value = palm(self.mobi(b'<p><a href="chapter2">Keep</a></p>', self.png((255, 0, 0)), version), ".mobi")
            self.assertEqual(value["textParts"], {"title": "Title", "content": "Keep"})
            self.assertEqual(value["structure"]["mobiVersion"], version)
            self.assertIn(["start", "a", [("href", "chapter2")]], value["structure"]["markup"]["content"])
            self.assertEqual(len(value["pictures"]), 1)
            self.assertEqual(value["structure"]["exth"], [[100, b"Me!".hex()]])
        a, b = self.root / "a.mobi", self.root / "b.mobi"
        a.write_bytes(self.mobi(b'<a href="good">identical text</a>'))
        b.write_bytes(self.mobi(b'<a href="lost">identical text</a>'))
        old = {"kind": "binary", "sha256": "same"}
        status, _, metrics = compare_output(old, old, a, b, self.thresholds)
        self.assertEqual(status, "FAIL")
        self.assertEqual(metrics["readback"]["textRatios"]["content"], 1)

    def test_even_byte_equal_embedded_images_are_decoded_and_strictly_compared(self):
        a, b = self.root / "a.mobi", self.root / "b.mobi"
        old = {"kind": "binary", "sha256": "same"}
        a.write_bytes(self.mobi(b"<p>text</p>", self.png((255, 0, 0))))
        b.write_bytes(a.read_bytes())
        status, _, metrics = compare_output(old, old, a, b, self.thresholds)
        self.assertEqual(status, "PASS")
        self.assertTrue(metrics["pictures"]["1"]["sameGeometry"])
        b.write_bytes(self.mobi(b"<p>text</p>", self.png((0, 0, 255))))
        self.assertEqual(compare_output(old, old, a, b, self.thresholds)[0], "FAIL")
        a.write_bytes(self.mobi(b"<p>text</p>", b"\x89PNG\r\n\x1a\ncorrupt")); b.write_bytes(a.read_bytes())
        self.assertNotEqual(compare_output(old, old, a, b, self.thresholds)[0], "PASS")

    def test_strict_picture_comparison_inspects_remaining_images_after_a_failure(self):
        red, blue = ("image/png", self.png((255, 0, 0))), ("image/png", self.png((0, 0, 255)))
        metrics = {}
        self.assertIn("similarity", pictures_equal([red, red], [blue, red], self.thresholds, metrics, strict=True))
        self.assertEqual(set(metrics), {"1", "2"})
        self.assertEqual(metrics["2"]["frames"][0]["psnr"], 99)

    def test_inflate_rejects_truncation_trailing_data_and_expansion(self):
        for codec, compress in (("zlib", zlib.compress), ("bz2", bz2.compress)):
            compressed = compress(b"abc" * 1024)
            self.assertEqual(inflate(compressed, 3072, codec), b"abc" * 1024)
            for payload in (compressed[:-1], compressed + b"garbage"):
                with self.subTest(codec=codec), self.assertRaises(ValueError): inflate(payload, codec=codec)
            with self.assertRaises(ValueError): inflate(compressed, codec=codec, limit=100)
            with self.assertRaises(ValueError): inflate(compressed, expected=10, codec=codec)

    @staticmethod
    def rb(payload):
        compressed = zlib.compress(payload)
        entry = struct.pack("<III", 1, len(payload), len(compressed)) + compressed
        header = bytearray(40); header[:14] = b"\xb0\x0c\xb0\x0c\x02\0NUVO\0\0\0\0"
        struct.pack_into("<II", header, 24, 40, 88 + len(entry))
        return bytes(header) + struct.pack("<I32sIII", 1, b"book.html", len(entry), 88, 8) + entry

    def test_rocketbook_reads_markup_and_rejects_truncated_chunks(self):
        value = rocketbook(self.rb(b"<html><p>Keep &amp; compare</p></html>"))
        self.assertIn("Keep", value["textParts"]["book.html"])
        self.assertEqual(value["structure"]["entries"], ["book.html"])
        with self.assertRaises(ValueError): rocketbook(self.rb(b"x")[:-1])
        data = bytearray(self.rb(b"x")); struct.pack_into("<I", data, 88, 99999)
        with self.assertRaisesRegex(ValueError, "count limit"): rocketbook(data)

    @staticmethod
    def snb(payload):
        name = b"snbc/chapter.snbc\0"
        fat = struct.pack(">III", 0x41000000, 0, len(payload)) + name
        compressed_fat = zlib.compress(fat)
        block = bz2.compress(payload)
        offset = 44 + len(compressed_fat)
        tail = zlib.compress(struct.pack(">III", offset, 0, 0))
        return (struct.pack(">8s9I", b"SNBP000B", 0x8000, 0xa3a3a3, 0, 1, len(fat), len(compressed_fat), 0, len(payload), 0)
                + compressed_fat + block + tail + struct.pack(">II8s", len(tail), offset + len(block), b"SNBP000B"))

    def test_snb_decodes_text_and_checks_tail_references(self):
        value = snb(self.snb(b"<chapter><p>Content</p></chapter>"))
        self.assertIn("Content", value["textParts"]["snbc/chapter.snbc"])
        for data in (self.snb(b"<p/>")[:-1], b"SNBP000B", self.snb(b"<p/>") + b"bad"):
            with self.subTest(size=len(data)), self.assertRaises(ValueError): snb(data)

    @staticmethod
    def lrf(payload, compressed=True):
        raw = b"\xcc\xf5" + struct.pack("<H", len(payload.encode("utf-16-le"))) + payload.encode("utf-16-le")
        encoded = struct.pack("<I", len(raw)) + zlib.compress(raw) if compressed else raw
        stream = (struct.pack("<HIH", 0xF500, 1, 10) + struct.pack("<HIHHH", 0xF504, len(encoded), 0xF554, 0x100 if compressed else 0, 0xF505)
                  + encoded + b"\x06\xf5\x01\xf5")
        meta = b'<Info><BookInfo><Title>Fixture</Title></BookInfo></Info>'; packed = zlib.compress(meta)
        header = bytearray(88); header[:8] = b"L\0R\0F\0\0\0"
        struct.pack_into("<HHIQQ", header, 8, 1000, 0, 1, 1, 88 + len(packed) + len(stream))
        struct.pack_into("<HHII", header, 76, len(packed) + 4, 0, 0, len(meta))
        return bytes(header) + packed + stream + struct.pack("<IIII", 1, 88 + len(packed), len(stream), 0)

    def test_lrf_decodes_text_and_preserves_control_graph_without_compressed_bytes(self):
        a = lrf(self.lrf("한글 content"))
        b = lrf(self.lrf("한글 content", False))
        self.assertEqual(a, b)
        self.assertEqual(a["textParts"]["object:1:text:0"], "한글 content")
        with self.assertRaises(ValueError): lrf(self.lrf("text")[:-1])

    def test_lrf_toc_reads_labels_references_and_rejects_recursive_tags(self):
        data = bytearray(self.lrf("text"))
        table, = struct.unpack_from("<Q", data, 24)
        label = "Chapter".encode("utf-16-le")
        raw = struct.pack("<IIIIH", 1, 0, 1, 1, len(label)) + label
        stream = struct.pack("<HIHHIH", 0xf500, 2, 0x1e, 0xf504, len(raw), 0xf554) + b"\0\0\x05\xf5" + raw + b"\x06\xf5\x01\xf5"
        index = data[table:] + struct.pack("<IIII", 2, table, len(stream), 0)
        data[table:] = stream + index
        struct.pack_into("<QQ", data, 16, 2, table + len(stream))
        value = lrf(bytes(data))
        self.assertEqual(value["textParts"]["object:2:toc:0"], "Chapter")
        self.assertEqual(value["structure"]["objects"]["2"]["tags"][0], ["toc", [[1, 1, "object:2:toc:0"]]])
        with self.assertRaisesRegex(ValueError, "emphasis"): lrf_tag(b"\x78\xf5" + b"\0" * 4 + b"\x78\xf5", 0)
        with self.assertRaises(Unavailable): lrf_tag(b"\xff\xf5", 0)

    def test_dwg_retains_known_geometry_and_reports_unknown_fields(self):
        raw = {"OBJECTS": [{"entity": "LINE", "handle": [0, 1, 1], "start": [0, 1, 2]},
                           {"object": "TABLESTYLE", "handle": [0, 1, 54], "unknown_bits": "aabb", "num_unknown_bits": 16}],
               "APPINFO": {"unknown_bits": "ff"}}
        (self.root / "reader.stderr").write_text("SUCCESS\n")
        with patch("readback.tool", return_value="reader"), patch("readback.external", return_value=json.dumps(raw).encode()):
            value = dwg(self.root / "test.dwg", {}, self.root)
        self.assertEqual(value["structure"], raw)
        self.assertEqual(len(value["uninspected"]), 2)
        old = {"kind": "binary", "sha256": "same"}
        a, b = self.root / "a.dwg", self.root / "b.dwg"
        with patch("compare.readback", return_value=value):
            self.assertEqual(compare_output(old, old, a, b, self.thresholds)[0], "WARN")
        for field, replacement in (("start", [0, 1, 99]), ("unknown_bits", "ccdd")):
            changed = copy.deepcopy(value)
            changed["structure"]["OBJECTS"][0 if field == "start" else 1][field] = replacement
            with patch("compare.readback", side_effect=[value, changed]):
                self.assertEqual(compare_output(old, old, a, b, self.thresholds)[0], "FAIL")

    def test_doc_native_importer_reads_text_styles_and_rejects_corruption(self):
        source, path = self.root / "source.rtf", self.root / "fixture.doc"
        source.write_text(r'{\rtf1\ansi Plain {\b Bold}\par {\field{\*\fldinst HYPERLINK "https://example.invalid/test"}{\fldrslt Link}}}')
        bounded_command(["/usr/bin/textutil", "-convert", "doc", "-output", path, source])
        value = readback(path)
        self.assertNotIn("error", value)
        self.assertIn("Plain Bold", value["textParts"]["document"])
        runs = value["structure"]["runs"]
        # Apple's DOC fixture writer drops the hyperlink target before import.
        self.assertNotIn(b"https://example.invalid/test", path.read_bytes())
        self.assertTrue(any("Bold" in r.get("NSFont", {}).get("name", "") for r in runs))
        path.write_bytes(b"corrupt compound document")
        self.assertIn("error", readback(path))

    def test_binary_input_limit_is_enforced_before_reading(self):
        path = self.root / "large.pdb"
        with path.open("wb") as stream: stream.truncate(LIMIT + 1)
        value = readback(path)
        self.assertEqual(value["error"]["kind"], "invalid")
        self.assertIn("byte limit", value["error"]["message"])

    def test_pinned_reader_must_match_exact_binary(self):
        path = self.root / "reader"; path.write_bytes(b"test")
        config = {"dwgread": {"path": str(path), "sha256": hashlib.sha256(b"test").hexdigest()}}
        self.assertEqual(tool(config, "dwgread"), str(path))
        path.write_bytes(b"changed")
        with self.assertRaisesRegex(Unavailable, "SHA-256"): tool(config, "dwgread")
        with self.assertRaisesRegex(Unavailable, "pinned"): tool({}, "convertlit")

    def test_external_extraction_is_pinned_private_and_cannot_modify_the_input(self):
        program, path = self.root / "extractor", self.root / "fixture.lit"
        path.write_bytes(b"retained input")

        def run(script):
            program.write_text("#!/bin/sh\nset -e\n" + script); program.chmod(0o700)
            config = {"convertlit": {"path": str(program), "sha256": hashlib.sha256(program.read_bytes()).hexdigest()}}
            return readback(path, config)

        value = run('printf "<p>Independent extraction</p>" > "${2}book.html"\n')
        self.assertEqual(value["textParts"]["book.html"], "Independent extraction")
        value = run('printf "modified" > "$1"\n')
        self.assertEqual(value["error"]["kind"], "unavailable")
        self.assertEqual(path.read_bytes(), b"retained input")
        try: value = run('ln -s "$1" "${2}link.txt"\n')
        except RuntimeError as error: self.assertIn("symlink", str(error))
        else: self.assertIn("error", value)

    def test_markup_structure_is_not_normalized_and_malformed_xml_fails(self):
        from readback import package, result
        a = package(result("fixture", []), {"book.opf": b'<book id="uuid-a"><title>Title</title></book>'})
        b = package(result("fixture", []), {"book.opf": b'<book id="uuid-b"><title>Title</title></book>'})
        self.assertEqual(a["textParts"], b["textParts"])
        self.assertNotEqual(a["structure"], b["structure"])
        with self.assertRaises(ParseError): package(result("fixture", []), {"book.opf": b"<broken>"})

    def test_timeout_and_unavailable_readers_never_become_pass(self):
        a, b = self.root / "a.lit", self.root / "b.lit"
        old = {"kind": "binary", "sha256": "same"}
        with patch("compare.readback", side_effect=subprocess.TimeoutExpired(["reader"], 60)):
            status, _, metrics = compare_output(old, old, a, b, self.thresholds)
        self.assertEqual(status, "WARN")
        self.assertEqual(set(metrics["readback"]["errors"]), {"baseline", "candidate"})

    def test_selected_missing_case_fails_and_report_declares_the_subset(self):
        roots = [self.root / side for side in ("baseline", "candidate")]
        for root in roots:
            root.mkdir(); (root / "run.json").write_text('{"results": []}')
            (root / "cases.json").write_text('[]')
        output = self.root / "comparison"
        with self.assertRaisesRegex(RuntimeError, "exited 1"):
            bounded_command([sys.executable, "-I", "-B", Path(__file__).with_name("compare.py"), *roots,
                             "--out", output, "--case", "missing-case"])
        report = json.loads((output / "report.json").read_text())
        self.assertEqual(report["selectedCaseIDs"], ["missing-case"])
        self.assertEqual(report["summary"], {"FAIL": 1})



if __name__ == "__main__": unittest.main()
