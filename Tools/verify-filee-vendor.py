#!/usr/bin/env python3
"""Check the pinned Filee source snapshot in Vendor/ against its SHA-256 manifest."""
import hashlib
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINNED_COMMIT = "21fdd05ef7181b032ed83ec895cc9bbc4b198985"


def verify(root):
    manifest = json.loads((root / "filee-manifest.json").read_text())
    if manifest["commit"] != PINNED_COMMIT:
        raise ValueError("Unexpected upstream commit")
    snapshot = root / "Filee"
    files = {path.relative_to(snapshot).as_posix() for path in snapshot.rglob("*") if path.is_file()}
    if files != set(manifest["files"]):
        raise ValueError("Imported source file list changed")
    for name, expected in manifest["files"].items():
        file = snapshot / name
        if file.is_symlink() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError("Imported source changed: " + name)
    return len(files)


def selftest():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / "Filee" / "sample.cs"
        source.parent.mkdir()
        source.write_bytes(b"original")
        manifest = {"commit": PINNED_COMMIT, "files": {"sample.cs": hashlib.sha256(b"original").hexdigest()}}
        (root / "filee-manifest.json").write_text(json.dumps(manifest))
        assert verify(root) == 1
        source.write_bytes(b"changed")
        try:
            verify(root)
        except ValueError:
            pass
        else:
            raise AssertionError("Changed source accepted")
        source.write_bytes(b"original")
        (source.parent / "unexpected.cs").write_bytes(b"extra")
        try:
            verify(root)
        except ValueError:
            pass
        else:
            raise AssertionError("Extra source accepted")
    print("vendor selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    elif sys.argv[1:]:
        sys.exit("Usage: verify-filee-vendor.py [--selftest]")
    else:
        print("Verified", verify(ROOT / "Vendor"), "pinned Filee source files")
