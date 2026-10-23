#!/usr/bin/env python3
"""Generate/replay conversion cases and preserve outputs plus semantic fingerprints."""
import argparse
from collections import Counter
import copy
import json
from pathlib import Path
import re
import shutil
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hostwire import Host, ProtocolError, RPCError, add_host_arguments, own_copies, write_json
from fingerprint import ensure_native, fingerprint, sha256


def engine_hint(source, target, formats):
    """Family attribution only: host-wire-v1 never exposes the executed route."""
    category = formats.get(source, {}).get("category")
    if category in ("audio", "video"): return "ffmpeg"
    if category == "font": return "font"
    if category == "archive" or target in ("zip", "7z", "folder", "tgz", "tbz2", "txz", "tar", "gz", "bz2", "xz"): return "archive"
    if category == "cad": return "cad"
    if source == "eml": return "email"
    if source in ("svg", "svgz", "ai"): return "vector"
    if source == "icns" or target == "icns": return "icns"
    if category == "image": return "pdfsharp" if target == "pdf" else "magick"
    if source == "pdf": return "pdfium" if formats.get(target, {}).get("category") == "image" else "pdf-text" if target == "txt" else "pdfsharp" if target == "pdf" else "document-route"
    if source == "hwp": return "unhwp" if target in ("txt", "md", "html", "hwpx") else "rhwp"
    if source == "hwpx": return "hwpx-writer" if target in ("txt", "md", "html", "docx", "epub") else "rhwp"
    if source in ("rst", "tex"): return "pandoc"
    if target in ("mobi", "azw3", "lit", "lrf", "pdb", "pml", "rb", "snb", "tcr"): return "calibre"
    if category == "ebook" or target in ("epub", "fb2", "htmlz", "txtz", "cbz"): return "ebook"
    if source in ("docm", "dotx", "dotm", "xlsm", "xltx", "pptm", "potx", "ppsx") or target in ("docm", "dotx", "dotm", "xlsm", "xltx", "pptm", "potx", "ppsx"): return "ooxml"
    if category == "spreadsheet": return "spreadsheet"
    if source == "md": return "markdown"
    if target == "docx": return "docx-writer"
    if target == "hwpx": return "hwpx-writer"
    return "document-route"


