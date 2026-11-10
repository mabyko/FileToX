#!/usr/bin/env python3
"""Rebuild the pinned, symbol-isolated arm64 static SVG bridge. No global installation."""
import argparse, hashlib, json, os, pathlib, subprocess, tarfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cache', type=pathlib.Path, default=ROOT.parents[1] / 'build' / 'skia-svg')
args = parser.parse_args()
cache = args.cache.resolve()
cache.mkdir(parents=True, exist_ok=True)
provenance = json.loads((ROOT / 'PROVENANCE.json').read_text())
for name, digest in provenance['headers'].items():
    if hashlib.sha256((ROOT / 'headers' / name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Header checksum mismatch: ' + name)
arch = 'arm64'
upstream_arch = 'aarch64'
digest = provenance['archives'][upstream_arch]
def run(*cmd):
    try:
        return subprocess.check_output([str(x) for x in cmd], stderr=subprocess.STDOUT, env={**os.environ, 'ZERO_AR_DATE': '1'}).decode()
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.output.decode(errors='replace')) from error
exports = cache / 'exports.txt'
exports.write_text('_ftx_svg_render\n')
name = f'skia-binaries-b7f043e0b1e2a850e702-{upstream_arch}-apple-darwin-jpegd-jpege-pdf-svg-textlayout-webpd-webpe.tar.gz'
archive = cache / name
if not archive.exists():
    with urllib.request.urlopen('https://github.com/rust-skia/skia-binaries/releases/download/0.153.3/' + name, timeout=60) as response:
        archive.write_bytes(response.read())
if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
    raise SystemExit('Checksum mismatch: ' + str(archive))
folder = cache / arch
folder.mkdir(exist_ok=True)
with tarfile.open(archive) as source:
    # Only the required static archives; never execute extracted upstream files.
    for entry in source.getmembers():
        if pathlib.PurePosixPath(entry.name).name in ['libsvg.a', 'libskshaper.a', 'libskresources.a', 'libskia.a', 'libskunicode_icu.a', 'libskunicode_core.a'] and entry.isfile():
            (folder / pathlib.PurePosixPath(entry.name).name).write_bytes(source.extractfile(entry).read())
flags = ['-arch', arch, '-mmacosx-version-min=15.0', '-std=c++20', '-O2', '-DNDEBUG', '-DSK_BUILD_FOR_MAC']
run('clang++', *flags, '-I', ROOT / 'headers', '-c', ROOT / 'FileToX/bridge.cpp', '-o', folder / 'bridge.o')
run('clang++', '-arch', arch, '-mmacosx-version-min=15.0', '-nostdlib', '-r', folder / 'bridge.o',
    *[folder / n for n in ['libsvg.a', 'libskshaper.a', 'libskresources.a', 'libskia.a', 'libskunicode_icu.a', 'libskunicode_core.a']], '-o', folder / 'merged.o')
# Localize every C++/codec/parser symbol, preventing link-order coupling to the engine's other codecs.
run('nmedit', '-s', exports, folder / 'merged.o', '-o', folder / 'localized.o')
symbols = run('nm', '-gU', folder / 'localized.o').splitlines()
if len(symbols) != 1 or not symbols[0].endswith(' T _ftx_svg_render'):
    raise SystemExit('Unexpected native exports: ' + str(symbols))
output = folder / 'libFileToXSvg.a'
run('libtool', '-static', '-o', output, folder / 'localized.o')
if arch not in run('lipo', '-info', output):
    raise SystemExit('Wrong architecture: ' + arch)
output = ROOT / 'lib/libFileToXSvg.a'
output.write_bytes((folder / 'libFileToXSvg.a').read_bytes())
assert run('lipo', '-archs', output).split() == ['arm64']
check = cache / ('selfcheck-' + arch)
run('clang', '-arch', arch, '-mmacosx-version-min=15.0', '-I', ROOT / 'FileToX/include',
    ROOT / 'FileToX/selfcheck.c', output, '-lc++', '-framework', 'Foundation',
    '-framework', 'CoreGraphics', '-framework', 'CoreText', '-o', check)
run(check)
print(str(output), hashlib.sha256(output.read_bytes()).hexdigest())
