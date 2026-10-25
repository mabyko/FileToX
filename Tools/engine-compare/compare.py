#!/usr/bin/env python3
"""Compare captured behavior and content; write report.md and report.json."""
import argparse
from collections import Counter, defaultdict
from difflib import SequenceMatcher
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import zipfile
from functools import lru_cache

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fingerprint import native, normalized, sha256, command, decode
from hostwire import write_json
from readback import FORMATS as READBACK_FORMATS, readback
from semantic import xml_text, document_text, tar_entries, generated_calibre_cover, rst_dimensions, read_tcr_payload, document_image_references


def ratio(a, b):
    a, b = normalized(a), normalized(b)
    return 1.0 if a == b else SequenceMatcher(None, a, b, autojunk=False).ratio()


def entries_equal(a, b):
    return [(e["name"], e.get("directory", False), e.get("sha256")) for e in a] == [
            (e["name"], e.get("directory", False), e.get("sha256")) for e in b]


@lru_cache(maxsize=128)
def picture_scores(left, right, strict=False):
    if left == right and not strict:
        return {"sameGeometry": True, "frames": [{"psnr": 99, "ssim": 1}]}
    with tempfile.TemporaryDirectory(prefix="filetox-picture-compare-") as folder:
        paths = [Path(folder) / name for name in ("left", "right")]
        for path, data in zip(paths, (left, right)): path.write_bytes(data)
        scores = native("compare", *paths)
        if not strict and generated_calibre_cover(left) and generated_calibre_cover(right) and scores.get("sameGeometry"):
            # Calibre chooses a random theme/layout when it generates a cover.
            # Require the same recognized title/author, not merely the COM marker.
            a, b = (native("ocr", p)["text"] for p in paths)
            scores["generatedCoverTextMatches"] = bool(a) and a == b
            scores["recognizedText"] = [a, b]
        return scores


def picture_below_threshold(scores, thresholds):
    return not scores.get("generatedCoverTextMatches") and any(
        f["psnr"] < thresholds["psnr"] or f["ssim"] < thresholds["ssim"] for f in scores["frames"])


def pictures_equal(left, right, thresholds, metrics, strict=False):
    problems = []
    if len(left) != len(right):
        if not strict: return "Embedded picture count changed"
        problems.append("Embedded picture count changed")
    for index in range(max(len(left), len(right)) if strict else len(left)):
        a = left[index] if index < len(left) else right[index]
        b = right[index] if index < len(right) else left[index]
        if a[0] != b[0]:
            if not strict: return "Embedded picture media type changed"
            problems.append("Embedded picture media type changed")
        scores = picture_scores(a[1], b[1], strict)
        metrics[str(index + 1)] = scores
        problem = ("Embedded picture geometry changed" if not scores.get("sameGeometry") else
                   "Embedded picture similarity below threshold" if picture_below_threshold(scores, thresholds) else None)
        if problem:
            if not strict: return problem
            problems.append(problem)
    return "; ".join(dict.fromkeys(problems)) or None


def media_packets(path):
    # Container IDs/timestamps are omitted; encoded payloads and packet timing stay strict.
    result = json.loads(command(["/opt/homebrew/bin/ffprobe", "-v", "error", "-show_packets", "-show_streams",
        "-show_data_hash", "sha256", "-show_entries",
        "packet=stream_index,pts,dts,duration,size,data_hash:stream=extradata_hash", "-of", "json", path]))
    # FFprobe includes stream tag subsections even with restricted show_entries.
    for stream in result.get("streams", []):
        tags = stream.get("tags", {})
        for key in ("file_package_umid", "material_package_umid", "creation_time"):
            tags.pop(key, None)
        if not tags: stream.pop("tags", None)
    return result


