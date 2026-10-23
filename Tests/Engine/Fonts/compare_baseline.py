#!/usr/bin/env python3
"""Create isolated C# font comparison inputs/outputs; never touches installed app/user state.

python3 Tests/Engine/Fonts/compare_baseline.py /tmp/ftx-font-baseline-<unique>
FILETOX_FONT_BASELINE=<that directory> swift test --filter FontBaselineTests
The XCTest writes Swift outputs and comparisons.json for inspection/browser validation.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=False)
for name in ("core", "engines", "tmp", "inputs", "expected", "swift"):
    (root / name).mkdir()
formats = ["ttf", "otf", "woff", "woff2", "eot"]
fixtures = Path(__file__).resolve().parent / "Fixtures"
originals = [fixtures / name for name in ("FileeTest-TrueType.ttf", "FileeTest-CID.otf", "FileeTest-NameKeyed.otf")]
originals += [Path("/System/Library/Fonts/Supplemental/Arial.ttf"),
              Path("/System/Library/Fonts/Supplemental/Times New Roman.ttf"),
              Path("/System/Library/Fonts/Supplemental/STIXGeneral.otf")]
host = Path("/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine")
env = dict(os.environ, TMPDIR=str(root / "tmp") + "/")
proc = subprocess.Popen([str(host), "--data", str(root / "core"), "--engines", str(root / "engines"), "--lang", "en"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(root / "stderr.log", "wb"), env=env)
messages, cond = [], threading.Condition()

def reader():
    for raw in proc.stdout:
        msg = json.loads(raw)
        with cond:
            messages.append(msg)
            cond.notify_all()
threading.Thread(target=reader, daemon=True).start()

def wait(pred):
    until = time.monotonic() + 180
    with cond:
        while True:
            for msg in messages:
                if pred(msg):
                    return msg
            if time.monotonic() > until:
                raise TimeoutError("host response timed out")
            cond.wait(1)

counter = 0

def call(method, **params):
    global counter
    counter += 1
    rid = str(counter)
    proc.stdin.write((json.dumps(dict(v=1, id=rid, method=method, params=params)) + "\n").encode())
    proc.stdin.flush()
    msg = wait(lambda m: m.get("id") == rid)
    if "error" in msg:
        raise RuntimeError(msg["error"])
    return msg["result"]

def convert(source, target, destination):
    job = call("job.start", paths=[str(source)], targetFormat=target)["jobId"]
    result = wait(lambda m: m.get("event") == "job.finished" and m["data"]["jobId"] == job)["data"]
    if result["state"] != "completed":
        raise RuntimeError(result)
    outputs = [o["path"] for f in result["files"] for o in f.get("outputs", [])]
    assert len(outputs) == 1, result
    if Path(outputs[0]).resolve() != destination.resolve():
        shutil.copyfile(outputs[0], destination)

manifest = []
try:
    hello = wait(lambda m: m.get("event") == "hello")
    catalog = call("catalog.get")
    (root / "host.json").write_text(json.dumps(dict(hello=hello, font=next(e for e in catalog["engines"] if e["id"] == "font")), indent=2))
    for original in originals:
        family = original.stem
        base = root / "inputs" / (family + original.suffix)
        shutil.copyfile(original, base)
        inputs = {}
        for fmt in formats:
            path = root / "inputs" / (family + "." + fmt)
            if fmt != original.suffix[1:]:
                convert(base, fmt, path)
            inputs[fmt] = path
        for sourceFormat, source in inputs.items():
            for target in formats:
                if sourceFormat == target:
                    continue
                filename = family + "." + sourceFormat + "-to-" + target + "." + target
                expected = root / "expected" / filename
                convert(source, target, expected)
                manifest.append(dict(family=family, sourceFormat=sourceFormat, target=target, input=str(source), expected=str(expected), swift=str(root / "swift" / filename)))
        print("Prepared", family, flush=True)
    google = root / "inputs" / "FileeTest-TrueType.google.woff2"
    shutil.copyfile(fixtures / google.name, google)
    for target in formats:
        if target == "woff2":
            continue
        filename = "Google.woff2-to-" + target + "." + target
        expected = root / "expected" / filename
        convert(google, target, expected)
        manifest.append(dict(family="Google", sourceFormat="woff2", target=target, input=str(google), expected=str(expected), swift=str(root / "swift" / filename)))
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print("Prepared", len(manifest), "comparisons in", root, flush=True)
finally:
    proc.stdin.close()
    proc.wait(timeout=15)
