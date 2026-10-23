#!/usr/bin/env python3
"""Capture catalog and extension-based selection behavior, without converting."""
import argparse
import json
from pathlib import Path
import sys
import tempfile

# -I deliberately excludes the script directory; import only our adjacent modules.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from hostwire import Host, add_host_arguments, own_copies, write_json


def normalize(value, root):
    if isinstance(value, str):
        return value.replace(str(root), "$INPUT")
    if isinstance(value, list):
        return [normalize(v, root) for v in value]
    if isinstance(value, dict):
        return {k: normalize(v, root) for k, v in value.items()}
    return value


def capture(host):
    catalog = host.call("catalog.get")
    with tempfile.TemporaryDirectory(prefix="matrix-", dir=host.root) as temporary:
        root = Path(temporary)
        selections, files = {}, {}
        for fmt in sorted(catalog["formats"], key=lambda f: f["id"]):
            if fmt["isVirtual"]:
                continue
            extension = fmt["extensions"][0].lstrip(".")
            path = root / (fmt["id"] + "." + extension)
            path.touch()
            files[fmt["id"]] = path
            selections[fmt["id"]] = normalize(host.call("selection.resolve", paths=[str(path)]), root)
        second = root / "second.png"
        second.touch()
        unknown, folder = root / "unknown.unknownext", root / "folder"
        unknown.touch()
        folder.mkdir()
        groups = {"two-images": [files["png"], second],
                  "image-and-pdf": [files["png"], files["pdf"]],
                  "unknown-and-folder": [unknown, folder], "archive": [files["zip"]]}
        multi = {key: normalize(host.call("selection.resolve", paths=[str(p) for p in paths]), root)
                 for key, paths in sorted(groups.items())}
    return {"schema": 1, "catalog": catalog, "selections": selections, "multi": multi,
            "summary": {"formats": len(selections),
                        "availablePairs": sum(t["available"] for s in selections.values() for t in s["targets"]),
                        "availableTargetFormats": sorted({t["formatId"] for s in selections.values()
                                                          for t in s["targets"] if t["available"]}),
                        "availableEngines": [e["id"] for e in catalog["engines"] if e["available"]]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_host_arguments(parser)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    copies = own_copies(args)
    with Host(args.host, copies=copies, stderr_path=args.out.with_suffix(".stderr.log")) as host:
        result = capture(host)
        result["configuration"] = {"ownCopies": copies}
        write_json(args.out, result)
        print(json.dumps(result["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