def compare_readback(left, right, thresholds):
    decoded, errors = {}, {}
    for side, path in (("baseline", left), ("candidate", right)):
        try:
            value = readback(path, thresholds.get("semanticTools"))
            if "error" in value: errors[side] = value["error"]
            else: decoded[side] = value
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            errors[side] = {"kind": "unavailable", "message": str(error)}
    metrics = {"readback": {"version": 1, "errors": errors, "readers": {}, "limits": {}, "coverage": {}}}
    for side, value in decoded.items():
        for key in ("reader", "limits", "coverage", "uninspected"):
            if key not in value: continue
            metrics["readback"].setdefault("readers" if key == "reader" else key, {})[side] = value[key]
        metrics["readback"].setdefault("sizes", {})[side] = {
            "textCharacters": sum(len(t) for t in value["textParts"].values()), "pictures": len(value["pictures"]),
            "opaqueParts": len(value["opaqueParts"])}
    if errors:
        level = "FAIL" if errors.get("candidate", {}).get("kind") == "invalid" else "WARN"
        return level, ["Binary semantic readback " + side + " " + e["kind"] + ": " + e["message"] for side, e in errors.items()], metrics
    a, b = decoded["baseline"], decoded["candidate"]
    reasons = []
    if a["textParts"].keys() != b["textParts"].keys(): reasons.append("Decoded document text part names/count changed")
    scores = {name: ratio(a["textParts"][name], b["textParts"][name]) for name in sorted(a["textParts"].keys() & b["textParts"].keys())}
    metrics["readback"]["textRatios"] = scores
    if a["structure"] != b["structure"]:
        reasons.append("Decoded document structure or metadata changed")
        metrics["readback"]["structure"] = {"baseline": a["structure"], "candidate": b["structure"]}
    if any(score < thresholds["text"] for score in scores.values()): reasons.append("Decoded document text similarity below threshold")
    if a["opaqueParts"] != b["opaqueParts"]:
        reasons.append("Decoded non-text resource/index bytes changed; no equivalence waiver")
        metrics["readback"]["opaqueParts"] = {"baseline": a["opaqueParts"], "candidate": b["opaqueParts"]}
    if [p["name"] for p in a["pictures"]] != [p["name"] for p in b["pictures"]]: reasons.append("Decoded picture names/order/count changed")
    import base64
    pictures = lambda value: [(p["mediaType"], base64.b64decode(p["data"], validate=True)) for p in value["pictures"]]
    try:
        problem = pictures_equal(pictures(a), pictures(b), thresholds, metrics.setdefault("pictures", {}), strict=True)
        if problem: reasons.append(problem)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        return ("FAIL" if reasons else "WARN"), reasons + ["Decoded image inspection unavailable: " + str(error)], metrics
    if reasons: return "FAIL", reasons, metrics
    if a.get("uninspected") or b.get("uninspected"):
        return "WARN", ["Known content inspected; listed unsupported fields remain uninspected"], metrics
    if any(s != 1 for s in scores.values()) or any(f["psnr"] != 99 or f["ssim"] != 1 for p in metrics.get("pictures", {}).values() for f in p["frames"]):
        return "WARN", ["Decoded text/images are within unchanged thresholds; bytes differ"], metrics
    return "PASS", [], metrics


