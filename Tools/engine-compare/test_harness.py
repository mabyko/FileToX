#!/usr/bin/env python3
"""Focused self-checks: python3 -I Tools/engine-compare/test_harness.py."""
import copy
import base64
import gzip
import json
import tarfile
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hostwire import Host, ProtocolError, RPCError
from corpus import png, zip_write
from fingerprint import fingerprint, native
from compare import compare_case, compare_output
from run import generate_cases
from semantic import xml_text, document_text, generated_calibre_cover, rst_dimensions

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