def generate_cases(manifest, matrix, library, cap=6):
    samples = manifest["samples"]
    formats = {f["id"]: f for f in matrix["catalog"]["formats"]}
    by_format = {}
    for sample in samples:
        by_format.setdefault(sample["formatId"], []).append(sample)
    cases, used_targets, per_source = [], Counter(), Counter()
    def add(label, chosen, how, target, **extra):
        identifier = re.sub(r"[^a-zA-Z0-9._-]", "-", label)
        if any(c["id"] == identifier for c in cases):
            raise ValueError("Duplicate case id " + identifier)
        cases.append({"id": identifier, "samples": [s["id"] for s in chosen], "how": how,
                      "targetFormat": target,
                      "engineHint": engine_hint(chosen[0]["formatId"], target, formats), **extra})
        used_targets[target] += 1
        for sample in chosen: per_source[sample["id"]] += 1
    for index, sample in enumerate(samples):
        selection = matrix["selections"].get(sample["formatId"], {})
        targets = [t["formatId"] for t in selection.get("targets", []) if t["available"]]
        # Distribute targets across sources instead of always taking alphabetic prefixes.
        targets.sort(key=lambda t: (used_targets[t], t))
        for target in targets[:cap or None]:
            add(f"auto-{index:03d}-{sample['formatId']}-to-{target}", [sample], {"targetFormat": target}, target)
    possible = {t["formatId"] for sample in samples
                for t in matrix["selections"].get(sample["formatId"], {}).get("targets", []) if t["available"]}
    for target in sorted(possible - used_targets.keys()):
        eligible = [s for s in samples if any(t["formatId"] == target and t["available"]
                    for t in matrix["selections"].get(s["formatId"], {}).get("targets", []))]
        sample = min(eligible, key=lambda s: (per_source[s["id"]], s["id"]))
        add(f"coverage-{target}", [sample], {"targetFormat": target}, target)

    def choose(fmt, name=None):
        return next((s for s in by_format.get(fmt, []) if name is None or s["id"] == name), None)
    for preset in library["presets"]:
        eligible = [s for s in samples if any(p["presetId"] == preset["id"] and p["available"]
                    for p in matrix["selections"].get(s["formatId"], {}).get("presetOptions", []))]
        if eligible:
            target_category = formats.get(preset["targetFormat"], {}).get("category")
            sample = min(eligible, key=lambda s: (formats.get(s["formatId"], {}).get("category") != target_category,
                                                 per_source[s["id"]], s["id"]))
            add("builtin-" + preset["id"], [sample], {"presetId": preset["id"]}, preset["targetFormat"])

    template = library["presets"][0]
    def variant(name, sources, target, options, **extra):
        if not all(sources): return
        preset = copy.deepcopy(template)
        preset.update(id="compare-" + name, name=name, nameKey=None, targetFormat=target)
        for section, fields in options.items():
            preset[section].update(fields)
        add("option-" + name, sources, {"preset": preset}, target, **extra)

    image = choose("png", "한글 image.png") or choose("png")
    second = choose("png", "second.png")
    pdf = choose("pdf", "two-pages.pdf") or choose("pdf")
    video, audio = choose("mp4"), choose("wav")
    for name, target, options in [
        ("quality-25", "jpg", {"quality": 25}), ("quality-95", "jpg", {"quality": 95}),
        ("resize-percent", "png", {"resize": "percent", "resizePercent": 50}),
        ("resize-long-edge", "png", {"resize": "longEdge", "longEdge": 48}),
        ("grayscale", "png", {"grayscale": True}), ("dpi-300", "tiff", {"dpi": 300}),
        ("background-black", "jpg", {"background": "#000000"}),
        ("strip-metadata", "png", {"keepMetadata": False, "keepColorProfile": False}),
        ("ico-sizes", "ico", {"icoSizes": [16, 32, 64]}),
        ("tiff-none", "tiff", {"tiffCompression": "none"}),
        ("tiff-zip", "tiff", {"tiffCompression": "zip"}),
        ("tiff-lzw", "tiff", {"tiffCompression": "lzw"}),
        ("webp-lossless", "webp", {"webpLossless": True})]:
        variant(name, [image], target, {"image": options})
    variant("multipage-tiff", [image, second], "tiff", {"image": {"multiPageTiff": True}})
    for dpi in (72, 300):
        variant("render-" + str(dpi), [pdf], "png", {"pdf": {"renderDpi": dpi}})
    variant("page-range", [pdf], "png", {"pdf": {"pageRange": "2", "renderDpi": 72}})
    variant("split-pages", [pdf], "pdf", {"pdf": {"splitPages": True}})
    variant("merge-pdf", [pdf, image], "pdf", {"pdf": {"mergeIntoSingle": True}})
    for page in ("a4", "letter"):
        variant("page-" + page, [image], "pdf", {"pdf": {"pageSize": page, "marginMm": 12}})
    if choose("docx"):
        variant("pdf-a", [choose("docx")], "pdf", {"document": {"pdfA": True}})
    for quality in ("high", "small"):
        variant("media-" + quality, [video], "mp4", {"media": {"quality": quality}})
    variant("max-height", [video], "mp4", {"media": {"maxHeight": 64}})
    variant("remove-audio", [video], "mp4", {"media": {"removeAudio": True}})
    variant("audio-bitrate", [audio], "mp3", {"media": {"audioBitrateKbps": 64}})
    variant("audio-channels", [audio], "wav", {"media": {"audioChannels": 2, "audioSampleRate": 22050}})
    for form in ("pcm8", "pcm16", "pcm24", "pcm32", "float32"):
        variant("wav-" + form, [audio], "wav", {"media": {"wavFormat": form}})
    for level in ("store", "fast", "normal", "maximum"):
        variant("archive-" + level, [image, choose("txt"), choose("unknown"), choose("folder")], "zip",
                {"archive": {"combineIntoOne": True, "level": level}})
    for location in ("sameFolder", "subfolder", "customFolder"):
        variant("location-" + location, [image], "jpg", {"output": {"location": location,
                "subfolderName": "results", "customFolder": "$CASE/custom"}})
    variant("naming", [image, second], "jpg", {"output": {"location": "subfolder", "subfolderName": "results",
            "fileNamePattern": "{index}_{name}_{ext}_{preset}", "renames": [
                {"kind": "spacesToUnderscores", "find": "", "replace": ""},
                {"kind": "prefix", "find": "", "replace": "converted_"}]}})
    for policy in ("rename", "overwrite", "skip"):
        variant("conflict-" + policy, [image], "jpg", {"output": {"conflict": policy}}, preexisting=True)
    variant("keep-dates", [image], "jpg", {"output": {"keepDates": True}}, keepDates=True)
    # Exercise optional engines through the public settings API, using a full preset.
    for engine, src, target in [("magick", image, "jpg"), ("pdfsharp", image, "pdf"),
                                 ("pdfium", pdf, "png"), ("rhwp", choose("hwp"), "pdf"),
                                 ("unhwp", choose("hwp"), "txt"), ("markdown", choose("md"), "html"),
                                 ("spreadsheet", choose("csv"), "xlsx"),
                                 ("ooxml", choose("docm"), "docx"),
                                 ("hwpx-writer", choose("txt"), "hwpx"),
                                 ("docx-writer", choose("txt"), "docx"),
                                 ("pdf-text", pdf, "txt"), ("email", choose("eml"), "html"),
                                 ("vector", choose("svg"), "pdf"), ("icns", choose("icns"), "png"),
                                 ("font", choose("ttf"), "woff"), ("cad", choose("dxf"), "svg"),
                                 ("archive", choose("zip"), "7z"), ("ebook", choose("epub"), "txt"),
                                 ("ffmpeg", video, "mp3"), ("pandoc", choose("rst"), "docx"),
                                 ("calibre", choose("epub"), "mobi"),
                                 ("libreoffice", choose("rtf"), "odt")]:
        if src and any(e["id"] == engine and e["available"] for e in matrix["catalog"]["engines"]):
            variant("engine-" + engine, [src], target, {}, priority=engine)
            cases[-1]["engineHint"] = engine
    document_pdf = choose("pdf", "derived.pdf")
    if document_pdf:
        variant("engine-pdf-text-document", [document_pdf], "txt", {}, priority="pdf-text")
        cases[-1]["engineHint"] = "pdf-text"
    return cases


