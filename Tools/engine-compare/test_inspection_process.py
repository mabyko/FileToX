#!/usr/bin/env python3
"""Focused resource/cancellation checks for the shared native inspection supervisor."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from inspection_process import bounded_command


class InspectionProcessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self): self.tmp.cleanup()

    def test_child_has_private_home_and_no_inherited_variables(self):
        code = "import os,pathlib; assert 'FILETOX_TEST_SENTINEL' not in os.environ; assert pathlib.Path(os.environ['HOME']).name=='home'; print('isolated')"
        with patch.dict(os.environ, {"FILETOX_TEST_SENTINEL": "nonsecret-test"}):
            self.assertEqual(bounded_command([sys.executable, "-I", "-c", code]).strip(), b"isolated")

    def test_stdout_and_stderr_have_a_shared_output_bound(self):
        for fd in (1, 2):
            with self.subTest(fd=fd), self.assertRaisesRegex(RuntimeError, "output exceeds"):
                bounded_command([sys.executable, "-I", "-c", f"import os; os.write({fd},b'x'*20000)"], output_limit=1000)

    def test_timeout_kills_descendants_that_retain_pipes(self):
        marker = self.root / "orphan"
        child = f"import time,pathlib; time.sleep(.6); pathlib.Path({str(marker)!r}).write_text('orphan')"
        code = f"import subprocess,sys; subprocess.Popen([sys.executable,'-I','-c',{child!r}])"
        with self.assertRaises(subprocess.TimeoutExpired): bounded_command([sys.executable, "-I", "-c", code], timeout=.2)
        time.sleep(.65)
        self.assertFalse(marker.exists())

    def test_sigterm_cancels_reader_process_group(self):
        marker, ready = self.root / "orphan", self.root / "ready"
        child = f"import time,pathlib; pathlib.Path({str(ready)!r}).touch(); time.sleep(1); pathlib.Path({str(marker)!r}).touch()"
        runner = self.root / "runner.py"
        runner.write_text(f"import sys; sys.path.insert(0,{str(Path(__file__).parent)!r}); from inspection_process import bounded_command; bounded_command([sys.executable,'-I','-c',{child!r}])")
        proc = subprocess.Popen([sys.executable, "-I", str(runner)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue(ready.exists())
            proc.send_signal(signal.SIGTERM); proc.wait(timeout=3)
            time.sleep(1.1)
            self.assertFalse(marker.exists())
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()

    def test_extracted_files_are_bounded_and_symlinks_rejected(self):
        folder = self.root / "extract"; folder.mkdir()
        for operation in (f"(p/'data').write_bytes(b'x'*2000)", "(p/'escape').symlink_to('/tmp')"):
            code = f"import time; from pathlib import Path; p=Path({str(folder)!r}); {operation}; time.sleep(2)"
            with self.assertRaisesRegex(RuntimeError, "limit|symlink"):
                bounded_command([sys.executable, "-I", "-c", code], cwd=folder, watch=folder, output_limit=1000)
            for path in folder.iterdir(): path.unlink()


if __name__ == "__main__": unittest.main()
