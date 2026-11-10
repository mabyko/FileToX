#!/usr/bin/env python3
"""Verify arm64 staging with cached upstream binaries; never alter the source copies."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
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
ffmpeg_bundle = Path(os.environ.get('FILETOX_FFMPEG_BUNDLE', ROOT / 'build/ffmpeg/ffmpeg')).resolve(strict=True)
for name in ('ffmpeg', 'ffprobe'):
    sources['MacOS/engines/ffmpeg/bin/' + name] = ffmpeg_bundle / 'bin' / name
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
               EXPANDED_CODE_SIGN_IDENTITY='-', FILETOX_FFMPEG_BUNDLE=str(ffmpeg_bundle))
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
    ffmpeg_notices = target / 'Helper.app/Contents/Resources/Notices/ffmpeg'
    for source in sorted(ffmpeg_bundle.rglob('*')):
        if source.is_file() and source.parent.name != 'bin' and source.name != 'PROVENANCE.json':
            assert (ffmpeg_notices / source.relative_to(ffmpeg_bundle)).read_bytes() == source.read_bytes(), source
    assert not (ffmpeg_notices / 'PROVENANCE.json').exists(), 'local build paths must not ship'
    assert sorted(p.relative_to(target / 'Helper.app/Contents/MacOS/engines/ffmpeg').as_posix()
                  for p in (target / 'Helper.app/Contents/MacOS/engines/ffmpeg').rglob('*') if p.is_file()) == ['bin/ffmpeg', 'bin/ffprobe']
    spec = importlib.util.spec_from_file_location('ffmpeg_recipe', ROOT / 'Tools/build-ffmpeg.py')
    recipe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recipe)
    ffmpeg = target / 'Helper.app/Contents/MacOS/engines/ffmpeg/bin/ffmpeg'
    for option, expected, codec in [('-encoders', recipe.ENCODERS, True), ('-muxers', recipe.MUXERS, False), ('-decoders', recipe.DECODERS, True)]:
        assert expected <= recipe.listed(run([ffmpeg, '-hide_banner', option]).decode(), codec), option
    damaged = target / 'bad-ffmpeg'
    shutil.copytree(ffmpeg_bundle, damaged)
    (damaged / 'bin/ffprobe').write_bytes(b'incomplete copy')
    rejected = subprocess.run(['/bin/bash', str(ROOT / 'Tools/stage-bundled-engines.sh')],
                              env=dict(env, FILETOX_FFMPEG_BUNDLE=str(damaged)), capture_output=True)
    assert rejected.returncode != 0 and b'SHA-256 mismatch' in rejected.stderr
    assert recipe.ENCODERS <= recipe.listed(run([ffmpeg, '-hide_banner', '-encoders']).decode(), True), 'existing staging was changed'
    (damaged / 'bin/ffprobe').write_bytes((ffmpeg_bundle / 'bin/ffprobe').read_bytes())
    shutil.copy2(ffmpeg_bundle / 'bin/ffmpeg', damaged / 'bin/ffplay')
    rejected = subprocess.run(['/bin/bash', str(ROOT / 'Tools/stage-bundled-engines.sh')],
                              env=dict(env, FILETOX_FFMPEG_BUNDLE=str(damaged)), capture_output=True)
    assert rejected.returncode != 0 and b'Unexpected FFmpeg executables' in rejected.stderr
    assert recipe.ENCODERS <= recipe.listed(run([ffmpeg, '-hide_banner', '-encoders']).decode(), True), 'existing staging was changed'
    del sources['MacOS/FileToXAvifEncoder']
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest for p, digest in before.items())
for script in ('fetch-bundled-engines.py', 'fetch-optional-engines.py'):
    result = subprocess.run([sys.executable, str(ROOT / 'Tools' / script), '--rid', 'osx-x64', '--selftest'], capture_output=True)
    assert result.returncode == 2 and b'invalid choice' in result.stderr, (script, result.stderr)
print('PASS: six arm64-only signed binaries; AVIF and FFmpeg run with their notices; FFmpeg codecs and AV1 decoding present; '
      'corrupt FFmpeg input rejected before replacing staging; original ARM instructions and source files preserved; x64 downloads rejected.')
