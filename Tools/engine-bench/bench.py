#!/usr/bin/env python3
"""Time conversions on an engine host (Swift or the old C# helper) with the inputs from make-inputs.py.

Each case runs --repeat times through the host's wire protocol; the best time is printed. The same host, inputs and
machine make the numbers comparable; absolute values include host-side staging but not process start-up.
"""
import argparse, pathlib, shutil, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "engine-compare"))
from hostwire import Host  # noqa: E402

CASES = [("big.png", "jpg"), ("big.png", "webp"), ("big.pdf", "png"), ("big.pdf", "txt"), ("big.zip", "folder"), ("big.dxf", "svg"),
         ("big.dxf", "pdf"), ("big.epub", "fb2"), ("big.docx", "md"), ("big.docx", "txt"), ("big.md", "html"), ("big.md", "txt")]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", type=pathlib.Path, required=True)
    p.add_argument("--inputs", type=pathlib.Path, required=True)
    p.add_argument("--scratch", type=pathlib.Path, required=True)
    p.add_argument("--repeat", type=int, default=2)
    p.add_argument("--only", action="append", help="source→target, e.g. big.pdf→txt (repeatable)")
    a = p.parse_args()
    cases = [c for c in CASES if not a.only or f"{c[0]}→{c[1]}" in a.only]
    shutil.rmtree(a.scratch, ignore_errors=True); a.scratch.mkdir(parents=True)
    host = Host(str(a.host.resolve()), scratch=a.scratch); host.configure()
    try:
        for src, tgt in cases:
            if not (a.inputs / src).exists(): print(f"{src:9}→{tgt:6}   skipped (no input)"); continue
            best, state = None, None
            for i in range(a.repeat):
                d = a.scratch / f"{src}-{tgt}-{i}"; d.mkdir(); s = d / src; shutil.copy(a.inputs / src, s)
                t = time.time()
                try:
                    r = host.convert([str(s)], targetFormat=tgt, timeout=900); state = r["files"][0]["state"] if r.get("files") else r.get("state")
                except Exception as e:
                    state = f"ERR {str(e)[:60]}"
                dt = time.time() - t; best = dt if best is None or dt < best else best
            print(f"{src:9}→{tgt:6} {best:7.2f}s  {state}")
    finally:
        host.close()

if __name__ == "__main__":
    main()