def compare_output(a, b, left, right, thresholds):
    reasons, metrics = [], {}
    if a["kind"] != b["kind"]: return "FAIL", ["Output type changed"], metrics
    kind = a["kind"]
    if kind == "binary" and left and right and left.suffix.lower() == right.suffix.lower() and left.suffix.lower() in READBACK_FORMATS:
        return compare_readback(left, right, thresholds)
    if kind == "binary" and left and right and left.suffix.lower() == right.suffix.lower() == ".tcr":
        decoded, errors = {}, {}
        for name, path in (("baseline", left), ("candidate", right)):
            try: decoded[name] = read_tcr_payload(path)
            except (OSError, ValueError) as error: errors[name] = str(error)
        metrics["tcr"] = {"policy": "exact-decoded-bytes", "errors": errors,
                          "decodedSizes": {k: len(v) for k, v in decoded.items()}}
        if "candidate" in errors: return "FAIL", ["Candidate TCR is invalid: " + errors["candidate"]], metrics
        if "baseline" in errors: return "WARN", ["Baseline TCR inspection unavailable: " + errors["baseline"]], metrics
        equal = decoded["baseline"] == decoded["candidate"]
        if not equal:
            x, y = decoded["baseline"], decoded["candidate"]
            metrics["tcr"]["firstDifferenceOffset"] = next((i for i, (a, b) in enumerate(zip(x, y)) if a != b), min(len(x), len(y)))
        return ("PASS" if equal else "FAIL"), ([] if equal else ["TCR decoded payload bytes changed"]), metrics
    byte_equal = a.get("sha256") and a["sha256"] == b.get("sha256")
    if byte_equal and kind != "pdf":
        return "PASS", [], metrics
    if kind == "directory":
        equal = entries_equal(a["entries"], b["entries"])
        return ("PASS" if equal else "FAIL"), ([] if equal else ["Extracted entry names/content changed"]), metrics
    if a.get("inspectionError") or b.get("inspectionError"):
        return "WARN", ["Bytes differ; semantic inspection unavailable: " + str(
            a.get("inspectionError") or b.get("inspectionError"))], metrics
    ma, mb = a.get("metadata", {}), b.get("metadata", {})
    if kind == "image":
        if ma.get("frameCount") != mb.get("frameCount"):
            return "FAIL", ["Image frame count changed"], metrics
        for x, y in zip(ma.get("frames", []), mb.get("frames", [])):
            if (x["width"], x["height"]) != (y["width"], y["height"]):
                return "FAIL", ["Image dimensions changed"], metrics
            if x.get("hasAlpha") != y.get("hasAlpha"): reasons.append("Image alpha metadata changed")
            if x.get("colorModel") != y.get("colorModel"): reasons.append("Image color model changed")
            for key in ("dpiX", "dpiY"):
                if x.get(key) != y.get(key): reasons.append("Image DPI changed")
        try:
            metrics = native("compare", left, right)
        except (OSError, RuntimeError, ValueError) as error:
            return "WARN", ["Image comparison unavailable: " + str(error)], metrics
        if not metrics.get("sameGeometry"): return "FAIL", ["Image geometry changed"], metrics
        if any(f["psnr"] < thresholds["psnr"] or f["ssim"] < thresholds["ssim"] for f in metrics["frames"]):
            return "FAIL", ["Image similarity below threshold"], metrics
    elif kind == "pdf":
        if ma.get("pageCount") != mb.get("pageCount"):
            return "FAIL", ["PDF page count changed"], metrics
        scores = []
        for x, y in zip(ma["pages"], mb["pages"]):
            # Captured PDFKit boxes ignore rotation; the raster inspector checks rotated dimensions.
            if not thresholds.get("pdfRender") and (abs(x["width"]-y["width"]) > 1 or abs(x["height"]-y["height"]) > 1):
                return "FAIL", ["PDF page size changed by more than 1pt"], metrics
            scores.append(ratio(x["text"], y["text"]))
        metrics["pageTextRatios"] = scores
        if any(s < thresholds["text"] for s in scores):
            return "FAIL", ["PDF text similarity below threshold"], metrics
        annotation_error = None
        try:
            if left is None or right is None: raise ValueError("Saved PDF paths are required for annotation readback")
            annotations = {side: native("pdf-annotations", path) for side, path in (("baseline", left), ("candidate", right))}
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
            annotation_error = "PDF annotation inspection unavailable: " + str(error)
            metrics["annotationError"] = annotation_error
        else: metrics["annotations"] = annotations
        if thresholds.get("pdfRender"):
            try: metrics["raster"] = native("pdf-compare", left, right)
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
                return "WARN", ["PDF raster comparison unavailable: " + str(error)], metrics
            if not metrics["raster"].get("sameGeometry"):
                return "FAIL", ["PDF raster geometry changed"], metrics
            if picture_below_threshold(metrics["raster"], thresholds):
                return "FAIL", ["PDF raster similarity below threshold"], metrics
            reasons.append("PDF page content raster checked at 144 DPI; other bytes differ")
        elif not any(p["text"] for p in ma["pages"]):
            reasons.append("PDF has no extractable text; comparison checks page geometry only")
        if annotation_error: return "WARN", [annotation_error], metrics
        props = lambda doc: {"pages": [[item["properties"] for item in page] for page in doc["pages"]], "form": doc["form"]}
        if props(annotations["baseline"]) != props(annotations["candidate"]):
            return "FAIL", ["PDF annotation content, geometry, actions or form fields changed"], metrics
        if thresholds.get("pdfRender") and any(annotations["baseline"]["pages"]):
            try: metrics["annotationRaster"] = native("pdf-annotation-compare", left, right)
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
                return "WARN", ["PDF annotation raster comparison unavailable: " + str(error)], metrics
            if not metrics["annotationRaster"].get("sameGeometry"):
                return "FAIL", ["PDF annotation raster geometry changed"], metrics
            if picture_below_threshold(metrics["annotationRaster"], thresholds):
                return "FAIL", ["PDF annotation raster similarity below threshold"], metrics
        if annotations["baseline"] != annotations["candidate"]:
            reasons.append("PDF annotation appearance resources differ" + ("; normal screen appearance checked separately" if thresholds.get("pdfRender") else "; rendering not requested"))
        if byte_equal: return "PASS", [], metrics
    elif kind == "text":
        try:
            ta, pa = document_text(a["text"], left.suffix.lower() if left else "")
            tb, pb = document_text(b["text"], right.suffix.lower() if right else "")
            if left and right and left.suffix.lower() == right.suffix.lower() == ".rst":
                ta, tb, deltas = rst_dimensions(ta, tb)
                metrics["dimensionDeltaPoints"] = deltas
            metrics["textRatio"] = ratio(ta, tb)
            problem = pictures_equal(pa, pb, thresholds, metrics.setdefault("pictures", {}))
            if problem: return "FAIL", [problem], metrics
            if any(p.get("generatedCoverTextMatches") for p in metrics["pictures"].values()):
                reasons.append("Generated Calibre cover layout differs; recognized text matches")
        except (OSError, RuntimeError, ValueError) as error:
            return "WARN", ["Embedded picture comparison unavailable: " + str(error)], metrics
        if metrics["textRatio"] < thresholds["text"]:
            return "FAIL", ["Normalized text similarity below threshold"], metrics
        if ta == tb and not pa: return "PASS", [], metrics
    elif kind in ("archive", "zip"):
        ea, eb = ma["entries"], mb["entries"]
        if kind == "archive" and left and right:
            ta, tb = tar_entries(left), tar_entries(right)
            if ta is not None and tb is not None:
                equal = ta == tb
                return ("PASS" if equal else "FAIL"), ([] if equal else ["TAR member names/types/content changed"]), metrics
        if [e["name"] for e in ea] != [e["name"] for e in eb]:
            return "FAIL", ["Container entry names changed"], metrics
        if kind == "archive":
            if not entries_equal(ea, eb): return "FAIL", ["Archive entry content hashes changed"], metrics
            return "PASS", [], metrics
        else:
            parts_a, parts_b = ma.get("keyParts", {}), mb.get("keyParts", {})
            part_scores = {}
            for x, y in zip(ea, eb):
                if x["sha256"] == y["sha256"]: continue
                name = x["name"]
                if name not in parts_a or name not in parts_b:
                    if Path(name).suffix.lower() in (".jpg", ".jpeg", ".png", ".gif", ".webp", ".tiff", ".bmp", ".svg") and left and right:
                        try:
                            with zipfile.ZipFile(left) as za, zipfile.ZipFile(right) as zb:
                                scores = picture_scores(za.read(name), zb.read(name))
                            metrics.setdefault("pictures", {})[name] = scores
                            if not scores.get("sameGeometry"): return "FAIL", ["Embedded picture geometry changed: " + name], metrics
                            if picture_below_threshold(scores, thresholds):
                                return "FAIL", ["Embedded picture similarity below threshold: " + name], metrics
                            reasons.append(("Generated Calibre cover layout differs; recognized text matches: " if scores.get("generatedCoverTextMatches") else "Embedded picture encoding changed: ") + name)
                            continue
                        except (OSError, RuntimeError, ValueError) as error:
                            return "WARN", ["Embedded picture comparison unavailable: " + str(error)], metrics
                    return "FAIL", ["Binary document part changed: " + name], metrics
                ta, tb = xml_text(parts_a[name], name), xml_text(parts_b[name], name)
                score = ratio(ta, tb)
                part_scores[name] = score
                if score < thresholds["text"]:
                    metrics["partRatios"] = part_scores
                    return "FAIL", ["Document XML similarity below threshold: " + name], metrics
            metrics["partRatios"] = part_scores
            if not reasons and all(score == 1 for score in part_scores.values()): return "PASS", [], metrics
    elif kind == "media":
        if len(ma["streams"]) != len(mb["streams"]): return "FAIL", ["Media stream count changed"], metrics
        for x, y in zip(ma["streams"], mb["streams"]):
            for key in ("codec_type", "codec_name", "width", "height", "sample_rate", "channels", "sample_fmt", "pix_fmt", "r_frame_rate"):
                if x.get(key) != y.get(key): return "FAIL", ["Media stream field changed: " + key], metrics
        duration_a, duration_b = ma["duration"], mb["duration"]
        metrics["durationRelativeError"] = abs(duration_a-duration_b)/max(duration_a, 1e-6)
        if metrics["durationRelativeError"] > 0.02:
            return "FAIL", ["Media duration changed by more than 2%"], metrics
        if left and right:
            try:
                if media_packets(left) == media_packets(right): return "PASS", [], metrics
                reasons.append("Encoded media packets or timing differ; structure is within thresholds")
            except (OSError, RuntimeError, ValueError) as error:
                reasons.append("Media packet comparison unavailable: " + str(error))
    elif kind == "font":
        if ma != mb: return "FAIL", ["Font table tags or glyph count changed"], metrics
    else:
        return "WARN", ["Binary bytes differ; no semantic inspector for this type"], metrics
    return "WARN", reasons or ["Bytes differ; semantic comparison is within thresholds"], metrics


