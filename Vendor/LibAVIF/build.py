#!/usr/bin/env python3
"""Rebuilds lib/libavif.a (libavif 1.4.2 + libaom 3.14.1, AV1 encoder only, arm64, macOS 15) from local pinned sources.

Never downloads: pass the official libavif v1.4.2 source tarball and a libaom checkout at the pinned commit (CMake's
FetchContent is pointed at it and disconnected). CMake is the only tool beyond Xcode's command line tools; the build runs
with a plain PATH, so Homebrew packages are not found.

    python3 -I Vendor/LibAVIF/build.py --tarball libavif-v1.4.2.tar.gz --libaom aom --cmake bin/cmake --work /tmp/avif
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import tarfile

HERE = pathlib.Path(__file__).resolve().parent
PROVENANCE = json.loads((HERE / 'PROVENANCE.json').read_text())


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--tarball', required=True, type=pathlib.Path)
    parser.add_argument('--libaom', required=True, type=pathlib.Path)
    parser.add_argument('--cmake', required=True, type=pathlib.Path)
    parser.add_argument('--work', required=True, type=pathlib.Path, help='new or empty build folder')
    parser.add_argument('--install', action='store_true', help='replace lib/libavif.a with the result')
    args = parser.parse_args()

    libavif, libaom = PROVENANCE['libavif'], PROVENANCE['libaom']
    if sha256(args.tarball) != libavif['tarballSha256']:
        raise SystemExit('The libavif tarball is not the pinned v' + libavif['version'] + ' archive.')
    def git(*arguments):
        return subprocess.check_output(['/usr/bin/git', '-C', str(args.libaom), *arguments], text=True).strip()
    if git('rev-parse', 'HEAD') != libaom['commit'] or git('status', '--porcelain', '--untracked-files=no'):
        raise SystemExit('The libaom checkout is not a clean ' + libaom['tag'] + ' (' + libaom['commit'] + ').')
    if args.work.exists() and any(args.work.iterdir()):
        raise SystemExit('The work folder must be new or empty.')

    source = args.work / 'src'
    with tarfile.open(args.tarball) as archive:
        if hasattr(tarfile, 'data_filter'):
            archive.extractall(source, filter='data')
        else:
            # Pythons without extraction filters (Xcode's 3.9): the pinned archive holds plain files and folders only.
            for member in archive.getmembers():
                name = pathlib.PurePosixPath(member.name)
                if name.is_absolute() or '..' in name.parts or not (member.isfile() or member.isdir()):
                    raise SystemExit('Unexpected member in the libavif tarball: ' + member.name)
            archive.extractall(source)
    source = source / ('libavif-' + libavif['version'])
    build = args.work / 'build'
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(args.work), 'TMPDIR': str(args.work),
                   'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer', 'ZERO_AR_DATE': '1'}
    options = PROVENANCE['cmakeOptions'] + ['-DFETCHCONTENT_SOURCE_DIR_LIBAOM=' + str(args.libaom.resolve()),
                                            '-DFETCHCONTENT_FULLY_DISCONNECTED=ON']
    subprocess.run([str(args.cmake), '-S', str(source), '-B', str(build), *options], env=environment, check=True)
    subprocess.run([str(args.cmake), '--build', str(build), '--target', 'avif_static', '--parallel', '2'], env=environment, check=True)
    result = build / 'libavif.a'
    print('libavif.a', sha256(result), result.stat().st_size, 'bytes')
    if args.install:
        shutil.copyfile(result, HERE / 'lib/libavif.a')


if __name__ == '__main__':
    main()
