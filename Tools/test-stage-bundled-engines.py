#!/usr/bin/env python3
"""Verify arm64 staging with cached upstream binaries; never alter the source copies."""
import hashlib
import json
import os
from pathlib import Path
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
with tempfile.TemporaryDirectory(prefix='ftx-stage-arm64-') as folder:
    target = Path(folder)
    (target / 'Helper.app/Contents/Frameworks').mkdir(parents=True)
    env = dict(os.environ, ARCHS='arm64', TARGET_BUILD_DIR=folder,
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
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest for p, digest in before.items())
for script in ('fetch-bundled-engines.py', 'fetch-optional-engines.py'):
    result = subprocess.run([sys.executable, str(ROOT / 'Tools' / script), '--rid', 'osx-x64', '--selftest'], capture_output=True)
    assert result.returncode == 2 and b'invalid choice' in result.stderr, (script, result.stderr)
print('PASS: three arm64-only signed binaries; original ARM instructions and source files preserved; x64 downloads rejected.')
