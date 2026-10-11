#!/usr/bin/env python3
"""Fetch rhwp and 7zz from the pinned upstream manifest, into build/ only."""
import argparse
import hashlib
import io
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def unpack(archive, destination):
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        for entry in members:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.name or ":" in entry.name:
                raise ValueError("Unsafe archive path: " + entry.name)
            if not (entry.isdir() or entry.isfile()):
                raise ValueError("Links and special files are not accepted: " + entry.name)
        for entry in members:
            path = destination.joinpath(*PurePosixPath(entry.name).parts)
            if entry.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(entry) as source, path.open("wb") as output:
                    shutil.copyfileobj(source, output)
                path.chmod(entry.mode & 0o777)


def verified_archive(component):
    expected = component["sha256"].lower()
    if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise ValueError("Invalid pinned engine hash")
    cache = ROOT / "build/downloads"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (expected + "." + component["kind"])
    if not archive.exists():
        print("Downloading", component["url"], flush=True)
        with tempfile.TemporaryDirectory(dir=cache) as folder:
            partial = Path(folder) / "download"
            request = urllib.request.Request(component["url"], headers={"User-Agent": "FileToX-build"})
            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(partial) != expected:
                raise ValueError("Downloaded engine archive hash mismatch")
            partial.replace(archive)
    if digest(archive) != expected:
        raise ValueError("Cached engine archive hash mismatch")
    return archive


def fetch(rid):
    subprocess.run([sys.executable, str(ROOT / "Tools/verify-filee-vendor.py")], check=True)
    manifest = json.loads((ROOT / "Vendor/Filee/src/Filee.Engines/Infrastructure/engines.json").read_text())
    components = manifest["platforms"][rid]["components"]
    destination = ROOT / "build/engines" / rid
    destination.mkdir(parents=True, exist_ok=True)
    for name, program in [("rhwp", "rhwp"), ("7zip", "7zz")]:
        component = components[name]
        expected = component["sha256"].lower()
        archive = verified_archive(component)
        target = destination / name
        marker = target / ".filee-component"
        if marker.exists() and marker.read_text().strip() == expected and (target / program).is_file():
            continue
        with tempfile.TemporaryDirectory(dir=destination) as folder:
            extracted = Path(folder) / "payload"
            extracted.mkdir()
            unpack(archive, extracted)
            children = list(extracted.iterdir())
            payload = children[0] if len(children) == 1 and children[0].is_dir() else extracted
            executable = payload / program
            if not executable.is_file():
                raise ValueError("Expected executable missing: " + program)
            executable.chmod(executable.stat().st_mode | 0o111)
            (payload / ".filee-component").write_text(expected + "\n")
            if target.exists():
                shutil.rmtree(target)
            shutil.move(str(payload), target)
        print("Verified", name, component["version"], flush=True)
    return destination


def selftest():
    with tempfile.TemporaryDirectory() as folder:
        stage = Path(folder)
        for name, kind, valid in [("bin/tool", tarfile.REGTYPE, True), ("../escape", tarfile.REGTYPE, False),
                                  ("/escape", tarfile.REGTYPE, False), ("tool", tarfile.SYMTYPE, False)]:
            archive = stage / "sample.tar"
            with tarfile.open(archive, "w") as bundle:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.size = 2 if kind == tarfile.REGTYPE else 0
                entry.linkname = "elsewhere"
                bundle.addfile(entry, io.BytesIO(b"ok"))
            output = stage / "output"
            output.mkdir(exist_ok=True)
            try:
                unpack(archive, output)
            except ValueError:
                assert not valid, "Safe member rejected"
            else:
                assert valid, "Unsafe member accepted"
        assert not (stage / "escape").exists()
        assert digest(stage / "output/bin/tool") == hashlib.sha256(b"ok").hexdigest()
    print("engine archive selftest ok")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rid", choices=["osx-arm64", "osx-x64"], default="osx-arm64")
    parser.add_argument("--selftest", action="store_true")
    options = parser.parse_args()
    if options.selftest:
        selftest()
    else:
        print(fetch(options.rid))