def compare_case(a, b, left_root, right_root, thresholds):
    messages, output_results = [], []
    status = "PASS"
    def record(level, message):
        nonlocal status
        if {"PASS": 0, "WARN": 1, "FAIL": 2}[level] > {"PASS": 0, "WARN": 1, "FAIL": 2}[status]: status = level
        messages.append(message)
    if a.get("harnessError") or b.get("harnessError"):
        record("FAIL", "Harness/transport error: " + str(a.get("harnessError") or b.get("harnessError")))
    if a["state"] != b["state"]: record("FAIL", f"Job state: {a['state']} → {b['state']}")
    fields = lambda r: [(f["source"], f["state"], f.get("errorKey"), f.get("outputs", [])) for f in r.get("files", [])]
    if fields(a) != fields(b): record("FAIL", "Per-file state, errorKey, output assignment or names changed")
    if not a.get("sourcePreserved", True) or not b.get("sourcePreserved", True): record("FAIL", "An input was modified")
    if b.get("keepDatesDeltaSeconds", 0) > 1: record("FAIL", "keepDates did not preserve source modification time")
    oa = {o["name"]: o for o in a.get("outputs", [])}
    ob = {o["name"]: o for o in b.get("outputs", [])}
    if len(a.get("outputs", [])) != len(b.get("outputs", [])) or oa.keys() != ob.keys():
        record("FAIL", "Output count or relative names changed")
    for name in sorted(oa.keys() & ob.keys()):
        x, y = oa[name], ob[name]
        left, right = left_root / x["artifact"], right_root / y["artifact"]
        if not left.resolve().is_relative_to(left_root) or not right.resolve().is_relative_to(right_root):
            record("FAIL", "Artifact path escapes run directory")
            continue
        if not left.exists() or not right.exists():
            record("FAIL", "Captured artifact is missing: " + name)
            continue
        for item, path in ((x, left), (y, right)):
            if path.is_file() and sha256(path) != item["fingerprint"].get("sha256"):
                record("FAIL", "Captured artifact hash mismatch: " + name)
        level, reasons, metrics = compare_output(x["fingerprint"], y["fingerprint"], left, right, thresholds)
        if level != "PASS": record(level, name + ": " + "; ".join(reasons))
        output_result = {"name": name, "status": level, "reasons": reasons, "metrics": metrics}
        if left.suffix.lower() in (".html", ".htm", ".md"):
            output_result["imageReferences"] = {
                "baseline": document_image_references(decode(left.read_bytes()), left.suffix.lower(), left, left_root),
                "candidate": document_image_references(decode(right.read_bytes()), right.suffix.lower(), right, right_root)}
        output_results.append(output_result)
    if [(e["name"], e["sha256"]) for e in a.get("sidecars", [])] != [(e["name"], e["sha256"]) for e in b.get("sidecars", [])]:
        record("WARN", "Sidecar names/content differ; inspect captured artifacts")
    return {"id": a["id"], "status": status, "engineHint": a["engineHint"], "targetFormat": a["targetFormat"],
            "baselineState": a["state"], "candidateState": b["state"], "reasons": messages, "outputs": output_results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--psnr", type=float, default=30)
    parser.add_argument("--ssim", type=float, default=0.95)
    parser.add_argument("--text-ratio", type=float, default=0.95)
    parser.add_argument("--pdf-render", action="store_true", help="Also compare PDF media-box page content rendered at 144 DPI")
    parser.add_argument("--semantic-tools", type=Path, help="JSON mapping convertlit/dwgread to absolute path and sha256 pins")
    parser.add_argument("--case", dest="case_ids", action="append", help="Inspect only this retained case ID (repeatable); missing IDs fail")
    args = parser.parse_args()
    roots = [args.baseline.resolve(strict=True), args.candidate.resolve(strict=True)]
    runs = [json.loads((r / "run.json").read_text()) for r in roots]
    mapped = [{r["id"]: r for r in run["results"]} for run in runs]
    if any(len(m) != len(run["results"]) for m, run in zip(mapped, runs)):
        raise ValueError("Duplicate case IDs in run")
    thresholds = {"psnr": args.psnr, "ssim": args.ssim, "text": args.text_ratio}
    if args.semantic_tools: thresholds["semanticTools"] = json.loads(args.semantic_tools.read_text())
    if args.pdf_render: thresholds["pdfRender"] = True
    results = []
    plans = [json.loads((r / "cases.json").read_text()) for r in roots]
    plan_maps = [{c["id"]: c for c in p} for p in plans]
    all_ids = mapped[0].keys() | mapped[1].keys() | plan_maps[0].keys() | plan_maps[1].keys()
    if args.case_ids: all_ids = set(args.case_ids)
    for identifier in sorted(all_ids):
        a, b = (m.get(identifier) for m in mapped)
        if a is None or b is None:
            result = {"id": identifier, "status": "FAIL", "engineHint": (a or b or {}).get("engineHint", "unknown"),
                      "targetFormat": (a or b or {}).get("targetFormat", "unknown"),
                      "reasons": ["Case result missing from baseline or candidate"]}
        else:
            result = compare_case(a, b, *roots, thresholds)
            if plan_maps[0].get(identifier) != plan_maps[1].get(identifier):
                result["status"] = "FAIL"
                result["reasons"].append("Case definitions differ; replay baseline cases.json")
        results.append(result)
    summaries = {}
    for field in ("engineHint", "targetFormat"):
        grouped = defaultdict(Counter)
        for result in results: grouped[result[field]][result["status"]] += 1
        summaries[field] = {k: dict(v) for k, v in sorted(grouped.items())}
    pdf_limit = ("PDF media-box page content and Poppler page composites including annotations are separately raster-compared at 144 DPI. " if args.pdf_render else
                 "Empty-text PDF page content compares geometry only; annotation appearance is not rendered. ")
    pdf_limit += "Annotation objects/actions/form values are compared, including hidden annotations; rendering uses normal screen appearance without interaction/scripts. "
    report = {"schema": 1, "baseline": str(roots[0]), "candidate": str(roots[1]), "thresholds": thresholds,
              "selectedCaseIDs": sorted(args.case_ids) if args.case_ids else None,
              "inspectionPolicy": {"tcr": "exact-decoded-bytes", "imageReferences": "diagnostic-only",
                                   "binaryReadbackVersion": 1, "binaryReadbackFormats": sorted(READBACK_FORMATS),
                                   "pdfAnnotationVersion": 1, "pdfAnnotationRasterVersion": 1 if args.pdf_render else None,
                                   "pdfRasterDpi": 144 if args.pdf_render else None, "pdfRasterVersion": 2 if args.pdf_render else None},
              "summary": dict(Counter(r["status"] for r in results)), "groups": summaries, "cases": results,
              "limits": "Engine groups are inferred. Media compares structure/duration, fonts compare table tags/glyph count. " + pdf_limit +
                        "Listed binary formats are independently inspected even when bytes match; per-output coverage/limits apply. " +
                        "Binary image checks use unchanged pixel thresholds without generated-cover exemptions. Unsupported readback produces WARN, invalid candidate parsing produces FAIL."}
    write_json(args.out / "report.json", report)
    lines = ["# Engine differential report", "", " · ".join(f"{k}: {v}" for k, v in sorted(report["summary"].items())),
             "", f"Thresholds: PSNR ≥ {args.psnr} dB; global luminance SSIM-like ≥ {args.ssim}; text ratio ≥ {args.text_ratio}; PDF sizes ±1pt; media duration ±2%.", "", report["limits"], ""]
    for field, label in (("engineHint", "Engine family (inferred)"), ("targetFormat", "Target")):
        lines += ["## " + label, "", "| Name | PASS | WARN | FAIL |", "|---|---:|---:|---:|"]
        for key, counts in summaries[field].items():
            lines.append(f"| {key} | {counts.get('PASS', 0)} | {counts.get('WARN', 0)} | {counts.get('FAIL', 0)} |")
        lines.append("")
    lines += ["## Cases", "", "| Case | Result | Details |", "|---|---|---|"]
    for result in results:
        detail = "; ".join(result["reasons"]).replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {result['id']} | {result['status']} | {detail} |")
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(report["summary"], sort_keys=True))
    return 1 if any(r["status"] == "FAIL" for r in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
