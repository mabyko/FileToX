#!/usr/bin/env python3
"""Focused self-checks: python3 -I Tools/engine-compare/test_harness.py."""
import copy
import base64
import gzip
import hashlib
import json
import math
import tarfile
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hostwire import Host, ProtocolError, RPCError
from corpus import png, zip_write
from fingerprint import fingerprint, native
from compare import compare_case, compare_output
from run import generate_cases
from semantic import xml_text, document_text, generated_calibre_cover, rst_dimensions, tcr_payload, document_image_references

FAKE = '''#!{python} -I
import json, os, pathlib, sys
def send(value):
    print(json.dumps(dict(v=1, **value)), flush=True)
assert os.environ['TMPDIR'].endswith('/tmp/')
assert pathlib.Path(sys.argv[sys.argv.index('--data')+1]).name == 'core'
send(dict(event='hello', data=dict(protocol=1)))
for line in sys.stdin:
    r=json.loads(line); method=r['method']
    if method == 'noise':
        print('native non-JSON noise', flush=True)
    elif method == 'wrong-id':
        send(dict(id='unknown', result={{}}))
    elif method == 'oversize':
        print('x' * (4*1024*1024+1), flush=True)
    elif method == 'error':
        send(dict(id=r['id'], error=dict(code='invalid_input', message='test')))
    elif method == 'eof':
        break
    elif method == 'job.start':
        send(dict(id=r['id'], result=dict(jobId=r['id'])))
        send(dict(event='job.finished', data=dict(jobId=r['id'], state='completed', files=[])))
    else:
        send(dict(id=r['id'], result=r['params']))
    print('stderr drained', file=sys.stderr, flush=True)
'''


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.fake = self.root / "fake-host"
        self.fake.write_text(FAKE.format(python=sys.executable))
        self.fake.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def test_internal_inspector_starts_in_isolated_python(self):
        result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("fingerprint.py"))],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "Internal inspector: --woff2 PATH")

    def tcr(self, payload, entries=None):
        entries = entries or {}
        return b"!!8-Bit!!" + b"".join(bytes([len(entries.get(i, bytes([i])))]) + entries.get(i, bytes([i])) for i in range(256)) + payload

    def test_tcr_decodes_literal_dictionary_and_limits_expansion(self):
        self.assertEqual(tcr_payload(self.tcr(b"\0\1", {0: b"hello", 1: "한글".encode()})), b"hello" + "한글".encode())
        self.assertEqual(tcr_payload(self.tcr(b"\0", {0: b"\1", 1: b"recursive-would-be-wrong"})), b"\1")
        for data in (b"bad header", b"!!8-Bit!!", b"!!8-Bit!!\x05ab", self.tcr(b"")[:100]):
            with self.subTest(data=data[:20]), self.assertRaises(ValueError): tcr_payload(data)
        with self.assertRaises(ValueError): tcr_payload(self.tcr(b"\0\0", {0: b"abc"}), limit=5)
        with self.assertRaisesRegex(ValueError, "encoded input"):
            tcr_payload(b"!!8-Bit!!" + bytes(256) + bytes(65536), limit=0)

    def test_tcr_comparison_checks_decoded_bytes_in_older_binary_captures(self):
        a, b = self.root / "a.tcr", self.root / "b.tcr"
        a.write_bytes(self.tcr(b"AB")); b.write_bytes(self.tcr(b"\0", {0: b"AB"}))
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        old_a, old_b = {"kind": "binary", "sha256": "a"}, {"kind": "binary", "sha256": "b"}
        self.assertEqual(compare_output(old_a, old_b, a, b, thresholds)[0], "PASS")
        self.assertEqual(fingerprint(b)["metadata"]["decodedSize"], 2)
        b.write_bytes(self.tcr(b"ABFil"))
        self.assertEqual(compare_output(old_a, old_b, a, b, thresholds)[0], "FAIL")
        b.write_bytes(b"invalid")
        self.assertEqual(compare_output(old_b, old_b, b, b, thresholds)[0], "FAIL")
        self.assertEqual(compare_output(old_b, old_a, b, a, thresholds)[0], "WARN")

    def test_document_reference_audit_is_local_bounded_and_explicit_about_coverage(self):
        doc = self.root / "index.html"
        (self.root / "a b.png").write_bytes(b"not-decoded-by-reference-audit")
        html = '<img src="a%20b.png?v=1#part"><img src="missing.png"><img src="data:image/png;base64,AA=="><img src="https://example.invalid/a.png"><img src="../outside.png"><img src="http://[invalid">'
        rows = document_image_references(html, ".html", doc, self.root)["references"]
        self.assertEqual([r["state"] for r in rows], ["present", "missing", "embedded", "external-uninspected", "outside-run", "invalid-reference"])
        self.assertEqual(document_image_references('<base href="https://example.invalid/"><img src="a.png">', ".html", doc, self.root)["references"][0]["state"], "base-url-uninspected")
        self.assertEqual(document_image_references('![](<a%20b.png>)', ".md", doc, self.root)["references"][0]["state"], "present")
        self.assertEqual(document_image_references('```\n![](missing.png)\n```', ".md", doc, self.root)["coverage"], "unsupported-markdown")

    def test_missing_baseline_reference_diagnostic_does_not_waive_fail(self):
        left, right = self.root / "left", self.root / "right"
        left.mkdir(); right.mkdir()
        (left / "index.html").write_text('<img src="missing.jpg">')
        (right / "index.html").write_text('<img src="data:image/png;base64,AA==">')
        def record(folder):
            return {"id": "reference", "state": "completed", "engineHint": "test", "targetFormat": "html", "files": [],
                    "outputs": [{"name": "index.html", "artifact": "index.html", "fingerprint": fingerprint(folder / "index.html")}]}
        result = compare_case(record(left), record(right), left.resolve(), right.resolve(), {"psnr": 30, "ssim": .95, "text": .95})
        self.assertEqual(result["status"], "FAIL")
        refs = result["outputs"][0]["imageReferences"]
        self.assertEqual(refs["baseline"]["references"][0]["state"], "missing")
        self.assertEqual(refs["candidate"]["references"][0]["state"], "embedded")

    def test_malformed_html_reference_diagnostic_does_not_abort_identical_capture(self):
        folders = [self.root / "left", self.root / "right"]
        records = []
        for folder in folders:
            folder.mkdir()
            path = folder / "index.html"
            path.write_text('<![invalid]><img src="missing.png">')
            records.append({"id": "malformed", "state": "completed", "engineHint": "test", "targetFormat": "html", "files": [],
                            "outputs": [{"name": path.name, "artifact": path.name, "fingerprint": fingerprint(path)}]})
        result = compare_case(*records, *(p.resolve() for p in folders), {"psnr": 30, "ssim": .95, "text": .95})
        self.assertEqual(result["status"], "PASS")
        for exception in (AssertionError, NotImplementedError, ValueError):
            with self.subTest(exception=exception), patch("semantic.HTMLParser.feed", side_effect=exception("parser unavailable")):
                result = compare_case(*records, *(p.resolve() for p in folders), {"psnr": 30, "ssim": .95, "text": .95})
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(result["outputs"][0]["imageReferences"]["baseline"]["coverage"], "unavailable")

    def pdf(self, path, content, rotation=0, producer="test", width=20, height=20, origin=(0, 0)):
        stream = content.encode()
        x, y = origin
        objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
                   f"<< /Type /Page /Parent 2 0 R /MediaBox [{x} {y} {x+width} {y+height}] /Rotate {rotation} /Resources << >> /Contents 4 0 R >>".encode(),
                   f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream", f"<< /Producer ({producer}) >>".encode()]
        data = bytearray(b"%PDF-1.4\n"); offsets = [0]
        for i, obj in enumerate(objects, 1):
            offsets.append(len(data)); data.extend(f"{i} 0 obj\n".encode() + obj + b"\nendobj\n")
        xref = len(data); data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
        for offset in offsets[1:]: data.extend(f"{offset:010} 00000 n \n".encode())
        data.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R /Info 5 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
        path.write_bytes(data)

    def test_pdf_raster_fills_the_144_dpi_canvas(self):
        black, white = self.root / "black.pdf", self.root / "white.pdf"
        for rotation in (0, 90, 180, 270):
            for origin in ((0, 0), (7, -3)):
                with self.subTest(rotation=rotation, origin=origin):
                    x, y = origin
                    self.pdf(black, f"0 g {x} {y} 20 10 re f", rotation=rotation,
                             width=20, height=10, origin=origin)
                    self.pdf(white, "", rotation=rotation, width=20, height=10, origin=origin)
                    result = native("pdf-compare", black, white)
                    self.assertEqual((result["dpi"], result["rasterVersion"]), (144, 2))
                    # Every RGB byte must differ by 255; alpha remains 255 in both.
                    # A 72-DPI page centered in the canvas differs in only a quarter of it.
                    self.assertAlmostEqual(result["frames"][0]["psnr"], 10 * math.log10(4 / 3), places=6)

    def test_pdf_raster_detects_textless_layout_loss_and_preserves_rotation(self):
        a, b = self.root / "a.pdf", self.root / "b.pdf"
        self.pdf(a, "1 0 0 rg 0 0 10 20 re f")
        self.pdf(b, "0 0 1 rg 0 0 10 20 re f")
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        self.assertEqual(compare_output(fingerprint(a), fingerprint(b), a, b, thresholds)[0], "WARN")
        thresholds["pdfRender"] = True
        self.assertEqual(compare_output(fingerprint(a), fingerprint(b), a, b, thresholds)[0], "FAIL")
        self.pdf(b, "1 0 0 rg 10 0 10 20 re f", rotation=180, producer="other")
        score = native("pdf-compare", a, b)
        self.assertEqual(score["dpi"], 144)
        self.assertEqual(score["frames"][0]["psnr"], 99)
        self.assertEqual(compare_output(fingerprint(a), fingerprint(b), a, b, thresholds)[0], "WARN")
        self.pdf(b, "", width=999999999)
        with self.assertRaisesRegex(RuntimeError, "pixel limit"): native("pdf-compare", b, b)

    def test_pdf_raster_clips_content_to_its_own_media_box(self):
        a, b = self.root / "a.pdf", self.root / "b.pdf"
        for width, other_width in ((20, 21), (20.25, 20.25)):
            with self.subTest(width=width, other_width=other_width):
                self.pdf(a, f"0 g {width} 0 1 10 re f", width=width, height=10)
                self.pdf(b, "", width=other_width, height=10)
                score = native("pdf-compare", a, b)
                self.assertTrue(score["sameGeometry"])
                self.assertEqual(score["frames"][0], {"psnr": 99, "ssim": 1})

    def test_pdf_raster_comparison_accepts_equivalent_nonsquare_rotation(self):
        a, b = self.root / "a.pdf", self.root / "b.pdf"
        self.pdf(a, "1 0 0 rg 0 0 10 10 re f", width=20, height=10)
        self.pdf(b, "1 0 0 rg 0 0 10 10 re f", width=10, height=20, rotation=90)
        thresholds = {"psnr": 30, "ssim": .95, "text": .95, "pdfRender": True}
        status, reasons, metrics = compare_output(fingerprint(a), fingerprint(b), a, b, thresholds)
        self.assertEqual(status, "WARN", reasons)
        self.assertEqual(metrics["raster"]["frames"][0], {"psnr": 99, "ssim": 1})
        self.pdf(b, "", width=12, height=20, rotation=90)
        self.assertEqual(compare_output(fingerprint(a), fingerprint(b), a, b, thresholds)[0], "FAIL")

    def test_pdf_raster_timeout_is_an_unavailable_warning(self):
        pdf = {"kind": "pdf", "sha256": "a", "metadata": {"pageCount": 1, "pages": [{"width": 20, "height": 20, "text": ""}]}}
        other = copy.deepcopy(pdf); other["sha256"] = "b"
        with patch("compare.native", side_effect=subprocess.TimeoutExpired(["inspect"], 60)):
            status, reasons, _ = compare_output(pdf, other, self.root / "a.pdf", self.root / "b.pdf",
                                                {"psnr": 30, "ssim": .95, "text": .95, "pdfRender": True})
        self.assertEqual(status, "WARN")
        self.assertIn("PDF raster comparison unavailable", reasons[0])

    def test_report_limits_describe_selected_pdf_coverage(self):
        folders = [self.root / "left", self.root / "right"]
        for folder in folders:
            folder.mkdir(); (folder / "run.json").write_text('{"results": []}'); (folder / "cases.json").write_text('[]')
        for enabled in (False, True):
            output = self.root / str(enabled)
            args = [sys.executable, "-I", str(Path(__file__).with_name("compare.py")), *map(str, folders), "--out", str(output)]
            if enabled: args.append("--pdf-render")
            subprocess.run(args, check=True, capture_output=True)
            report = json.loads((output / "report.json").read_text())
            limits = report["limits"]
            self.assertEqual(report["inspectionPolicy"]["pdfRasterVersion"], 2 if enabled else None)
            self.assertEqual("144 DPI" in limits, enabled)
            self.assertEqual("geometry only" in limits, not enabled)

    def test_fast_finish_rpc_errors_and_clean_shutdown(self):
        log = self.root / "stderr.log"
        with Host(self.fake, stderr_path=log, timeout=2) as host:
            self.assertEqual(host.call("echo", paths=["한글 path"]), {"paths": ["한글 path"]})
            for _ in range(30):
                self.assertEqual(host.convert([], targetFormat="png")["state"], "completed")
            with self.assertRaises(RPCError): host.call("error")
            self.assertEqual(host.call("echo", answer=42), {"answer": 42})
        self.assertEqual(host.proc.returncode, 0)
        self.assertFalse(host.root.exists())
        self.assertIn("stderr drained", log.read_text())

    def test_protocol_noise_wrong_id_oversize_and_eof_are_failures(self):
        for method in ("noise", "wrong-id", "oversize", "eof"):
            host = Host(self.fake, timeout=2)
            try:
                with self.subTest(method=method), self.assertRaises(ProtocolError): host.call(method)
            finally:
                host.close(check=False)

    def test_archive_content_hashes_and_normalized_text(self):
        path = self.root / "data.zip"
        zip_write(path, {"한글 path.txt": "안녕하세요".encode(), "toc.ncx": b"<ncx/>"})
        metadata = fingerprint(path)["metadata"]
        self.assertEqual(metadata["entries"][1]["name"], "한글 path.txt")
        self.assertEqual(len(metadata["entries"][0]["sha256"]), 64)
        self.assertEqual(metadata["keyParts"]["toc.ncx"], "<ncx/>")
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        a = {"kind": "text", "sha256": "a", "text": "hello\r\n world"}
        b = {"kind": "text", "sha256": "b", "text": "hello world"}
        self.assertEqual(compare_output(a, b, None, None, thresholds)[0], "WARN")
        b["text"] = "different"
        self.assertEqual(compare_output(a, b, None, None, thresholds)[0], "FAIL")

    def test_image_dimensions_and_similarity(self):
        left, same, small = (self.root / name for name in ("a.png", "b.png", "c.png"))
        png(left); png(same); png(small, 32, 16)
        meta = fingerprint(left)
        self.assertNotIn("inspectionError", meta)
        self.assertEqual(meta["metadata"]["frameCount"], 1)
        self.assertEqual(native("compare", left, same)["frames"][0]["psnr"], 99)
        self.assertFalse(native("compare", left, small)["sameGeometry"])
        a = self.root / "dark.png"
        png(a, 96, 64, alpha=False)
        self.assertLess(native("compare", left, a)["frames"][0]["psnr"], 30)

    def test_capped_plan_covers_every_possible_target(self):
        samples = [{"id": "x.foo", "formatId": "foo"}]
        targets = [{"formatId": t, "available": True} for t in ("png", "txt", "pdf", "zip")]
        matrix = {"catalog": {"formats": [{"id": "foo", "category": "unknown"}], "engines": []},
                  "selections": {"foo": {"targets": targets, "presetOptions": []}}}
        template = {"id": "test", "targetFormat": "png", **{k: {} for k in ("image", "pdf", "document", "media", "archive", "output")}}
        library = {"presets": [template]}
        cases = generate_cases({"samples": samples}, matrix, library, cap=1)
        self.assertEqual({c["targetFormat"] for c in cases}, {"png", "txt", "pdf", "zip"})
        self.assertEqual(cases, generate_cases({"samples": samples}, matrix, library, cap=1))

    def test_state_error_and_names_are_strict(self):
        a = {"id": "test", "state": "failed", "engineHint": "test", "targetFormat": "png",
             "files": [{"source": "a.png", "state": "failed", "errorKey": "error.no_route", "outputs": []}], "outputs": []}
        b = copy.deepcopy(a)
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        self.assertEqual(compare_case(a, b, self.root, self.root, thresholds)["status"], "PASS")
        b["files"][0]["errorKey"] = "error.conversion_failed"
        self.assertEqual(compare_case(a, b, self.root, self.root, thresholds)["status"], "FAIL")

    def test_pdf_media_and_archive_thresholds(self):
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        def different(kind, metadata):
            a = {"kind": kind, "sha256": "left", "metadata": metadata}
            b = copy.deepcopy(a)
            b["sha256"] = "right"
            return a, b
        a, b = different("pdf", {"pageCount": 1, "pages": [{"width": 100, "height": 200, "text": "Korean 한글"}]})
        b["metadata"]["pages"][0]["width"] = 100.9
        self.assertEqual(compare_output(a, b, None, None, thresholds)[0], "WARN")
        b["metadata"]["pages"][0]["width"] = 101.1
        self.assertEqual(compare_output(a, b, None, None, thresholds)[0], "FAIL")
        a, b = different("media", {"duration": 10, "streams": [{"codec_type": "audio", "codec_name": "aac"}]})
        b["metadata"]["duration"] = 10.19
        self.assertEqual(compare_output(a, b, None, None, thresholds)[0], "WARN")
        b["metadata"]["duration"] = 10.21
        self.assertEqual(compare_output(a, b, None, None, thresholds)[0], "FAIL")
        a, b = different("archive", {"entries": [{"name": "a.txt", "sha256": "a"}]})
        b["metadata"]["entries"][0]["sha256"] = "b"
        self.assertEqual(compare_output(a, b, None, None, thresholds)[0], "FAIL")

    def test_pax_header_names_and_gzip_timestamps_do_not_hide_member_changes(self):
        def archive(pid, payload, name="a.txt"):
            record = b"19 comment=process\n"
            pax = tarfile.TarInfo(f"./PaxHeaders.{pid}/a.txt")
            pax.type = tarfile.XHDTYPE; pax.size = len(record)
            member = tarfile.TarInfo(name); member.size = len(payload)
            data = pax.tobuf() + record.ljust(512, b"\0") + member.tobuf() + payload.ljust(512, b"\0") + b"\0" * 1024
            path = self.root / f"{pid}.tgz"
            path.write_bytes(gzip.compress(data, mtime=pid))
            return path
        a, b = archive(1, b"hello"), archive(22, b"hello")
        def captured(path):
            return {"kind": "archive", "sha256": str(path), "metadata": {"entries": [{"name": "a.tar", "sha256": str(path)}]}}
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        self.assertEqual(compare_output(captured(a), captured(b), a, b, thresholds)[0], "PASS")
        for path in (archive(33, b"wrong"), archive(44, b"hello", "renamed.txt")):
            self.assertEqual(compare_output(captured(a), captured(path), a, path, thresholds)[0], "FAIL")

    def test_generated_xml_metadata_is_scoped_and_content_remains_strict(self):
        a = '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier>urn:uuid:11111111-1111-1111-1111-111111111111</dc:identifier><dc:title>Title</dc:title></package>'
        b = a.replace("11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222")
        self.assertEqual(xml_text(a), xml_text(b))
        self.assertNotEqual(xml_text(a), xml_text(b.replace("Title", "Lost")))
        user = '<body>11111111-1111-1111-1111-111111111111</body>'
        self.assertNotEqual(xml_text(user), xml_text(user.replace("1111", "2222")))
        core = '<core xmlns:d="http://purl.org/dc/terms/"><d:created>2026-01-01</d:created></core>'
        self.assertEqual(xml_text(core, "docProps/core.xml"), xml_text(core.replace("2026", "2027"), "docProps/core.xml"))
        self.assertNotEqual(xml_text(core, "body.xml"), xml_text(core.replace("2026", "2027"), "body.xml"))
        settings = '<c:config-item xmlns:c="urn:oasis:names:tc:opendocument:xmlns:config:1.0" c:name="RsidRoot">123</c:config-item>'
        self.assertEqual(xml_text(settings, "settings.xml"), xml_text(settings.replace("123", "456"), "settings.xml"))
        self.assertNotEqual(xml_text(settings.replace("RsidRoot", "ZoomValue"), "settings.xml"), xml_text(settings.replace("RsidRoot", "ZoomValue").replace("123", "456"), "settings.xml"))

    def test_rst_dimensions_tolerate_dpi_rounding_but_not_resizing(self):
        a = "image:: picture.jpg :width: 0.99986in :height: 0.66653in"
        b = "image:: picture.jpg :width: 1in :height: 0.66667in"
        left, right, deltas = rst_dimensions(a, b)
        self.assertEqual(left, right)
        self.assertLess(max(deltas), .011)
        self.assertIsNone(rst_dimensions(a, b.replace("1in", "2in"))[2])

    def test_indexed_tga_palette_uses_bgr_samples(self):
        indexed = bytearray(18)
        indexed[1] = 1; indexed[2] = 1; indexed[5] = 1; indexed[7] = 32
        indexed[12] = 1; indexed[14] = 1; indexed[16] = 8; indexed[17] = 32
        truecolor = bytearray(indexed)
        truecolor[1] = 0; truecolor[2] = 2; truecolor[5] = 0; truecolor[7] = 0; truecolor[16] = 32
        a, b = self.root / "indexed.tga", self.root / "truecolor.tga"
        a.write_bytes(indexed + bytes([200, 150, 100, 255, 0]))
        b.write_bytes(truecolor + bytes([200, 150, 100, 255]))
        scores = native("compare", a, b)
        self.assertTrue(scores["sameGeometry"])
        self.assertEqual(scores["frames"][0]["psnr"], 99)

    def test_tga_image_id_is_metadata_and_pixel_changes_are_detected(self):
        # The former Q8 matrix inspector treated the image ID comment as pixels.
        header = bytearray(18)
        header[12] = 3; header[14] = 1; header[16] = 24; header[17] = 32
        bgr = bytes([0, 0, 255, 0, 255, 0, 255, 0, 0])
        rgba = bytes([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255])
        expected = hashlib.sha256(rgba).hexdigest()
        paths = []
        for image_type in (2, 10):
            for length in (0, 34, 255):
                with self.subTest(image_type=image_type, image_id_bytes=length):
                    header[0] = length; header[2] = image_type
                    path = self.root / f"id-{image_type}-{length}.tga"
                    payload = bgr if image_type == 2 else bytes([2]) + bgr
                    path.write_bytes(header + b"X" * length + payload)
                    self.assertEqual(native("image", path)["frames"][0]["pixelSha256"], expected)
                    paths.append(path)
        scores = native("compare", paths[0], paths[-1])
        self.assertEqual(scores["frames"][0], {"psnr": 99, "ssim": 1})
        changed = self.root / "changed.tga"
        changed.write_bytes(paths[0].read_bytes()[:18] + bytes(9))
        self.assertLess(native("compare", paths[0], changed)["frames"][0]["psnr"], 30)

    def test_embedded_zip_images_use_pixels_and_reject_geometry_and_colour_loss(self):
        a, b, small, dark = [self.root / name for name in ("a.png", "b.png", "small.png", "dark.png")]
        png(a); png(b); png(small, 32, 16); png(dark, alpha=False)
        # An ancillary PNG chunk changes bytes without changing a pixel.
        import struct, zlib
        chunk = b"tEXt" + b"comment\0different encoder"
        payload = struct.pack(">I", len(chunk) - 4) + chunk + struct.pack(">I", zlib.crc32(chunk))
        b.write_bytes(b.read_bytes()[:-12] + payload + b.read_bytes()[-12:])
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        left = self.root / "a.docx"; zip_write(left, {"word/media/image.png": a.read_bytes()})
        for source, status in ((b, "WARN"), (small, "FAIL"), (dark, "FAIL")):
            right = self.root / "b.docx"; zip_write(right, {"word/media/image.png": source.read_bytes()})
            result = compare_output(fingerprint(left), fingerprint(right), left, right, thresholds)
            self.assertEqual(result[0], status, result)

    def test_inline_html_fb2_and_rtf_keep_picture_payloads_for_comparison(self):
        payload = b"picture samples"; data = base64.b64encode(payload).decode()
        html, pictures = document_text(f'<p>Keep me</p><img src="data:image/png;base64,{data}">', ".html")
        self.assertIn("Keep me", html); self.assertEqual(pictures, [("image/png", payload)])
        fb2 = '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><p>Keep me</p></body><binary id="img1" content-type="image/png">' + data + '</binary></FictionBook>'
        text, pictures = document_text(fb2, ".fb2")
        self.assertIn("Keep me", text); self.assertEqual(pictures, [("image/png", payload)])
        text, pictures = document_text(r'{\rtf1 Keep me {\pict\pngblip\picw10\pich10 ' + payload.hex() + '}}', ".rtf")
        self.assertIn("Keep me", text); self.assertEqual(pictures, [("image/png", payload)])

    def test_calibre_cover_marker_is_not_enough_to_accept_different_pixels(self):
        comment = b"Generated cover: calibre 9.15.0"
        cover = b"\xff\xd8\xff\xfe" + (len(comment) + 2).to_bytes(2, "big") + comment + b"\xff\xda"
        self.assertTrue(generated_calibre_cover(cover))
        self.assertFalse(generated_calibre_cover(b"ordinary file " + comment))
        from compare import picture_below_threshold
        scores = {"frames": [{"psnr": 10, "ssim": .1}]}
        thresholds = {"psnr": 30, "ssim": .95}
        self.assertTrue(picture_below_threshold(scores, thresholds))
        scores["generatedCoverTextMatches"] = True
        self.assertFalse(picture_below_threshold(scores, thresholds))

    def test_media_container_volatility_requires_identical_packets_and_timing(self):
        a = {"kind": "media", "sha256": "a", "metadata": {"duration": 1, "streams": [{"codec_name": "opus"}]}}
        b = copy.deepcopy(a); b["sha256"] = "b"
        thresholds = {"psnr": 30, "ssim": .95, "text": .95}
        with patch("compare.media_packets", return_value={"packets": [{"data_hash": "same", "pts": 0}]}):
            self.assertEqual(compare_output(a, b, self.root / "a.ogg", self.root / "b.ogg", thresholds)[0], "PASS")
        with patch("compare.media_packets", side_effect=[{"packets": ["a"]}, {"packets": ["b"]}]):
            self.assertEqual(compare_output(a, b, self.root / "a.ogg", self.root / "b.ogg", thresholds)[0], "WARN")
        from compare import media_packets
        probe = {"packets": [{"data_hash": "same", "pts": 0}], "streams": [{"tags": {"file_package_umid": "random", "title": "Keep me"}}]}
        with patch("compare.command", return_value=json.dumps(probe).encode()):
            value = media_packets(self.root / "a.mxf")
        self.assertEqual(value["streams"][0]["tags"], {"title": "Keep me"})
        self.assertEqual(value["packets"], probe["packets"])


if __name__ == "__main__":
    unittest.main()
