#!/usr/bin/env python3
"""Compare XCTest-built document fixtures with the installed host-wire-v1 C# helper.

FILETOX_DOCUMENT_FIXTURE_OUTPUT=/tmp/p3a-parity swift test --filter DocumentParityTests
python3 Tools/engine-compare/documents.py /tmp/p3a-parity <fresh-baseline-folder>
No user application state is read or changed. The helper's core, engines and TMPDIR are isolated.
"""
import difflib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
import zipfile

HOST = Path('/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine')

def local(tag):
    return tag.rsplit('}', 1)[-1]

def semantic_xml(data, ignore_dates=False):
    root = ET.fromstring(data)
    def walk(node):
        text = node.text or ''
        if ignore_dates and local(node.tag) in ('created', 'modified'):
            text = '<timestamp>'
        if list(node) and not text.strip():
            text = ''
        return (node.tag, tuple(sorted(node.attrib.items())), text,
                tuple((walk(c), '' if not (c.tail or '').strip() else c.tail) for c in node))
    return walk(root)

def first_difference(a, b, path=''):
    if a == b:
        return None
    if not isinstance(a, tuple) or not isinstance(b, tuple):
        return {'path': path, 'swift': str(a)[:300], 'baseline': str(b)[:300]}
    if len(a) != len(b):
        return {'path': path, 'swift_length': len(a), 'baseline_length': len(b)}
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return first_difference(x, y, f'{path}/{i}')

def compare(a, b, kind):
    if kind in ('hwpx', 'docx'):
        with zipfile.ZipFile(a) as za, zipfile.ZipFile(b) as zb:
            names_a, names_b = za.namelist(), zb.namelist()
            result = {'entries_equal': names_a == names_b, 'parts': {}}
            for name in sorted(set(names_a) | set(names_b)):
                if name not in names_a or name not in names_b:
                    result['parts'][name] = {'missing': 'swift' if name not in names_a else 'baseline'}
                    continue
                x, y = za.read(name), zb.read(name)
                if name.endswith(('.xml', '.hpf', '.rdf', '.rels')):
                    x, y = semantic_xml(x, kind == 'docx'), semantic_xml(y, kind == 'docx')
                result['parts'][name] = {'equal': x == y}
                if x != y:
                    result['parts'][name]['difference'] = first_difference(x, y) if isinstance(x, tuple) else {'swift_bytes': len(x), 'baseline_bytes': len(y)}
            result['equal'] = result['entries_equal'] and all(v.get('equal') for v in result['parts'].values())
            return result
    x, y = a.read_bytes(), b.read_bytes()
    result = {'equal': x == y, 'swift_bytes': len(x), 'baseline_bytes': len(y)}
    if kind in ('txt', 'md', 'html'):
        sx, sy = x.decode('utf-8-sig'), y.decode('utf-8-sig')
        result['text_equal'] = sx == sy
        result['diff'] = ''.join(difflib.unified_diff(sy.splitlines(True), sx.splitlines(True), fromfile='baseline', tofile='swift'))[:24000]
    return result

class Host:
    def __init__(self, work):
        self.lines, self.condition, self.n = [], threading.Condition(), 0
        (work / 'tmp').mkdir(parents=True)
        self.err = (work / 'stderr.log').open('wb')
        env = dict(os.environ, TMPDIR=str(work / 'tmp') + '/')
        self.proc = subprocess.Popen([str(HOST), '--data', str(work / 'core'), '--engines', str(work / 'engines'), '--lang', 'en'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, env=env)
        def reader():
            for raw in self.proc.stdout:
                try:
                    message = json.loads(raw)
                except ValueError:
                    continue
                with self.condition:
                    self.lines.append(message)
                    self.condition.notify_all()
        threading.Thread(target=reader, daemon=True).start()
        self.wait(lambda m: m.get('event') == 'hello', 60)
    def wait(self, predicate, timeout=180):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                for m in self.lines:
                    if predicate(m):
                        return m
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('C# helper did not return the expected message')
                self.condition.wait(min(remaining, 1))
    def call(self, method, **params):
        self.n += 1
        rid = str(self.n)
        self.proc.stdin.write((json.dumps({'v': 1, 'id': rid, 'method': method, 'params': params}) + '\n').encode())
        self.proc.stdin.flush()
        result = self.wait(lambda m: m.get('id') == rid)
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result['result']
    def convert(self, path, target):
        job = self.call('job.start', paths=[str(path)], targetFormat=target)['jobId']
        return self.wait(lambda m: m.get('event') == 'job.finished' and m['data']['jobId'] == job)['data']
    def close(self):
        self.proc.stdin.close()
        self.proc.wait(20)
        self.err.close()

def main():
    fixtures, work = map(lambda s: Path(s).resolve(), sys.argv[1:3])
    work.mkdir(parents=True, exist_ok=False)
    cases_file, = fixtures.rglob('parity-cases.json')
    cases = json.loads(cases_file.read_text())
    host = Host(work)
    report = []
    try:
        (work / 'catalog.json').write_text(json.dumps(host.call('catalog.get'), ensure_ascii=False, indent=2))
        for i, case in enumerate(cases):
            job = host.convert(Path(case['input']), case['to'])
            record = dict(case, baseline_state=job['state'])
            outputs = [o['path'] for f in job['files'] for o in (f.get('outputs') or [])]
            record['job'] = job
            if job['state'] == 'completed' and outputs:
                baseline = work / f'{i:02d}-{case["from"]}-to-{case["to"]}.{case["to"]}'
                shutil.copyfile(outputs[0], baseline)
                record['baseline'] = str(baseline)
                record['comparison'] = compare(Path(case['swift']), baseline, case['to'])
            report.append(record)
            print(case['from'] + ' → ' + case['to'], record['baseline_state'], record.get('comparison', {}).get('equal'), flush=True)
    finally:
        host.close()
        (work / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
        (work / 'wire.ndjson').write_text(''.join(json.dumps(m, ensure_ascii=False) + '\n' for m in host.lines))
    print(work / 'report.json')

if __name__ == '__main__':
    main()
