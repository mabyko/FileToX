# C# / Swift engine differential triage

Date: 2026-10-23. Original triage branch: `fix/swift-engine-differential`;
current integration branch: `refactor/swift-conversion-engine`.

The original triage below excluded 15 then-unported CAD cases from its verdict.
Later sections retain the resolved backend choices, CAD integration and final
849-case replay including CAD. The report distinguishes
comparator noise, confirmed engine defects, previously accepted differences, and
backend differences that still need an acceptance decision. A raw FAIL is not
automatically a Swift defect; matching failures can also receive PASS.

The final full optimisation replay (`a064ab8`) is **578 PASS / 263 WARN / 8 FAIL**.
Additional readback exposed a Calibre TCR content-corruption defect, reproduced directly without either host.
A subsequent scoped change bypasses that compressor and adds native RGB/grayscale JPEG decoding; see
[the native-library follow-up](#native-library-follow-up-2026-10-23). The full replay counts predate those changes
and are not proof of full content equivalence; see [verification and limits](#performance-integration-2026-10-23).

## Evidence and results

All paths below are relative to the named worktree, unless absolute.

- C# evidence, in worktree `t3-6fdca402`:
  `build/engine-compare/baseline-lo/run-optional` and
  `build/engine-compare/comparison-r1/report.json`.
- Original Swift evidence, in worktree `t3-6fdca402`:
  `build/engine-compare/candidate-r1`.
- Comparator-only replay of retained original artifacts, in this worktree:
  `build/engine-compare/comparison-r1-normalized`.
- First fixed helper, in this worktree:
  `build/engine-compare/candidate-fixed` and `comparison-fixed` under the same
  `build/engine-compare` directory.
- Final helper replay: `build/engine-compare/candidate-final`; final comparison:
  `build/engine-compare/comparison-final` in this worktree.

| Stage | FAIL | WARN | PASS | Non-CAD FAIL |
| --- | ---: | ---: | ---: | ---: |
| Original comparison | 122 | 388 | 339 | 107 |
| Original artifacts, corrected comparator | 83 | 235 | 531 | 68 |
| First fixed helper | 75 | 243 | 531 | 60 |
| Final helper (`cd35b98`) | **73** | **244** | **532** | **58** |
| JPEG/resize parity (`feat/jpeg-resize-parity`) | **67** | **233** | **549** | **52** |
| Merged branch with PDFium, JPEG/resize, Skia JPEG and CAD (`2fd553f`) | **8** | **263** | **578** | **7** |
| Final optimisations and Unicode correction (`a064ab8`) | **8** | **263** | **578** | **7** |

The JPEG/resize row is a later replay of the same corpus, cases and engine paths with the helper of branch
`feat/jpeg-resize-parity` (libjpeg-turbo JPEG writing and ImageMagick's resize, see the two "resolved" sections
below). Evidence in worktree `t3-4b2d90a6`: `build/engine-compare/candidate-jpeg-final`,
`comparison-jpeg-final/report.json` and `build/jpeg-parity/final-delta.txt` (every changed case, before → after).

The pre-merge non-CAD result was **58 FAIL / 244 WARN / 532 PASS** across 834 cases
(raw states 771 completed and 78 failed, including the 15 then-missing CAD routes).

**Final result on the merged integration branch (`2fd553f`): 8 FAIL / 263 WARN / 578 PASS
across all 849 cases**, replayed with `.build/release/FileToXEngine` from the README command
(`build/engine-compare/candidate-final2`, `comparison-final2/report.json`, logs
`candidate-final2.log` and `compare-final2.log` in worktree `t3-6fdca402`). Zero harness and
inspection errors; raw states 786 completed and 63 failed, the same 63 conversion failures
that the reference also fails. The 15 CAD cases are now 5 PASS, 9 WARN and 1 FAIL. The eight
FAILs are all in groups already classified below and none is a new engine defect:

| Cases | Group | Classification |
| --- | --- | --- |
| `auto-064-svg-to-{jp2,jpg,jxl}` | CoreSVG versus Svg.Skia rendering | b: accepted backend choice |
| `auto-061-psd-to-html`, `auto-077-webp-to-html`, `auto-101-gif-to-md`, `auto-086-dxf-to-md` | Image-to-markup resource packaging | c (reference): the C# Markdown/HTML references `assets/image1.jpg` but the C# output contains no such file; Swift writes the picture as a `_files` sidecar. `auto-086` joins the group now that the CAD route exists. |
| `auto-067-tcr-to-txtz` | Calibre generated cover | a: random cover theme (`images/img0001.jpg`), flips between replays |

The comparator removes 39 original FAILs without changing output artifacts. The
engine replay removes nine more FAILs relative to the normalized original run;
one additional final improvement is a Calibre cover happening to match the
reference, not another engine fix. Between the first fixed and final runs,
`auto-063-snb-to-rtf` improves FAIL -> WARN (fixed indentation),
`auto-067-tcr-to-txtz` improves FAIL -> PASS (matching random cover),
`auto-039-lrf-to-htmlz` changes WARN -> PASS, and `auto-054-pdb-to-rb` changes
PASS -> WARN. The last two are external-tool output volatility. Counts from one
replay must not be interpreted as a deterministic benchmark of random covers.

The saved first fixed report contains **531 PASS / 243 WARN**. The interrupted
agent's earlier progress message said 530 / 244; the saved report is authoritative.
Its 849-case run had zero harness errors and zero inspection errors. The final
replay uses the same corpus hashes, case plan, matrix and optional-engine paths.

Thresholds remain PSNR >= 30 dB **and** global luminance SSIM-like >= 0.95;
text/XML similarity >= 0.95; identical image geometry/frame count; PDF page sizes
within 1 pt. No global threshold was relaxed to remove a failure. The wire does
not expose the executed route, so `engineHint` describes a family, not proof of
every intermediate converter. Route attribution below combines source code and
retained output evidence.

Class **a** is comparator noise/volatility, **b** is a permitted or accepted
backend difference, and **c** is a real implementation/reference defect. **b?**
marks a measured backend difference whose quantitative acceptance is still open.

| Case group | Cause | Class | Action |
| --- | --- | --- | --- |
| TAR/PAX, XML IDs/dates, embedded image bytes, container IDs, TGA inspection, RST DPI | Incidental bytes were compared as content. | a | Normalize and add negative harness checks in `7b1393f`. |
| GIF alpha/canvas, PSD/PSB composites, comic geometry/quality, OOXML directories, SNB indentation | Port implementation diverged from Filee. | c | Fix in the four engine commits below, with regression tests. |
| 43 PDF raster cases | PDFKit/CoreGraphics versus PDFium/Skia. | b? | Retain strict FAIL; request a rendering-parity decision. |
| Six JPEG and three ICO cases | Native chroma/quantization and resize filters. | c (resolved) | JPEG written with libjpeg-turbo like ImageMagick, resize ported from ImageMagick: five of the nine now byte- or decode-identical, three JPEGs remain on the Skia/PDF-raster route. |
| Three SVG raster cases and JP2 quality differences | Backend/quality choices already recorded in the migration decisions. | b | Record scores and retain raw statuses; no new choice required. |
| Three image-to-markup cases | C# output lacks referenced assets; Swift preserves the images and changes layout/alt details. | c (reference) / b | Retain captured discrepancy; hand layout/alt evidence to the Markup owner. |
| Generated Calibre covers | Random themes/layouts; one first-fixed cover is a bilingual OCR false positive. | a / b | Normalize only when marker, geometry and nonempty OCR agree; document the visually verified strict-guard exception. |
| Other WARNs | Encoding/metadata differences or limited inspectors. | b, with stated limits | Retain warnings and evidence; no claim of unmeasured formatting or perceptual equivalence. |

## Completed fixes

| Commit | Cause and change | Verification |
| --- | --- | --- |
| `7b1393f` | Comparator treated PAX/TAR headers, generated UUID/date fields, embedded image bytes, RST DPI rounding and media-container identifiers as content. Compare TAR members, scoped XML metadata, decoded embedded pictures and media packet hashes/timing. Expand indexed TGA palettes before ImageIO decoding. | Harness tests retain negative checks for missing members, changed text/geometry/pixels and media payload/timing changes. Original artifacts improve from 122 to 83 FAIL without touching their outputs. |
| `883aa0b` | GIF lost binary transparency and enlarged its logical screen to fit later pages; PSD/PSB composites applied a second white matte. Match Filee's GIF alpha threshold/canvas and straight composite samples. | GIF alpha/canvas and PSD sample regression tests. `auto-060-psb-to-gif`: 33.878 dB / 0.998006. `auto-068-tga-to-psd` and `-psb`: decoded pixels identical, 99 dB / 1.0. `builtin-to-psd`: 36.822 dB / 0.999953. Five `auto-119-pdf-to-{m2ts,m4v,mkv,mov,mp4}` height failures become WARN with matching geometry. |
| `c8938d4` | Comic PDF rendering used different page boxes, rotation, rounded pixel dimensions and an uncalibrated JPEG quality mapping. Reuse `PdfiumConverter.render`, the shared JPEG quality mapping and NFC-preserving output helper. | Fractional rotated crop-box regression and byte-preserving JPEG-copy checks for CBZ/fixed-layout EPUB. Remaining PDF-renderer differences stay visible. |
| `ce96e74` | OOXML rewriting discarded explicit directory entries. Preserve empty and populated directory entries while changing the package variant. | DOCM/DOTX/DOTM tests verify directory entries and original embedded JPEG bytes survive. |
| `cd35b98` | `MarkdownWriter.escapeLineStart` returned its trimmed probe for ordinary paragraphs, deleting indentation on the SNB -> RTF route. Return the original text unless a line marker needs escaping, matching C#. | New test fails before the fix for spaces, tabs and two U+3000 ideographic spaces; passes after it. No file under `Sources/Engine/Engines/Markup` was changed. |

The comparator-only result includes all 91 archive cases and all 21 spreadsheet
cases at PASS. OOXML has 60 PASS, five downstream PDF-rendering FAILs and one WARN
in the first fixed run. This is normalization of measured content, not a claim
that every format has an independent perceptual inspector.

Focused XCTest coverage:

- `RasterFormatTests.testGifTransparencyUsesTheFileeHalfAlphaThreshold`
- `RasterFormatTests.testGifLogicalScreenKeepsFirstPageGeometry`
- `RasterFormatTests.testPsdAndPsbCompositeSamplesMatchFileeWriter`
- `RasterFormatTests.testPhotoshopWhiteMattedCompositeIsUnblended`
- `ComicRenderingTests.testComicPagesUseRasterCropRotationAndTruncatedDimensions`
- `ComicRenderingTests.testComicAndEpubCopyExistingJpegBytes`
- `OoxmlVariantTests.testWordVariantsPreserveJpegBytesAndDirectoryEntries`
- `DocumentExportFixTests.testMarkdownPreservesLeadingWhitespaceInOrdinaryParagraphs`

## Remaining FAIL groups and resolved handoff findings

The retained full replay had **58 non-CAD FAILs**: 43 PDF raster cases, six JPEG
cases, three ICO cases, three SVG cases and three image-to-markup resource cases.
The PDFium follow-up below resolves all 43 PDF raster FAILs, and the JPEG/resize
parity work resolves the six JPEG and three ICO cases; the two were measured on
separate branches, so the combined replay after merging is recorded in the final
ledger. The three Skia-encoded PDF-page JPEGs were then resolved on the merged branch
(see the ImageIO JPEG encoding section), leaving three SVG and three image-to-markup
cases as the expected non-CAD FAILs. The
Calibre OCR and SNB subsections retain evidence from the first fixed run, but
neither remains FAIL in the final run.

### PDFKit versus PDFium/Skia rasterization

**Resolved: the user requires the same PDFium as C#.** `feat/pdfium-render` bundles
PDFium **147.0.7690.0**, the bblanchon.PDFium.macOS 147.0.7690 build used by PDFtoImage
5.2.1. The arm64 executable code matches the installed C# helper. See the
[vendoring/render contract](../../Vendor/PDFium/README.md). PDFKit remains for
non-raster text/layout extraction and PDF page manipulation.

The same **43 baseline cases / 44 pages or images** were replayed at unchanged
thresholds: **0 FAIL, 6 PASS, 37 WARN**. Dimensions/counts match. **21/44** decoded
images are pixel-identical (including six byte-identical outputs); the remaining
23 score **57.754–79.047 dB PSNR**, **0.999432–0.999994 SSIM**. Before: **31.788–39.393 dB**,
**0.872954–0.948911 SSIM**. `auto-055-pdf-to-webp` is now byte-identical to C#.
WARNs retain alpha/color-model/DPI metadata, container and image encoder (JPEG,
AVIF, GIF, JPEG XL, JP2) differences; thresholds and comparator are unchanged.
No PDF raster similarity failures remain in this group.

`PdfiumDocument` mirrors PDFtoImage's FPDF_ANNOT-only flags (no LCD_TEXT), white
premultiplied BGRA8888 bitmap, form environment/lifecycle/FPDF_FFLDraw, intrinsic
crop/rotation, and Float DPI scaling. Bitmap dimensions truncate; the drawing
rectangle **ceils** the scaled size. All native lifetime/rendering calls share a
global lock, including comic and PDF document-image routes. The two-page C# fixture
matches every pixel in XCTest, including form appearance, annotation, transparency,
text, and fractional crop/rotation.

Evidence in worktree `t3-34b75636`, under `build/engine-compare/`:

- `pdf-raster-cases.json`: the 43 original cases from the ledger below.
- `baseline-pdf-raster`: copied projection of the retained C# `baseline-lo/run-optional`;
  original case definitions/artifacts, original baseline unchanged.
- `candidate-pdfium`, `comparison-pdfium/report.json`: Swift replay and raw report.
- `pixel-reference`: independent C# capture of the checked-in XCTest fixture.
- Before: `t3-e7ea93ff/build/engine-compare/comparison-fixed/report.json`.

Replay from this worktree with existing external engines:

```sh
BASE=worktrees/t3-6fdca402/build/engine-compare/baseline-lo
FILETOX_BUNDLED_ENGINES=worktrees/t3-6fdca402/build/engines/osx-arm64 \
python3 -I Tools/engine-compare/run.py --host .build/debug/FileToXEngine \
  --optional-root build/optional-engines/osx-arm64 \
  --own-copy libreoffice=worktrees/t3-6fdca402/build/optional-engines/osx-arm64/libreoffice \
  --corpus "$BASE/corpus" --matrix "$BASE/matrix-optional.json" \
  --cases build/engine-compare/pdf-raster-cases.json \
  --sevenzip /Applications/FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/engines/7zip/7zz \
  --out build/engine-compare/candidate-pdfium
python3 -I Tools/engine-compare/compare.py build/engine-compare/baseline-pdf-raster \
  build/engine-compare/candidate-pdfium --out build/engine-compare/comparison-pdfium
```

Validation of the PDFium follow-up:

- `swift build --build-tests`: PASS (`build-tests-final.log`).
- Unfiltered `swift test` with the existing bundled-engine path: **468 engine tests,
  21 skipped, zero failures**; **12 Core tests, one known failure** at
  `RealEngineHostTests.swift:83` (22 engines versus expected 23 until CAD merges).
  No other failure (`swift-tests-final.log`).
- Full Xcode test action and clean test action: **542 tests** (74 app + 468 engine),
  **46 skipped, zero failures** (`xcode-tests-fixed.log`, `xcode-tests-clean.log`).
  Clean used the same scheme/destination with `-disableAutomaticPackageResolution`;
  existing package and pinned external-engine caches were reused.
- Final Xcode `PdfiumRenderingTests`: **4/4 PASS**, including retained error texts,
  exact C# pixels, concurrent native lifetimes and cancellation.
- Comparator harness self-tests: **15/15 PASS**. The two-page C# capture also matches
  every pixel through the Xcode-built helper (99 dB sentinel / SSIM 1; alpha metadata
  alone remains WARN).
- Deep strict signature verification: helper and parent app PASS. PDFium is embedded
  at `Contents/Frameworks/libpdfium.dylib`, loaded with `@rpath`; a relocated helper
  is also verified and run from `/tmp` (`pixel-relocated`, `relocated-host.log`).
- Both dylib slices link successfully with macOS 15 deployment. arm64 initializes;
  x86_64 runtime remains unverified: this Mac returns `Bad CPU type in executable`
  because Rosetta is unavailable. Developer ID/notarization and physical Intel QA
  remain outside this local validation.
- Bundle contribution: **11,376,192 bytes (10.85 MiB)** for the universal dylib,
  **119,686 bytes (116.9 KiB)** for licence/notices, plus the small Swift wrapper.
  This records the added library/notices, not an entire Release build size comparison.
  Public headers stay in the repo.

The projection uses physical copies: the comparator rejects symlinks escaping a run
directory. The full 849-case suite was not rerun in this follow-up. Scores are min–max
across every output page/image. **99** is the harness's identical-pixel sentinel;
six byte-identical outputs also receive 99/1 here.

| Case | Before PSNR dB | Before SSIM | PDFium PSNR dB | PDFium SSIM | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| `auto-009-fb2-to-avif` | 37.545 | 0.895273 | 60.913 | 0.999954 | WARN |
| `auto-009-fb2-to-bmp` | 37.538 | 0.894619 | 99.000 | 1.000000 | WARN |
| `auto-009-fb2-to-cbz` | 37.575 | 0.895923 | 61.227 | 0.999751 | WARN |
| `auto-010-md-to-gif` | 34.972 | 0.913927 | 73.831 | 0.999990 | WARN |
| `auto-012-txt-to-jp2` | 36.284 | 0.892029 | 79.047 | 0.999994 | WARN |
| `auto-012-txt-to-jpg` | 36.323 | 0.892923 | 61.944 | 0.999681 | WARN |
| `auto-012-txt-to-jxl` | 36.267 | 0.891745 | 59.608 | 0.999488 | WARN |
| `auto-022-azw3-to-psb` | 34.900 | 0.912467 | 99.000 | 1.000000 | WARN |
| `auto-022-azw3-to-psd` | 34.900 | 0.912467 | 99.000 | 1.000000 | WARN |
| `auto-024-docm-to-tga` | 34.143 | 0.890139 | 99.000 | 1.000000 | PASS |
| `auto-025-dotm-to-avif` | 34.170 | 0.890566 | 67.664 | 0.999947 | WARN |
| `auto-025-dotm-to-tiff` | 34.143 | 0.890139 | 99.000 | 1.000000 | WARN |
| `auto-025-dotm-to-webp` | 34.184 | 0.890748 | 99.000 | 1.000000 | PASS |
| `auto-026-dotx-to-bmp` | 34.143 | 0.890139 | 99.000 | 1.000000 | WARN |
| `auto-026-dotx-to-cbz` | 34.191 | 0.890886 | 61.110 | 0.999761 | WARN |
| `auto-030-epub-to-gif` | 34.885 | 0.912221 | 75.212 | 0.999993 | WARN |
| `auto-034-hwp-to-png` | 36.274 | 0.892314 | 99.000 | 1.000000 | WARN |
| `auto-035-hwpx-to-ppm` | 36.274 | 0.892314 | 99.000 | 1.000000 | PASS |
| `auto-035-hwpx-to-psb` | 36.274 | 0.892314 | 99.000 | 1.000000 | WARN |
| `auto-035-hwpx-to-psd` | 36.274 | 0.892314 | 99.000 | 1.000000 | WARN |
| `auto-046-mobi-to-jxl` | 31.788–39.393 | 0.914399–0.948911 | 58.698–60.846 | 0.999432–0.999894 | WARN |
| `auto-055-pdf-to-webp` | 34.184 | 0.890748 | 99.000 | 1.000000 | PASS |
| `auto-071-txtz-to-avif` | 34.977 | 0.914325 | 57.754 | 0.999954 | WARN |
| `auto-071-txtz-to-bmp` | 34.983 | 0.914119 | 99.000 | 1.000000 | WARN |
| `auto-071-txtz-to-cbz` | 34.975 | 0.914410 | 58.434 | 0.999785 | WARN |
| `auto-096-html-to-avif` | 38.193 | 0.917842 | 58.380 | 0.999946 | WARN |
| `auto-096-html-to-bmp` | 38.210 | 0.917287 | 99.000 | 1.000000 | WARN |
| `auto-096-html-to-cbz` | 38.222 | 0.918410 | 60.216 | 0.999750 | WARN |
| `auto-110-doc-to-avif` | 33.984 | 0.873487 | 67.894 | 0.999944 | WARN |
| `auto-110-doc-to-bmp` | 33.957 | 0.872954 | 99.000 | 1.000000 | WARN |
| `auto-111-docx-to-cbz` | 34.191 | 0.890886 | 61.110 | 0.999761 | WARN |
| `auto-112-html-to-gif` | 36.238 | 0.891609 | 68.179 | 0.999924 | WARN |
| `auto-113-odt-to-jp2` | 36.277 | 0.892354 | 78.773 | 0.999993 | WARN |
| `auto-113-odt-to-jpg` | 36.316 | 0.893263 | 61.959 | 0.999683 | WARN |
| `auto-113-odt-to-jxl` | 36.269 | 0.892168 | 60.509 | 0.999560 | WARN |
| `auto-120-txt-to-png` | 36.274 | 0.892314 | 99.000 | 1.000000 | WARN |
| `auto-120-txt-to-ppm` | 36.274 | 0.892314 | 99.000 | 1.000000 | PASS |
| `auto-120-txt-to-psb` | 36.274 | 0.892314 | 99.000 | 1.000000 | WARN |
| `auto-120-txt-to-psd` | 36.274 | 0.892314 | 99.000 | 1.000000 | WARN |
| `auto-123-txt-to-avif` | 36.294 | 0.892655 | 69.958 | 0.999950 | WARN |
| `auto-123-txt-to-bmp` | 36.274 | 0.892314 | 99.000 | 1.000000 | WARN |
| `auto-123-txt-to-webp` | 36.319 | 0.893130 | 99.000 | 1.000000 | PASS |
| `builtin-to-cbz` | 34.894 | 0.912828 | 58.403 | 0.999782 | WARN |

### ImageIO JPEG encoding — resolved

**Resolved (2026-10-23, `feat/jpeg-resize-parity`):** decision "match ImageMagick". JPEG is written by
libjpeg-turbo 3.2.0 (the version inside the C# helper's Magick.Native) set up like ImageMagick 7.1.2-32's
`WriteJPEGImage` with Filee's settings ([migration decisions](swift-engine-migration.md)).

| Case | Before | After |
| --- | --- | --- |
| `auto-032-flv-to-jpg` | FAIL 27.393 dB / 0.999092 | **PASS, byte-identical** |
| `auto-045-mkv-to-jpg` | FAIL 27.393 dB / 0.999092 | **PASS, byte-identical** |
| `auto-079-wmv-to-jpg` | FAIL 27.580 dB / 0.999108 | **PASS, byte-identical** |
| `auto-043-m4v-to-cbz` | FAIL 28.027 dB / 0.993090 | FAIL 28.027 dB / 0.993090 |
| `auto-045-mkv-to-hwpx` | FAIL 27.914 dB / 0.993128 | FAIL 27.914 dB / 0.993128 |
| `auto-076-webm-to-hwpx` | FAIL 27.920 dB / 0.993238 | FAIL 27.920 dB / 0.993238 |

The three remaining cases were not ImageMagick JPEGs: their route is video → PDF → CBZ/HWPX, and the embedded
picture is a PDF page that Filee rendered with PDFium and encoded with **Skia** (`ComicBook.RenderPdf` at the preset
quality, `PdfDocumentReader`'s scan at 85). The C# files show it: IJG tables of quality 90/85 with 4:2:0 sampling
and optimized Huffman tables, which ImageMagick would have written 4:4:4 at 90. **Resolved after the PDFium and
libjpeg-turbo merges:** `JpegEncoder.writeSkia` drives the same libjpeg-turbo with SkJpegEncoder's settings (three
components, 4:2:0, slow integer DCT, optimized Huffman tables, JFIF without density, no profiles).
`JpegEncoderTests.testSkiaFilesAreByteIdenticalToSkiaSharp` pins seven encodings to the bytes the installed helper's
libSkiaSharp (SkiaSharp 3.119.4, libjpeg-turbo 2.1.5.1) writes from the same pixels. Replayed on the merged branch
(`build/engine-compare/candidate-skia3`, `comparison-skia3`): all three cases **PASS**; the CBZ page and both HWPX
`BinData` pictures are byte-identical to the C# files, so the PDFium page pixels match too. The other ImageMagick JPEG
routes also improved: twelve preset/option JPEG cases (`builtin-to-jpg`, `option-*`) went WARN → PASS byte-identical,
`builtin-jpg-70` 39.848 → 46.066 dB (its JPEG XL source is decoded by ImageIO, not libjxl).
The only lower scores are `auto-012-txt-to-jpg` and `auto-113-odt-to-jpg` (36.323 → 36.291 and 36.316 → 36.285 dB,
still FAIL on SSIM 0.89): ImageMagick's encoding now applied to PDFKit pages that differ from PDFium's. Calibre
cases with generated covers changed randomly in both directions, as in earlier replays.

Cases: `auto-032-flv-to-jpg`, `auto-043-m4v-to-cbz`,
`auto-045-mkv-to-hwpx`, `auto-045-mkv-to-jpg`,
`auto-076-webm-to-hwpx`, `auto-079-wmv-to-jpg`.

PSNR is **27.393-28.027 dB**, below 30; SSIM is **0.993090-0.999108**.
Geometry matches. In `auto-032-flv-to-jpg`, the C# JPEG's SOF sampling factors are
`11/11/11` (4:4:4); Swift's are `22/11/11` (4:2:0). Quantization tables also
differ. The output sizes are 8,440 versus 6,355 bytes. Thus the size reduction
alone does not show missing video frames or document content; the embedded JPEG
in CBZ/HWPX triggers the same strict pixel test as standalone output.

### vImage versus ImageMagick ICO resampling — resolved

**Resolved (2026-10-23, `feat/jpeg-resize-parity`):** ImageMagick's `ResizeImage` (Q8) is ported to Swift
(`MagickResize`, including its filter choice and clang's fused multiply-adds), and ICO padding, ICNS entries and
alpha removal keep straight samples like ImageMagick. All three cases now decode identical to the C# icons in all
six frames (99 dB / 1.0); they are WARN only because ImageIO's ICO container differs from ImageMagick's (PNG vs BMP
entries).

| Case | Before (16 px frame) | After (every frame) |
| --- | --- | --- |
| `auto-032-flv-to-ico` | FAIL 29.974 dB / 0.996098 | WARN 99 dB / 1.0 |
| `auto-045-mkv-to-ico` | FAIL 29.974 dB / 0.996098 | WARN 99 dB / 1.0 |
| `auto-079-wmv-to-ico` | FAIL 29.802 dB / 0.995891 | WARN 99 dB / 1.0 |

Other resize routes: `option-resize-long-edge` and `option-resize-percent` 43.624 dB → identical pixels;
`builtin-to-ico`, `option-ico-sizes`, `auto-061-psd-to-ico`, the video ICNS cases → identical pixels;
`auto-011-cbz-to-ico` 32.552 → 46.088 dB, `auto-113-odt-to-ico` 35.166 → 53.362 dB (PDF-raster sources).
`builtin-to-icns` and `auto-100-avif-to-icns` stay at 36.4 dB: their HEIC/AVIF sources decode differently in ImageIO
and libheif (already 33 dB at the unresized 1024 px entry).

The original analysis follows.

Cases: `auto-032-flv-to-ico`, `auto-045-mkv-to-ico`,
`auto-079-wmv-to-ico`. All retain six square frames at
**256, 128, 64, 48, 32, 16 px**, including alpha metadata. Only the 16 px frame
falls below 30 dB: **29.974 dB / 0.996098** for FLV/MKV, and
**29.802 dB / 0.995891** for WMV. Other sizes clear both thresholds.
`ImagePixels.resize` uses vImage high-quality Lanczos; Filee asks ImageMagick to
resize. Do not suppress the failing smallest frame by comparing only frame zero.

### CoreSVG versus Svg.Skia rendering

**Classification:** previously accepted backend choice, with measured residual.
**Decision needed:** none to retain the chosen backend. These remain raw FAILs;
the user has not authorized changing the generic image thresholds.

Cases: `auto-064-svg-to-jp2` (**31.823 dB / 0.870260**),
`auto-064-svg-to-jpg` (**39.351 dB / 0.931245**),
`auto-064-svg-to-jxl` (**31.827 dB / 0.870225**). Geometry matches.
The [migration decision](swift-engine-migration.md#4-동등한-대체가-어려운-기능)
selects the macOS SVG renderer with CSS/tspan preprocessing. Different
rasterizers still produce different text and edge samples. The JP2 quality
limitation below can compound an SVG or PDF route; it does not explain away a
low score on JPG or JXL.

### Image-to-markup resource packaging

**Classification:** baseline resource loss plus an already documented Swift
resource-writing behavior; not a new Swift content-loss defect.
**Decision needed:** none to preserve readable images. Keep the raw discrepancy
and pass the case evidence to the Markup branch for its own parity checks.

| Case | C# artifact | Swift artifact | Measured discrepancy |
| --- | --- | --- | --- |
| `auto-061-psd-to-html` | 574-byte HTML references `assets/image1.jpg`; no such file or sidecar exists in the captured sample directory. | 3,549-byte HTML embeds one JPEG data URI. | Normalized text ratio 0.963090; embedded picture count 0 versus 1. |
| `auto-077-webp-to-html` | Same 574-byte HTML and missing relative image. | 3,461-byte HTML embeds one JPEG data URI. | Same text ratio and picture-count difference. |
| `auto-101-gif-to-md` | `![image](assets/image1.jpg)`; no image asset or sidecar. | `![](<sips_files/img0001.jpg>)` plus the actual 3,216-byte JPEG sidecar. | Text ratio 0.642857 and a sidecar difference. |

These sample directories contain only the source and HTML/MD on the C# side.
`run.py` fingerprints all remaining files as sidecars, so the missing image is
not merely an omitted sidecar field. Swift HTML uses an empty alt and explicit
96 px width instead of the C# generic `image` alt; those differences are retained
in the evidence rather than normalized away. The existing
[HWP export report](swift-hwp-export-r3.md) documents shared `EbookFiles.dataUri`
and `markdownImages` use by HDocument writers, including `<output>_files` media.
No blanket relative-link/data-URI equivalence was added: it could hide missing
resources. Markup/Markdown/Email source remains owned by
`feat/markdown-html-pandoc-email`.

### Calibre generated cover / OCR false positive (final PASS)

**Classification:** manually verified comparator limitation on volatile cover
layout. **Decision needed:** none for the engine. Keep the strict OCR guard and
this triage evidence; do not accept arbitrary covers by marker alone.

`auto-067-tcr-to-txtz`: both ZIPs have byte-identical **132-byte `index.txt`** and
a 494-byte `metadata.opf` with normalized metadata equivalence, plus one generated
1200 x 1600 JPEG each. Both images
have Calibre's explicit generated-cover COM marker. The first fixed pictures
score **13.623 dB / 0.127085**, with sizes **171,141 versus 63,326 bytes**.
Visual inspection confirms the same `FileToX sample` title and
`안녕하세요. Bold and italic.` text, rendered in different themes and line wraps.
Calibre's `covers.py` chooses both theme and style using `random.choice`.

Vision reports `['FileToX sample', 'Bold and', 'italic.']` versus
`['FileToX sample', '|. Bold and italic.']`, missing/misreading Korean and changing
line segmentation. The exact nonempty OCR equality guard therefore cannot prove
equivalence. Local extracted evidence is under
`build/engine-compare/cover-inspection/{baseline,candidate}/tcr-cover.jpg`.
Improving bilingual OCR or adding a narrowly scoped generated-cover comparator
would be separate harness work; ignoring all cover pixels would be unsound.
On the final replay this case receives **PASS**: the generated cover bytes match
the reference, and `metadata.opf` has normalized similarity 1.0. This confirms
the observed volatility without relaxing the comparator. The manual evidence
above describes the earlier first-fixed cover, not the final matching picture.

### SNB indentation: fixed, not an accepted deviation

`auto-063-snb-to-rtf` in the first fixed replay loses two U+3000 characters at
the start of each of four text paragraphs. Apart from the generated JPEG cover,
these are the only normalized RTF differences: C# emits `\\u12288 ?` twice per
paragraph; Swift emitted none. Text ratio **0.922078** fails 0.95.

The cause is `Documents/MarkdownWriter.swift`, outside the Markup-owned code:
`escapeLineStart` used `return t` instead of C#'s `return text`. This affects a
route through the shared document writer and Pandoc, not an SNB decoder defect
or RTF image loss. Commit `cd35b98` preserves that indentation. The final replay
below records the post-fix result, including any remaining random cover warning.
Final result: **WARN**, normalized RTF text ratio **1.0**, all eight U+3000
escapes preserved. The only warning is the generated cover, whose recognized
title matches; cover pixels score 16.874 dB / 0.229619.

## WARN classification and limits

Warnings are retained when the evidence supports a limited claim. The per-case
ledger assigns exactly one primary category to each final warning; an output may
also carry secondary reasons in `report.json`.

| Category | Evidence and disposition |
| --- | --- |
| Decoded/structured content within thresholds | Same geometry/frames and acceptable scores, similar text/XML, or font table tags/glyph counts. Retain WARN for changed encoding. Font checks do not compare glyph outlines. SVG differences follow the selected native backend. No new decision needed unless stricter parity is desired. |
| Unsupported binary books and documents | The comparator intentionally has no semantic parser for DOC/HWP and several binary ebook types. Independent original-candidate readback covered all seven changed DOC/HWP outputs (text identical) and 51 changed book outputs (50 text-identical). The remaining `auto-096-html-to-tcr` has a C#-only trailing `Fil`; Swift retains the complete source sentence. This is evidence against truncation, not exhaustive formatting equivalence. |
| Different encoded media packets | Codecs, stream counts, geometry, pixel format/frame rate, audio properties and duration pass; packets or their timing differ. Keep WARN: structure is not perceptual video/audio equivalence. Identical packets with only container IDs/timestamps changed now PASS. |
| PDF with no extractable text | Twelve cases in the first fixed replay check page count and geometry only. Keep WARN; no claim of page-pixel equivalence is made. |
| Verified generated Calibre covers | Explicit COM marker, identical geometry and matching nonempty OCR permit layout volatility at WARN. Ten cases in the first fixed run meet that guard. The TCR cover above does not. |
| Image metadata | Six first-fixed cases have DPI and/or alpha-metadata changes while decoded comparisons pass. DPI is not content-neutral for every consumer, so retain WARN. |
| Embedded image encoding | Three first-fixed cases have different image bytes but the same image geometry and acceptable decoded pixels. The inspector measures the picture instead of treating compression metadata as lost document content. |

The first fixed WARN categories total **243**: 104 within-threshold structured
outputs, 57 unsupported binary cases, 51 media-packet cases, 12 empty-text PDFs,
10 generated covers, six metadata cases and three embedded-encoding cases.
The final warning counts are **104 / 58 / 51 / 12 / 10 / 6 / 3**, respectively,
totaling **244**. The unsupported-binary increase is the volatile RB output.

### Previously accepted JPEG 2000 limitation

The [2026-10-23 migration decision](swift-engine-migration.md) explicitly accepts
that ImageIO ignores lossy JPEG 2000 quality; q100 lossless works. No codec was
added or installed for this triage. In the first fixed run, the four JP2 WARNs
(`auto-032-flv-to-jp2`, `auto-045-mkv-to-jp2`, `auto-079-wmv-to-jp2`,
`auto-100-avif-to-jp2`) score **34.227-40.864 dB / 0.999904-0.999909** with equal
geometry. The JP2 FAILs on document/SVG input also have the renderer differences
described above. **No new user decision is needed for the quality limitation.**

RAW and CAD are separate workstreams. This small corpus is not evidence that
the independently chosen LibRaw/Apple fallback policy has been fully revalidated.

## Verification and final ledger

`swift build --build-tests` and `swift build -c release --product FileToXEngine`
pass. `python3 -I Tools/engine-compare/test_harness.py` passes all **15** tests.
The new whitespace test was observed failing before the one-line correction
(three assertions) and passing afterward.

The requested unfiltered `swift test`, with
`FILETOX_BUNDLED_ENGINES=worktrees/t3-6fdca402/build/engines/osx-arm64`,
runs **433 engine tests: zero failures, 18 skipped**. Its separate 12-test Core
target has one failure: `RealEngineHostTests.swift:83` expects 23 engines but
this pre-CAD branch registers 22. The image/PDF/archive conversions in that Core
test succeed with the bundled-engine path set. Do not change the expected
catalog count to conceal the separately owned missing CAD port.

The earlier unconfigured test run also lacked the bundled 7-Zip path, causing
archive skips and Core archive assertions; supplying the existing path resolves
those prerequisite failures without installing or changing anything. The final
engine-only command and replay results are recorded below. Logs remain under
`build/engine-compare/{build-tests-verified,all-tests-verified,engine-tests-verified,harness-tests-resumed}.log`.

### Merged-branch verification

On `2fd553f` (PDFium, libjpeg-turbo/resize, Skia JPEG and CAD merged): `swift build --build-tests`
and `swift test` run **510 engine tests (46 skipped) and 12 Core tests with zero failures**; the
engine-count assertion now sees 23 engines. The Xcode test action passes with **74 app tests and
510 engine tests**. `Tools/engine-compare/core-host-compat.py` against a copy of the real user data
(`settings.json`, `history.json`) reports no wire or semantic differences between the C# and Swift
hosts; the saved files differ only in JSON key order (`build/user-data-compat-final/summary.json`).

**Isolated clean build (no .NET access).** `xcodebuild clean test` on `2f03d05` ran under
`env -i` with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` (no `dotnet` anywhere on it) inside a
`sandbox-exec` profile denying every read of `~/.dotnet`, `~/.nuget` and `/usr/local/share/dotnet`,
with Xcode's manifest sandbox and the Swift subprocess sandbox disabled so the nested seatbelt
does not abort them (`build/isolated.sb`, `build/xcode-isolated.log`). The clean build succeeded
and the products contain no `dotnet*`, `libcoreclr*`, `*.dll`, `*.deps.json` or
`*.runtimeconfig.json`. The engine bundle ran **510 tests with one failure**:
`ProcessRunnerTests.testTimeoutKillsTheWholeTree` could not start `/bin/ps`, which the seatbelt
profile itself blocks (`/bin/ps` fails the same way in that sandbox with no test involved); it passes
outside. The app test bundle could not be hosted inside the sandbox ("the test runner hung before
establishing connection", the App-Sandboxed test host cannot apply a nested sandbox); its 74 tests
passed in the unsandboxed run above. The .NET folders in the home directory were not modified.

No changes were made to Markup, Email, the RAW reader, installed applications,
user application data, .NET or NuGet installations. No software was installed.
All generated evidence stays in this worktree; no push or merge was performed.

The explicit engine-only verification also **passes: 433 tests, 18 skipped, zero failures** (415 executed without a skip). Its command is:

```sh
FILETOX_BUNDLED_ENGINES=worktrees/t3-6fdca402/build/engines/osx-arm64 swift test --filter FileToXEngineTests
```

The final replay uses the command in `Tools/engine-compare/README.md` with
`--host` pointing to this worktree's `.build/release/FileToXEngine`, the retained
`baseline-lo/{corpus,matrix-optional.json,run-optional/cases.json}` paths and the
same external-engine and 7-Zip paths. Comparison exits 1 because known FAILs
remain; the conversion harness itself completed successfully. The full command
outputs are `candidate-final.log` and `compare-final.log` under the evidence root.

### Per-case accounting

This ledger covers all **495 original non-CAD FAIL/WARN cases**, plus any originally passing case that is now WARN/FAIL: **495 rows** in total. The 15 CAD cases are excluded. PASS rows record evidence of resolved comparator differences; they do not imply byte identity. Scores are min..max over all measured output frames/pictures; original and final statuses are raw comparator results. For the 43 PDF raster rows, Final now records the PDFium follow-up; its secondary
reasons/metrics are in `comparison-pdfium/report.json`. Other rows retain the
original final replay and `comparison-final/report.json`.

| Case | Original | Final | Classification / action | Evidence |
| --- | --- | --- | --- | --- |
| `auto-000-bz2-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-001-gz-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-001-gz-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-001-gz-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-001-gz-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-002-lzma-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-002-lzma-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-003-tar-to--` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-003-tar-to-7z` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-003-tar-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-003-tar-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-003-tar-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-004-tbz2-to--` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-004-tbz2-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-004-tbz2-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-004-tbz2-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-004-tbz2-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-004-tbz2-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-005-tgz-to-7z` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-005-tgz-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-005-tgz-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-005-tgz-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-005-tgz-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-006-txz-to--` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-006-txz-to-7z` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-006-txz-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-006-txz-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-006-txz-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-007-xz-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-007-xz-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-007-xz-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-008-zip-to--` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-008-zip-to-7z` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-008-zip-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-008-zip-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-008-zip-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-009-fb2-to-avif` | FAIL | WARN | b: PDFium resolved | dB 60.913; SSIM 0.999954 |
| `auto-009-fb2-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-009-fb2-to-bmp` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-009-fb2-to-cbz` | FAIL | WARN | b: PDFium resolved | dB 61.227; SSIM 0.999751 |
| `auto-009-fb2-to-doc` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-009-fb2-to-docm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-010-md-to-docx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-010-md-to-dotm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-010-md-to-dotx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-010-md-to-epub` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-010-md-to-fb2` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `auto-010-md-to-gif` | FAIL | WARN | b: PDFium resolved | dB 73.831; SSIM 0.999990 |
| `auto-011-cbz-to-htmlz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-011-cbz-to-hwpx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-011-cbz-to-icns` | WARN | WARN | b: within thresholds | dB 35.302..42.172; SSIM 0.998665..0.999863; within thresholds |
| `auto-011-cbz-to-ico` | WARN | WARN | b: within thresholds | dB 32.552..39.962; SSIM 0.997960..0.999729; within thresholds |
| `auto-012-txt-to-jp2` | FAIL | WARN | b: PDFium resolved | dB 79.047; SSIM 0.999994 |
| `auto-012-txt-to-jpg` | FAIL | WARN | b: PDFium resolved | dB 61.944; SSIM 0.999681 |
| `auto-012-txt-to-jxl` | FAIL | WARN | b: PDFium resolved | dB 59.608; SSIM 0.999488 |
| `auto-012-txt-to-lit` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-012-txt-to-lrf` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-012-txt-to-md` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `auto-015-7z-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-015-7z-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-015-7z-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-016-aac-to-mka` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-017-ac3-to-opus` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-017-ac3-to-weba` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-019-au-to-mka` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-020-avi-to-mkv` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-021-avif-to-mxf` | WARN | WARN | b: media packets | media packets |
| `auto-021-avif-to-pdf` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `auto-021-avif-to-png` | WARN | WARN | b: within thresholds | dB 34.261; SSIM 0.999930; within thresholds |
| `auto-021-avif-to-ppm` | WARN | WARN | b: within thresholds | dB 34.261; SSIM 0.999891; within thresholds |
| `auto-022-azw3-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-022-azw3-to-pdb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-022-azw3-to-psb` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-022-azw3-to-psd` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-023-caf-to-opus` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-023-caf-to-weba` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-024-docm-to-tcr` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-024-docm-to-tga` | FAIL | PASS | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-025-dotm-to-avif` | FAIL | WARN | b: PDFium resolved | dB 67.664; SSIM 0.999947 |
| `auto-025-dotm-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-025-dotm-to-tiff` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-025-dotm-to-txt` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `auto-025-dotm-to-txtz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-025-dotm-to-webp` | FAIL | PASS | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-026-dotx-to-bmp` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-026-dotx-to-cbz` | FAIL | WARN | b: PDFium resolved | dB 61.110; SSIM 0.999761 |
| `auto-026-dotx-to-docm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-026-dotx-to-docx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-026-dotx-to-dotm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-027-dv-to-webm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-029-eot-to-woff` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-030-epub-to-fb2` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `auto-030-epub-to-gif` | FAIL | WARN | b: PDFium resolved | dB 75.212; SSIM 0.999993 |
| `auto-030-epub-to-htmlz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-030-epub-to-hwpx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-032-flv-to-icns` | WARN | WARN | b: within thresholds | dB 41.216..46.846; SSIM 0.999756..0.999926; within thresholds |
| `auto-032-flv-to-ico` | FAIL | FAIL | b?: ICO resampling | dB 29.974..37.346; SSIM 0.996098..0.999240 |
| `auto-032-flv-to-jp2` | WARN | WARN | b: within thresholds | dB 40.864; SSIM 0.999909; within thresholds |
| `auto-032-flv-to-jpg` | FAIL | FAIL | b?: JPEG encoding | dB 27.393; SSIM 0.999092 |
| `auto-032-flv-to-jxl` | WARN | WARN | b: within thresholds | dB 33.889; SSIM 0.999326; within thresholds |
| `auto-033-htmlz-to-epub` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-033-htmlz-to-lit` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-033-htmlz-to-lrf` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-033-htmlz-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-033-htmlz-to-odt` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-034-hwp-to-mov` | WARN | WARN | b: media packets | media packets |
| `auto-034-hwp-to-mp4` | WARN | WARN | b: media packets | media packets |
| `auto-034-hwp-to-pdb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-034-hwp-to-png` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-035-hwpx-to-ppm` | FAIL | PASS | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-035-hwpx-to-psb` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-035-hwpx-to-psd` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-035-hwpx-to-rb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-036-icns-to-m2ts` | WARN | WARN | b: media packets | media packets |
| `auto-036-icns-to-m4v` | WARN | WARN | b: media packets | media packets |
| `auto-036-icns-to-mkv` | WARN | WARN | b: media packets | media packets |
| `auto-036-icns-to-mpg` | WARN | WARN | b: media packets | media packets |
| `auto-036-icns-to-mxf` | WARN | WARN | b: media packets | media packets |
| `auto-037-jxl-to-tex` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-037-jxl-to-tga` | WARN | WARN | b: within thresholds | dB 56.575; SSIM 0.999977; within thresholds |
| `auto-037-jxl-to-tiff` | WARN | WARN | b: within thresholds | dB 56.575; SSIM 0.999977; within thresholds |
| `auto-037-jxl-to-ts` | WARN | WARN | b: media packets | media packets |
| `auto-038-lit-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-038-lit-to-doc` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-038-lit-to-docm` | FAIL | WARN | b: generated cover | dB 14.085; SSIM 0.954056; generated cover |
| `auto-038-lit-to-docx` | FAIL | WARN | b: generated cover | dB 17.255; SSIM 0.173460; generated cover |
| `auto-038-lit-to-snb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-038-lit-to-tcr` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-039-lrf-to-dotm` | WARN | WARN | b: generated cover | dB 22.362; SSIM 0.997112; generated cover |
| `auto-039-lrf-to-dotx` | FAIL | WARN | b: generated cover | dB 16.709; SSIM 0.348315; generated cover |
| `auto-039-lrf-to-epub` | FAIL | WARN | b: generated cover | dB 13.838; SSIM 0.252080; generated cover |
| `auto-039-lrf-to-fb2` | FAIL | WARN | b: generated cover | text 1.000000; dB 16.754; SSIM 0.936707; generated cover |
| `auto-039-lrf-to-html` | FAIL | WARN | b: generated cover | text 1.000000; dB 13.217; SSIM -0.177794; generated cover |
| `auto-039-lrf-to-htmlz` | FAIL | PASS | a/b: replay matches reference | reference match on replay |
| `auto-040-m2ts-to-webm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-041-m4a-to-mka` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-042-m4b-to-opus` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-042-m4b-to-weba` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-043-m4v-to-avif` | WARN | WARN | b: within thresholds | dB 45.450; SSIM 0.999932; within thresholds |
| `auto-043-m4v-to-bmp` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-043-m4v-to-cbz` | FAIL | FAIL | b?: JPEG encoding | dB 28.027; SSIM 0.993090 |
| `auto-045-mkv-to-hwpx` | FAIL | FAIL | b?: JPEG encoding | dB 27.914; SSIM 0.993128 |
| `auto-045-mkv-to-icns` | WARN | WARN | b: within thresholds | dB 41.216..46.846; SSIM 0.999756..0.999926; within thresholds |
| `auto-045-mkv-to-ico` | FAIL | FAIL | b?: ICO resampling | dB 29.974..37.346; SSIM 0.996098..0.999240 |
| `auto-045-mkv-to-jp2` | WARN | WARN | b: within thresholds | dB 40.864; SSIM 0.999909; within thresholds |
| `auto-045-mkv-to-jpg` | FAIL | FAIL | b?: JPEG encoding | dB 27.393; SSIM 0.999092 |
| `auto-046-mobi-to-jxl` | FAIL | WARN | b: PDFium resolved | dB 58.698–60.846; SSIM 0.999432–0.999894 |
| `auto-046-mobi-to-lit` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-046-mobi-to-lrf` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-046-mobi-to-odt` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-047-mov-to-mkv` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-048-mp2-to-mka` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-049-mpg-to-mxf` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-049-mpg-to-pdf` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `auto-049-mpg-to-psb` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-050-mxf-to-psd` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-050-mxf-to-tiff` | WARN | WARN | b: image metadata | dB 99.000; SSIM 1.000000; image metadata |
| `auto-051-odp-to-potx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-051-odp-to-ppsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-051-odp-to-pptm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-051-odp-to-pptx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-052-ods-to-xlsm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-052-ods-to-xlsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-052-ods-to-xltx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-053-opus-to-opus` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-053-opus-to-weba` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-054-pdb-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-054-pdb-to-rb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-054-pdb-to-rtf` | FAIL | WARN | b: generated cover | text 1.000000; dB 14.059; SSIM 0.962554; generated cover |
| `auto-054-pdb-to-snb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-054-pdb-to-tcr` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-055-pdf-to-pdb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-055-pdf-to-txtz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-055-pdf-to-webm` | WARN | WARN | b: media packets | media packets |
| `auto-055-pdf-to-webp` | FAIL | PASS | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-055-pdf-to-wmv` | WARN | WARN | b: media packets | media packets |
| `auto-056-potx-to-avif` | WARN | WARN | b: image metadata | dB 99.000; SSIM 1.000000; image metadata |
| `auto-056-potx-to-odp` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-056-potx-to-ppsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-056-potx-to-pptm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-056-potx-to-pptx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-057-ppsx-to-odp` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-057-ppsx-to-potx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-057-ppsx-to-pptm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-057-ppsx-to-pptx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-058-ppt-to-bmp` | WARN | WARN | b: image metadata | dB 99.000; SSIM 1.000000; image metadata |
| `auto-058-ppt-to-cbz` | FAIL | WARN | b: embedded encoding | dB 99.000; SSIM 1.000000; embedded encoding |
| `auto-058-ppt-to-doc` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-058-ppt-to-odp` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-058-ppt-to-potx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-058-ppt-to-ppsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-059-pptm-to-docm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-059-pptm-to-docx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-059-pptm-to-dotm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-059-pptm-to-dotx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-059-pptm-to-epub` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-059-pptm-to-fb2` | FAIL | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `auto-060-psb-to-3g2` | WARN | WARN | b: media packets | media packets |
| `auto-060-psb-to-3gp` | WARN | WARN | b: media packets | media packets |
| `auto-060-psb-to-avi` | WARN | WARN | b: media packets | media packets |
| `auto-060-psb-to-dv` | WARN | WARN | b: media packets | media packets |
| `auto-060-psb-to-flv` | WARN | WARN | b: media packets | media packets |
| `auto-060-psb-to-gif` | FAIL | WARN | c: fixed alpha/composite/canvas | dB 33.878; SSIM 0.998006; within thresholds |
| `auto-061-psd-to-html` | FAIL | FAIL | c/b: markup resource handoff | text 0.963090; embedded count 0 -> 1 |
| `auto-061-psd-to-hwp` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-061-psd-to-hwpx` | FAIL | WARN | b: embedded encoding | dB 43.246; SSIM 0.999697; embedded encoding |
| `auto-061-psd-to-icns` | WARN | WARN | b: within thresholds | dB 43.748..48.567; SSIM 0.999667..0.999930; within thresholds |
| `auto-061-psd-to-ico` | WARN | WARN | b: within thresholds | dB 34.902..42.149; SSIM 0.997774..0.999646; within thresholds |
| `auto-062-rb-to-lit` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-062-rb-to-lrf` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-062-rb-to-md` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-062-rb-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-062-rb-to-odt` | FAIL | WARN | b: generated cover | dB 16.512; SSIM 0.084195; generated cover |
| `auto-062-rb-to-pdb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-063-snb-to-pdf` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-063-snb-to-rb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-063-snb-to-rst` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-063-snb-to-rtf` | FAIL | WARN | c: fixed indentation; b: cover | text 1.000000; dB 16.874; SSIM 0.229619; generated cover |
| `auto-063-snb-to-tcr` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-064-svg-to-jp2` | FAIL | FAIL | b: CoreSVG (accepted) | dB 31.823; SSIM 0.870260 |
| `auto-064-svg-to-jpg` | FAIL | FAIL | b: CoreSVG (accepted) | dB 39.351; SSIM 0.931245 |
| `auto-064-svg-to-jxl` | FAIL | FAIL | b: CoreSVG (accepted) | dB 31.827; SSIM 0.870225 |
| `auto-064-svg-to-m2ts` | WARN | WARN | b: media packets | media packets |
| `auto-064-svg-to-m4v` | WARN | WARN | b: media packets | media packets |
| `auto-065-svgz-to-mkv` | WARN | WARN | b: media packets | media packets |
| `auto-065-svgz-to-mov` | WARN | WARN | b: media packets | media packets |
| `auto-065-svgz-to-mp4` | WARN | WARN | b: media packets | media packets |
| `auto-065-svgz-to-mpg` | WARN | WARN | b: media packets | media packets |
| `auto-065-svgz-to-mxf` | WARN | WARN | b: media packets | media packets |
| `auto-066-tbz2-to--` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-066-tbz2-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-066-tbz2-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-066-tbz2-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-066-tbz2-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-067-tcr-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-067-tcr-to-doc` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-067-tcr-to-snb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-067-tcr-to-tex` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-067-tcr-to-txtz` | FAIL | PASS | a/b: replay matches reference | reference match on replay |
| `auto-068-tga-to-png` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-068-tga-to-psb` | FAIL | WARN | c: fixed alpha/composite/canvas | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-068-tga-to-psd` | FAIL | WARN | c: fixed alpha/composite/canvas | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-069-tgz-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-069-tgz-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-069-tgz-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-069-tgz-to-txz` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-069-tgz-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-070-ts-to-webm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-071-txtz-to-avif` | FAIL | WARN | b: PDFium resolved | dB 57.754; SSIM 0.999954 |
| `auto-071-txtz-to-bmp` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-071-txtz-to-cbz` | FAIL | WARN | b: PDFium resolved | dB 58.434; SSIM 0.999785 |
| `auto-071-txtz-to-docm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-071-txtz-to-docx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-071-txtz-to-dotm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-072-txz-to--` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-072-txz-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-072-txz-to-tbz2` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-072-txz-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-074-voc-to-mka` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-075-weba-to-opus` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-075-weba-to-weba` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-076-webm-to-hwpx` | FAIL | FAIL | b?: JPEG encoding | dB 27.920; SSIM 0.993238 |
| `auto-076-webm-to-icns` | WARN | WARN | b: within thresholds | dB 41.173..46.911; SSIM 0.999760..0.999928; within thresholds |
| `auto-077-webp-to-dotx` | FAIL | WARN | b: embedded encoding | dB 44.773; SSIM 0.999729; embedded encoding |
| `auto-077-webp-to-html` | FAIL | FAIL | c/b: markup resource handoff | text 0.963090; embedded count 0 -> 1 |
| `auto-077-webp-to-hwp` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-079-wmv-to-ico` | FAIL | FAIL | b?: ICO resampling | dB 29.802..37.385; SSIM 0.995891..0.999264 |
| `auto-079-wmv-to-jp2` | WARN | WARN | b: within thresholds | dB 40.751; SSIM 0.999907; within thresholds |
| `auto-079-wmv-to-jpg` | FAIL | FAIL | b?: JPEG encoding | dB 27.580; SSIM 0.999108 |
| `auto-079-wmv-to-jxl` | WARN | WARN | b: within thresholds | dB 33.496; SSIM 0.999181; within thresholds |
| `auto-081-woff2-to-woff` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-082-xls-to-ods` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-082-xls-to-xlsm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-082-xls-to-xlsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-082-xls-to-xltx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-083-xlsm-to-ods` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-083-xlsm-to-xlsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-083-xlsm-to-xltx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-084-xlsx-to-ods` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-084-xlsx-to-xlsm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-084-xlsx-to-xltx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-085-xltx-to-lit` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-085-xltx-to-ods` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-085-xltx-to-xlsm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-085-xltx-to-xlsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-087-svg-to-mp4` | WARN | WARN | b: media packets | media packets |
| `auto-087-svg-to-mpg` | WARN | WARN | b: media packets | media packets |
| `auto-087-svg-to-mxf` | WARN | WARN | b: media packets | media packets |
| `auto-090-ttf-to-woff` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-091-bmp-to-pdf` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `auto-091-bmp-to-png` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-091-bmp-to-psb` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-091-bmp-to-psd` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-091-bmp-to-rst` | FAIL | WARN | b: within thresholds | text 1.000000; within thresholds |
| `auto-092-ppm-to-rtf` | FAIL | WARN | b: within thresholds | text 0.999210; dB 49.166; SSIM 0.999905; within thresholds |
| `auto-092-ppm-to-tex` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-092-ppm-to-tiff` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-092-ppm-to-ts` | WARN | WARN | b: media packets | media packets |
| `auto-093-tga-to-3g2` | WARN | WARN | b: media packets | media packets |
| `auto-093-tga-to-vob` | WARN | WARN | b: media packets | media packets |
| `auto-093-tga-to-webm` | WARN | WARN | b: media packets | media packets |
| `auto-093-tga-to-webp` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-093-tga-to-wmv` | WARN | WARN | b: media packets | media packets |
| `auto-094-eml-to-lrf` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-094-eml-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-094-eml-to-pdb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-096-html-to-avif` | FAIL | WARN | b: PDFium resolved | dB 58.380; SSIM 0.999946 |
| `auto-096-html-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-096-html-to-bmp` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-096-html-to-cbz` | FAIL | WARN | b: PDFium resolved | dB 60.216; SSIM 0.999750 |
| `auto-096-html-to-doc` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-096-html-to-tcr` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-097-rst-to-docm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-097-rst-to-docx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-097-rst-to-dotm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-097-rst-to-dotx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-097-rst-to-epub` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-097-rst-to-fb2` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `auto-098-tex-to-gif` | WARN | WARN | b: image metadata | dB 43.606; SSIM 0.969291; image metadata |
| `auto-098-tex-to-htmlz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-098-tex-to-hwpx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-098-tex-to-ico` | WARN | WARN | b: within thresholds | dB 35.337..45.651; SSIM 0.999163..0.999929; within thresholds |
| `auto-099-png-to-3gp` | WARN | WARN | b: media packets | media packets |
| `auto-099-png-to-avi` | WARN | WARN | b: media packets | media packets |
| `auto-099-png-to-dv` | WARN | WARN | b: media packets | media packets |
| `auto-099-png-to-flv` | WARN | WARN | b: media packets | media packets |
| `auto-100-avif-to-icns` | WARN | WARN | b: within thresholds | dB 36.349..39.577; SSIM 0.999648..0.999889; within thresholds |
| `auto-100-avif-to-jp2` | WARN | WARN | b: within thresholds | dB 34.227; SSIM 0.999904; within thresholds |
| `auto-100-avif-to-jpg` | WARN | WARN | b: within thresholds | dB 33.394; SSIM 0.999601; within thresholds |
| `auto-100-avif-to-jxl` | WARN | WARN | b: within thresholds | dB 33.100; SSIM 0.999578; within thresholds |
| `auto-100-avif-to-m2ts` | WARN | WARN | b: media packets | media packets |
| `auto-101-gif-to-md` | FAIL | FAIL | c/b: markup resource handoff | text 0.642857; actual Swift JPEG sidecar; C# asset absent |
| `auto-101-gif-to-mkv` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-102-heic-to-mp4` | WARN | WARN | b: media packets | media packets |
| `auto-102-heic-to-mpg` | WARN | WARN | b: media packets | media packets |
| `auto-102-heic-to-mxf` | WARN | WARN | b: media packets | media packets |
| `auto-103-jp2-to-pdf` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `auto-103-jp2-to-png` | WARN | WARN | b: within thresholds | dB 58.227; SSIM 0.999991; within thresholds |
| `auto-103-jp2-to-ppm` | WARN | WARN | b: within thresholds | dB 58.851; SSIM 0.999987; within thresholds |
| `auto-104-jpg-to-psb` | WARN | WARN | b: within thresholds | dB 47.066; SSIM 0.999962; within thresholds |
| `auto-104-jpg-to-psd` | WARN | WARN | b: within thresholds | dB 47.066; SSIM 0.999962; within thresholds |
| `auto-104-jpg-to-rst` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-104-jpg-to-rtf` | FAIL | WARN | b: within thresholds | text 0.999210; dB 39.845; SSIM 0.999582; within thresholds |
| `auto-104-jpg-to-tex` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-104-jpg-to-tga` | WARN | WARN | b: within thresholds | dB 47.066; SSIM 0.999962; within thresholds |
| `auto-105-psd-to-tiff` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-105-psd-to-ts` | WARN | WARN | b: media packets | media packets |
| `auto-105-psd-to-vob` | WARN | WARN | b: media packets | media packets |
| `auto-106-tiff-to-webm` | WARN | WARN | b: media packets | media packets |
| `auto-106-tiff-to-webp` | WARN | WARN | b: within thresholds | dB 46.651; SSIM 0.999815; within thresholds |
| `auto-106-tiff-to-wmv` | WARN | WARN | b: media packets | media packets |
| `auto-107-pptx-to-lit` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-107-pptx-to-odp` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-107-pptx-to-potx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-107-pptx-to-ppsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-107-pptx-to-pptm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-108-csv-to-ods` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-108-csv-to-xlsm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-108-csv-to-xlsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-108-csv-to-xltx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-109-tsv-to-lrf` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-109-tsv-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-109-tsv-to-ods` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-109-tsv-to-pdb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-110-doc-to-avif` | FAIL | WARN | b: PDFium resolved | dB 67.894; SSIM 0.999944 |
| `auto-110-doc-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-110-doc-to-bmp` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-110-doc-to-tcr` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-111-docx-to-cbz` | FAIL | WARN | b: PDFium resolved | dB 61.110; SSIM 0.999761 |
| `auto-111-docx-to-docm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-111-docx-to-dotm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-111-docx-to-dotx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-111-docx-to-epub` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-112-html-to-docx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-112-html-to-fb2` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `auto-112-html-to-gif` | FAIL | WARN | b: PDFium resolved | dB 68.179; SSIM 0.999924 |
| `auto-112-html-to-htmlz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `auto-112-html-to-hwpx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-113-odt-to-ico` | WARN | WARN | b: within thresholds | dB 35.166..44.492; SSIM 0.999117..0.999902; within thresholds |
| `auto-113-odt-to-jp2` | FAIL | WARN | b: PDFium resolved | dB 78.773; SSIM 0.999993 |
| `auto-113-odt-to-jpg` | FAIL | WARN | b: PDFium resolved | dB 61.959; SSIM 0.999683 |
| `auto-113-odt-to-jxl` | FAIL | WARN | b: PDFium resolved | dB 60.509; SSIM 0.999560 |
| `auto-113-odt-to-lit` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-114-rtf-to-lrf` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-114-rtf-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-114-rtf-to-odt` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-114-rtf-to-pdb` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-118-wav-to-mka` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `auto-119-pdf-to-icns` | WARN | WARN | b: within thresholds | dB 35.302..42.172; SSIM 0.998665..0.999863; within thresholds |
| `auto-119-pdf-to-m2ts` | FAIL | WARN | c: fixed alpha/composite/canvas | media packets |
| `auto-119-pdf-to-m4v` | FAIL | WARN | c: fixed alpha/composite/canvas | media packets |
| `auto-119-pdf-to-mkv` | FAIL | WARN | c: fixed alpha/composite/canvas | media packets |
| `auto-119-pdf-to-mov` | FAIL | WARN | c: fixed alpha/composite/canvas | media packets |
| `auto-119-pdf-to-mp4` | FAIL | WARN | c: fixed alpha/composite/canvas | media packets |
| `auto-120-txt-to-png` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-120-txt-to-ppm` | FAIL | PASS | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-120-txt-to-psb` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-120-txt-to-psd` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-121-pdf-to-mpg` | WARN | WARN | b: media packets | media packets |
| `auto-121-pdf-to-mxf` | WARN | WARN | b: media packets | media packets |
| `auto-121-pdf-to-rst` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-121-pdf-to-rtf` | FAIL | WARN | b: within thresholds | text 0.998826; dB 39.750; SSIM 0.999223; within thresholds |
| `auto-122-png-to-tex` | WARN | WARN | b: within thresholds | within thresholds |
| `auto-122-png-to-tiff` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `auto-122-png-to-ts` | WARN | WARN | b: media packets | media packets |
| `auto-123-txt-to-avif` | FAIL | WARN | b: PDFium resolved | dB 69.958; SSIM 0.999950 |
| `auto-123-txt-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-123-txt-to-bmp` | FAIL | WARN | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `auto-123-txt-to-tcr` | WARN | WARN | b: unsupported binary | unsupported binary |
| `auto-123-txt-to-webp` | FAIL | PASS | b: PDFium resolved | dB 99.000; SSIM 1.000000 |
| `builtin-jpg-70` | WARN | WARN | b: within thresholds | dB 39.848; SSIM 0.999537; within thresholds |
| `builtin-merge-pdf` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `builtin-pdf-split` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `builtin-tiff-300` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `builtin-to-7z` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-avif` | WARN | WARN | b: within thresholds | dB 42.377; SSIM 0.999774; within thresholds |
| `builtin-to-azw3` | WARN | WARN | b: unsupported binary | unsupported binary |
| `builtin-to-bmp` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `builtin-to-cbz` | FAIL | WARN | b: PDFium resolved | dB 58.403; SSIM 0.999782 |
| `builtin-to-docx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-epub` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-fb2` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `builtin-to-gif` | WARN | WARN | b: image metadata | dB 35.653; SSIM 0.996936; image metadata |
| `builtin-to-icns` | WARN | WARN | b: within thresholds | dB 36.244..39.461; SSIM 0.999658..0.999888; within thresholds |
| `builtin-to-ico` | WARN | WARN | b: within thresholds | dB 34.553..42.896; SSIM 0.997811..0.999627; within thresholds |
| `builtin-to-jpg` | WARN | WARN | b: within thresholds | dB 48.418; SSIM 0.999950; within thresholds |
| `builtin-to-jxl` | WARN | WARN | b: within thresholds | dB 38.672; SSIM 0.999784; within thresholds |
| `builtin-to-md` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `builtin-to-mkv` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-mobi` | WARN | WARN | b: unsupported binary | unsupported binary |
| `builtin-to-odp` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-ods` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-odt` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-opus` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-pdf` | WARN | WARN | b: within thresholds | within thresholds |
| `builtin-to-png` | WARN | WARN | b: within thresholds | dB 34.261; SSIM 0.999930; within thresholds |
| `builtin-to-pptx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-psd` | FAIL | WARN | c: fixed alpha/composite/canvas | dB 36.822; SSIM 0.999953; within thresholds |
| `builtin-to-tar` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-tga` | FAIL | WARN | b: image metadata | dB 99.000; SSIM 1.000000; image metadata |
| `builtin-to-tgz` | FAIL | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-tiff` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `builtin-to-webm` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-webp` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `builtin-to-woff` | WARN | WARN | b: within thresholds | within thresholds |
| `builtin-to-xlsx` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-to-zip` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `builtin-zip-all` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-archive-fast` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-archive-maximum` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-archive-normal` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-archive-store` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-background-black` | WARN | WARN | b: within thresholds | dB 33.589; SSIM 0.999773; within thresholds |
| `option-conflict-overwrite` | WARN | WARN | b: within thresholds | dB 33.786; SSIM 0.999622; within thresholds |
| `option-conflict-rename` | WARN | WARN | b: within thresholds | dB 33.786; SSIM 0.999622; within thresholds |
| `option-dpi-300` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `option-engine-archive` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-engine-calibre` | WARN | WARN | b: unsupported binary | unsupported binary |
| `option-engine-docx-writer` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-engine-font` | WARN | WARN | b: within thresholds | within thresholds |
| `option-engine-hwpx-writer` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-engine-icns` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `option-engine-libreoffice` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-engine-magick` | WARN | WARN | b: within thresholds | dB 33.786; SSIM 0.999622; within thresholds |
| `option-engine-ooxml` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-engine-pandoc` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-engine-pdfium` | WARN | WARN | b: within thresholds | dB 41.959..44.259; SSIM 0.999837..0.999942; within thresholds |
| `option-engine-pdfsharp` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `option-engine-spreadsheet` | WARN | PASS | a: comparator normalization | semantic/normalized match |
| `option-engine-unhwp` | WARN | PASS | a: comparator normalization | text 1.000000; semantic/normalized match |
| `option-engine-vector` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `option-grayscale` | WARN | WARN | b: within thresholds | dB 55.145; SSIM 0.999949; within thresholds |
| `option-ico-sizes` | WARN | WARN | b: within thresholds | dB 34.497..39.817; SSIM 0.997857..0.999386; within thresholds |
| `option-keep-dates` | WARN | WARN | b: within thresholds | dB 33.786; SSIM 0.999622; within thresholds |
| `option-location-customFolder` | WARN | WARN | b: within thresholds | dB 33.786; SSIM 0.999622; within thresholds |
| `option-location-sameFolder` | WARN | WARN | b: within thresholds | dB 33.786; SSIM 0.999622; within thresholds |
| `option-location-subfolder` | WARN | WARN | b: within thresholds | dB 33.786; SSIM 0.999622; within thresholds |
| `option-merge-pdf` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `option-multipage-tiff` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `option-naming` | WARN | WARN | b: within thresholds | dB 31.291..33.786; SSIM 0.999614..0.999622; within thresholds |
| `option-page-a4` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `option-page-letter` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `option-page-range` | WARN | WARN | b: within thresholds | dB 45.776; SSIM 0.999964; within thresholds |
| `option-quality-25` | WARN | WARN | b: within thresholds | dB 37.552; SSIM 0.998080; within thresholds |
| `option-quality-95` | WARN | WARN | b: within thresholds | dB 34.319; SSIM 0.999737; within thresholds |
| `option-render-300` | WARN | WARN | b: within thresholds | dB 42.214..44.512; SSIM 0.999848..0.999946; within thresholds |
| `option-render-72` | WARN | WARN | b: within thresholds | dB 45.776..46.289; SSIM 0.999838..0.999964; within thresholds |
| `option-resize-long-edge` | WARN | WARN | b: within thresholds | dB 43.624; SSIM 0.999962; within thresholds |
| `option-resize-percent` | WARN | WARN | b: within thresholds | dB 43.624; SSIM 0.999962; within thresholds |
| `option-split-pages` | WARN | WARN | b: empty-text PDF | empty-text PDF |
| `option-strip-metadata` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `option-tiff-lzw` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `option-tiff-none` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `option-tiff-zip` | WARN | WARN | b: within thresholds | dB 99.000; SSIM 1.000000; within thresholds |
| `option-webp-lossless` | WARN | WARN | b: within thresholds | dB 53.413; SSIM 0.999974; within thresholds |

## Performance integration (2026-10-23)

Recovered the interrupted work based on `15943f6`. The original agent worktrees, installed C# reference application
and original user data were preserved. No dependency was added. Production changes are signed commits:

- `ee715af`: linear ebook regex replacement and document/XML escaping and trimming fast paths; eight regressions.
- `5ff2f80`: ad-hoc Release helper signing fix for bundled PDFium, with a signing-entitlement regression test.
- `87708cb`: independent PDFKit text workers, attribute/format caching and serialized attributed-string creation;
  page order, every text run's style and cancellation are covered by two regressions.
- `f6a7c07`: Markdown reference indexing, literal scans and allocation reductions; four regressions.
- `a064ab8`: preserve canonical Unicode escaping. U+1FEF equals a backtick under Swift Character equality, so
  non-ASCII text must reach the original Character predicate. Isolated, embedded and mixed cases were added to
  the existing document regression. Independent re-review found the issue resolved and no remaining findings.

PDF text remains on PDFKit: a PDFium text draft changed Korean spacing in three corpus PDFs and was rejected.
Each text worker owns its PDFDocument and reader; page order is restored before header/footer removal and
assembly. Only attributed-string construction uses the new shared lock, reducing Foundation attribute-table
contention. PDFium raster rendering and its global lock are unchanged. Cross-job throughput of the text lock is
unmeasured. The subsequent Markdown autolink experiment was slower and was not retained.

Measurements and goal gaps are recorded in [the benchmark results](../../Tools/engine-bench/README.md#optimisation-results-2026-10-23).
Focused evidence remains under `build/resume/{pdf-next-validation,ebook-validation,markdown-next-validation}`.

### Final conversion replay

The final production host is retained at `build/resume/final-integrated-host/FileToXEngine`, SHA-256
`7d661dbea80547e3f8eecfbc6f12ea77a7552bd17b2148c2819fca7bf45a2774`. Its bundle, all 290 captured source
hashes, the 124 corpus files and the harness inputs matched before and after the replay. The snapshot includes
all five production commits above; committing the already captured Unicode fix did not change source bytes.

All **849 cases** were replayed at unchanged thresholds: **578 PASS / 263 WARN / 8 FAIL**. Raw states match the
C# baseline and previous Swift run: **786 completed / 63 failed**, with **zero harness or inspection errors**.
The eight strict FAILs remain recorded:

- Three SVG raster cases: `auto-064-svg-to-{jp2,jpg,jxl}`, the accepted CoreSVG/Svg.Skia rendering difference.
- Four broken C# image references: `auto-061-psd-to-html`, `auto-077-webp-to-html`, `auto-086-dxf-to-md`,
  `auto-101-gif-to-md`. Swift's outputs preserve the image sidecars.
- `auto-067-tcr-to-txtz`: generated Calibre cover variation and OCR disagreement. It was WARN in the preceding
  replay and is FAIL in this one; the threshold was not relaxed.

The seven non-cover FAIL outputs are byte-identical to the preceding Swift candidate. The preceding frozen-host
round had **577 PASS / 265 WARN / 7 FAIL**; two Calibre cover statuses explain the count changes. The first attempt
executed **0/849** because optional engine folders had been intentionally removed after earlier validation.
Those missing prerequisites were restored before either complete round; the failed attempt is not a test pass.

All 55 changed binary book/document outputs were read back through Calibre (165 commands), and all final text
readbacks matched the C# baseline. This is still not proof of layout or embedded-object equivalence. Decompressed
TCR bytes exposed a real quality issue hidden by binary WARN: `auto-096-html-to-tcr` has a spurious trailing `Fil`
versus the source and preceding Swift output, also present in the C# baseline. Two preceding TCR outputs contained
invalid UTF-8 that the final run did not contain (`auto-038-lit-to-tcr` and `auto-063-snb-to-tcr`; DOCM/PDB payloads
were valid and identical). These findings are not waived as harmless metadata. Existing question-mark losses
in PDB/RB-derived text also remain where the C# baseline matches. No blanket claim of full content equivalence is made.

A bounded direct-engine investigation reproduced corruption in unchanged **Calibre 9.15.0 without either host**.
Four conversions of byte-identical HTML with isolated profiles produced two clean 49-byte payloads and two
52-byte payloads with trailing `Fil`, exactly matching the replay variants. Direct compressor probes isolated
the defect to `TCRCompressor._combine_codes`: changing dictionary meanings while a terminal/stale code remains
in the stream corrupts content; unordered set iteration makes the result process-dependent. The same method
reproduced the exact invalid UTF-8 SNB payload from valid input. Calibre's own decompressor agreed with the
independent decoder, excluding a readback-decoder explanation. The particular LIT variant was not separately
reproduced. The external TCR defect remains unfixed; no version, format or quality threshold was changed.
Evidence and exact seven-call reproduction: `build/resume/tcr-variability-triage/{findings.md,summary.json}`.

Six generated DWG files also read back successfully to DXF through the final Swift host; content matched apart
from four time fields. This does not replace AutoCAD/ODA validation.

Commands, per-case evidence and limits: `build/resume/final-replay-r3-summary.json`,
`build/resume/final-replay-r3-comparison/report.{json,md}` and `build/resume/final-replay-r3-inspection/`.

### Build, tests and packaging

- Final-source SwiftPM tests after the Unicode fix: **524 engine tests, 17 skipped, zero failures**, and
  **12 Core tests, zero failures** (536 total). Log: `build/resume/swift-test-post-review.log`.
- Production `swift build -c release --jobs 4 --product FileToXEngine`: succeeded, including the Unicode fix.
  Log: `build/resume/swift-release-final.log`.
- SDK-denying Xcode `clean build-for-testing`: succeeded with the optimisations and signing phase.
  Log: `build/resume/xcode-clean-isolated-final.log`.
- Full Xcode tests from that clean build: **74 app tests + 524 engine tests**, **56 skipped**, **zero failures**.
  Log: `build/resume/xcode-test-final.log`. This build preceded the final Unicode correction.
- Xcode engine tests inside the SDK-denying sandbox: **523 tests, 56 skipped, zero failures**. Only
  `ProcessRunnerTests.testTimeoutKillsTheWholeTree` was explicitly excluded because that sandbox cannot execute
  `/bin/ps` (`Operation not permitted`), independently reproduced. It passed in the normal full runs.
  Log: `build/resume/xcode-engine-test-isolated-final.log`.
- The Unicode correction was subsequently rebuilt and tested by Xcode inside the same SDK-denying sandbox:
  **five document text tests, zero skips, zero failures**. Log: `build/resume/xcode-unicode-test-isolated.log`.
- Final-source Xcode Release build in the SDK-denying sandbox: succeeded.
  Log: `build/resume/xcode-release-isolated-final.log`.
- The final Release copy contains **no .NET runtime files, DLLs or runtime/dependency manifests**; `otool -L`
  contains no .NET links, and `codesign --verify --deep --strict` passed.
- Relocated final Release copies passed **22 smoke checks ad hoc and 22 with the existing personal development
  certificate**, with repository, SDK and NuGet access denied. Each run includes 20 real conversions and two
  selection checks, with no staging leftovers. Logs: `build/resume/release-final-smoke-{adhoc,certificate}.log`;
  audit: `build/resume/release-final-bundle-audit.json`; copy path: `build/resume/release-final-proof-path.txt`.
- `Tools/engine-compare/test_harness.py`: **15 passed**. Real settings, history, presets and profiles compared
  through C# and Swift hosts on copies had no semantic differences; original user data was not written.
  Evidence: `build/resume/user-data-baseline/summary.json`.

The signing fix addresses an actual relocated-app failure: ad-hoc hardened helpers and PDFium lack a Team ID,
so library validation rejects the dylib even when signature verification succeeds. A checkout-local rpath could
hide that failure. Apple's [library validation documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
explains the same-Team-ID requirement. `Tools/prepare-engine-entitlements.py` grants the exception only to signing
identity `-`; certificate-signed helpers get an empty dictionary. Xcode passes the generated file directly to
codesign after the script, avoiding a generated `CODE_SIGN_ENTITLEMENTS` dependency cycle. Hardened Runtime
remains enabled, and no bundle ID, project team or local identity was changed.

The relocated certificate proof signs PDFium, the helper and the main app with the existing certificate matching
the personal team already selected in ignored local configuration. All three signatures have that Team ID, the
helper has no library-validation exception, and both signature and runtime checks pass. This is a copy-signing
proof, not an Xcode certificate-signing build, Developer ID distribution or notarization.

### Isolation and remaining limits

`build/isolated.sb` denies reads/writes of `~/.dotnet`, `~/.nuget` and `/usr/local/share/dotnet`; an explicit probe
confirmed the denials and absence of `dotnet` from PATH (`build/resume/no-dotnet-probe.log`). Home SDK/NuGet
folders were not deleted or modified. The clean build used:

```sh
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/sandbox-exec -f build/isolated.sb /usr/bin/xcodebuild clean build-for-testing \
  -project FileToX.xcodeproj -scheme FileToX -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-resume-isolated \
  -clonedSourcePackagesDirPath build/DerivedData-unified2/SourcePackages \
  -disableAutomaticPackageResolution -IDEPackageSupportDisableManifestSandbox=YES \
  'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox' -jobs 4
```

The package cache was resolved beforehand. Only nested manifest/compiler sandboxes are disabled to permit the
outer SDK-denying sandbox. This is not a separate SDK-free macOS installation. The full app test host remains
incompatible with the outer sandbox and was tested outside it with the clean PATH. Skipped optional-tool,
fixture and codec tests are not passes. Full visual/layout QA and perceptual media/glyph equivalence are not
established by the comparison harness.

Pandoc 3.12, Calibre 9.15.0 and LibreOffice 26.2.6 were temporarily restored under this checkout's ignored build
folder using pinned SHA-256 archives; no global installation or application settings changed. After all checks and
final measurements, their three copies and verified download archives were removed (**2.84 GB**;
`build/resume/optional-engines-cleanup.json`). Reproduction inputs, decoded bytes, disassembly, reports and frozen
native hosts were retained; reproducing optional-engine calls requires restoring the same pinned engines.
Homebrew FFmpeg and bundled rhwp/7-Zip are preserved. No AutoCAD/ODA application or macOS VM tool was found
locally. Intel runtime, separate-OS testing,
AutoCAD/ODA, Xcode certificate signing, Developer ID signing and notarization remain unverified.

Build tools remain Swift/Xcode and Python 3 (standard-library scripts); XcodeGen is required only to regenerate
the project. Runtime dependencies remain macOS frameworks; native libjpeg-turbo, LibRaw, PDFium, libwebp, libjxl,
Brotli, libxml2 and zlib; bundled rhwp and 7-Zip; optional FFmpeg, Ghostscript, Pandoc, LibreOffice and Calibre.
No installation, deployment, notarization or push was performed.

## Native library follow-up (2026-10-23)

This scoped follow-up fixes TCR output corruption and improves JPEG input parity. It does not replace the
849-case full-run ledger above or claim that its eight strict FAILs have disappeared. No native dependency or
external-engine version was added or changed in production.

### TCR: retain extraction, replace compression

Calibre still parses the book and runs its original TCR output formatter with the original defaults. A short
script executed by the same installation's `calibre-debug` captures the bytes passed to its compressor. The
replacement exists only in that child process; Calibre's installed files and user settings are untouched.
`TcrWriter` then writes a deterministic TCR dictionary/byte stream, assigning only unused codes and keeping
dictionary entries at most 255 bytes. It never redefines a code already used by the stream. Compression checks
task cancellation, and output remains staged until compression succeeds. Empty and binary input are supported.

The companion is found beside the resolved `ebook-convert`, not beside an unrelated PATH symlink. An incomplete
installation without that companion produces an explicit error before publishing output. The script uses
Calibre's embedded Python; it adds no system-Python runtime requirement. Other Calibre output formats retain
their existing command. The upstream compressor remains unfixed; this is a FileToX workaround.

Evidence under `build/resume/tcr-safe-r1/`:

- An independently compiled Swift codec's **35 inputs** (empty, all byte values, Unicode, repeated bytes,
  deterministic random data and saved HTML/SNB/LIT witnesses) round-trip exactly through Calibre's own decoder:
  `codec-results.json`, `verify-codec.py`, `codec-validation.log`.
- **Seven real host conversions**, including DOCM, LIT, PDB, SNB, HTML, DOC and Korean TXT input, all completed
  without harness/inspection errors. Decoded UTF-8 matches the clean expected bytes in all seven. HTML loses
  the erroneous trailing `Fil`; the other six match their clean preceding outputs. `replay/`, `host-readbacks.json`
  and `verify-host.py` preserve the raw evidence. This preserves inherited PDB question-mark losses; it does not
  claim to repair source/import losses unrelated to compression.
- **11 focused tests, zero skips/failures**, including real Calibre writing/reading, binary codec round trips,
  missing/wrong companion behavior and cancellation: `swift-tests-post-review.log`.
- A diagnostic 3,936,033-byte compression produced 571,722 bytes in 2.35 s under concurrent work. This is not
  an integrated conversion benchmark or a claim of equal compressed bytes/size to the faulty compressor.

The TCR replay host is retained at `build/resume/native-followup-host/` with source hashes. Its JPEG decoder
precedes the subsequent progress-monitor correction described below; TCR implementation bytes are unchanged.

### JPEG: reuse the existing C decoder

The existing libjpeg-turbo 3.2.0 C shim now decodes ordinary 8-bit RGB/grayscale JPEG using ImageMagick's libjpeg
defaults. ImageIO retains responsibility for metadata, ICC space, EXIF orientation and resolution. Unsupported
precision/color spaces and CMYK/YCCK preserve the previous ImageIO path. Decode errors and cancellation destroy
the decoder, free samples and clear the output pointer. Swift owns successful samples through a freeing Data.

Worker evidence: `build/resume/jpeg-native-20261023/findings.md` and `host-replay.json`:

- **46 focused image tests passed** without skips, including the initial four new decoder regressions.
- **105 real host conversions** across C#, frozen Swift and candidate Swift. Candidate matches C# pixel for
  pixel in **24/24 non-CMYK raster cases** and **6/6 non-CMYK JPEG re-encodings**. Three JPEG files are also
  byte-identical; remaining metadata/profile bytes differ. All five CMYK outputs remain byte-identical to the
  frozen Swift output, with the existing material C# color difference explicitly unresolved.
- Independent review found a progressive-input cancellation gap: `jpeg_start_decompress` consumes entropy
  scans before output scanlines. A libjpeg progress monitor now checks cancellation in that phase and returns
  the cancellation status through the shared cleanup. A malformed first progressive scan distinguishes this
  path in the regression: the direct C probe returns error status 1 before the fix and cancellation status 2
  after it, with no retained sample buffer. Review of that correction found no remaining actionable issue.

### Additional C/C++ alternatives actually exercised

- **ImageMagick MagickWand C**: direct calls and an official 7.1.2-32 Q8 source build both ran without .NET.
  Decoder/reference hashes matched; explicitly selecting the same grayscale filter made 16/16 resize probes
  byte-identical. The bounded source build still depends on Homebrew libraries, has nonrelocatable install
  names and lacks today's full WebP/JXL/HEIC coverage with a clean PATH. Production adoption needs a complete,
  reproducible coder/delegate configuration and packaging, not just a link to the scratch dylib. Neither the
  installed reference application's native binary nor the scratch Wand build is shipped by FileToX.
- **cmark-gfm C**: official tag `0.29.0.gfm.13` was built and compared. The prototype's TXT median was 0.109 s
  against the frozen host's ~0.91 s, but does different work and omits required semantics. **80,662/119,792**
  byte comparisons differed, including **26,274 TXT outputs**. Missing YAML/math/definition-list/attribute
  handling and renderer differences prevent a global replacement. No production change was retained.
  `build/resume/native-markdown-r1/REPORT.md` records mismatch examples, source pins and exact commands.
- **Skia C++ SkSVGDOM**: a standalone arm64 CPU executable without .NET improved the three targeted SVG
  raster comparisons within unchanged similarity thresholds. Scratch corrections for SVG2 href references and
  percentage viewports raised normalized coverage from 11/16 to **15/16**, versus CoreSVG's 9/16. Image references,
  percentage sizing and pattern/use now match C# pixels exactly; text-path passes at 32.004 dB. Vertical text is
  still worse than CoreSVG (20.382 versus 20.832 dB), so a quality-preserving default replacement is not established.
  Production remains unchanged. `build/resume/svg-skia-cpp-20261023/{REPORT.md,followup/REPORT.md}` preserve
  source pins, the 17.4 MiB arm64 executable, build commands and measurements. Universal packaging, notices,
  a bounded C bridge, resource restrictions and vector-PDF behavior still require implementation/verification.

PDF text remains on PDFKit and Markdown remains on the compatible Swift parser. Their previous <=0.84 s and
<=0.60 s goals remain unmet. COM/IPTC, CMYK, JP2 quality control, grayscale ICO filtering, external CAD validation,
Intel/independent-OS execution and distribution signing/notarization limits above remain open.

### Follow-up integration verification (completed 2026-10-24)

Logs and exact Xcode argument arrays are under `build/resume/tcr-safe-r1/`:

- Full Release SwiftPM run: **534 engine + 12 Core tests**, **28 skipped**, **zero failures**. This preceded the
  final JPEG progress-monitor correction. Missing optional tools and opt-in corpus/fixture paths explain the
  skips; they are not passes. `swift-tests-full.log`.
- Final affected SwiftPM run after that correction: **58 tests, zero skips/failures**, including five decoder
  tests, encoder/resize/raster/ICNS tests and all TCR/Calibre tests. `swift-tests-final-focused.log`.
- SDK-denying Xcode **clean build-for-testing succeeded**; engine tests: **533 tests, 57 skipped, zero failures**.
  As in the previous isolated run, the `/bin/ps`-dependent process-tree timeout test was explicitly excluded;
  it passes in the normal full run. This clean test build also precedes the final JPEG correction.
  `xcode-clean-build-isolated.log`, `xcode-engine-tests-isolated.log`, `xcode-results.json`.
- The final correction was then rebuilt by Xcode inside that sandbox and **all five JPEG decoder tests passed**
  with no skips, including progressive entropy cancellation. `xcode-final-jpeg-tests-isolated.log` and
  `xcode-final-jpeg-command.json`. Regenerated checked-in project membership includes both new test files.
- Final-source **Xcode Release build succeeded** in the SDK-denying sandbox. Bundle audit found **zero .NET
  files and no .NET links**; `codesign --verify --deep --strict` passed. Helper SHA-256:
  `ea2b8e10135f2d37ab09aef4a6ef62da9cc76db872036d081924f411ea9d1919`.
  `xcode-release-isolated.log`, `release-audit.json`.
- A relocated Release copy, with repository/SDK/NuGet access denied and a clean PATH, passed **22 checks**
  (20 actual conversions and two selection checks), with no staging leftovers.
  `release-relocated-proof-final.json`, `release-relocated-smoke-final.log`. The first buffered smoke log was
  empty despite exit 0; it is not used as the check-count evidence. The fresh unbuffered run records all 22.
- The final Release helper separately passed **all seven TCR cases** inside the SDK-denying sandbox. Calibre's
  decoder confirmed the seven clean expected byte streams and valid UTF-8 again.
  `release-tcr-command.json`, `release-tcr-replay.log`, `release-host-readbacks.json`.

No 849-case full replay, Intel execution, new app UI run or distribution signing/notarization was performed in
this follow-up. The installed reference app and original user data remain untouched. Pinned Calibre/LibreOffice
validation copies are retained under ignored `build/optional-engines/osx-arm64/` for reproduction; they are not
registered in user settings or embedded in the Release app. No global installation, push or deployment was made.

## External CAD and certificate-build verification (2026-10-24)

The verified TCR/JPEG follow-up is checkpointed in signed commits `c98dee0`, `4aa80a7` and `194b692`.
Further image, SVG and performance implementation proceeds in separate worktrees. The checks below use the
checkpoint implementation; final-source integration must repeat the affected checks and the full replay.

### External DWG interoperability

The official **ODA File Converter 27.9.0.0 arm64** was downloaded into the ignored verification folder, not
installed in `/Applications` or bundled with FileToX. Its DMG SHA-256 is
`c39ded1268205929b15c82b5211397d01ec1a26ca397567a6b4f9d93432ae599`; deep/strict signature verification passed.
The [official download page](https://www.opendesign.com/guestfiles/oda_file_converter) and the executable's usage
text establish the CLI inputs. Context7's ODA entry has no useful File Converter CLI coverage.

Three fresh native DWGs from the sample, mixed-entity and Korean fixtures, plus two existing ACadSharp controls,
were read and converted to ACAD2018 DXF with **audit disabled and recovery NONE**. All five succeeded. Reading
each DWG and ODA DXF through the frozen native helper produced identical raster pixels (PSNR 99/SSIM 1, same
geometry) and identical SVG text. All input bytes stayed unchanged. This closes the external-reader check for
these fixtures, not every DWG object or actual AutoCAD behavior. The ODA child had separate HOME/config/cache,
network access denied, and writes to the original user's Library/config/cache denied.

Evidence: `build/resume/quality-final-20261024/oda/{REPORT.md,download.json,bundle-audit.json,convert-no-audit.json,`
`readback-results.json,summary.json}`. The local ODA copy remains available to reproduce the checks.

### Xcode certificate signing

At checkpoint `194b692`, an **actual Xcode Release build** with the already configured team's existing development
certificate succeeded inside the SDK-denying sandbox. This extends the earlier copy-signing-only proof. No bundle
ID, configured team, keychain settings or registration was changed, and no provisioning update was requested.

The main app, helper and PDFium all carry that certificate's Team ID. The helper has **no library-validation
exception**, deep/strict signature verification passes, and a relocated copy passed **22 checks** (20 conversions,
two selection checks) with repository/SDK/NuGet access denied and a clean PATH. The helper is arm64; PDFium contains
arm64 and x86_64. This is development-certificate validation, not Developer ID distribution or notarization.

Evidence: `build/resume/quality-final-20261024/{xcode-certificate-baseline-command.json,`
`certificate-baseline-proof.json,certificate-baseline-relocated-smoke.log}`.

No Developer ID certificate or local macOS VM tool was available. An explicit x86_64 execution probe returns
`Bad CPU type in executable`; Rosetta was not installed by this task. Physical Intel execution, a separate SDK-free
OS and notarization remain unavailable. Final cross-build verification is separate from actual Intel execution.
The SDK probe confirms `.dotnet`/`.nuget` reads are denied and `dotnet` is absent from clean PATH; the guarded
`/usr/local/share/dotnet` path is absent. Home SDK/NuGet content was not removed or modified.

## Native image and Markdown follow-up (2026-10-24, integration pending)

Image commits `b248065` and `5a20490` import the signed implementation from the image worktree. OpenJPEG
**2.5.4** is compiled statically from pinned official source, with source-specific notices in the engine resource
bundle. It supplies PSNR-controlled lossy JP2 codestreams; ImageIO retains container metadata and the existing
lossless quality-100 path. One-pixel images retain ImageIO because an isolated upstream OpenJPEG probe corrupted
gray-alpha samples. Source profile conversion follows the color space actually stored by ImageIO; arbitrary ICC
byte preservation and universal 16-bit equivalence are not claimed.

The existing libjpeg-turbo decoder now retains conventional CMYK samples and handles Adobe CMYK/YCCK inversion.
JPEG writing, orientation and resize retain that color space; RGB-only writers convert before attaching profiles.
JPEG COM and Photoshop APP13 resources survive JPEG/PNG output and are removed by metadata stripping. ICO filter
selection now tracks palette versus direct storage through grayscale, padding and resize.

Worker verification passed **55 focused tests** and completed **405 conversions** across C#, frozen native and
candidate hosts. ICO matches **54/54 frames**, and RGB/gray/RGBA JP2 matches **12/12 quality cases**. Strict sample
and color-space matches improve **59 to 109 of 135 cases**. These are scoped worker results; final-source full
replay and Xcode/SDK-denied verification remain pending. Report and exact commands:
`worktrees/t3-b315f9d1/build/image-parity/findings.txt`.

Remaining image differences include CMYK ICO processing order, GIF quantization and some AVIF/JXL/TGA output.
The reference's unmarked-CMYK inversion and ink-channel grayscale errors are intentionally corrected, with
black/white regressions; strict differences remain recorded. Metadata forwarding beyond JPEG/PNG, arbitrary JP2
ICC preservation and one-pixel JP2 quality control remain limited. OpenJPEG cancellation is checked during sample
copy and stream callbacks; cancellation latency inside wavelet/entropy computation is not established.

Independent Swift review found a profiled-CMYK regression in the new fixed-formula RGB conversion. Parent commit
`d207c7a` restricts that formula to untagged images, reusing the existing profile predicate so tagged CMYK reaches
Core Graphics' ICC-managed sRGB conversion. A profiled CMYK JPEG round-trip and saved PNG both match an independent
CGContext exactly. **14 focused image/decoder tests passed**, with zero skips/failures; the second review found
no further actionable issue. The worker's 135-case strict counts above precede this correction.

Markdown optimization `eee334e` required two independent review fixes. Commit `4a7e491` restores both original
weak parent references and removes parent teardown loops, preserving legacy mutation semantics and avoiding
dangling-reference aborts. Three regressions cover insertion/removal, clear and block replacement. The final
bounded review found no further actionable issue. Repaired code passes **30 focused tests, one optional skip,
zero failures**, **119,792 strict byte comparisons**, and **5,830 production TXT/HTML byte comparisons**.
Evidence is under `build/resume/quality-final-20261024/markdown-*`. The worker's **0.63s TXT** timing predates these
safety repairs and must not be quoted as final performance. Uniform production timings remain pending; neither
the Markdown **0.60s** nor PDF **0.84s** target is accepted as achieved.

### SVG implementation and reviewed fallback correction

Signed worker commits `5789026` and `1d8b376` add SVG2 `href` normalization and a universal static Skia bridge.
They are imported as `5e16c4c` and `ea7af73`; the package merge retains both COpenJPEG and CNativeSvg.
The entire source DOM must satisfy a conservative primitive/attribute capability set: untransformed root/groups,
rectangles and paths with supported literal paints. Text, CSS, resources/references, gradients, filters, transforms,
nested viewports and unknown features retain CoreSVG. Vector PDF always retains CoreSVG. This preserves the
existing vertical-text behavior; the broader experimental text normalizer was rejected because it regressed other
CSS/combining-text cases.

The native bridge borrows the CGContext's premultiplied RGBA buffer synchronously. Its implementation symbols are
localized to avoid coupling to existing JPEG/WebP/Brotli libraries. Pinned arm64/x86_64 archives and matching
headers come from public upstream releases; no installed C# binary is shipped. Source, archive and notice hashes,
both-architecture C linkage and relocation evidence are recorded in the worker's
`worktrees/t3-14e072f8/build/svg-integration/REPORT.md`.

Worker integrated-host comparisons pass the original JP2/JPG/JXL gates at **72.30/67.73/61.85 dB** with unchanged
PSNR/SSIM thresholds. Across **55 SVGs**, 42 unsupported drawings retain exact baseline pixels and the original
thin-path fixture plus 12 primitive cases improve, with no negative quality deltas. Focused tests report **25 passes,
three optional Ghostscript skips, zero failures**. These are scoped results, not a full 849-case acceptance.
Independent review reproduced silently missing prefixed SVG children when serialization retained their prefix.
Parent commit `38da38d` conservatively requires an explicit SVG default namespace and rejects descendant default
namespace resets, retaining CoreSVG for both reviewed triggers. Tests check routing and opaque red rendered pixels;
the second review found no further actionable issue. Final parent runtime and full-replay acceptance remain pending.
An active native draw cannot be interrupted;
cancellation discards its result before output commit. Actual Intel execution remains unavailable.
