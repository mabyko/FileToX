# Engine comparison

Offline host-wire-v1 verification for the C# and Swift helpers. Python uses only
the standard library and runs with `-I`. Adjacent imports are added explicitly.
No app settings or installed binaries are modified. Every host gets fresh core,
download, TMPDIR and Calibre directories, removed after stdin EOF shutdown.

Run from the repository root on macOS with Xcode command line tools installed.
`inspect.swift` compiles automatically into `build/engine-compare/bin/inspect`.
ImageIO measures and compares **all** image frames; PDFKit measures PDF pages/text.
FFprobe and bundled 7-Zip inspect media and archives. WOFF2 inspection uses an
already-installed FreeType through stdlib `ctypes` in a subprocess; it never
installs anything. Other font containers are read directly in Python.

## Capture

Use a new output directory for corpus and runs. The installed self-contained C#
helper needs no .NET SDK. Supply your actual engine paths:

```sh
HOST=/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine
OPTIONAL=build/optional-engines/osx-arm64
SEVENZIP=/Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/engines/7zip/7zz
BASE=build/engine-compare/baseline

python3 -I Tools/engine-compare/matrix.py --host "$HOST" --out "$BASE/matrix-default.json"
python3 -I Tools/engine-compare/matrix.py --host "$HOST" --optional-root "$OPTIONAL" --out "$BASE/matrix-optional.json"
python3 -I Tools/engine-compare/corpus.py --host "$HOST" --optional-root "$OPTIONAL" --out "$BASE/corpus"
python3 -I Tools/engine-compare/run.py --host "$HOST" --optional-root "$OPTIONAL" --corpus "$BASE/corpus" --matrix "$BASE/matrix-optional.json" --sevenzip "$SEVENZIP" --out "$BASE/run-optional"
python3 -I Tools/engine-compare/run.py --host "$HOST" --corpus "$BASE/corpus" --matrix "$BASE/matrix-default.json" --sevenzip "$SEVENZIP" --out "$BASE/run-default"
```

`--optional-root` writes `settings.engineOwnCopies` through `settings.save` in
the temporary host library, preserving all other settings. Any installed/system
engines can still be found by the host. Individual overrides use repeated
`--own-copy 'PACKAGE=/absolute/path'`. Missing programs remain unavailable; there
are no downloads. The supplied LibreOffice folder in the initial capture has
only `.filee-component`, so this configuration adds Pandoc and Calibre, not LibreOffice.

Matrices preserve the entire catalog and selection responses, including ordered
slices/tools/presetOptions, reasons and guidance. Placeholder paths become
`$INPUT/...`; keys and input formats are sorted, without timestamps or temp IDs.
Resolution uses one empty file per primary extension and four multi-input groups.

The corpus manifest records each recipe, source, hash, size, and unsuccessful
attempt. Sources and Python archive headers have fixed content/times. Native
encoders and the baseline host may embed volatile IDs/dates: retain the captured
corpus and replay its hashes for a valid differential comparison. Re-generating
host-derived fixtures is not guaranteed to reproduce identical bytes.

## Candidate and comparison

Always replay **the baseline's cases and corpus**, including its matrix. A
candidate with missing routes must fail those cases, not silently remove them.

```sh
CANDIDATE=/absolute/path/to/SwiftEngineHost
python3 -I Tools/engine-compare/run.py --host "$CANDIDATE" --optional-root "$OPTIONAL" --corpus "$BASE/corpus" --matrix "$BASE/matrix-optional.json" --cases "$BASE/run-optional/cases.json" --sevenzip "$SEVENZIP" --out build/engine-compare/candidate
python3 -I Tools/engine-compare/compare.py "$BASE/run-optional" build/engine-compare/candidate --out build/engine-compare/comparison
```

For default-engine comparison, omit `--optional-root` and use `matrix-default.json`
and `run-default/cases.json`. Optionally capture a candidate matrix with `matrix.py`
and diff its JSON against the corresponding baseline matrix.

The generated plan caps automatic targets at six per sample, then adds any
uncovered reachable target, every runnable built-in preset, option variants, and
an explicit priority probe for every available engine with a fixture. Use
`--cap-per-source 0` for every available target of every sample. Priorities are
restored after each probe. `engineHint` is a family inferred from formats or a
requested engine priority: the wire does **not** expose the executed route, so
per-engine summaries are not proof that every intermediate engine ran.

