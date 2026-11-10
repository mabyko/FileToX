#!/usr/bin/env python3
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


class EngineEntitlementsTests(unittest.TestCase):
    def test_only_ad_hoc_signing_disables_library_validation(self):
        script = pathlib.Path(__file__).with_name("prepare-engine-entitlements.py")
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "derived" / "EngineHost.entitlements"
            for identity, expected in [("-", {"com.apple.security.cs.disable-library-validation": True}),
                                       ("certificate-hash", {}), ("-", {"com.apple.security.cs.disable-library-validation": True})]:
                subprocess.run([sys.executable, "-I", str(script), str(output), identity], check=True)
                self.assertEqual(plistlib.loads(output.read_bytes()), expected)
                modified = output.stat().st_mtime_ns
                subprocess.run([sys.executable, "-I", str(script), str(output), identity], check=True)
                self.assertEqual(output.stat().st_mtime_ns, modified)


if __name__ == "__main__":
    unittest.main()
