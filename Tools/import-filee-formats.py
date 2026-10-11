#!/usr/bin/env python3
"""Export the pinned format catalog to Resources/FileeFormats.json and docs/formats.md.

Offline and deterministic: reads the pinned Filee checkout as text (no C# is executed), fails closed on any
grammar it does not recognise, and keeps the original order.

  python3 -I Tools/import-filee-formats.py              # write JSON + docs
  python3 -I Tools/import-filee-formats.py --check      # exit 1 if either generated file is stale
  python3 -I Tools/import-filee-formats.py --selftest   # inline unit checks of the parser/exporter

Grammar accepted (anything else raises ImportError_):
  FileFormat.cs:      the exact record signature with `bool Writable = true`, and `enum FormatCategory { A, B, }`
  FormatRegistry.cs:  `public const string Folder = "x";` and
                      Known = [ new(<"id"|Folder>, "Display", FormatCategory.X, ["ext", ...] [, Writable: true|false]), ... ];
                      with // comments and blank lines between records. No escapes in strings, no /* */ comments.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PINNED_COMMIT = "21fdd05ef7181b032ed83ec895cc9bbc4b198985"
REPOSITORY = "https://github.com/KnifeLemon/Filee"
REGISTRY_REL = "src/Filee.Core/Formats/FormatRegistry.cs"
MODEL_REL = "src/Filee.Core/Formats/FileFormat.cs"
DEFAULT_SOURCE = ROOT / ".reference/Filee" / REGISTRY_REL
DEFAULT_OUTPUT = ROOT / "Resources/FileeFormats.json"
DEFAULT_DOCS = ROOT / "docs/formats.md"

RECORD_SIGNATURE = re.compile(
    r"public\s+sealed\s+record\s+FileFormat\(\s*string\s+Id,\s*string\s+DisplayName,\s*FormatCategory\s+Category,"
    r"\s*IReadOnlyList<string>\s+Extensions,\s*bool\s+Writable\s*=\s*true\)")
STR = r'"[^"\\\n]*"'
RECORD = re.compile(
    r"new\(\s*(?P<id>" + STR + r"|[A-Za-z_]\w*)\s*,\s*(?P<name>" + STR + r")\s*,\s*FormatCategory\.(?P<cat>\w+)\s*,"
    r"\s*\[(?P<ext>[^\[\]]*)\]\s*(?:,\s*Writable:\s*(?P<writable>true|false)\s*)?\)")
EXT_LIST = re.compile(r"\s*" + STR + r"(?:\s*,\s*" + STR + r")*\s*,?\s*")
AFTER_RECORD = re.compile(r"\s*(?:,|\Z)")


class ImportError_(Exception):
    pass


def _fail(msg):
    raise ImportError_(msg)


def _unquote(token):
    return token[1:-1]


def _strip_comments(text):
    if "/*" in text:
        _fail("block comments are not part of the supported grammar")
    return re.sub(STR + r"|//[^\n]*", lambda m: "" if m.group().startswith("//") else m.group(), text)


def parse_categories(model_src):
    text = _strip_comments(model_src)
    if not RECORD_SIGNATURE.search(text):
        _fail("FileFormat record signature changed (parameter order or Writable default)")
    m = re.search(r"public\s+enum\s+FormatCategory\s*\{(?P<body>[^{}]*)\}", text)
    if not m:
        _fail("FormatCategory enum not found")
    names = [n.strip() for n in m.group("body").split(",")]
    if names and names[-1] == "":
        names.pop()
    if not names or not all(re.fullmatch(r"[A-Za-z_]\w*", n) for n in names) or len(set(names)) != len(names):
        _fail("FormatCategory enum has unsupported members")
    return names


def parse_known(registry_src, categories):
    text = _strip_comments(registry_src)
    const = re.findall(r'public\s+const\s+string\s+Folder\s*=\s*(' + STR + r")\s*;", text)
    if len(const) != 1:
        _fail("expected exactly one `public const string Folder = \"...\";`")
    folder_id = _unquote(const[0])
    block = re.search(r"\bKnown\s*\{\s*get;\s*\}\s*=\s*\[(?P<body>.*?)\n\s*\];", text, re.S)
    if not block:
        _fail("Known = [ ... ]; block not found")
    body = block.group("body")

    formats, pos, explicit = [], 0, 0
    while True:
        pos = re.compile(r"\s*").match(body, pos).end()
        if pos == len(body):
            break
        m = RECORD.match(body, pos)
        if not m:
            _fail("unrecognised grammar at: " + body[pos:pos + 80].replace("\n", " "))
        raw_id = m.group("id")
        if raw_id.startswith('"'):
            fid = _unquote(raw_id)
        elif raw_id == "Folder":
            fid = folder_id
        else:
            _fail("unsupported id expression " + raw_id)
        if not fid or fid != fid.lower():
            _fail("id must be non-empty lower-case: %r" % fid)
        if m.group("cat") not in categories:
            _fail("unknown category %s for %s" % (m.group("cat"), fid))
        if not EXT_LIST.fullmatch(m.group("ext")):
            _fail("unsupported extension list for %s" % fid)
        explicit += m.group("writable") is not None
        formats.append({
            "id": fid,
            "displayName": _unquote(m.group("name")),
            "category": m.group("cat"),
            "extensions": [_unquote(t) for t in re.findall(STR, m.group("ext"))],
            "writable": m.group("writable") != "false",
            "isVirtual": fid == folder_id,
        })
        pos = AFTER_RECORD.match(body, m.end())
        if not pos:
            _fail("expected `,` after record %s" % fid)
        pos = pos.end()

    # Independent cross-checks: raw token counts must agree with what the record parser produced.
    n = len(formats)
    for label, found, parsed in (("new(", len(re.findall(r"\bnew\s*\(", body)), n),
                                 ("FormatCategory.", body.count("FormatCategory."), n),
                                 ("Writable:", body.count("Writable:"), explicit)):
        if found != parsed:
            _fail("token count mismatch for %s: raw %d vs parsed %d" % (label, found, parsed))
    if body.count("Writable: false") != sum(1 for f in formats if not f["writable"]):
        _fail("read-only count mismatch")
    if not n:
        _fail("no formats parsed")

    seen_id, seen_ext = {}, {}
    for f in formats:
        if f["id"] in seen_id:
            _fail("duplicate id " + f["id"])
        seen_id[f["id"]] = True
        for e in f["extensions"]:
            if e == "":
                if not f["isVirtual"]:
                    _fail("empty extension on non-virtual format " + f["id"])
                continue
            if e.lower() in seen_ext:
                _fail("duplicate extension %r (%s, %s)" % (e, seen_ext[e.lower()], f["id"]))
            seen_ext[e.lower()] = f["id"]
    return formats


def build_export(registry_src, model_src, commit=PINNED_COMMIT):
    formats = parse_known(registry_src, parse_categories(model_src))
    return {
        "schemaVersion": 1,
        "upstream": {"repository": REPOSITORY, "commit": commit, "source": REGISTRY_REL, "license": "MIT"},
        "formats": formats,
    }


def to_json(export):
    return json.dumps(export, indent=2, ensure_ascii=False) + "\n"


def counts(export, categories):
    formats = export["formats"]
    per_cat = {c: [f for f in formats if f["category"] == c] for c in categories}
    return {
        "total": len(formats),
        "actual": sum(1 for f in formats if not f["isVirtual"]),
        "virtual": sum(1 for f in formats if f["isVirtual"]),
        "readonly": sum(1 for f in formats if not f["writable"]),
        "extensions": sum(1 for f in formats for e in f["extensions"] if e),
        "categories": {c: len(v) for c, v in per_cat.items()},
    }


def to_markdown(export, categories):
    u, c = export["upstream"], counts(export, categories)
    out = [
        "# Filee 형식 카탈로그",
        "",
        "<!-- Tools/import-filee-formats.py가 생성한다. 직접 수정하지 말고 스크립트를 다시 실행한다. -->",
        "",
        "Filee `FormatRegistry.Known`이 등록한 형식의 정적 목록이다. **이 목록은 카탈로그일 뿐 실행 시점의 변환 능력이 아니다.**"
        " 어떤 형식 사이의 변환이 실제로 가능한지는 엔진 설치 상태, `ConverterCatalog`, `RoutePlanner`가 결정하며,"
        " 이 문서와 `Resources/FileeFormats.json`은 그 판단에 쓰지 않는다. 읽기 전용은 Filee가 변환 대상(출력)으로 제공하지 않는 형식이다.",
        "",
        "## 출처",
        "",
        "- 저장소: %s" % u["repository"],
        "- 커밋: `%s`" % u["commit"],
        "- 원본 파일: `%s` (분류 정의는 `%s`)" % (u["source"], MODEL_REL),
        "- 라이선스: %s (`Resources/Filee.LICENSE`)" % u["license"],
        "- 생성기: `Tools/import-filee-formats.py` → `Resources/FileeFormats.json`",
        "- 재생성·`--check`에는 위 커밋의 `.reference/Filee` 체크아웃이 필요하다. 앱 빌드에는 필요하지 않다.",
        "",
        "## 요약",
        "",
        "- 전체 %d개 = 실제 형식 %d개 + 가상 `folder` %d개" % (c["total"], c["actual"], c["virtual"]),
        "- 읽기 전용 %d개, 확장자 %d개(중복 없음, 가상 `folder`의 빈 확장자 제외), 분류 %d개"
        % (c["readonly"], c["extensions"], len(categories)),
        "",
        "| 분류 | 형식 수 |",
        "| --- | ---: |",
    ]
    out += ["| %s | %d |" % (name, n) for name, n in c["categories"].items()]
    out += ["", "가상 `folder`는 \"Extract\" 프리셋의 출력(압축 해제 폴더)을 나타내는 의사 형식이며 Archive 분류에 속한다."
            " 확장자 목록은 빈 문자열 하나다.", ""]
    for cat in categories:
        out += ["## %s" % cat, "", "| id | 이름 | 확장자 | 비고 |", "| --- | --- | --- | --- |"]
        for f in export["formats"]:
            if f["category"] != cat:
                continue
            exts = ", ".join("`.%s`" % e for e in f["extensions"] if e) or "(없음)"
            notes = [n for n, on in (("가상", f["isVirtual"]), ("읽기 전용", not f["writable"])) if on]
            out.append("| `%s` | %s | %s | %s |" % (f["id"], f["displayName"].replace("|", "\\|"), exts, ", ".join(notes)))
        out.append("")
    return "\n".join(out)


def load_sources(source):
    source = Path(source)
    model = source.with_name(Path(MODEL_REL).name)
    git = lambda *a: subprocess.run(["git", "--no-replace-objects", "-C", str(source.parent), *a], capture_output=True, text=True, encoding="utf-8")
    head = git("rev-parse", "HEAD")
    if head.returncode != 0 or head.stdout.strip() != PINNED_COMMIT:
        _fail("source is not a git checkout at pinned commit %s" % PINNED_COMMIT)
    contents = []
    for file, relative in ((source, REGISTRY_REL), (model, MODEL_REL)):
        pinned = git("rev-parse", PINNED_COMMIT + ":" + relative)
        current = git("hash-object", "--no-filters", str(file.resolve()))
        if pinned.returncode != 0 or current.returncode != 0 or current.stdout != pinned.stdout:
            _fail("%s differs from the pinned source" % file)
        contents.append(file.read_text(encoding="utf-8"))
    return tuple(contents)


def selftest():
    model = "public enum FormatCategory { Image, Pdf, Archive, }\n" \
            "public sealed record FileFormat(string Id, string DisplayName, FormatCategory Category, " \
            "IReadOnlyList<string> Extensions, bool Writable = true) { }"
    reg = '''public const string Folder = "folder";
    public static X Known { get; } =
    [
        // comment with new( and "quotes"
        new("png", "PNG", FormatCategory.Image, ["png"]),
        new("raw", "RAW", FormatCategory.Image,
            ["dng", "cr2"], Writable: false),
        new("pdf", "P|DF", FormatCategory.Pdf, ["pdf"], Writable: true),
        new("tgz", "TAR.GZ", FormatCategory.Archive, ["tar.gz", "tgz"]),
        new(Folder, "Folder", FormatCategory.Archive, [""]),
    ];'''
    cats = parse_categories(model)
    exp = build_export(reg, model)
    f = {x["id"]: x for x in exp["formats"]}
    assert [x["id"] for x in exp["formats"]] == ["png", "raw", "pdf", "tgz", "folder"]  # order kept
    assert f["png"]["writable"] is True and f["pdf"]["writable"] is True  # default / explicit true
    assert f["raw"]["writable"] is False and f["raw"]["extensions"] == ["dng", "cr2"]  # explicit false, multi-line
    assert f["tgz"]["extensions"] == ["tar.gz", "tgz"]  # aliases + compound
    assert f["folder"]["isVirtual"] and f["folder"]["extensions"] == [""] and not f["png"]["isVirtual"]
    c = counts(exp, cats)
    assert (c["total"], c["actual"], c["virtual"], c["readonly"], c["extensions"]) == (5, 4, 1, 1, 6), c
    assert c["categories"] == {"Image": 2, "Pdf": 1, "Archive": 2}, c
    assert to_json(exp) == to_json(build_export(reg, model))  # deterministic
    assert to_markdown(exp, cats) == to_markdown(build_export(reg, model), cats)
    assert json.loads(to_json(exp)) == exp

    def rejects(old, new, src=reg, mdl=model):
        try:
            build_export(src.replace(old, new), mdl)
        except ImportError_:
            return
        raise AssertionError("accepted: " + new)

    rejects('new("pdf", "P|DF", FormatCategory.Pdf, ["pdf"], Writable: true)',
            'new("pdf", "P|DF", FormatCategory.Pdf, ["pdf"], Writable: true, Foo: 1)')  # new named arg
    rejects('["png"]', '["png"].ToArray()')
    rejects('"pdf", "P|DF"', '"png", "P|DF"')  # duplicate id
    rejects('["pdf"]', '["PNG"]')  # duplicate extension, case-insensitive
    rejects("FormatCategory.Pdf", "FormatCategory.Nope")  # unknown category
    rejects('new("png"', 'new(Other')  # unsupported id expression
    rejects('"tar.gz", "tgz"]', '"tar.gz", "tgz"],')  # stray comma pair -> unrecognised
    rejects("[\"png\"]),", "[\"png\"])")  # missing comma between records
    rejects("// comment", "/* comment */")
    rejects('new("png"', 'new("PNG"')  # upper-case id
    rejects("];", "]")  # no block terminator
    for bad_model in (model.replace("Writable = true", "Writable = false"), model.replace("Pdf, ", "Pdf Pdf, ")):
        try:
            build_export(reg, bad_model)
        except ImportError_:
            continue
        raise AssertionError("accepted bad model")
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--source", type=Path, default=DEFAULT_SOURCE, help="path to FormatRegistry.cs")
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="JSON output path")
    ap.add_argument("--docs", type=Path, default=DEFAULT_DOCS, help="Markdown output path")
    ap.add_argument("--check", action="store_true", help="fail if generated files differ from the source")
    ap.add_argument("--selftest", action="store_true", help="run inline parser/exporter checks and exit")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    try:
        registry_src, model_src = load_sources(a.source)
        export, cats = build_export(registry_src, model_src), parse_categories(model_src)
    except (ImportError_, OSError, UnicodeError) as e:
        sys.exit("error: %s" % e)
    outputs = {a.output: to_json(export), a.docs: to_markdown(export, cats)}
    if a.check:
        stale = [str(p) for p, t in outputs.items() if not p.exists() or p.read_text(encoding="utf-8") != t]
        if stale:
            sys.exit("stale: " + ", ".join(stale))
    else:
        for p, t in outputs.items():
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(t, encoding="utf-8")
    c = counts(export, cats)
    print("%s: %d formats (%d actual + %d virtual), %d categories, %d extensions, %d read-only"
          % ("fresh" if a.check else "wrote", c["total"], c["actual"], c["virtual"], len(cats), c["extensions"], c["readonly"]))
    print(", ".join("%s=%d" % kv for kv in c["categories"].items()))


if __name__ == "__main__":
    main()