def replace_case(value, root):
    if isinstance(value, str): return value.replace("$CASE", str(root))
    if isinstance(value, list): return [replace_case(x, root) for x in value]
    if isinstance(value, dict): return {k: replace_case(v, root) for k, v in value.items()}
    return value


def summarize(results):
    return {"cases": len(results), "states": dict(sorted(Counter(r["state"] for r in results).items())),
            "errorKeys": dict(sorted(Counter(f.get("errorKey") for r in results for f in r.get("files", [])
                                              if f.get("errorKey")).items())),
            "harnessErrors": sum(bool(r.get("harnessError")) for r in results),
            "inspectionErrors": sum(bool(o["fingerprint"].get("inspectionError")) for r in results for o in r.get("outputs", [])),
            "targetFormats": sorted({r["targetFormat"] for r in results}),
            "engineHints": sorted({r["engineHint"] for r in results})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_host_arguments(parser)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cases", type=Path, help="Replay the exact cases.json from the baseline")
    parser.add_argument("--cap-per-source", type=int, default=6, help="0 runs all available pairs")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--sevenzip", type=Path)
    parser.add_argument("--limit", type=int, help="Limit for harness development only")
    parser.add_argument("--resume", action="store_true", help="Keep captured cases and execute missing cases only")
    args = parser.parse_args()
    ensure_native()
    root, corpus = args.out.resolve(), args.corpus.resolve(strict=True)
    if args.resume:
        if not (root / "run.json").is_file(): raise ValueError("--resume requires an existing run.json")
    else:
        root.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((corpus / "manifest.json").read_text())
    matrix = json.loads(args.matrix.read_text())
    samples = {s["id"]: s for s in manifest["samples"]}
    copies = own_copies(args)
    report = {"schema": 1, "host": str(args.host.resolve()), "corpus": str(corpus),
              "matrix": str(args.matrix.resolve()), "configuration": {"ownCopies": copies},
              "engineAttribution": "engineHint is an inferred family or requested priority, not an executed route from the wire",
              "results": []}
    if args.resume:
        previous = json.loads((root / "run.json").read_text())
        for key in ("host", "corpus", "matrix", "configuration"):
            if previous[key] != report[key]: raise ValueError("Cannot resume with changed " + key)
        report = previous
    host = Host(args.host, copies=copies, stderr_path=root / "host.stderr.log")
    def save():
        report["summary"] = summarize(report["results"])
        write_json(root / "run.json", report)
    try:
        report["hello"] = {k: v for k, v in host.hello.items() if k != "dataDir"}
        report["catalog"] = host.call("catalog.get")
        library = host.call("library.get")
        write_json(root / "library.json", library)
        cases = json.loads(args.cases.read_text()) if args.cases else generate_cases(manifest, matrix, library, args.cap_per_source)
        if isinstance(cases, dict): cases = cases["cases"]
        if args.limit: cases = cases[:args.limit]
        if args.resume:
            previous_cases = {c["id"]: c for c in json.loads((root / "cases.json").read_text())}
            current_cases = {c["id"]: c for c in cases}
            for result in report["results"]:
                if previous_cases[result["id"]] != current_cases.get(result["id"]):
                    raise ValueError("Cannot resume with changed case " + result["id"])
        write_json(root / "cases.json", cases)
        completed = {r["id"] for r in report["results"]}
        for index, case in enumerate(cases):
            if case["id"] in completed: continue
            if Path(case["id"]).name != case["id"] or case["id"] in (".", ".."):
                raise ValueError("Invalid case id")
            case_root = root / "cases" / case["id"] / "sample"
            case_root.mkdir(parents=True)
            paths, source_hashes = [], {}
            for sample_id in case["samples"]:
                sample = samples[sample_id]
                source = (corpus / sample["path"]).resolve(strict=True)
                if not source.is_relative_to(corpus): raise ValueError("Sample escapes corpus")
                if source.is_file() and sha256(source) != sample["sha256"]:
                    raise ValueError("Corpus hash mismatch: " + sample_id)
                dest = case_root / source.name
                if source.is_dir(): shutil.copytree(source, dest)
                else: shutil.copy2(source, dest)
                paths.append(dest)
                if dest.is_file(): source_hashes[dest] = sha256(dest)
            if case.get("preexisting"):
                paths[0].with_suffix(".jpg").write_bytes(b"existing-file-sentinel\n")
            result = {k: copy.deepcopy(case[k]) for k in ("id", "samples", "targetFormat", "engineHint")}
            start = time.monotonic()
            try:
                if case.get("priority"):
                    host.configure(first=case["priority"])
                job = host.convert(paths, timeout=args.timeout, **replace_case(case["how"], case_root))
                result["elapsedSeconds"] = round(time.monotonic() - start, 6)
                result["state"] = job["state"]
                result["files"], result["outputs"] = [], []
                for f in job["files"]:
                    file = {k: f.get(k) for k in ("state", "errorKey", "errorDetail")}
                    file["source"] = str(Path(f["source"]).relative_to(case_root))
                    file["outputs"] = []
                    for output in f.get("outputs") or []:
                        path = Path(output["path"])
                        if not path.resolve().is_relative_to(case_root):
                            raise RuntimeError("Host output escapes isolated case: " + str(path))
                        relative = path.relative_to(case_root).as_posix()
                        file["outputs"].append({"name": relative, "isDirectory": output["isDirectory"]})
                        result["outputs"].append({"name": relative, "artifact": path.relative_to(root).as_posix(),
                                                  "fingerprint": fingerprint(path, args.sevenzip)})
                    result["files"].append(file)
                result["sourcePreserved"] = all(sha256(path) == digest for path, digest in source_hashes.items())
                if not result["sourcePreserved"]: result["harnessError"] = "Host changed an input"
                if case.get("keepDates") and result["outputs"]:
                    output = root / result["outputs"][0]["artifact"]
                    result["keepDatesDeltaSeconds"] = abs(output.stat().st_mtime - paths[0].stat().st_mtime)
                result["sidecars"] = [{"name": p.relative_to(case_root).as_posix(), "size": p.stat().st_size,
                                       "sha256": sha256(p)} for p in sorted(case_root.rglob("*"))
                                      if p.is_file() and p not in paths and not any(
                                          p == root / o["artifact"] or (root / o["artifact"]).is_dir() and
                                          p.is_relative_to(root / o["artifact"]) for o in result["outputs"])]
                result["stagingLeftovers"] = [p.name for p in case_root.rglob(".filee-out-*")]
                if result["stagingLeftovers"]: result["harnessError"] = "Staging directories remain"
                write_json(case_root.parent / "job.json", job)
            except (TimeoutError, ProtocolError, RPCError, OSError, RuntimeError, ValueError) as error:
                result.update(state="harnessError", harnessError=str(error),
                              elapsedSeconds=round(time.monotonic() - start, 6))
                if isinstance(error, RPCError): result["rpcError"] = error.error
                host.close(check=False)
                host = Host(args.host, copies=copies, stderr_path=root / "host.stderr.log")
            finally:
                if case.get("priority") and not host.closed:
                    current = host.call("library.get")
                    settings = copy.deepcopy(current["settings"])
                    settings["enginePriority"] = library["settings"]["enginePriority"]
                    host.call("settings.save", baseRevision=current["revision"], settings=settings)
            report["results"].append(result)
            save()
            print(f"{index+1}/{len(cases)} {case['id']}: {result['state']} ({result['elapsedSeconds']:.2f}s)", flush=True)
    finally:
        try:
            host.close()
        finally:
            save()
    print(json.dumps(report["summary"], ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
