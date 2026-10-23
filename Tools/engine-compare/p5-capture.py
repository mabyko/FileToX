#!/usr/bin/env python3
"""Capture P5 expected outputs from the installed C# host using isolated data directories.

First export fresh builder inputs:
  FTX_P5_EXPORT_DIR=/tmp/ftx-p5-inputs swift test --filter \
    'OfficeComparisonTests|OoxmlVariantTests/testCSharpBaselinePackages|XlsRecordTests/testBuiltinXlsFormatsAndDateSystemsMatchCSharpBaseline'
Then regenerate the committed comparison fixtures:
  python3 Tools/engine-compare/p5-capture.py --inputs /tmp/ftx-p5-inputs

To refresh the optional route fixture too, export LibreOffice inputs with
FILETOX_LIBREOFFICE=/path/LibreOffice.app and --filter
LibreOfficeFormatTests/testRealRoutesMatchCSharpBaseline, then pass
--libreoffice /path/LibreOffice.app to this script. The C# planner chooses
its cheaper built-in spreadsheet engine for XLS -> XLSX; that fixture
cross-checks displayed values rather than LibreOffice's equivalent format-code escaping.

Only ZIP payloads are compared: compression streams, timestamps and ZIP metadata vary by implementation.
No user data or installed application files are changed. Python's standard library is sufficient.
"""
import argparse
import base64
import csv
import html
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "Tests/Engine/Office/Fixtures"


