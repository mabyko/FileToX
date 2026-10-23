#!/usr/bin/env python3
"""Focused self-checks: python3 -I Tools/engine-compare/test_harness.py."""
import copy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hostwire import Host, ProtocolError, RPCError
from corpus import png, zip_write
from fingerprint import fingerprint, native
from compare import compare_case, compare_output
from run import generate_cases

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


if __name__ == "__main__":
    unittest.main()
