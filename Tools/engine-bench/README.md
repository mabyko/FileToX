# Engine benchmark

Times representative conversions on an engine host with large generated inputs, so Swift paths can be compared with
each other over time and with the old C# helper on the same machine.

```sh
python3 -I Tools/engine-bench/make-inputs.py --out build/bench/in --seed-png "build/engine-compare/baseline-lo/corpus/samples/한글 image.png"
swift build -c release --product FileToXEngine
FILETOX_BUNDLED_ENGINES=$PWD/build/engines/osx-arm64 python3 -I Tools/engine-bench/bench.py --host .build/release/FileToXEngine --inputs build/bench/in --scratch build/bench/swift
python3 -I Tools/engine-bench/bench.py --host /Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine --inputs build/bench/in --scratch build/bench/csharp
```

Reference (2026-10-23, M-series Mac, best of 2):

| Case | C# helper | Swift `2f03d05` |
| --- | ---: | ---: |
| big.png → jpg / webp (24 MP) | 0.70 / 1.31 s | 0.61 / 1.35 s |
| big.pdf → png / txt (200 pages) | 51.18 / 0.84 s | 5.34 / 4.01 s |
| big.zip → folder (2,000 files) | 0.32 s | 0.36 s |
| big.dxf → svg / pdf (50,000 lines) | 0.61 / 0.43 s | 0.39 / 0.38 s |
| big.epub → fb2 (300 chapters) | 0.36 s | 1.24 s |
| big.docx → md / txt (5,000 paragraphs) | 0.08 / 0.06 s | 0.30 / 0.35 s |
| big.md → html / txt (3.9 MB) | 1.17 / 0.43 s | 1.24 / 1.15 s |

## Optimisation results (2026-10-23)

Final integrated Release helper (`a064ab8`) versus the preserved baseline, on the same inputs (best of five runs).
These final measurements ran sequentially after all builds, conversions and readback investigations had finished:

| Case | Before | After | Goal |
| --- | ---: | ---: | --- |
| big.pdf → txt | 3.86 s | 1.38 s | ≤0.84 s; not reached |
| big.epub → fb2 | 1.19 s | 0.45 s | ≤0.54 s; reached |
| big.docx → md | 0.29 s | 0.09 s | ≤0.12 s; reached |
| big.docx → txt | 0.34 s | 0.09 s | ≤0.09 s; reached |
| big.md → txt | 1.16 s | 0.92 s | ≤0.60 s; not reached |
| big.md → html | 1.20 s | 0.97 s | No regression; improved |

Logs: `build/resume/bench-verified-{baseline,final}.log`; exact commands:
`build/resume/bench-verified-commands.json`. All 30 integrated outputs matched: 25 were byte-identical and five
FB2 files differed only in their generated document UUID (`build/resume/bench-verified-output-parity.json`).
Times are rounded to 0.01 s. Five additional raw DOCX→TXT measurements confirmed the boundary: best **0.086447 s**
(`build/resume/bench-verified-docx-txt-precision.json`). Earlier task measurements under concurrent work remain
diagnostic; the table does not claim that all paths match the C# helper's speed.

- PDF keeps PDFKit: the PDFium text draft changed Korean spacing in three corpus PDFs and was rejected.
  Attribute-range/format caching and up to eight independent PDFKit workers reduce overhead while retaining page
  order, headers/footers and cancellation. Serializing attributed-string creation reduces Foundation lock contention;
  cross-job throughput of that shared lock is unmeasured. PDFKit attributed-string creation remains the main cost.
- EPUB/DOCX avoid quadratic regex replacement, repeated string reconstruction and unnecessary escaping/trimming.
  The Markdown writer's escape fast path is restricted to ASCII so canonical Unicode equivalents retain the
  original Character-based escaping (including U+1FEF, canonically equal to a backtick).
- Markdown avoids repeated reference scans, intermediate UTF-16 arrays, failed autolink parsing and discarded
  table separator cells. It retains the existing parser and renderer.

Output checks: 66 PDF conversions across 22 PDFs (all seven successful TXT outputs byte-identical); 26 large/corpus
and 301 EPUB/document fixture cases (29 sidecars byte-identical); 119,792 Markdig comparisons, 1,828 Markdown
hostwire files and 2,000 additional Unicode inputs; a further pass matched 5,830 TXT/HTML outputs to the frozen
production host and repeated all 119,792 Markdig comparisons. Only baseline-proven UUIDs, document timestamps and ZIP
metadata were excluded where applicable; matching failed conversions are included in the case counts.
DOCX/HWPX payloads produced from PDFs matched, and the EPUB/document checks required no HWPX payload normalization.

Integration commands and limits are recorded in
[the migration verification log](../../docs/design/engine-differential-triage.md#performance-integration-2026-10-23).

## Final native integration (2026-10-24)

Final code `dc7ab6a` was measured after builds and conversion replays ended, against the preserved uniform
production baseline `194b692`. Five rounds per case alternate baseline/final host order. Best times:

- PDF → TXT: 1.384810 → **1.389179 s**; ≤0.84 s remains unmet.
- EPUB → FB2: 0.427374 → **0.434319 s**.
- DOCX → MD/TXT: 0.090216/0.085262 → **0.091151/0.085448 s**.
- Markdown → HTML/TXT: 0.956213/0.892803 → **0.876474/0.813709 s**; TXT ≤0.60 s remains unmet.

All 60 outputs match, with only the proven generated FB2 document UUID normalized. Both parent links remain
weak after independent lifetime review; the worker's pre-repair 0.63 s Markdown TXT result is superseded.
Raw timings, medians, executable/input hashes and output parity:
`build/resume/quality-final-20261024/post-cmyk-default/performance/{raw.json,summary.json}`. Exact environment and
command: `post-cmyk-default/performance-command.json`; sequential harness: `post-cmyk-default/bench-final.py`.
The baseline/final host SHA-256 prefixes are `82b4e625`/`7add727d`.

Final source/build/quality limits are recorded in
[the final integration record](../../docs/design/engine-differential-triage.md#final-native-quality-integration-2026-10-24).