def number_workbook(path, examples):
    ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    formats = list(dict.fromkeys(e["format"] for e in examples))
    esc = lambda s: html.escape(str(s), quote=True)
    relationships = lambda items: '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + ''.join(
        f'<Relationship Id="{i}" Type="{rel}/{t}" Target="{p}"/>' for i, t, p in items) + '</Relationships>'
    parts = {
        "_rels/.rels": relationships([("main", "officeDocument", "xl/workbook.xml")]),
        "xl/workbook.xml": f'<workbook xmlns="{ns}" xmlns:r="{rel}"><sheets><sheet name="Formats" sheetId="1" r:id="sheet"/></sheets></workbook>',
        "xl/_rels/workbook.xml.rels": relationships([("sheet", "worksheet", "worksheets/sheet1.xml"), ("styles", "styles", "styles.xml")]),
        "xl/styles.xml": f'<styleSheet xmlns="{ns}"><numFmts count="{len(formats)}">' + ''.join(
            f'<numFmt numFmtId="{164+i}" formatCode="{esc(f)}"/>' for i, f in enumerate(formats)) +
            '</numFmts><fonts count="1"><font/></fonts><fills count="1"><fill/></fills><borders count="1"><border/></borders><cellXfs count="' + str(len(formats)) + '">' + ''.join(
                f'<xf numFmtId="{164+i}" fontId="0" fillId="0" borderId="0"/>' for i in range(len(formats))) + '</cellXfs></styleSheet>',
        "xl/worksheets/sheet1.xml": f'<worksheet xmlns="{ns}"><sheetData>' + ''.join(
            f'<row r="{i+1}"><c r="A{i+1}" s="{formats.index(e["format"])}"><v>{e["value"]}</v></c></row>' for i, e in enumerate(examples)) + '</sheetData></worksheet>',
        "[Content_Types].xml": '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>' + ''.join(
            f'<Override PartName="/{p}" ContentType="application/vnd.openxmlformats-officedocument.{t}+xml"/>' for p, t in [
                ("xl/workbook.xml", "spreadsheetml.sheet.main"), ("xl/styles.xml", "spreadsheetml.styles"), ("xl/worksheets/sheet1.xml", "spreadsheetml.worksheet")]) + '</Types>',
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, xml in parts.items():
            archive.writestr(name, xml)


class Host:
    def __init__(self, helper, work):
        (work / "tmp").mkdir()
        self.stderr = (work / "stderr.log").open("wb")
        self.proc = subprocess.Popen([str(helper), "--data", str(work / "core"), "--engines", str(work / "engines"), "--lang", "en"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                     env=dict(os.environ, TMPDIR=str(work / "tmp") + "/"))
        self.next_id = 0
        self.receive(lambda m: m.get("event") == "hello")

    def receive(self, predicate):
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("Host ended; inspect its stderr")
            message = json.loads(line)
            if predicate(message):
                return message

    def call(self, method, params):
        self.next_id += 1
        rid = str(self.next_id)
        self.proc.stdin.write((json.dumps({"v": 1, "id": rid, "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        result = self.receive(lambda m: m.get("id") == rid)
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["result"]

    def convert(self, input_path, target):
        job_id = self.call("job.start", {"paths": [str(input_path)], "targetFormat": target})["jobId"]
        job = self.receive(lambda m: m.get("event") == "job.finished" and m["data"]["jobId"] == job_id)["data"]
        if job["state"] != "completed":
            raise RuntimeError(job)
        return [Path(o["path"]) for f in job["files"] for o in f.get("outputs", [])]

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--helper", type=Path, default=Path("/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine"))
    parser.add_argument("--libreoffice", type=Path, help="Existing verified LibreOffice.app or program folder for optional route comparisons")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ftx-p5-baseline-") as temp:
        root = Path(temp)
        host = Host(args.helper, root)
        try:
            if args.libreoffice:
                library = host.call("library.get", {})
                settings = library["settings"]
                settings["engineOwnCopies"] = {"libreoffice": str(args.libreoffice.resolve())}
                settings["enginePriority"] = ["libreoffice"] + [e for e in settings.get("enginePriority", []) if e != "libreoffice"]
                host.call("settings.save", {"baseRevision": library["revision"], "settings": settings})
            examples = json.loads((FIXTURES / "number-format-baseline.json").read_text())
            number_input = root / "formats.xlsx"
            number_workbook(number_input, examples)
            output = host.convert(number_input, "tsv")[0]
            rows = list(csv.reader(io.StringIO(output.read_text(encoding="utf-8-sig"), newline=""), delimiter="\t"))
            assert len(rows) == len(examples), (len(rows), len(examples))
            for example, row in zip(examples, rows):
                example["text"] = row[0] if row else ""
            (FIXTURES / "number-format-baseline.json").write_text(json.dumps(examples, ensure_ascii=False, indent=2) + "\n")
            payloads = {}
            for source in ["csv", "tsv", "xlsx", "ods", "xls"]:
                for target in ["xlsx", "ods", "csv", "tsv"]:
                    if source == target:
                        continue
                    key = source + "-" + target
                    folder = root / key
                    folder.mkdir()
                    original = args.inputs / (("table" if source in ["csv", "tsv"] else "sales") + "." + source)
                    input_path = folder / original.name
                    input_path.write_bytes(original.read_bytes())
                    payloads[key] = []
                    for output in host.convert(input_path, target):
                        record = {"suffix": output.name[len(input_path.stem):]}
                        if target in ["xlsx", "ods"]:
                            with zipfile.ZipFile(output) as archive:
                                record["entries"] = {n: base64.b64encode(archive.read(n)).decode() for n in archive.namelist()}
                        else:
                            record["bytes"] = base64.b64encode(output.read_bytes()).decode()
                        payloads[key].append(record)
            (FIXTURES / "conversion-baseline.json").write_text(json.dumps(payloads, ensure_ascii=False, indent=2) + "\n")
            ooxml = {}
            for case in sorted((args.inputs / "ooxml-cases").glob("*")):
                source, target, *_ = case.name.split("-")
                original = case / ("sample." + source)
                folder = root / case.name
                folder.mkdir()
                input_path = folder / original.name
                input_path.write_bytes(original.read_bytes())
                output = host.convert(input_path, target)[0]
                with zipfile.ZipFile(output) as archive:
                    ooxml[case.name] = {"from": source, "to": target, "entries": {n: base64.b64encode(archive.read(n)).decode() for n in archive.namelist()}, "order": archive.namelist()}
            if ooxml:
                (FIXTURES / "ooxml-baseline.json").write_text(json.dumps(ooxml, ensure_ascii=False, indent=2) + "\n")
            xls_records = {}
            for case in sorted((args.inputs / "xls-record-cases").glob("*")):
                folder = root / case.name
                folder.mkdir()
                input_path = folder / "sample.xls"
                input_path.write_bytes((case / "sample.xls").read_bytes())
                csv_output = host.convert(input_path, "csv")[0]
                xlsx_output = host.convert(input_path, "xlsx")[0]
                with zipfile.ZipFile(xlsx_output) as archive:
                    xls_records[case.name] = {"csv": base64.b64encode(csv_output.read_bytes()).decode(), "entries": {n: base64.b64encode(archive.read(n)).decode() for n in archive.namelist()}}
            if xls_records:
                (FIXTURES / "xls-record-baseline.json").write_text(json.dumps(xls_records, ensure_ascii=False, indent=2) + "\n")
            libreoffice = {}
            if args.libreoffice:
                for case in sorted((args.inputs / "libreoffice-cases").glob("*")):
                    source, target = case.name.split("-")
                    folder = root / ("lo-" + case.name)
                    folder.mkdir()
                    input_path = folder / ("sample." + source)
                    input_path.write_bytes((case / input_path.name).read_bytes())
                    output = host.convert(input_path, target)[0]
                    libreoffice[case.name] = base64.b64encode(output.read_bytes()).decode()
                if libreoffice:
                    (FIXTURES / "libreoffice-baseline.json").write_text(json.dumps(libreoffice, ensure_ascii=False, indent=2) + "\n")
            print(f"Captured {len(examples)} formatted cells, {len(payloads)} spreadsheet, {len(ooxml)} OOXML, {len(xls_records)} XLS date-system fixtures, {len(libreoffice)} optional route conversions.")
        finally:
            host.close()


if __name__ == "__main__":
    main()
