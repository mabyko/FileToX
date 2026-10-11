#!/usr/bin/env python3
"""Fetch pinned optional engines into build/, without installing apps or settings."""
import argparse
import importlib
import json
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import zipfile
from pathlib import Path, PurePosixPath

bundled = importlib.import_module("fetch-bundled-engines")
ROOT = Path(__file__).resolve().parent.parent


def unpack_zip(archive, destination):
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            path = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename or ":" in entry.filename:
                raise ValueError("Unsafe ZIP path: " + entry.filename)
            output = destination.joinpath(*path.parts)
            if stat.S_ISLNK(mode):
                continue
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(entry) as source, output.open("wb") as target:
                    shutil.copyfileobj(source, target)
                if mode & 0o777:
                    output.chmod(mode & 0o777)
        for entry in bundle.infolist():
            if not stat.S_ISLNK(entry.external_attr >> 16):
                continue
            output = destination.joinpath(*PurePosixPath(entry.filename).parts)
            target = bundle.read(entry).decode("utf-8")
            resolved = (output.parent / target).resolve()
            if Path(target).is_absolute() or not resolved.is_relative_to(destination.resolve()) or not resolved.is_file() or resolved.is_symlink():
                raise ValueError("ZIP alias must point to a file inside the payload: " + entry.filename)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.symlink_to(target)


def unpack_dmg(archive, destination, name):
    with tempfile.TemporaryDirectory(dir=destination.parent) as folder:
        mount = Path(folder) / "mount"
        mount.mkdir()
        attached = False
        try:
            subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(archive)], check=True)
            attached = True
            application = mount / {"libreoffice": "LibreOffice.app", "calibre": "calibre.app"}[name]
            if not application.is_dir() or application.is_symlink():
                raise ValueError("Expected application missing from engine DMG")
            subprocess.run(["/usr/bin/ditto", str(application), str(destination / application.name)], check=True)
        finally:
            if attached:
                subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True)


def program(root, name):
    candidates = {"pandoc": [root / "pandoc", root / "bin/pandoc"],
                  "libreoffice": [root / "LibreOffice.app/Contents/MacOS/soffice"],
                  "calibre": [root / "calibre.app/Contents/MacOS/ebook-convert"]}[name]
    return next((path for path in candidates if path.is_file()), None)


def verified_optional_archive(name, component):
    try:
        return bundled.verified_archive(component)
    except urllib.error.HTTPError as error:
        version = component["version"]
        original = f"https://github.com/kovidgoyal/calibre/releases/download/v{version}/calibre-{version}.dmg"
        if error.code != 404 or name != "calibre" or component["url"] != original or not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise
        # The same upstream version and hash, hosted on calibre's official mirror.
        mirror = dict(component, url=f"https://download.calibre-ebook.com/{version}/calibre-{version}.dmg")
        print("Pinned URL returned 404; using the official calibre mirror with the unchanged SHA-256", flush=True)
        return bundled.verified_archive(mirror)


def fetch(name, rid):
    subprocess.run([sys.executable, str(ROOT / "Tools/verify-filee-vendor.py")], check=True)
    manifest = json.loads((ROOT / "Vendor/Filee/src/Filee.Engines/Infrastructure/engines.json").read_text())
    component = manifest["platforms"][rid]["components"][name]
    archive = verified_optional_archive(name, component)
    target = ROOT / "build/optional-engines" / rid / name
    target.parent.mkdir(parents=True, exist_ok=True)
    marker = target / ".filee-component"
    if marker.exists() and marker.read_text().strip().lower() == component["sha256"].lower() and program(target, name):
        return program(target, name)
    with tempfile.TemporaryDirectory(dir=target.parent) as folder:
        payload = Path(folder) / "payload"
        payload.mkdir()
        if component["kind"] == "zip":
            unpack_zip(archive, payload)
            children = list(payload.iterdir())
            if len(children) == 1 and children[0].is_dir():
                payload = children[0]
        elif component["kind"] == "dmg":
            unpack_dmg(archive, payload, name)
        else:
            raise ValueError("Unsupported optional engine archive")
        executable = program(payload, name)
        if executable is None:
            raise ValueError("Expected engine program missing: " + name)
        executable.chmod(executable.stat().st_mode | 0o111)
        (payload / ".filee-component").write_text(component["sha256"] + "\n")
        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(payload), target)
    return program(target, name)


def selftest():
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        for name, alias, valid in [("bin/pandoc", None, True), ("../escape", None, False),
                                  ("/escape", None, False), ("alias", "bin/pandoc", True), ("escape-link", "../escape", False)]:
            archive = root / "sample.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                entry = zipfile.ZipInfo(name)
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16 if alias else (stat.S_IFREG | 0o755) << 16
                bundle.writestr(entry, alias.encode() if alias else b"ok")
            output = root / "output"
            output.mkdir(exist_ok=True)
            try:
                unpack_zip(archive, output)
            except ValueError:
                assert not valid, "Safe ZIP entry rejected"
            else:
                assert valid, "Unsafe ZIP entry accepted"
        assert not (root / "escape").exists()
        assert program(root / "output", "pandoc") == root / "output/bin/pandoc"
        assert (root / "output/alias").resolve() == (root / "output/bin/pandoc").resolve()
    print("optional engine ZIP selftest ok")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", nargs="?", choices=["pandoc", "libreoffice", "calibre"])
    parser.add_argument("--rid", choices=["osx-arm64", "osx-x64"], default="osx-arm64")
    parser.add_argument("--selftest", action="store_true")
    options = parser.parse_args()
    if options.selftest:
        selftest()
    elif options.engine:
        print(fetch(options.engine, options.rid))
    else:
        parser.error("Select an engine or --selftest")
