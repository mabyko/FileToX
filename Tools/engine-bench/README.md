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

The slow Swift paths (PDF → TXT, EPUB → FB2, DOCX → MD/TXT, Markdown → TXT) are the targets of the optimisation work;
`sample`-ing PDF → TXT showed PDFKit attributed-string access per character (ObjC bridging, retain/release) at the top.
