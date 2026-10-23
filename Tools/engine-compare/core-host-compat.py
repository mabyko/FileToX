#!/usr/bin/env python3
"""Compare the non-engine wire and user-data contracts using isolated copies only."""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading


class Host:
    def __init__(self, executable, root):
        self.root = Path(root)
        self.log = (self.root / 'stderr.log').open('wb')
        self.process = subprocess.Popen([str(executable), '--data', str(self.root / 'core'), '--engines', str(self.root / 'engines'), '--tmp', str(self.root / 'tmp'), '--lang', 'en'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        hello = self.lines.get(timeout=60)
        if hello.get('event') != 'hello':
            raise RuntimeError('Host did not send hello: ' + str(hello))
        self.next = 0

    def read(self):
        for line in self.process.stdout:
            self.lines.put(json.loads(line))

    def call(self, method, params=None):
        self.next += 1
        request = {'v': 1, 'id': str(self.next), 'method': method, 'params': params or {}}
        self.process.stdin.write((json.dumps(request, ensure_ascii=False) + '\n').encode())
        self.process.stdin.flush()
        while True:
            line = self.lines.get(timeout=120)
            if line.get('id') == str(self.next):
                if 'error' in line:
                    raise RuntimeError(str(line['error']))
                return line['result']

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.reader.join(timeout=3)
        self.log.close()


def differing_paths(a, b, path=''):
    if isinstance(a, dict) and isinstance(b, dict):
        return [p for key in sorted(a.keys() | b.keys()) for p in (differing_paths(a[key], b[key], path + '/' + key) if key in a and key in b else [path + '/' + key])]
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [path + '/length']
        return [p for i, (x, y) in enumerate(zip(a, b)) for p in differing_paths(x, y, path + '/' + str(i))]
    return [] if a == b else [path]


def snapshot(executable, root):
    host = Host(executable, root)
    try:
        library = host.call('library.get')
        before = {'library': library, 'history': host.call('history.get'), 'formats': host.call('catalog.get')['formats']}
        updated = host.call('settings.save', {'baseRevision': library['revision'], 'settings': library['settings']})
        host.call('library.save', {'baseRevision': updated['revision'], 'presets': updated['presets'], 'profiles': updated['profiles']})
        return before
    finally:
        host.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, default=Path.home() / 'Library/Application Support/FileToX/core')
    parser.add_argument('--baseline', type=Path, default=Path('/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine'))
    parser.add_argument('--swift', type=Path, default=Path('.build/debug/FileToXEngine'))
    parser.add_argument('--output-dir', type=Path)
    args = parser.parse_args()
    root = (args.output_dir or Path(tempfile.mkdtemp(prefix='ftx-user-data-compare-'))).resolve()
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    names = ['settings.json', 'history.json', 'presets.json', 'profiles.json']
    copied = []
    for name in names:
        original = args.source_dir / name
        if original.is_file():
            for version in ['csharp', 'swift']:
                target = root / version / 'core' / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, target)
            copied.append(name)
    if 'settings.json' not in copied:
        raise RuntimeError('The compatibility check requires a copied settings.json.')
    a = snapshot(args.baseline.resolve(), root / 'csharp')
    b = snapshot(args.swift.resolve(), root / 'swift')
    result = {'copiedFiles': copied, 'wire': {key: differing_paths(a[key], b[key]) for key in a}, 'files': {}}
    for name in names:
        csharp, swift = root / 'csharp/core' / name, root / 'swift/core' / name
        if csharp.exists() and swift.exists():
            result['files'][name] = {'semanticDifferences': differing_paths(json.loads(csharp.read_text()), json.loads(swift.read_text())), 'byteEqual': csharp.read_bytes() == swift.read_bytes()}
    (root / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    print('Local copies and summary:', root)
    return int(any(result['wire'].values()) or any(file['semanticDifferences'] for file in result['files'].values()))


if __name__ == '__main__':
    raise SystemExit(main())