Each case copies inputs into `RUN/cases/ID/sample/`. Outputs stay there for visual
inspection, named relative to that sample directory. `job.json` preserves the raw
finished event; `run.json` holds states, errors, timing, sidecars, source integrity,
and fingerprints. `host.stderr.log` collects stderr without pipe backpressure.
`cases.json` is a portable replay plan; `$CASE` in inline presets expands at run time.
Custom plans are a JSON list with `id`, `samples` (manifest IDs), `targetFormat`,
`engineHint`, and `how` (exactly one of `targetFormat`, `presetId`, `preset`).

`--timeout` defaults to 120 seconds per conversion; a timeout cancels the job,
waits ten seconds, and restarts the isolated host if needed. Transport/timeouts
are recorded as `harnessError`. `--resume` retains existing completed cases and
executes missing cases after checking configuration and case definitions. It
refuses existing unfinished case directories; inspect those before continuing.
Runs return nonzero for script/protocol shutdown errors. Conversion failures are
data in `run.json`, not an early exit. A baseline can itself contain failed jobs.

## Reports and checks

`compare.py` emits `report.md` and `report.json`, with per-case and per-engine-family/
target counts. PASS means identical behavior and output bytes/content. WARN means
different bytes with similar measured content, an unsupported inspector, or
different sidecars. FAIL means a state/errorKey/name/count/assignment change or
content below threshold. Missing/changed cases fail. Exit status is 1 for any FAIL.

Defaults: same image dimensions/frame count, PSNR ≥30 dB **and** global luminance
SSIM-like ≥0.95; PDF page count equal, dimensions within 1pt, text similarity ≥0.95;
normalized text and document XML similarity ≥0.95; archive entry names/content
hashes equal; media codecs/stream count, geometry/audio properties equal and
duration within 2%; font table tags/glyph count equal. Tune `--psnr`, `--ssim`,
`--text-ratio` when a deliberate implementation change needs another tolerance.

Comparison also works with older captured fingerprints: normalization reads the
retained artifacts without rewriting either run. TAR comparisons read through
gzip/bzip2/xz and PAX headers, comparing member names/types/link targets/content
instead of hashing an inner TAR's volatile PAX header names and checksums. ZIP
package XML is canonicalized; generated OPF/NCX/FB2 UUIDs, creation/modification
dates in document metadata, DrawingML field UUIDs and ODF revision IDs are scoped
to their metadata fields. User text, titles, links, media parts and member names
remain significant.
RST image dimensions use the same 1pt tolerance as PDF page dimensions, so DPI
quantization such as `0.99986in` versus `1in` does not fail a short text document.

Changed embedded raster pictures in ZIP documents, HTML data URLs, FB2 binaries
and RTF pict groups use the same decoded geometry, frame count, PSNR and SSIM
checks as standalone images. Metrics retain each picture's scores. Calibre
randomly chooses a generated cover's theme/layout; only JPEGs with its explicit
COM marker, identical geometry, and identical nonempty Vision OCR results can
receive WARN for that volatility despite different pixels. Other pictures keep
the image thresholds. OCR disagreement remains FAIL. The native inspector
expands ImageMagick's indexed TGA palettes before ImageIO decoding to avoid
ImageIO's red/blue palette swap.

Media with matching structure is additionally checked using FFprobe packet data
hashes, timing and codec extradata. Identical encoded payloads receive PASS when
only container IDs/dates differ (including Matroska/Ogg/MXF); different packets
remain WARN. Pixel format and frame rate are checked alongside stream geometry.
Unsupported binary books/documents remain WARN; this is not proof of content
equivalence. A smaller output needs inspection or readback, even when WARN.

Limits: global SSIM is not windowed SSIM. Empty-text PDFs compare geometry only;
media checks structure rather than perceptual audio/video quality, and font
metadata does not compare glyph outlines. Unsupported decoders explicitly WARN
when bytes differ. Error detail strings are retained, but compared errors use
`errorKey` because paths/native messages vary. Similar XML can still need review.

```sh
python3 -I Tools/engine-compare/test_harness.py
python3 -I Tools/engine-compare/compare.py "$BASE/run-optional" "$BASE/run-optional" --out build/engine-compare/self-comparison
```

The self-check covers strict stdout, IDs, fast completion, EOF/shutdown, normalized
text, archive hashes, image geometry/scores, strict states, and capped-plan coverage.
It also checks PAX/gzip volatility against real member loss, scoped XML metadata,
embedded-image colour/geometry loss, inline picture extraction, TGA palette order,
generated-cover guards, and strict media packet/timing comparisons.
Only tools are committed; corpus, native binaries, output artifacts and reports
remain under ignored `build/`.
