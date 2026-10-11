#!/usr/bin/env python3
"""Real-engine smoke run (engine-host.md G3 samples) against a published host.

usage: smoke.py <FileToXEngine> <empty work dir>
Starts the host on a fresh data folder, converts generated samples and checks the results' signatures.
"""
import json, os, pathlib, subprocess, sys, threading, time, zlib, struct, zipfile

host, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
work.mkdir(parents=True, exist_ok=True)
files = work / "files"; files.mkdir(exist_ok=True)
proc = subprocess.Popen([str(host), "--data", str(work / "core"), "--lang", "en"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(work / "stderr.log", "wb"))
lines, cond = [], threading.Condition()

def reader():
    for raw in proc.stdout:
        msg = json.loads(raw)  # any non-JSON line fails the run
        with cond:
            lines.append(msg); cond.notify_all()
threading.Thread(target=reader, daemon=True).start()

def wait(pred, timeout=300):
    end = time.time() + timeout
    with cond:
        while True:
            for m in lines:
                if pred(m): return m
            if time.time() > end: raise TimeoutError
            cond.wait(1)

n = 0
def call(method, **params):
    global n; n += 1; rid = str(n)
    proc.stdin.write((json.dumps({"v": 1, "id": rid, "method": method, "params": params}) + "\n").encode()); proc.stdin.flush()
    m = wait(lambda m: m.get("id") == rid)
    if "error" in m: raise RuntimeError(f"{method}: {m['error']}")
    return m["result"]

def convert(paths, **how):
    job = call("job.start", paths=[str(p) for p in paths], **how)["jobId"]
    return wait(lambda m: m.get("event") == "job.finished" and m["data"]["jobId"] == job)["data"]

def png(path, w=8, h=8):
    rows = b"".join(b"\0" + b"".join(bytes([x * 30 % 256, y * 30 % 256, 128]) for x in range(w)) for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return path

SIG = {"png": b"\x89PNG", "jpg": b"\xff\xd8", "pdf": b"%PDF", "zip": b"PK", "docx": b"PK", "xlsx": b"PK", "hwpx": b"PK",
       "tiff": (b"II*\0", b"MM\0*"), "woff2": b"wOF2", "csv": None, "html": None, "hwp": b"\xd0\xcf\x11\xe0", "md": None, "txt": None,
       "svg": None, "epub": b"PK", "webp": b"RIFF"}
results = []
def check(name, data, ext=None, count=None, expect_unavailable=None):
    outs = [o["path"] for f in data["files"] for o in (f.get("outputs") or [])]
    ok = data["state"] == "completed" and outs
    if ok and ext:
        sig = SIG.get(ext)
        for o in outs:
            if pathlib.Path(o).is_dir(): continue
            head = pathlib.Path(o).read_bytes()[:8]
            if sig and not head.startswith(sig if isinstance(sig, bytes) else sig) and not (isinstance(sig, tuple) and any(head.startswith(s) for s in sig)):
                ok = False
    if ok and count is not None and len(outs) != count: ok = False
    errs = [(f["errorKey"], f.get("errorDetail")) for f in data["files"] if f.get("errorKey")]
    results.append((name, bool(ok), data["state"], outs, errs))

hello = wait(lambda m: m.get("event") == "hello", 60)
catalog = call("catalog.get")
unavailable = {e["id"]: e.get("reasonKey") for e in catalog["engines"] if not e["available"]}

a = png(files / "photo.png", 64, 48)
check("png→jpg", convert([a], targetFormat="jpg"), "jpg")
subprocess.run(["sips", "-s", "format", "heic", str(a), "--out", str(files / "photo.heic")], capture_output=True)
if (files / "photo.heic").exists():
    check("heic→png", convert([files / "photo.heic"], targetFormat="png"), "png")
check("png→pdf", convert([a], targetFormat="pdf"), "pdf")
b = png(files / "second.png", 32, 32)
lib = call("library.get")
merge = next(p for p in lib["presets"] if p["pdf"]["mergeIntoSingle"])
merged = convert([a, b], presetId=merge["id"]); check("merge pdf", merged, "pdf", 1)
if merged["files"][0].get("outputs"):
    check("2-page pdf→png", convert([merged["files"][0]["outputs"][0]["path"]], targetFormat="png"), "png", 2)
preset = dict(merge, id="tiff-one", targetFormat="tiff", name="TIFF")
preset["image"] = dict(merge["image"], multiPageTiff=True); preset["pdf"] = dict(merge["pdf"], mergeIntoSingle=False)
check("multi-page tiff", convert([a, b], preset=preset), "tiff", 1)
(files / "notes.unknownext").write_text("?")
folder = files / "folder"; folder.mkdir(exist_ok=True); (folder / "inside.txt").write_text("in")
zipall = next(p for p in lib["presets"] if p["archive"]["combineIntoOne"])
zipped = convert([a, files / "notes.unknownext", folder], presetId=zipall["id"]); check("zip all (unknown+folder)", zipped, "zip", 1)
if zipped["files"][0].get("outputs"):
    z = zipped["files"][0]["outputs"][0]["path"]
    check("zip→folder", convert([z], targetFormat="folder"), None, 1)
md = files / "doc.md"; md.write_text("# Title\n\nHello **world**.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
docx = convert([md], targetFormat="docx"); check("md→docx", docx, "docx")
if docx["files"][0].get("outputs"):
    d = docx["files"][0]["outputs"][0]["path"]
    check("docx→html", convert([d], targetFormat="html"), "html")
    check("docx→pdf", convert([d], targetFormat="pdf"), "pdf")
    check("docx→epub", convert([d], targetFormat="epub"), "epub")
txt = files / "한글 문서.txt"; txt.write_text("안녕하세요\n두 번째 줄\n")
hwpx = convert([txt], targetFormat="hwpx"); check("txt→hwpx (Korean, space)", hwpx, "hwpx")
if hwpx["files"][0].get("outputs"):
    h = hwpx["files"][0]["outputs"][0]["path"]
    hwp = convert([h], targetFormat="hwp"); check("hwpx→hwp (rhwp)", hwp, "hwp")
    if hwp["files"][0].get("outputs"):
        check("hwp→pdf", convert([hwp["files"][0]["outputs"][0]["path"]], targetFormat="pdf"), "pdf")
csv = files / "table.csv"; csv.write_text("a,b\n1,2\n")
xlsx = convert([csv], targetFormat="xlsx"); check("csv→xlsx", xlsx, "xlsx")
if xlsx["files"][0].get("outputs"):
    check("xlsx→csv", convert([xlsx["files"][0]["outputs"][0]["path"]], targetFormat="csv"), "csv")
svg = files / "shape.svg"; svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="red"/></svg>')
check("svg→png", convert([svg], targetFormat="png"), "png")
dxf = files / "line.dxf"; dxf.write_text("0\nSECTION\n2\nENTITIES\n0\nLINE\n8\n0\n10\n0\n20\n0\n30\n0\n11\n10\n21\n10\n31\n0\n0\nENDSEC\n0\nEOF\n")
check("dxf→svg", convert([dxf], targetFormat="svg"), "svg")
font = next((p for p in pathlib.Path("/System/Library/Fonts/Supplemental").glob("*.ttf")), None)
if font:
    import shutil; shutil.copy(font, files / font.name)
    check("ttf→woff2", convert([files / font.name], targetFormat="woff2"), "woff2")
mp4 = files / "clip.mp4"; mp4.write_bytes(b"\0" * 16)
sel = call("selection.resolve", paths=[str(mp4)])
mp3 = next(t for t in sel["targets"] if t["formatId"] == "mp3")
results.append(("mp4→mp3 availability", mp3["available"] or mp3.get("reasonKey") is not None, "resolve", [], [(mp3.get("reasonKey"), mp3.get("reasonText"))]))
slices = sel["slices"]
results.append(("mp4 slices carry package guidance", all(s["available"] or s.get("reasonKey") for s in slices), "resolve", [],
                [(s["presetId"], s.get("needsPackage"), s.get("canDownload"), s.get("guidanceKey")) for s in slices][:3]))

proc.stdin.close(); proc.wait(15)
leftovers = list(files.rglob(".filee-out-*"))
for name, ok, state, outs, errs in results:
    print(("PASS " if ok else "FAIL ") + name, state, [os.path.basename(o) for o in outs][:4], errs[:2])
print("unavailable engines:", unavailable)
print("staging leftovers:", leftovers)
sys.exit(0 if all(r[1] for r in results) and not leftovers else 1)
