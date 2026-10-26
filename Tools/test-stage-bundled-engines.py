#!/usr/bin/env python3
"""Verify arm64 staging with cached upstream binaries; never alter the source copies."""
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(args, **kwargs):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.STDOUT, **kwargs)


def text_bytes(path):
    return b"\n".join(run(['/usr/bin/otool', '-arch', 'arm64', '-s', '__TEXT', '__text', path]).splitlines()[2:])


manifest = json.loads((ROOT / 'Sources/Engine/Resources/engines.json').read_text())
for name in ('rhwp', '7zip'):
    component = manifest['platforms']['osx-arm64']['components'][name]
    archive = ROOT / 'build/downloads' / (component['sha256'] + '.' + component['kind'])
    assert archive.is_file(), 'Fetch the pinned bundled engines before this test'

sources = {
    'MacOS/engines/rhwp/rhwp': ROOT / 'build/engines/osx-arm64/rhwp/rhwp',
    'MacOS/engines/7zip/7zz': ROOT / 'build/engines/osx-arm64/7zip/7zz',
    'Frameworks/libpdfium.dylib': ROOT / 'Vendor/PDFium/lib/libpdfium.dylib',
}
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources.values()}
licenses = sorted((ROOT / 'Vendor/LibAVIF/LICENSES').iterdir())
with tempfile.TemporaryDirectory(prefix='ftx-stage-arm64-') as folder:
    target = Path(folder)
    (target / 'Helper.app/Contents/Frameworks').mkdir(parents=True)
    # The AVIF encoder as the FileToXAvifEncoder tool target builds it into the products folder.
    products = target / 'Products'
    products.mkdir()
    run(['/usr/bin/xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=15.0', '-O2', '-I', ROOT / 'Vendor/LibAVIF/headers',
         ROOT / 'Vendor/LibAVIF/FileToX/avifenc.c', ROOT / 'Vendor/LibAVIF/lib/libavif.a', '-o', products / 'FileToXAvifEncoder'])
    sources['MacOS/FileToXAvifEncoder'] = products / 'FileToXAvifEncoder'
    env = dict(os.environ, ARCHS='arm64', TARGET_BUILD_DIR=folder, BUILT_PRODUCTS_DIR=str(products),
               EXECUTABLE_FOLDER_PATH='Helper.app/Contents/MacOS',
               FRAMEWORKS_FOLDER_PATH='Helper.app/Contents/Frameworks',
               UNLOCALIZED_RESOURCES_FOLDER_PATH='Helper.app/Contents/Resources',
               EXPANDED_CODE_SIGN_IDENTITY='-')
    run(['/bin/bash', ROOT / 'Tools/stage-bundled-engines.sh'], env=env)
    for relative, source in sources.items():
        staged = target / 'Helper.app/Contents' / relative
        assert run(['/usr/bin/lipo', '-archs', staged]).strip() == b'arm64', staged
        assert text_bytes(staged) == text_bytes(source), (relative, 'ARM instructions changed')
        assert staged.stat().st_mode & 0o777 == source.stat().st_mode & 0o777, staged
        run(['/usr/bin/codesign', '--verify', '--strict', staged])
    encoder = target / 'Helper.app/Contents/MacOS/FileToXAvifEncoder'
    # CS_RUNTIME (0x10000), also with an ad hoc signature (0x10002).
    assert int(re.search(rb'flags=0x([0-9a-f]+)', run(['/usr/bin/codesign', '-dv', encoder])).group(1), 16) & 0x10000, 'hardened runtime'
    assert [line.split()[0] for line in run(['/usr/bin/otool', '-L', encoder]).splitlines()[1:]] == [b'/usr/lib/libSystem.B.dylib'], 'only libSystem'
    # The staged encoder runs: a 2 x 1 RGB hand-off becomes an AVIF file.
    handoff = target / 'picture'
    handoff.write_bytes(b'FTXAVIF\0' + struct.pack('<IIIIII', 1, 2, 1, 3, 60, 0) + struct.pack('<QQQQ', 0, 0, 0, 0) + bytes([255, 0, 0, 0, 0, 255]))
    run([encoder, handoff, target / 'picture.avif'])
    assert (target / 'picture.avif').read_bytes()[4:12] == b'ftypavif'
    notices = target / 'Helper.app/Contents/Resources/Notices/LibAVIF'
    assert [p.name for p in sorted(notices.iterdir())] == [p.name for p in licenses]
    assert all((notices / p.name).read_bytes() == p.read_bytes() for p in licenses)
    del sources['MacOS/FileToXAvifEncoder']
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest for p, digest in before.items())
for script in ('fetch-bundled-engines.py', 'fetch-optional-engines.py'):
    result = subprocess.run([sys.executable, str(ROOT / 'Tools' / script), '--rid', 'osx-x64', '--selftest'], capture_output=True)
    assert result.returncode == 2 and b'invalid choice' in result.stderr, (script, result.stderr)
print('PASS: four arm64-only signed binaries (the AVIF encoder with the hardened runtime, running, with its LibAVIF notices); '
      'original ARM instructions and source files preserved; x64 downloads rejected.')
