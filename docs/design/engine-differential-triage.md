# C# / Swift engine differential triage

Latest validation: [remaining-work integration, 2026-10-26](#remaining-work-integration-2026-10-26).
Earlier sections preserve historical snapshots; their “final” results and remaining-work lists
describe those dates, not the current integrated source. Raw comparison verdicts remain preserved.

Date: 2026-10-23. Original triage branch: `fix/swift-engine-differential`;
current integration branch: `refactor/swift-conversion-engine`.

The original triage below excluded 15 then-unported CAD cases from its verdict.
Later sections retain the resolved backend choices, CAD integration and final
849-case replay including CAD. The report distinguishes
comparator noise, confirmed engine defects, previously accepted differences, and
backend differences that still need an acceptance decision. A raw FAIL is not
automatically a Swift defect; matching failures can also receive PASS.

The historical full optimisation replay (`a064ab8`) is **578 PASS / 263 WARN / 8 FAIL**.
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

## Native image and Markdown follow-up (2026-10-24)

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
and color-space matches improve **59 to 109 of 135 cases**. These scoped worker results precede the profile
corrections and final parent verification below. Report and exact commands:
`worktrees/t3-b315f9d1/build/image-parity/findings.txt`.

Remaining image differences include CMYK ICO processing order, GIF quantization and some AVIF/JXL/TGA output.
At this stage, unmarked-CMYK inversion was classified as a reference error; the 2026-10-25 investigation corrected
that classification. ImageIO's decode array and ImageMagick both use inverted JPEG inks without an Adobe marker,
so the native reader now follows that convention. The reference's ink-channel grayscale error remains deliberately
different, with black/white regressions; strict differences remain recorded. Metadata forwarding beyond JPEG/PNG, arbitrary JP2
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
safety repairs and must not be quoted as final performance. Final uniform production timings are recorded below;
neither the Markdown **0.60s** nor PDF **0.84s** target was achieved.

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
the second review found no further actionable issue. Final parent runtime and full-replay results are recorded below.
An active native draw cannot be interrupted;
cancellation discards its result before output commit. Actual Intel execution remains unavailable.

## Final native quality integration (2026-10-24)

The final production-code checkpoint is signed commit `dc7ab6a`. It includes the independently reviewed native
image/SVG changes, weak-parent Markdown repairs and the final JPEG profile correction. The frozen normal Release
host is `build/resume/quality-final-20261024/post-cmyk-default/final-host/FileToXEngine`, SHA-256
`7add727d75a6dc4a1e1803c6269798c233eccc432c49599d8f98a93181a532df`.

### Final profile correction and supplemental images

The first parent ICC correction exposed another distinction: ImageIO assigns Generic CMYK to untagged JPEGs.
Commit `dc7ab6a` checks the actual JPEG ICC APP2 payload before choosing the source space. Untagged native CMYK
uses DeviceCMYK; genuinely tagged images keep ICC-managed conversion. Adobe/YCCK RGBA regression hashes come from
preserved C# outputs, and the tagged JPEG/PNG regression compares an independent CGContext. The third scoped
review found no further actionable issue; **56 affected tests passed, zero skips/failures**.

The fresh final-host matrix completes **135/135 jobs**, plus **four metadata/strip jobs**. Strict stored-sample,
space/dimension/frame equality is **102/135**, versus frozen Swift **59/135**. Separate visible equality is
**104/135**. This restores 13 strict and 15 visible matches lost when implicit Generic CMYK was treated as an
embedded profile. ICO retains **54/54 exact frames** and JP2 **12/12 exact quality cases**.

Seven tagged-CMYK cases differ from the original worker/C# formula. Final PPM/PNG/BMP/TGA pixels match an independent
oracle using native Q8 CMYK samples plus the actual 55,280-byte source ICC in CGContext **byte for byte**. The
ImageIO JPEG decoding oracle remains different (RGB PSNR 32.156718 dB); that decoding difference is recorded.
The strict differences are retained, not waived. Four untagged CMYK JPEG outputs have no invented ICC, while the
genuine tagged JPEG retains its source ICC bytes. JPEG/PNG COM, IPTC and Photoshop resources and their stripping
checks pass. Earlier worker **109/135** and pre-correction **89/135** figures are historical, not final results.

Evidence: `post-cmyk-default/image-final/{REPORT.txt,summary.json,comparison.json,icc-oracle.json,`
`metadata-audit.json,jpeg-icc-checks.json,freeze-verification.json}`. All 2,975 immutable evidence/source files remain
unchanged. The corrected integrity manifest excludes its own growing logs; the original manifest assertion and
all completed conversions are retained, with no conversion rerun used to hide a result.

### Fresh full replay

All **849/849 original cases** were replayed with the pinned optional tools under SDK/NuGet denial:

- **786 completed / 63 failed jobs**, matching C#, r3 native and the pre-profile-fix capture; no harness or inspection
  errors, source changes, or staging leftovers. The 63 failures retain the existing codec/input/no-text/no-audio errors.
- Against C#: **581 PASS / 264 WARN / 4 FAIL**. The four FAILs remain `auto-061-psd-to-html`,
  `auto-077-webp-to-html`, `auto-086-dxf-to-md` and `auto-101-gif-to-md`; captured baseline image references are missing.
- Against r3 native: **738 PASS / 107 WARN / 4 FAIL**. Three SVG raster FAILs against old native are the intended
  improvement toward C#; generated Calibre cover variation accounts for the other FAIL and additional WARN.
- Against pre-profile-fix host `517294cb`: **764 PASS / 85 WARN / 0 FAIL**. No image bytes or image metadata changed
  in this original corpus, and all seven TCR target outputs are byte-identical. Supplemental CMYK cases above cover
  the profile correction that the original corpus does not exercise.

All thresholds remain unchanged. WARN includes unsupported binary semantics, textless-PDF geometry-only checks,
font/media structural checks and generated covers; it does not establish general visual/layout parity. The four
C# strict failures and all WARN limitations remain open. Original corpus, harness, tools, 13 frozen host/resource
files and 741 production source files pass before/after integrity checks.

Evidence: `post-cmyk-default/{final-replay-REPORT.md,final-replay-summary.json,final-replay-per-case-changes.json}`,
the three comparison folders and `replay-final/`. Earlier captures and binaries remain preserved.

### Final-source build, data and packaging verification

- Full Swift run: **565 engine + 12 Core tests**, **14 skips**, **zero failures**. The passing host tests include
  settings persistence and language changes. Earlier legacy user-data compatibility evidence remains applicable;
  original user data and the installed C# reference app were not replaced.
- A fresh, separate DerivedData directory at final code `dc7ab6a` passed SDK-denied **clean build-for-testing**,
  then **564 engine tests, 57 skips, zero failures**. Only the `/bin/ps`-dependent process-tree test was explicitly
  excluded from this sandbox run; it passes in the normal full Swift run. App tests run in the clean environment
  outside that sandbox: **74 tests, zero failures**. Skipped tests are not passes.
- An actual SDK-denied **Xcode Release build with the existing development certificate** passed after the correction.
  No team, bundle ID, registration or provisioning settings changed. Main app/helper/PDFium share the existing
  team; the helper has no library-validation exception. Deep/strict verification passes.
- The Release bundle contains **zero .NET files and no .NET or Homebrew load dependencies**. OpenJPEG and Skia
  notices are present and byte-exact. Helper SHA-256:
  `d7ad41debf39da7ac52c35b63572d514af96ecbe41cf76fd1cbb634f972365f3`.
- A separately copied certificate-signed app passes **22 checks** (20 conversions and two selection checks) with
  repository and home .NET/NuGet access denied and system-only PATH, with no staging leftovers. The parent captures
  stdout through a pipe before saving it: redirecting a sandboxed child directly to a denied repository log can
  produce an empty log. Only the fresh captured 22-PASS log is counted.
- All **seven final Release TCR cases** decode through Calibre to the clean expected bytes and valid UTF-8.
- Final-code **x86_64 Release cross-compilation/linkage** passes under the same SDK-denying clean environment;
  native objects and helper architecture/links are verified. Intel execution remains unavailable (`Bad CPU type`).

Evidence is under `post-cmyk-default/`: `swift-final-results.json`, `final-clean/{plan.json,results.json,*.log}`,
`xcode-final-results.json`, `release-final-audit.json`, `release-final-relocated-proof.json`,
`release-final-relocated-smoke.log`, `release-tcr-readbacks.json` and `x86-crossbuild/RESULT.md`.
The SDK folders are inaccessible to verification processes; they were not deleted. No separate SDK-free OS/VM,
physical Intel runtime, Developer ID signing or notarization was available. No push, publication or app reinstall
was performed.

### Sequential production performance

After all builds/replays ended, the original uniform production baseline `82b4e625` and final `7add727d` ran five
rounds per case, alternating host order. Best times, before → final:

- PDF → TXT: **1.384810 → 1.389179 s**; **0.84 s target unmet**. PDF implementation is unchanged in this phase.
- EPUB → FB2: **0.427374 → 0.434319 s**; within the 0.54 s target.
- DOCX → MD: **0.090216 → 0.091151 s**; within the 0.12 s target.
- DOCX → TXT: **0.085262 → 0.085448 s**; within the 0.09 s target.
- Markdown → HTML: **0.956213 → 0.876474 s**.
- Markdown → TXT: **0.892803 → 0.813709 s**; **0.60 s target unmet**.

All **60 outputs** match, excluding only the previously proven generated FB2 document UUID. Input and executable
hashes stay unchanged; raw times and medians are in `post-cmyk-default/performance/{raw.json,summary.json}`.
The exact command/environment and sequential A/B script are retained beside that folder. These measurements use
the repaired weak-parent implementation; the unsafe worker's 0.63 s TXT figure is not the final result.

### Dependencies and remaining limits

The app/helper, queue, staging, settings, presets and history are Swift. Native components include PDFium raster
rendering, LibRaw RAW development, libjpeg-turbo JPEG, OpenJPEG lossy JP2, libwebp/libjxl/Brotli, libxml2/zlib and
the conservative Skia C++ SVG path. PDFKit retains PDF text semantics; a PDFium text draft changed Korean spacing.
The Swift Markdown parser retains Markdig behavior; the much faster cmark-gfm replacement failed 80,662 of 119,792
comparisons. Document/CAD models and writers retain the verified Swift semantics. Existing rhwp/7-Zip are bundled;
FFmpeg, Ghostscript, Pandoc, LibreOffice and complete Calibre remain optional external tools. ODA was used only for
the earlier five-file interoperability check, not bundled as a runtime dependency.

Open work includes the two performance targets; the strict/WARN differences above; complex/vertical SVG text
still handled by CoreSVG; remaining CMYK ICO, GIF/AVIF/JXL/TGA and JP2 profile/precision/one-pixel quality limits;
raw metadata forwarding beyond JPEG/PNG; and broader JPEG ICC provenance. In the supplemental audit, an untagged
gray JPEG still synthesizes a 4,508-byte profile and one tagged RGB JPEG loses its 3,144-byte profile, unchanged
from the earlier worker/pre-fix behavior. No universal metadata-preservation claim is made. Mid-wavelet OpenJPEG
cancellation latency, interruption inside one Skia draw and PDF text cross-job throughput remain unmeasured;
cancelled results are checked before output commit. Actual Intel/older-OS execution and distribution signing/
notarization remain unverified.


## Apple Silicon-only final verification (2026-10-25)

The supported product is now **Apple Silicon M1 and newer, arm64, macOS 15+**.
Intel and Rosetta execution are outside support and completion criteria; earlier cross-build evidence remains
historical. Source checkpoint `70fff7d` includes the reviewed JPEG ICC, CMYKA ICO, SVG longhand inheritance,
CMYKA flattening safety and Markdown block-context changes. App/helper/tests share `ARCHS: arm64`; engine
staging rejects other architectures. CLI Xcode validation also passes `ARCHS=arm64` and an arm64 destination
to constrain package dependency builds. This validation ran on **M2 Max/macOS 27.0.1**, not physical M1/macOS 15.

Evidence root: `build/resume/remaining-1-5-20261024/arm64-final-20261025/`.
The normal production host is arm64, SHA-256
`32bb0c6c47bf5c06650e356168ee2c6569659c65c98116ec69b7bdb1c5dbdd96`;
its capture preserves 13 executable/resource hashes and 745 tracked build-area paths. The only subsequent
capture-path change was the authorized, noncompiled `Vendor/PDFium/README.md` support clarification.
Raw integrity failures and before/after manifests preserve that difference; all runtime inputs, native binaries,
resources, original corpus, external tools and original captures stayed intact. Full manifest equality is not claimed.

### Changes and actual image checks

- JPEG now tracks actual validated multipart ICC provenance. Genuine RGB sRGB (3,144 bytes) and CMYK
  (55,280 bytes) profiles survive byte for byte; a gray JPEG no longer receives an invented 4,508-byte profile.
  Writers reject profile/sample-model mismatches. Native APP2 marker counts handle exact 65,519-byte multiples.
- CMYKA ICO keeps five-channel samples through padding/resizing, then converts to RGB. Shared background
  flattening converts CMYKA to RGB before blending, preventing the old invalid-image force-unwrap crash.
- The final host completed **135/135 image jobs plus four metadata jobs**. Strict stored equality against C# is
  **103/135**, separate visible equality **105/135**, versus 102/104 for the prior `7add` production host.
  No strict/visible equality regressions against `7add`; only the two CMYK ICO cases changed pixels.
  Standard ICO matches **54/54 frames**, JP2 quality **12/12 cases**. Tagged CMYK ICO matches an independent
  Q8 CMYKA-resize + genuine ICC/CoreGraphics oracle exactly, while still differing from unmanaged C#.
- All seven prior tagged CMYK outputs preserve their pixels. Comments/IPTC/Photoshop metadata and stripping
  are checked independently. JPEG provenance does not fix non-JPEG inference: gray PNG still has an inferred
  GRAY profile and RGB PNG can lose the source sRGB bytes. Remaining 32 strict/30 visible differences are listed
  in `image-final/summary.json`; no threshold/inspector waiver was applied.
- SVG longhand font-weight inheritance improves seven new text cases while preserving 55 retained SVGs and
  the original JP2/JPG/JXL gates. General vertical shaping, filters and shorthand inheritance remain limited.
  New text cases still miss a quality gate; the original vertical fixture remains 20.83 dB.
- Markdown avoids repeated block-context reference assignments while keeping all parent links weak.
  Its implementation handoff passed 119,792 strict comparisons and 5,830 production outputs. The final
  integrated suite/replay and large-input benchmark complement that evidence; those earlier corpus jobs are
  not counted as newly repeated final-host conversions. No additional safe PDF text optimization was retained.

### Build, tests and packaged execution

- The integrated Swift release suite before the pause passed **582 engine + 12 Core tests**, 14 skips, zero
  failures. Runtime code stayed unchanged afterwards. New arm64 SDK-denied **clean build-for-testing** passes;
  Xcode engine tests: **581 tests, 57 skips, zero failures**. The process-tree timeout test is explicitly excluded
  from that sandbox because `/bin/ps` is restricted; it passed in the normal Swift suite. Missing optional
  tools account for additional skips. A separate clean-environment app run passes **74/74 tests**, outside the
  SDK sandbox. Actual external-tool conversion coverage is recorded separately in the 849 replay.
- The actual existing-team development-certificate **arm64 Xcode Release** succeeds. App/helper executables
  are arm64. All five packaged Mach-O files have an arm64 slice; original universal 7-Zip/PDFium remain
  universal. Deep/strict signing passes, helper has no library-validation exception, no .NET runtime/files or
  Homebrew/.NET load dependencies are present, and exact OpenJPEG/Skia notices are included.
- Release helper SHA-256: `5a3a393ca9b2fe4c216d63d08c73dc59bdda7181982002b0a1c5439c049c1727`.
  A copied app outside the checkout passes **22 checks** with repository and SDK read/write access denied.
  The Release helper also completes seven TCR conversions; Calibre's independent decoder reads all seven as
  exact clean expected UTF-8. Settings/data compatibility evidence from the earlier phase remains applicable;
  no user data, installed reference app or home SDK folders were replaced/deleted.
- Commands/logs: `xcode-final-plan.json`, `xcode-final-results.json`, `swift-production-result.json`,
  `release-final-audit.json`, `release-final-relocated-proof.json`, `release-tcr-readbacks.json`.
  Isolation is a clean environment plus denied SDK paths on this Mac, not a fresh SDK-free OS installation.
  Developer ID distribution, notarization, physical M1/macOS 15 and separate-OS execution remain unverified.

### Fresh replay and corrected inspection

All **849/849** host jobs ran once: **786 completed / 63 existing failures**, zero transport/harness errors.
No job state, error-key, output count/assignment or history audit issue was found, and staging leftovers are empty.
All seven TCR output files are byte-identical to `7add`.

The initial capture had five WOFF2 inspection errors: the new TCR import prevented the isolated Python font
inspector from starting. Commit `d309b62` moves that import into the TCR branch and adds an isolated-entry
regression. Both Python 3.9 and 3.15 pass **24/24 harness tests**; all five preserved WOFF2 outputs decode correctly.
The original replay/capture and errors remain intact. A separate derived capture re-inspects only those five
fingerprints, with **zero repeated host conversions and zero artifact changes**; it has zero inspection errors.

Comparison totals retain distinct policies. Legacy C# comparison: **580 PASS / 264 WARN / 5 FAIL**;
legacy versus `7add`: **765 / 83 / 1**. The new exact-TCR + optional 144DPI PDF-page-content policy against C#:
**585 PASS / 255 WARN / 9 FAIL**. These policies are not interchangeable and do not establish blanket layout parity.

The unwaived legacy FAILs are the four captured C# missing-image references and `auto-067-tcr-to-txtz`.
For the latter, title/author, normalized metadata and `index.txt` match, but Calibre-generated cover layouts and
OCR differ; bounded evidence indicates likely template variation, and the strict result remains FAIL.
Stronger inspection additionally retains the SNB/TCR trailing newline, corrected HTML/TCR `Fil` payload,
SNB PDF first-page raster difference and BMP PDF raster PSNR 28.59248 dB. The BMP's extracted RGB image payload
is byte-identical to source/C#/`7add`; this does not waive its rendered difference. The SNB PDF's second page is
exact; the direct XObject probe did not establish first-page cover attribution. PDF inspection excludes annotations
and uses bounded whole-media-box page content, not a proof of every visual/layout property.

`final-replay-summary.json`/`REPORT.md` preserve the original run, failed inspection and exact documentation
integrity delta. Corrected inspection provenance and reports are in `woff2-correction.json`, `reinspection-summary.json`,
`replay-inspected/` and `reinspection/`. No outputs, comparison thresholds or old reports were rewritten.


### Sequential performance and remaining dependencies

The final normal production host (`32bb0c6c…`) was measured against the immutable prior production host
`7add727d…`, after all builds, delegated work and comparisons finished. Five rounds alternate host order;
all 60 outputs match, with only the proven generated FB2 document UUID normalized. Best times:

- big.pdf → txt: 1.405622 → **1.411316 s**; ≤0.84 s remains unmet.
- big.epub → fb2: 0.440922 → **0.444566 s**; ≤0.54 s reached.
- big.docx → md: 0.093436 → **0.094477 s**; ≤0.12 s reached.
- big.docx → txt: 0.086643 → **0.085483 s**; ≤0.09 s reached.
- big.md → html: 0.896054 → **0.866980 s**; improved.
- big.md → txt: 0.828811 → **0.794579 s**; ≤0.60 s remains unmet.

Raw times, medians, output hashes/parity, host/input hashes and exact isolated command are in
`build/resume/remaining-1-5-20261024/arm64-final-20261025/`:
`performance/{raw.json,summary.json}`, `performance-command.json`, `performance-result.json` and `bench-final.py`.
No timing under concurrent builds is used as acceptance evidence.

The PDF investigation retained no additional safe speedup: PDFKit attributed-string construction remains the
cost. PDFium text extraction changed Korean spacing; geometry-only font inference also failed parity. A global
cmark-gfm replacement was rejected because 80,662/119,792 outputs differed. The smaller Swift Markdown change
preserves the established semantics; the two performance goals are still open.

Runtime dependencies are Swift/macOS frameworks plus pinned native LibRaw, libjpeg-turbo, libwebp, libjxl,
OpenJPEG, PDFium and Skia. Bundled rhwp/7-Zip remain. FFmpeg, Ghostscript, Pandoc, LibreOffice and Calibre are
external tools used only for their routes; pinned optional QA copies were retained. FreeType and native
ImageMagick comparison oracles are QA dependencies, not libraries newly shipped with the app. Initial package
resolution/download caches may need network access; they require no .NET tooling.

Domain-specific routing, job management, settings/presets/history, wire protocol and format semantics stay in
Swift. They have no drop-in C/C++ replacement that preserves the Filee contracts. C/C++ is used where a native
codec/renderer matches quality and options; blanket replacements that changed text/images were not accepted.
Remaining work includes the unwaived strict/WARN differences, general SVG text shaping, non-JPEG ICC and
container fidelity, PDF/Markdown speed targets, native cancellation latency during synchronous computation,
and separate hardware/OS/distribution verification. No conversion route was removed to obtain these results.


## Intel support cleanup (2026-10-25)

Following the M1+ support decision, `d61299a` retains an arm64-only Skia bridge and `0b2a6c7` removes
Intel runtime/download selection. Skia's active download/rebuild/self-check no longer contains x86 work.
The current static archive is **17,849,304 bytes**, down from 37,790,536; its SHA-256 is
`3f5579445b952c6915fbacd367661bcbaad405cc817b8da77410ddf21d03d4d8`.
Its selected arm64 archive bytes are identical to the prior universal archive's arm64 slice. The single
export, 99 header pins, notices and C adapter stay intact; native C self-check and six mocked builder checks pass.

`Tools/stage-bundled-engines.sh` now copies, selects arm64 if necessary, and signs code before helper signing.
It also replaces the framework-embed phase's PDFium copy with an arm64 derivative and signs it again.
Pinned PDFium/rhwp/7-Zip source copies and notices stay unchanged. The new staging regression checks all
three outputs' architectures, ARM instruction bytes, file modes, signatures and original source hashes;
it also checks x64 CLI rejection. Both existing archive self-tests pass. The independent review found no
introduced actionable defect in RID callers, build-phase order, source isolation or the native bridge.

Actual SDK-denied development-certificate Xcode Release passes. **All five packaged Mach-O files are arm64
only**, share the current signing team, and pass deep/strict signing with no helper library-validation exception.
No .NET or Homebrew load dependency is present. The relocated app passes **22 checks** with checkout and
SDK access denied. Focused SDK-denied PDFium/SVG tests pass **37 tests, three Ghostscript skips, zero failures**.
The Release helper SHA-256 is `75d104714902068d54fd53d58396d27cd27a1ac04052b95cf89a2f0a46af3a04`.

Measured app file bytes decrease **78,264,615 → 69,236,908**, saving **9,027,707 bytes (8.61 MiB)**.
The smaller static Skia archive reduces the checkout by **19,941,232 bytes (19.02 MiB)**; its discarded x86
slice was already absent from arm64 executable linkage, so this is not additional app-size savings.
The explicitly scoped inactive Intel SwiftPM cache (1,237,688 KiB) and 12 Intel object folders in two completed
DerivedData builds (222,860 KiB) were removed. Source caches, ARM products, original baselines, historical
reports, user SDK folders and installed reference apps were preserved. This is cache-size removal, not a claim
about exact physical free-space gain on a filesystem with shared extents.

Evidence: `build/resume/intel-trim-20261025/` contains staging test logs, exact focused/Release commands and
results, `release-final-audit.json`, relocation proof, size comparison and cleanup manifests.
Full 849 replay and speed measurements were not repeated for byte-equivalent ARM selection; the preceding
849 captures and sequential measurements remain their original evidence. No format, preset or user-data logic
changed. Existing strict failures, non-JPEG ICC/container fidelity, SVG text limitations, PDF/Markdown speed goals,
native cancellation latency, physical M1/macOS 15/separate-OS execution and distribution notarization remain open.
Generic upstream C/C++ portability code and immutable cross-platform manifest metadata remain as provenance,
not active Intel application support. No push, deployment or installed-app replacement occurred.

## Integrated watch, ICC and native cancellation follow-up (2026-10-25)

Tested source: `34bc0ae9132c79d9e1333e9692b4f385f022b6a9`, on an M2 Max with macOS 27.0.1.
Support remains M1+/arm64/macOS 15+. This is not physical M1 or macOS 15 execution evidence.
All implementation review findings were resolved before final validation. The parent cancellation test fixture
was then made independent of the caller's global `TMPDIR`; production temporary-folder protection was retained.

Watch settings, cached status, queue events, history and ephemeral stop-before-quit are connected. The monitor
baselines existing files, uses a three-second monotonic settling heuristic, skips packages/download directories,
limits scans to 10,000 entries and batches to 128 inputs. It freezes physical output roots and validates allocation
and publication against protected originals. Failed/cancelled/changed inputs are not moved. Historical batch
errors remain visible without cancelling healthy work. External commit and output-kind filesystem work runs
outside RPC/job state locks; local settings/history persistence remains synchronous.

JPEG/PNG source ICC tracking follows the actual pixel space. Native JPEG samples retain valid numbered ICC
chunks in either physical order; ImageIO fallback pixels retain decoder-space reconciliation. JPEG profiles above
16,707,345 bytes fail before publication. PNG scan work includes bytes produced on failed zlib calls and stops
within 16 MiB plus one 1 MiB buffer. BMP row padding is zeroed only for the verified layout; indexed BMP input
is converted correctly and headerless output is rejected. The shared inflater still rejects corrupt streams.
Skia picture playback now checks cancellation between draw commands. Parsing, recording and one draw can
still be uninterruptible. The separately proposed SVG font-shorthand change `e3c9671` remains excluded.

### Build, data and distribution checks

- SDK-denied Swift: **636 engine tests, 14 skips, zero failures**, plus **13 Core tests, zero failures**.
  The process-tree test's `/bin/ps` verification cannot launch inside the macOS sandbox profile. That one test
  passes separately with an empty HOME and restricted PATH. Original environment-failure logs are retained.
- SDK-denied Xcode arm64 clean build and **636 engine tests, 57 skips, zero failures** pass. App tests run in
  the separate clean environment outside that extra profile: **74 tests, zero failures**.
- Actual current-team development-certificate Release passes. All **five Mach-O files are arm64**, with no
  .NET files or Homebrew dynamic linkage; deep/strict signing and helper library validation pass. This is not
  Developer ID signing or notarization. The app contains **69,557,998 file bytes**.
- The relocated app passes **22 checks** with checkout and SDK access denied. Its helper SHA-256 is
  `e8dbd1caad290df64225ff2d29a50e47fecc9ad42cbbbe5bff945bd644e76440`.
- The normal SwiftPM Release comparison host SHA-256 is
  `e10e9b9c4d6d5b01e39a09886126da008c56b28bf11f55b2840f83afdccdebc3`.
  Its **13 runtime files and 969 tracked source/input files** remain unchanged through validation. User SDK
  folders, installed reference apps, corpora and all prior reports/captures are preserved. No C# reference was rerun.

Settings schema 8 and wire v1 remain compatible. The current suite covers settings, presets, unknown fields,
history and watch round trips; earlier copied-user-data evidence remains in the 2026-10-23 record. New requests
are `watch.status` and session-only `watch.stop`; existing job events carry watch conversions.

### Fresh conversion comparisons

All **849 cases** replayed once: **786 completed, 63 existing failed jobs**, zero harness/inspection errors.
There are no state, per-file error-key, output-count or output-name changes against C# or the immediately
previous `32bb` capture. No staging remains and all outputs/inputs pass their hash/existence audits.

- Legacy policy vs C#: **581 PASS / 263 WARN / 5 FAIL**.
- Current exact-TCR/PDF-render policy vs C#: **586 / 254 / 9**.
- Legacy policy vs `32bb`: **764 / 84 / 1**.
- Current policy vs `32bb`: **764 / 83 / 2**.

Every strict failure remains unwaived. The C# legacy failures are four missing baseline image references
(`auto-061-psd-to-html`, `auto-077-webp-to-html`, `auto-086-dxf-to-md`, `auto-101-gif-to-md`) and Calibre's
generated cover difference (`auto-067-tcr-to-txtz`). Current policy additionally flags the two corrected TCR
payloads (`auto-063-snb-to-tcr`, `auto-096-html-to-tcr`) and two PDF raster differences
(`auto-063-snb-to-pdf`, `auto-091-bmp-to-pdf`). Against `32bb`, only the SNB PDF page and TXTz cover remain.
The changed RB→ODT classification is a coincidental Calibre cover match, not a claimed code improvement.

All **149 image-target files and seven TCR outputs** are byte-identical to `32bb`; 14/15 compared PDF rasters
match it exactly. The prior five WOFF2 inspection failures are gone and their outputs remain byte-identical.
No new output has a broken image reference. One CoreGraphics PDF warning was not reproduced by a bounded
read-only check and affected no output; its source remains unknown.

The image supplement completes **135 matrix jobs + four metadata jobs**: strict **103/135**, visible **105/135**,
unchanged. ICO **54/54 frames** and JP2 quality **12/12** match. Another 22 bounded controls yield 21 completed
jobs and one expected JPEG-capacity rejection. Ordered/reordered profiles and BMP safeguards pass. Of the
CMYK oracle controls, one resized case lacks the preserved independent resize oracle; it is checked unchanged
against the prior output, without an independent resized-accuracy claim. The two PNG metadata changes and
three BMP padding changes are accounted for; no blanket ICC/timestamp normalization was applied.

### Sequential production timing

Both frozen hosts use normal Release flags. Each case runs five alternating A/B rounds after this task's builds
and conversion jobs stop. System load average was approximately 34.6→34.9; unrelated OS work was not controlled.
These are observed timings on this host, not idle-machine or M1 guarantees. All **60 outputs** match apart from
the previously proven generated FB2 document UUID.

- PDF→TXT: best **1.349→0.630 s**, final median **0.634 s**; the ≤0.84 s target is met in this run.
- Markdown→TXT: best **0.795→0.667 s**, median **0.676 s**; the ≤0.60 s target remains unmet.
- Markdown→HTML: best **0.855→0.731 s**, median **0.733 s**.
- EPUB→FB2: best **0.422→0.418 s**, median **0.425 s**.
- DOCX→Markdown: best **0.091→0.089 s**, median **0.090 s**.
- DOCX→TXT: best **0.085→0.082 s**, median **0.084 s**.

### Remaining limits and evidence

Strict image/container gaps and the TGA inspector limitation remain. Binary formats without semantic inspection
(50 comparisons vs `32bb`, 51 vs C#), PDF annotations, general SVG vertical shaping/filters and arbitrary
non-JPEG/PNG ICC provenance are not proven equivalent. Native OpenJPEG computation can still delay cancellation
by seconds; preceding ImageIO work is also not immediately interruptible. Watch input caps do not bound total
output-message size; unsupported exclusive rename retains originals. Settling remains heuristic.

Managed in-app engine installation is unimplemented; the old Mac host also had no install API. Optional system
or selected FFmpeg/Ghostscript/Pandoc/LibreOffice/Calibre remain dependencies for their respective conversions.
Physical M1/macOS 15, separate SDK-free OS, GUI/TCC/SMB/exFAT and real login/notification lifecycle remain
unverified. No deployment, notarization, push or installed-app replacement occurred.

Local evidence is in `build/resume/remaining-collab-20261025/`: `FINAL.md`, `final-validation-summary.json`,
`swift-final-results.json`, `xcode-final-results.json`, `sdk-absence-proof.json`, Release audit/relocation proofs,
`replay-validation/`, `image-validation/`, and `performance/`. These directories hold exact commands,
environments, output hashes and failure IDs. Source review/finding-to-test records are retained in
`REPORT/watch-integration-20261025/` and the isolated implementation worktrees.

## CMYK, BMP and inspection corrections (2026-10-25)

The validated source is `5f9486af1635a788854f9e7e82f4cd873769b08a`. This phase fixes concrete image defects;
it does not implement managed engine downloads or claim that all remaining C# differences are regressions.
The earlier records above are preserved. No C# reference host was rerun, no thresholds were relaxed, and no
strict failure was waived. All execution was on an M2 Max with macOS 27.0.1, not physical M1/macOS 15 hardware.

### Production fixes and review

- Native JPEG decoding now inverts CMYK/YCCK samples even without an Adobe marker, matching ImageIO's decode
  array and the retained ImageMagick decoder. The earlier classification of unmarked inversion as a reference
  error was incorrect. Higher precision and unsupported native input retain ImageIO fallback.
- PSD/PSB retain CMYK inks and their matching source ICC instead of converting them to RGB. A five-channel
  CMYK-plus-alpha image can exceed PSD's 32-bit layer-section length even within its dimension limit. The writer
  now rejects an oversized section with a PSB recommendation before publication; PSB retains 64-bit lengths.
  Independent R2 review accepted the guard, boundary tests and eight byte-identical ordinary-output controls.
  The guard runs after layer encoding; multi-GiB memory use and end-to-end rejection were not exercised.
- BMP reading preserves validated Windows DIB pixels-per-meter values. The corpus's 3780 ppm is 96.012 DPI,
  not ImageIO's rounded 96. BMP→PDF now matches C# at **71.991 × 47.994 pt**, with exact V2 raster pixels.
  BMP→RST text and its **149 × 99** JPEG sidecar are byte-exact to C#, replacing the former 150 × 100 sidecar.
  BMP→PNG/PSD/PSB and the BMP-based GIF control change density metadata while keeping pixels identical.

The imported production commits are `5f5369f` (BMP), `f6c1837` (JPEG), `abcd45f` (PSD/PSB) and `5f9486a`
(PSD length guard). `86cc0e5` adds both new test files to Xcode and corrects the affected decoder documentation.
All commits are OpenPGP-signed with DCO. Independent reviews found no remaining actionable issue in their
bounded scopes; they do not establish arbitrary-file correctness.

### Inspector corrections are separate from production gains

`ded3424` explicitly scales PDF rendering to 144 DPI, clips to each page's media box, and checks rotation-aware
geometry. The former drawing transform only scaled down, leaving a 72-DPI page centered on a nominal 144-DPI
canvas. Reports now record **pdfRasterVersion 2**. The focused harness passes **28 tests**, including painted
area, off-page clipping and nonsquare rotation regressions; independent R2 review accepted the changes.

Reinspecting the preserved previous engine with V2 changes its C# result from historical **586/254/9** to
**586/255/8** (PASS/WARN/FAIL), without any conversion. Its old BMP PDF already meets V2 thresholds at
57.736599 dB / 0.9999816924; the actual BMP fix raises this to exact pixels (99/1). Therefore the reduction
of one aggregate FAIL is an inspection correction, not a production improvement. PSNR/SSIM/text thresholds
remain unchanged. PDF annotations are still not rendered.

The frozen supplemental Q8 inspector also misreads a 34-byte TGA image-ID comment as pixels. Literal-pixel
regressions cover raw/RLE TGA and ID lengths 0/34/255. The actual 3567-byte TGA payload and canonical ImageIO
pixels are identical to C#. A separately reported corrected score must not be counted as a changed output.

### Integrated conversion results

All **135 image matrix jobs**, four stripping jobs and two CMYKA controls completed. Another 22 bounded controls
produce 21 successes and the expected 16,707,346-byte JPEG ICC capacity failure, with no output published.
That is **163 jobs, 162 successes, one expected failure**. Legacy Q8 strict matches improve **103→112/135**;
visible matches improve **105→112/135**. No exact match is lost. Exactly ten files change; the other 125 are
byte-identical to the previous engine, and all 135 match the accepted worker. ICO retains **54/54 frames** and
JP2 quality **12/12 cases**. The independent **19×13 ICC resize oracle is now available and matches exactly**,
superseding the earlier evidence gap without modifying the old report.

The separate corrected-TGA inspection gives **113/135 strict and visible matches**, leaving 22 actual
disagreements. The original 23 legacy differences remain recorded: five C# ink-luma grayscale errors, two C#
CMYK→JXL errors, ten ICC-managed cases, five codec differences and the TGA inspector defect. Correct source
interpretation is retained instead of reproducing the reference's ink-channel errors. The corrected unmarked
gray output is exact to rendered-light luma even though its C# PSNR drops from 10.2821 to 9.5725 dB.

One fresh **849-case** replay completes **786 jobs with the same 63 failed conversions**, zero harness or
inspection errors, no unexpected state/error-key/output-count/name changes and no staging leftovers.
Comparison PASS is differential parity, not successful conversion:

- Legacy vs C#: **581 PASS / 263 WARN / 5 FAIL**; vs immediate previous `e10e`: **760/88/1**.
- V2 vs C#: **586/255/8**; vs `e10e`: **760/87/2**.
- Preserved `e10e` vs C# under the same V2 policy: **586/255/8**, without rerunning the old host.

All eight V2 C# FAILs remain explicit: four broken reference-image links, the existing two corrected TCR
payloads, and generated-cover differences in SNB→PDF and TCR→TXTz. Both immediate-engine FAILs are those
cover differences. SNB object analysis isolates the change to its generated JPEG cover; page 2, Form content
and CTM are exact. Artwork is not normalized. All seven TCR outputs are byte-identical to `e10e`.
BMP→RST changes WARN→PASS against C#; RB→ODT changes PASS→WARN due to another generated-cover variation.

### Build, packaging and remaining limits

- SDK-denied Swift: **644 engine tests, 14 skips, zero failures**, plus **13 Core tests**. The one process-tree
  test requiring `/bin/ps` passes separately with an empty HOME and restricted PATH outside the extra profile.
- SDK-denied arm64 Xcode clean build and **644 engine tests, 57 skips, zero failures**; **74 app tests** in
  the separate clean environment; actual development-certificate Release and deep/strict signature verification.
- All **five packaged Mach-O files are arm64**, with no .NET files or Homebrew dynamic dependencies.
  The app has **69,561,342 file bytes** and passes **22 relocated checks** with repository and SDK access denied.
  Development-certificate signing is not Developer ID signing or notarization.
- SwiftPM comparison host SHA-256: `158a40ecc3367b20098242d51ed0ebaf49883b109ab04ff7b8ea1f3244c33ffc`.
  Packaged helper SHA-256: `1591d5d34e45e02bf16eaec4b1f3ca5e9ec684c36b9b73a8934d2e1512ccb38d`.
  All **13 runtime files and 971 captured sources** remain unchanged throughout verification. User data,
  SDK/NuGet folders, installed reference apps, corpora and prior captures/reports are preserved.

The retained AVIF metadata fixture remains **0.9674 dB below C# source-relative RGBA PSNR** with the current
ImageIO encoder. GIF/JXL encoder differences and PSD/PSB IPTC resource forwarding remain unresolved; the latter
is preexisting. Tagged lossy output still has codec loss even when the source ICC is applied correctly.
General SVG vertical shaping/filters, arbitrary non-JPEG/PNG ICC provenance and unsupported binary semantics
remain outside proven parity. This replay has 49 unsupported-binary warnings vs `e10e`, 51 vs C#; byte equality
does not establish visual parity. The generic CoreGraphics warning remains unattributed with no observed output
effect. No text-performance code changed or timing was rerun; the earlier Markdown TXT 0.667 s result still
misses its 0.60 s target.

Managed engine installation remains unimplemented. Optional FFmpeg/Ghostscript/Pandoc/LibreOffice/Calibre and
bundled rhwp/7-Zip remain dependencies alongside Swift, macOS frameworks and the retained native libraries.
Physical M1/macOS 15, a separate SDK-free OS, GUI/TCC/SMB/exFAT, real login/notification lifecycle and notarization
remain unverified. No deployment, push or installed-app replacement occurred.

Exact commands, environments, hashes, per-case results and remaining IDs are retained under
`build/resume/quality-corrections-20261025/`: `FINAL.md`, `final-validation-summary.json`, `parent-validation.json`,
Swift/Xcode result files, Release audit/relocation proof, `image-validation/` and `replay-validation/`.
Pre-review builds were deliberately cancelled when the PSD length issue was found; their partial logs remain
under `pre-review-builds/` and are not counted as completed checks. The complete reruns above use `5f9486a`.


## Bounded AVIF encoder investigation (2026-10-25, evening)

The ImageIO quality option alone does not close the remaining AVIF metadata fixture gap. Eleven frozen-host
encodes at qualities 25–100 completed; qualities 99 and 100 are byte-identical. The best reaches **29.5382 dB**
source-relative RGBA PSNR versus the preserved C# output's **29.9389 dB**, while growing from 1,963 to 3,356 bytes
relative to the current quality-75 output. No option remapping was retained.

A scratch arm64 build of **libavif 1.4.2 + libaom 3.14.1** runs without .NET and links only libSystem. Its default
quality-75 YUV444 candidate improves that fixture from **28.9715 to 31.6806 dB**, with 1,283 bytes, and improves
the other two measured RGB/CMYK-managed matrix samples. However, **12 of 50** broader source/quality conditions
regress: low-quality RGB and grayscale. All 50 conversions complete and their alpha planes are exact. Sixteen
additional YUV420/YUV400 probes do not resolve those regressions. The larger RGB example also costs more time
and bytes. These measurements do not justify replacing ImageIO globally, and **no AVIF dependency or encoder
change is included in the application**.

The official source archive SHA-256 is
`2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d`; libaom is pinned to
`03087864cf4bea6abb0d28f95cf7843511413d8f`. Commands, native binaries, source pins, 36 codec-setting probes,
50 broader comparisons, 16 subsampling probes and per-case results are retained under
`build/resume/until20-20261025/native-avif/`. The separate ImageIO option experiment is in `avif-options/` beside it.
These are diagnostic source-relative quality comparisons, not an all-format visual-parity or production
packaging/cancellation claim. Preserved C# outputs were read; the C# host was not executed.


The follow-up calibration reads actual AV1 headers: ImageIO uses quality-dependent quantizers without the
prototype's default IQ tuning, quantization matrices or chroma delta-q. Explicit `tune=ssim` removes the examined
RGB regressions, but four gray-square cases still lose 0.42–0.96 dB after matching quantizers. The broader candidate
also changes size tradeoffs (median 1.52× file bytes); its absent metadata must not be mistaken for compression
savings. The calibration report records 95 additional encodes and distinguishes original IQ timings from the new
SSIM timings (`seconds`, not the inherited `nativeSeconds` field).

A further isolated candidate investigation retained no production change. One 24-megapixel probe took 2.79 s
with two native threads versus 0.47 s through ImageIO/sips, with measured peak memory of 859 MB versus 441 MB.
The native encode cannot be interrupted internally. A separate RGBA probe with lossless alpha grew about 9× at
quality 50 and 3.6× at quality 75. These are single diagnostic runs under shared load, not accepted performance
benchmarks. Correct metadata/orientation handling, alpha policy and symbol isolation also remain necessary before
shipping. Reports are in `native-avif/calibration/` above and
`worktrees/t3-40b9a46e/build/avif-proto/REPORT.md`.

## Managed engine installation and final follow-up (2026-10-25)

이번 후속 변경은 관리형 외부 엔진 설치, PSD/PSB IPTC 보존, 대용량 host 응답과 Markdown 꼬리 추가 최적화다. 기준 실행 파일은 앞 절의 SwiftPM Release `158a40ecc3367b20098242d51ed0ebaf49883b109ab04ff7b8ea1f3244c33ffc`이며 C# 기준선은 다시 실행하지 않았다. 검증은 M2 Max/macOS 27.0.1에서 수행했다. 지원 범위는 M1 이상 arm64/macOS 15 이상으로 유지하지만 해당 최소 하드웨어·OS 실행 증거는 아니다.

### 변경과 검토

- Pandoc 3.12, Calibre 9.15.0, LibreOffice 26.2.6의 고정 arm64 패키지를 앱에서 내려받는다. 크기·SHA-256 검증, 안전한 압축 해제·DMG 분리·실행 파일 확인 후 기존 경로를 덮어쓰지 않고 배치한다. 진행·취소·재시도·상태 갱신과 종료 시 정리 대기를 연결했다. 디스크 작업은 상태 잠금 밖에서 수행하며 정리가 반환된 뒤 종료 상태와 task 제거를 함께 반영한다. 이미 배치한 설치를 취소로 되돌리지는 않는다. 기존 엔진 폴더 교체·자동 업데이트·이어받기는 제공하지 않는다.
- 설치 UI의 갱신 오류가 다른 다운로드의 폴링을 중단하지 않도록 수정했다. 취소된 이전 폴링의 오류는 표시하지 않고, 종료 중 취소 응답·수동 새로고침이 새 폴링을 시작하지 않도록 했다. 기존 종료 정리 중 폴링은 유지한다. 독립 검토의 지적을 수정했고, 마지막 새로고침 가드는 부모 코드 검토와 수정 전 실패·수정 후 통과 회귀 테스트로 확인했다.
- PSD/PSB는 JPEG APP13, PNG raw-profile tEXt/zTXt, PSD/PSB 리소스에서 IPTC `0x0404`와 digest `0x0425`만 바이트 그대로 보존한다. 픽셀·ICC·해상도와 다른 Photoshop 리소스는 이 경로로 복사하지 않는다. `keepMetadata=false`는 IPTC도 제거한다. PNG 해제량은 오류 스트림까지 누적 계산하며 한도를 넘으면 이후 해제를 하지 않는다. iTXt·다른 입력 형식·PSD의 COM/EXIF/XMP는 이번 범위에 포함하지 않았다.
- 앱은 `--chunked-output`으로 큰 응답을 원문 2 MiB 단위로 받는다. 물리 줄은 4 MiB, 논리 메시지와 대기 큐는 각각 64 MiB까지다. 목록·이력을 잘라내지 않으며 기존 클라이언트와 요청 제한은 유지한다. 64 MiB 초과 메시지의 오류/fatal 정책은 남아 있다.
- Markdown의 소유된 마지막 inline 노드에 바로 이어 붙이는 경로를 추가했다. weak 부모 참조와 기존 변형 API 의미는 유지했다. 119,792개 Markdig 바이트 비교, 5,830개 실제 host 출력과 관련 회귀 검사가 통과했다. 후속 single-child transfer 실험은 TXT 중앙값 0.66643→0.66503초(0.2%)에 그쳐 폐기했고 추가 생산 변경은 없다.

### 소스와 실행 파일 연결

엔진·Core 전체 검증 소스는 `8a7c3cc`, 849건·이미지 검증 소스는 `a5d32f2`, 마지막 앱 소스는 `d9b260d`다. 그 사이 바뀐 생산 코드는 `Sources/App/AppModel.swift`뿐이며 테스트 변경도 `Tests/App/AppModelTests.swift`에 한정된다. `final-host/`의 변환 검증용 캡처는 보존했고 `final-app-source-host/`에 마지막 앱 소스와의 연결을 따로 기록했다. 두 SwiftPM 실행 파일과 리소스 13개는 바이트가 같다.

- SwiftPM Release helper SHA-256: `75da280a6647dbf851652a704c53ba3445acdeb71a8565b9fe77c862cf63aa94`.
- 서명된 Xcode Release helper SHA-256: `baa76eabd1acb355bd28fa9346c794522b0b69e16a91ab0c2216896a80593107`.
- Xcode 앱 실행 파일 SHA-256: `fe94cb099a26f6a9c4794ccb58b8db03e6f09aa7af86000ba5a4c0a2d39f6e38`.

전체 명령·환경·종료 코드·해시는 `build/resume/until20-20261025/`에 보관한다. `swift-final-results.json`, `xcode-final-results.json`, `xcode-final-ui-results.json`, `xcode-final-quitguard-results.json`, `quitguard-source-binding.json`이 단계별 범위와 소스 차이를 구분한다. 후속 문서 커밋은 검증한 실행 소스를 바꾸지 않는다.

### 빌드·테스트·배포 구성

- SDK 접근 차단 Swift 엔진 669개: 14개 skip, 실패 0. `ps` 사용을 위해 별도 빈 HOME 환경에서 실행한 프로세스 트리 종료 1개도 통과했다. Core 18개는 실패 0이다.
- SDK 접근 차단 Xcode 엔진 669개: 58개 skip, 실패 0. 최종 앱 소스의 Xcode 클린 빌드와 별도 clean 환경 앱 81개 테스트는 실패 0이다. 선택 도구·표본 미설정 skip을 통과로 세지 않는다.
- 기존 개발 인증서의 Release 서명과 deep/strict 검사가 통과했다. Mach-O 5개는 모두 arm64이며 .NET 파일·런타임과 Homebrew 동적 링크가 없다. 앱 파일 합계는 69,942,728바이트, helper는 35,292,832바이트다. Developer ID·공증 검증은 아니다.
- 저장소와 .NET 경로 접근을 막은 재배치 앱의 22개 실행 검사가 통과했다. 같은 서명된 재배치 helper가 실제 HTTPS로 42,267,373바이트 Pandoc 패키지를 검증·설치하고 RST→DOCX 내용 검사를 통과했다. 설치 응답 0.000146초, 설치 중 다른 RPC 3개도 응답했고 staging 잔여물은 없다. 이 수치는 한 번의 기능 검사이며 성능 보장은 아니다. Calibre·LibreOffice도 고정 캐시 패키지 설치·실변환 검사에서 통과했다.
- 사용자의 .NET/NuGet 폴더, 기존 설치 앱과 사용자 설정은 삭제·교체하지 않았다. SDK가 설치되지 않은 별도 OS나 물리 M1/macOS 15 검증으로 확대해 말하지 않는다.

### 실제 변환 비교

849건을 한 번 새로 실행했다. 786개 완료·기존과 같은 63개 변환 실패이며 harness·검사 오류는 0이다. 상태·오류 키·출력 수·이름의 변화가 없고 staging과 private HOME/TMP는 비어 있었다. 런타임 13개·캡처 소스 974개와 기준선·도구·입력의 전후 해시가 같았다.

| 비교 정책 | PASS | WARN | FAIL |
| --- | ---: | ---: | ---: |
| Legacy 대 C# | 582 | 262 | 5 |
| Legacy 대 직전 Swift 158a40 | 763 | 85 | 1 |
| V2 PDF-render 대 C# | 587 | 254 | 8 |
| V2 PDF-render 대 직전 Swift 158a40 | 763 | 84 | 2 |

새 FAIL ID는 없고 기존 실패는 면제하지 않았다. 동일하게 실패한 변환도 비교 PASS에 포함되므로 PASS는 변환 성공 건수가 아니다. C# 대 V2의 8건은 기준선의 이미지 참조 누락 4건, 수정된 TCR 내용 차이 2건, Calibre 자동 표지 차이 2건이다. TCR 7개는 직전 Swift와 바이트가 같다. C# 대비 한 건의 WARN→PASS는 LIT→DOCX 자동 표지가 우연히 같은 바이트로 생성된 결과이며 생산 개선으로 세지 않는다. 바이너리 50개(대 C# 51개)는 의미 검사가 없고 PDF 주석은 래스터 검사 범위 밖이다.

이미지 검증은 186건 중 185개 성공과 의도된 초과 ICC 거부 1개다. 기존 135개 화소·시각 결과는 모두 유지됐고 133개 파일은 바이트가 같다. `metadata` PSD/PSB 두 파일만 정확히 30바이트 IPTC가 추가됐으며 나머지 바이트는 그대로다. IPTC 23/23, ICO 54/54 프레임, JP2 품질 12/12, CMYKA 2/2와 독립 19×13 ICC resize oracle이 통과했다. 7,705개 보호 파일은 바뀌지 않았다.

C# 엄격·시각 일치는 112/135이며 TGA 검사 오류만 고친 별도 정책은 113/135다. 기존 23개 차이는 C# CMYK 회색조 오류 5개, C# CMYK JXL 오류 2개, 실제 ICC 변환·코덱 손실 차이 10개, GIF/AVIF/RGB JXL 코덱 차이 5개, TGA 검사기 1개다. 실제 AVIF 품질 부족을 포함해 면제하지 않았다. 다른 Photoshop 리소스·일부 입력 형식의 메타데이터와 전체 형식의 시각 동등성까지 보장하지 않는다.

### 순차 성능과 남은 항목

이 작업의 동시 빌드·변환 없이 5회씩 순서를 교차한 60개 변환이다. 아래는 최선 값이며 공유 M2 Max의 진단값이다. 모든 비교 출력은 같고 FB2 문서 UUID만 이전에 입증한 규칙으로 제외했다. PDF 코드는 이번 변경에서 바뀌지 않았으므로 수치 변화 전부를 새 최적화의 효과로 해석하지 않는다.

| 입력 → 출력 | 직전 Swift (초) | 현재 (초) |
| --- | ---: | ---: |
| big.pdf → TXT | 0.60619 | 0.54721 |
| big.epub → FB2 | 0.45782 | 0.45616 |
| big.docx → MD | 0.09280 | 0.09339 |
| big.docx → TXT | 0.08451 | 0.08424 |
| big.md → HTML | 0.74372 | 0.72686 |
| big.md → TXT | 0.69104 | 0.66548 |

PDF TXT의 0.84초 목표는 충족하지만 Markdown TXT의 0.60초 목표는 미달이다. AVIF 네이티브 대안은 앞 절의 회색조 회귀·alpha 크기·메모리·취소·패키징 문제 때문에 앱에 넣지 않았다. 복잡한 SVG·세로쓰기, JPEG/PNG 밖의 일부 ICC/메타데이터, 검사기가 없는 바이너리 의미, 실제 M1/macOS 15·SMB/exFAT/TCC·로그인/알림 실기와 배포 공증도 남아 있다.

별도 AVIF 후속 실험에서는 기존 `ProcessRunner.swift`와 작은 scratch helper 대체물을 사용해 외부 인코더의 프로세스 그룹 취소를 검사했다. 24 MP·q75·인코더 2스레드에서 정상 인코딩은 2.46초, 실행 중 세 번의 취소는 5.3/7.6/8.8ms, 외부 그룹 종료의 재측정은 8.2ms였다. 여섯 인코더 호출에서 게시·staging 파일은 남지 않았으며 정상 출력은 이전 native 출력과 바이트가 같다. 인자 파싱 실패 네 번은 인코더를 시작하기 전 실패로 따로 남겼다. 이는 앱 큐·staging 통합이나 최종 파일 쓰기 도중 강제 종료 검증이 아니다. 회색조 0.42–0.96dB 회귀, 24 MP에서 ImageIO보다 큰 메모리·시간 비용, alpha 크기, 화소·메타데이터 전달과 별도 서명 helper 패키징은 해결하지 않았다. `build/avif-proto/REPORT.md`의 후속 절에 근거를 남겼으며 앱 소스·의존성은 바꾸지 않았다.

## Remaining work integration (2026-10-26)

이번 통합은 이미지 메타데이터·TGA·SVG 텍스트·Markdown 성능, 별도 AVIF 인코더와 의미 검사 확대를 반영한다. 실행 소스는 `bff5988d18b28d40ce27baddcbece31d44213ce6`이며, 검증 환경은 M2 Max/macOS 27.0.1이다. 현재 후보만 실행하고 C#·직전 Swift 결과는 보존된 파일로 비교했다. C# host와 과거 기준선 host를 다시 실행하지 않았다. 아래 결과는 모든 형식의 화소·레이아웃·메타데이터 동등성을 뜻하지 않는다.

### 변경과 독립 검토

- 이미지 메타데이터 변경 13개를 통합했다. 출력 크기·방향·DPI에 맞춘 EXIF, PNG raw-profile iTXt와 주석, PSD/PSB의 허용된 EXIF·XMP·IPTC·caption·copyright·URL, 추가 입력 형식의 ICC 보존을 다룬다. TIFF 페이지별 태그, PSD 누적 ICC 16 MiB 한도, EXIF DPI와 BMP V5 내장 프로필의 후속 수정은 `51845cd`의 독립 R3 검토에서 통과했다. BMP의 제한된 24/32비트 내장 RGB ICC 경로는 픽셀 범위·마스크·프로필 겹침을 검사하며 링크된 프로필을 읽지 않는다. 모든 형식의 태그를 복사하는 일반 보존 기능은 아니다.
- TGA 출력은 비-sRGB RGB/색인 입력을 8비트 sRGB로 변환한 뒤 프로필 없는 형식에 기록한다. 알파를 보존하고 이미 sRGB인 입력과 회색조 경로를 유지한다. 독립 검토와 실제 출력 검증을 통과했다.
- SVG의 상대 `font` 단축 속성, 상속·대소문자·공백, 세로쓰기와 글리프 방향을 보완했다. 표현할 수 없는 bidi·baseline 조합은 기존 렌더러로 되돌린다. `ae83640`의 독립 R5는 새로운 지적 없이 20개 쌍을 통과했다. C# 글꼴·세로 라틴 문자 방향 차이까지 해소한 것은 아니다.
- Markdown은 중복 탐색과 중간 할당을 줄이고 기존 노드 소유권·변형 의미를 유지했다. 119,792개 엄격 출력, 6,000개 AST와 5,830개 실제 host 출력 검증을 보존했다. 최종 통합 실행 파일의 대용량 성능·출력 검증은 아래에 별도로 기록한다.
- AVIF는 고정한 libavif 1.4.2/libaom 3.14.1을 별도 arm64 `FileToXAvifEncoder`로 실행한다. 단일 8비트 RGB 입력의 ImageIO 결과를 먼저 만든 뒤 네이티브 후보와 비교한다. ImageIO로 읽은 premultiplied 표본의 색·알파 SSE가 모두 증가하지 않고 하나 이상 감소하며 메타데이터 가드를 통과할 때만 후보를 쓴다. 회색조·색인·고정밀·다중 프레임·도구 없는 경로는 ImageIO를 유지한다. 취소는 도구의 프로세스 트리를 종료하고 전용 0700 임시 폴더를 정리한다.
- AVIF R1에서 큰 EXIF를 JPEG 메타데이터 전달 경로가 조용히 누락하는 문제가 발견됐다. 입력 중 ImageIO가 보존한 태그와 문자열 값을 후보에서 확인하고, 손실되면 ImageIO 파일을 유지하도록 수정했다. `8c205d7`의 독립 R2는 13쌍/26개 새 변환에서 100,007자 EXIF·GPS 보존, 짧은·중첩 XMP, 회전·DPI·strip 경로를 확인했다. 배열·구조 값은 최상위 태그의 존재만 확인하므로 깊은 메타데이터 동등성은 보장하지 않는다. EXIF 픽셀 치수는 출력 크기 수정 때문에 이 비교에서 제외한다.
- PDF 주석·액션·폼과 지원하는 바이너리 형식의 독립 readback 검사를 추가했다. 주석 객체·appearance 회귀 표본과 바이너리 검사 테스트를 통과했다. 새 검사가 드러낸 UUID·메타데이터·순서·텍스트·표지 차이도 엄격 판정에 남기며, 단순히 검사기가 생겼다는 이유로 동등하다고 판정하지 않는다.

SVG·메타데이터·AVIF의 마지막 검토에는 수정이 필요한 새 지적이 없었다. 각 검토는 지정된 소스·표본·가드의 범위에 한정되며 보편적 품질 보증이 아니다. AVIF의 518조건 확장 검사는 메타데이터 가드 추가 전 증거다. 가드 추가 후에는 집중 회귀·새 독립 26건·최종 통합 검증을 실행했으며 518조건 전체를 다시 실행했다고 세지 않는다.

### 소스·실행 파일과 빌드

전체 증거 루트는 `build/resume/remaining-complete-20261025/`다. `final-host/capture.json`은 실행 소스 992개와 SwiftPM 런타임 파일 14개를 SHA-256으로 고정한다. 후속 문서 커밋은 이 소스·실행 파일을 바꾸지 않으며 `final-doc-source-binding.json`으로 연결한다.

| 실행 파일 | SHA-256 |
| --- | --- |
| SwiftPM Release engine | `959ca44e879bcc74b4f30815ae2f4ad278cff365d1da49fcf0626f9834a16f99` |
| SwiftPM AVIF 도구 | `f5247f168dd96e09d38e465355ec38f137b1e68a70d3c915b440ec2b447c7b73` |
| Apple Development Xcode Release engine | `9346866996c4c360fc132b97a91d9826046de650c84e834a52c351825de7cd08` |
| Xcode Release 앱 실행 파일 | `6d34f9f4e0fe7992aa510446aef97f2195b8ca76ffb81e9587bfb29ec7d101d2` |

- .NET SDK 접근 차단 Swift 엔진 728개(14개 skip)·Core 18개와 별도 빈 HOME의 프로세스 트리 종료 검사 1개가 실패 없이 완료됐다. 선택 도구·표본 미설정 skip은 통과로 세지 않는다.
- .NET SDK 접근 차단 Xcode 클린 빌드·엔진 728개(58개 skip), 별도 clean 환경 앱 81개와 기존 팀 Apple Development 인증서의 Release 빌드가 통과했다.
- 번들 Mach-O 6개는 모두 arm64이며 .NET 파일·Homebrew 동적 링크가 없다. 내부 코드의 같은 Team ID, library-validation 예외 없는 helper와 deep/strict 서명을 확인했다. AVIF 도구의 고지 5개는 원문과 바이트가 같다. 앱 파일 합계는 76,609,264바이트, 엔진 실행 파일은 35,426,272바이트다.
- 저장소·.NET 경로 접근을 차단한 재배치 앱의 23개 실행 검사가 통과했다. 새 도구의 실제 AVIF 4:4:4 변환을 포함하며 staging 잔여물은 없다. 이는 Developer ID 배포 서명·공증 검증이 아니다.

명령·종료 코드는 `swift-final-results.json`, `xcode-reviewed/xcode-final-results.json`에, 배포 감사는 `release-final-audit.json`, `release-final-relocated-proof.json`과 로그에 남겼다. 중간 소스의 `candidate-965f9f8/` 결과는 최종 증거로 대체해 세지 않는다. 사용자의 .NET/NuGet 폴더·설치 앱·실제 설정은 변경하지 않았다.

### 849건 재실행과 비교 정책

최종 유효 실행은 `replay-validation-20261026-corrected/`다. **786개 완료·기존과 같은 63개 변환 실패**, harness·검사 오류 0이다. 상태·오류 키·출력 수·이름은 직전 Swift와 같았다. 오류 상세 21건의 차이는 실행 루트와 `.filee-out-` 임시 식별자에만 있고, 한정된 경로 정규화로 확인했다. TCR 7개는 직전 Swift와 바이트가 같다.

첫 실행 `replay-validation-20261026/`은 새 검증 래퍼의 광범위한 쓰기 차단으로 LibreOffice 45건이 추가 실패했다(741개 완료/108개 실패). 같은 고정 실행 파일과 입력으로 쓰기 제한이 있는 경우 실패, SDK 접근만 차단한 경우 성공을 재현했다. 성공 ODT의 `content.xml`은 직전 결과와 바이트가 같았다. 잘못된 환경의 실행·감사 결과를 보존하고, 전용 HOME/TMP와 SDK 접근 차단을 유지한 새 경로에서 전체 849건을 다시 실행했다. 첫 시도의 수치를 생산 회귀로 세지 않는다.

| 비교 정책과 대상 | PASS | WARN | FAIL |
| --- | ---: | ---: | ---: |
| Legacy 대 C# | 582 | 261 | 6 |
| Legacy 대 직전 Swift | 746 | 101 | 2 |
| 확장 의미 검사 대 C# | 599 | 202 | 48 |
| 확장 의미 검사 대 직전 Swift | 758 | 53 | 38 |
| 같은 확장 정책으로 보존된 직전 Swift 대 C#만 재검사 | 599 | 204 | 46 |

마지막 행은 변환기를 다시 실행하지 않은 정책 대조군이다. 보존된 같은 출력에서 기존 WARN 38개가 FAIL, 12개가 PASS로 바뀐다. 따라서 이전 V2의 `587/254/8`과 현재 `599/202/48`을 직접 비교해 새 회귀 40건이라고 해석하면 안 된다. 반대로 새 FAIL을 모두 무시해서도 안 된다. **문턱값을 낮추거나 실패를 면제하지 않았다.** 동일하게 실패한 변환도 비교 PASS에 포함되므로 PASS는 변환 성공 수가 아니다. WARN 역시 시각·내용 동등성의 증거가 아니다.

동일한 확장 정책의 대조군보다 추가된 C# FAIL은 두 건이며 해소된 FAIL은 없다.

- `auto-043-m4v-to-avif`: C#와의 PSNR은 45.4505→24.0188 dB로 낮아져 FAIL이다. 실제 추출 프레임은 태그 없는 sRGB 160×120 PNG다. 현재 후보와 도구를 뺀 동일 후보의 ImageIO 대조군이 각각 최종·직전 파일을 바이트 그대로 재현했다. 입력 대비 ImageIO 디코딩 PSNR은 native 45.9055 dB, 직전 22.7268 dB, C# 22.7199 dB다. Q8 독립 디코딩도 native 46.97 dB, 직전 42.39 dB, C# 41.51 dB로 같은 방향이다. 공통 sRGB와 원래 표본 공간의 값도 같다. 이전 4:2:0 출력의 색 경계 손실을 4:4:4가 줄인 사례이며, 원래 C# 비교 FAIL 판정은 유지한다. 저장된 원본 버퍼와 파일 해시를 이용한 독립 재계산에서도 SSE 96,151 대 19,990,566/20,022,470을 확인했다. 근거는 `m4v-source-audit/result.json`과 AVIF 구현 작업의 `build/avif/m4v-043/`에 있다.
- `auto-063-snb-to-rb`: 텍스트는 유지되지만 Calibre 자동 표지가 달라졌다(최종 C# 비교 PSNR 26.72 dB, SSIM 0.94729). 생성 표지 변동으로 분류하되 FAIL을 유지한다. Legacy의 직전 Swift 대비 다른 FAIL인 `auto-067-tcr-to-txtz`도 자동 표지 차이다.

검사기는 비교별 바이너리 출력 61개를 readback했고 오류는 0이다. PDF 19개는 래스터와 주석 객체 검사를 거쳤지만 이 19개에는 주석이 없으므로 코퍼스의 주석 보존 실증으로 말하지 않는다. 주석 표본 검증은 별도의 집중 테스트 증거다. 바이너리 검사도 지원하는 디코더·필드의 범위에 한정된다.

실제 파일 감사는 입력 사본 864개, 결과 항목 794개에 해당하는 실제 출력 파일 802개와 sidecar 18개를 확인했다. 직전 Swift 대비 결과 항목 303개(302개 case)와 sidecar 3개가 바이트 변경됐고 추가·삭제된 결과는 없다. 런타임 14개·소스 992개·기준선·입력·도구는 전후 해시가 같고 private HOME/TMP·staging은 비어 있다. `final-handoff.json`, `per-case-deltas.json`, `comparison-analysis.json`, `inspection-coverage.json`, `raw-audit.json`과 `integrity-final-check.json`에 판정·귀속·감사를 보존한다. 감사 summary SHA-256은 `8a45f4c32e6daa3d55a3f2211c79908995296e7fbc00c49a30e278beb4654e1e`다.

### 이미지·메타데이터·SVG 보충 검증

최종 실행 파일로 이미지 161건을 실행해 160개 성공·의도된 초과 ICC 거부 1개를 확인했다. 성공 파일 160개는 검토된 AVIF 구현의 `cases5`와 바이트가 같다. 기존 135개 매트릭스는 C#와 raw·visible 엄격 일치가 각각 112개이며, 직전 Swift와 달라진 화소 출력은 AVIF 3개(`cmyk-all`, `cmyk-profile-all`, `metadata-all`)다. 이 수치를 전체 이미지 동등성으로 확대하지 않는다.

별도 TGA 17건은 모두 검증을 통과했다. 프로필 RGB JPEG/PNG의 sRGB 독립 oracle 대비 최대 채널 오차는 각각 52→0, 48→0이며 기존 매트릭스의 TGA 3개는 바이트가 같다. SVG 실제 출력 66개와 R5의 40건/20쌍은 보존된 검토 결과와 화소·파일이 같고 기존 정규화 63개도 유지됐다. 보충 PNG 한 파일의 바이트 차이는 추가된 tEXt 2개뿐이며 IDAT·렌더링은 같고 메타데이터 구현 결과와도 일치한다.

메타데이터 부분집합 64건/66개 출력에서 태그·속성 차이나 누락은 없다. 65개 파일은 검토된 메타데이터 구현과 바이트가 같고 `builtin-to-avif` 1개는 인코딩 바이트가 다르다. 이 출력의 입력 대비 색 SSE는 103,895→20,120, 알파 오차는 0이며 Q8 PSNR은 41.4971→49.1552 dB다. raw byte `REVIEW_REQUIRED`는 보존하고 이 한 표본의 근거를 붙였다. 첫 849건과 수정한 재실행의 이 부분집합 64건·입력 발생 65개·출력 66개는 전부 바이트가 같아서 보충 메타데이터 증거도 최종 재실행에 적용된다.

근거는 `image-supplement-final/final-audit/REPORT.md`, `image-supplement-final/corrected-replay-binding/REPORT.md`와 연결된 JSON에 있다. 이미지 감사의 보호 경로 2,973개는 바뀌지 않았다. 앞 절에 기록한 C# CMYK 오류·ICC/코덱 차이와 미지원 태그·형식은 이 검증으로 면제되지 않는다.

### 최종 후보 성능

다른 작업의 빌드·변환을 끝낸 뒤 동일 후보만 6종 × 5회, 총 30회 순차 실행했다. .NET SDK 접근 차단과 전용 HOME/TMP를 사용했다. 이전 시간은 역사적 값이며 동시점 A/B 측정이 아니다. 공유 M2 Max의 진단값으로, 다른 사용자의 모든 시스템 부하가 없었다고 주장하지 않는다.

| 입력 → 출력 | 최선 (초) | 중앙값 (초) |
| --- | ---: | ---: |
| big.pdf → TXT | 0.580092 | 0.603380 |
| big.epub → FB2 | 0.407639 | 0.412003 |
| big.docx → MD | 0.089163 | 0.092700 |
| big.docx → TXT | 0.081940 | 0.083386 |
| big.md → HTML | 0.603105 | 0.606248 |
| big.md → TXT | 0.546107 | 0.556180 |

**Markdown TXT 0.60초와 PDF TXT 0.84초 목표를 각각 5/5회 충족했다.** 최댓값도 각각 0.564790초·0.652617초다. 모든 출력은 보존된 직전 결과와 동등하며 FB2의 검증된 문서 UUID·생성 날짜만 제외한다. 보호 파일 50개가 그대로이고 staging 잔여물은 없다. `performance-reviewed/summary.json`, `raw.json`, `command.json`에 전체 시간과 명령을 남겼다.

첫 성능 시도는 PDF 5회 뒤 FB2 생성 날짜가 2026-10-25에서 26으로 바뀌어 바이트 비교를 중단했다. 원래 시도와 파일은 `performance/`에 보존했다. 재귀 XML 비교로 차이가 문서 UUID와 `document-info/date` 두 필드뿐임을 확인한 뒤, 문서 날짜 하나의 속성과 본문이 일치하고 보존된 두 날짜 중 하나인 경우만 제외했다. 본문 변경·중복 날짜·다른 날짜는 거부하는 self-check 6개도 통과했다. 이는 변환 코드나 일반 비교기의 완화가 아니며 근거는 `performance-date-attribution.json`, `performance-date-selfcheck/result.json`이다.

### 남아 있는 한계

AVIF 선택 가드는 ImageIO 디코딩 표본 오차와 한정된 메타데이터만 비교한다. 확장 Q8 검사에서 q1 CMYK 한 조건의 0.1862 dB 저하는 그대로 남는다. 네이티브 후보를 버리는 경우에도 첫 ImageIO 인코딩·네이티브 인코딩·두 디코딩의 비용을 지불한다. 최종 가드 전 진단에서 8.8/24/36 MP의 중앙 시간은 ImageIO 0.29/0.43/0.42초에서 후보 비교 포함 1.89/3.62/2.48초로 늘었다. host 피크는 최대 약 1.44 GB, 별도 도구 피크는 약 1.1 GB였다. 서로 다른 프로세스의 피크를 동시에 측정한 총 메모리로 합산하지 않는다. 저품질에서 ImageIO가 버리는 ICC를 보존해 파일이 8.07배인 사례도 있으며 무조건 작은 파일을 보장하지 않는다.

SVG shorthand 표본의 C# 대비 SSIM은 0.375165→0.300399, PSNR은 15.6966→16.2245 dB로 엇갈린다. serif·세로 라틴 방향 차이와 복잡한 SVG는 남아 있다. 메타데이터는 누적 크기 제한·허용된 리소스·형식별 지원에 한정되며 BigTIFF·ICO 프레임 매핑·XCF 원본 ICC와 모든 중첩 태그 보존을 보장하지 않는다. 새로운 바이너리 의미 검사도 모든 문서 기능의 동등성을 증명하지 않는다.

물리 M1/macOS 15, 외장 exFAT·SMB·TCC 재실행과 실제 로그아웃/로그인 후 자동 실행·알림은 검증하지 않았다. Ghostscript가 없고 FFmpeg 일부 인코더도 없으므로 관련 skip·변환 실패가 남는다. Developer ID 서명·공증은 이번 작업에서 제외했다. 앞의 역사적 기록과 이 절의 raw FAIL·WARN을 보존하며 완전한 시각·내용 동등성이나 배포 완료로 표현하지 않는다.

## Quality follow-up and alternatives (2026-10-26)

이 절은 앞 절의 엄격 FAIL을 다시 분류하고 실제 손실과 비용을 줄이는 후속 작업이다. 최종 실행 소스는 `6c1509817424f10a5f8228c3b748fc57c1671824`다. LIT 목차 서식·SVG 경로 텍스트·AVIF 메타데이터와 비용을 보완했고, 전체 C# 엄격 FAIL 48건은 남아 있다. 문턱값과 원래 판정을 바꾸지 않는다. 근거 루트는 `build/resume/quality-next-20261026/`다.

### 최종 통합 검증

정상 SwiftPM Release host SHA-256은 `3ab08f5130ec90f9fbb212c380358f0c7cbbfb38cc075e6ca99ab3a7d2584301`, AVIF 도구는 `01a1b0cd2ee3824b4cb687426e3c8d7a61b7286250c3ca937f8e4680b596da11`다. `final-host/capture.json`이 런타임 14개와 소스 993개를 연결한다. 이후 README·설계 문서만 변경하며 `final-handoff.json`에 실행 소스와 문서 커밋을 구분한다.

.NET SDK 접근을 차단한 SwiftPM 엔진 **750개(14개 skip)**·Core **18개**, 별도 프로세스 트리 종료 검사와 queued-cancel 검사가 실패 없이 완료됐다. Xcode 클린 빌드와 엔진 **750개(59개 skip)**·앱 **81개**도 실패가 없다. Skip은 통과로 세지 않는다. 별도의 Release 앱은 기존 Apple Development 인증서로 서명했고, Mach-O 6개가 모두 arm64이며 .NET 파일과 Homebrew 동적 링크가 없다. PDFium·OpenJPEG·Skia·AVIF 고지와 라이브러리 검증을 유지했다. 저장소·SDK를 읽을 수 없는 별도 경로에서 **23개 실행 검사**와 deep/strict 서명 검사가 통과했다. 이 패키지의 엔진 SHA-256은 `586ead72ff67d4a2c0148e31a8dfdb63d9ada8e5e2b300f3bcc0a53c1e23bb20`다.

Release의 첫 Xcode 서명 사전 검사는 전용 HOME에서 인증서를 찾지 못해 exit 65로 끝났다. 인증서를 열거하거나 설정을 바꾸지 않고 이미 지정된 인증서·키체인을 명시한 사본 서명을 확인한 뒤, 서명 없는 Release 빌드에 중첩 실행 파일 → helper → 앱 순서로 서명했다. helper에는 빈 entitlements를 적용해 library validation을 유지했다. 최초 재배치 실행도 임시 경로가 차단한 저장소 안에 놓여 exit 2였고, `/private/tmp`의 새 전용 경로에서 검증했다. 원래 실패 기록은 `xcode-validation/xcode-final-results.json`, `release-audit-initial-source-denial/`에, 복구는 `xcode-validation/explicit-signing/`·`xcode-recovered-final-results.json`·`release-final-{audit,relocated-proof}.json`에 보존한다.

849개를 새 최종 host로 한 번씩 실행했다. **786개 완료·63개 실패**, harness·inspection 오류 0이며 모든 작업 상태와 오류 키가 직전 Swift와 같다. 같은 실패를 포함한 비교 PASS는 변환 성공 수가 아니다.

| 비교 | PASS | WARN | FAIL |
| --- | ---: | ---: | ---: |
| Legacy · C# 대비 | 581 | 262 | 6 |
| Legacy · 직전 Swift 대비 | 764 | 84 | 1 |
| 확장 의미 검사 v2 · C# 대비 | 598 | 203 | 48 |
| 확장 의미 검사 v2 · 직전 Swift 대비 | 776 | 33 | 40 |
| 같은 현재 판독기로 보존된 직전 Swift를 C#와 비교 | 599 | 202 | 48 |

C# 대비 엄격 FAIL의 사례 집합은 대조군과 같다. `auto-039-lrf-to-dotm` 하나가 생성 표지 차이로 PASS→WARN이고, 그 외 판정 변화는 없다. 직전 Swift 대비 엄격 FAIL 40개에는 생성 UUID·시간, OPF/리소스 순서, 추가된 목차 CSS, 생성 표지, DWG 헤더 등이 포함된다. 본문 텍스트 비교 187개 부분은 직전 Swift와 모두 비율 1.0이며 C# 대비 본문에서 0.95 미만인 부분은 없다. 구조·리소스·그림의 차이를 본문 보존만으로 면제하지 않는다. 원래 판정과 PSNR 30·SSIM 0.95·텍스트 0.95 기준을 유지한다.

바이너리 readback은 비교별 61개, PDF 검사는 19개이며 reader 오류가 없다. PDF 표본은 주석 보존 전체를 입증하지 않는다. 입력 사본 864개·결과 항목 794개에 해당하는 출력 파일 802개·sidecar 18개를 감사했다. 직전 Swift 대비 284개 사례의 결과 항목 285개와 sidecar 3개는 바이트가 다르고 결과 추가·삭제는 없다. TCR 7개는 직전 Swift와 바이너리까지 같다. 영상 프레임의 `auto-043-m4v-to-avif`도 직전 파일과 바이트가 같아 앞 절의 입력 대비 품질 분석을 재사용할 수 있다. 보호 파일은 그대로이며 staging 잔여물은 없다. `replay-validation/audit-complete.json`과 그 summary, `final-comparison-attribution.json`에 연결했다.

첫 binding은 이전 HarfBuzz 14.6.0 두 파일이 설치 경로에서 사라져 변환 실행 전에 중단됐다. 현재 설치된 15.0.0_1을 읽기 전용으로 고정했고 기존 나머지 28개 파일의 해시는 같았다. 기존 목록 밖의 transitive dependency 두 개도 포함해 PDF 판독기의 32개 파일을 고정했다. 설치·전역 설정 변경은 하지 않았다. 다섯 비교와 보존 출력 대조군 모두 이 동일한 판독기를 사용했다. 원래 binding과 실패 시도, 현재 의존 경로·해시는 `replay-validation/reader-binding-recovery/`에 보존했다. 이전 환경과 판독기 바이너리 전체가 동일하다고 주장하지 않는다.

### 의미 검사와 전자책 수정

바이너리 readback의 실패 이유를 본문과 메타데이터 텍스트로 구분했다. 이전의 텍스트 손실 FAIL 14개는 OPF/LRF 메타데이터 텍스트 차이였고, 검사한 본문 텍스트 비율은 모두 1.0이었다. 비교 정책 v2는 수치·문턱값·PASS/WARN/FAIL을 그대로 유지한다. 보존된 바이너리 출력 61개를 C#와 직전 Swift 각각에 대해 재검사했고 모든 기존 판정·텍스트 수치가 같으며 reader 오류는 0이었다. 독립 R1은 새 22개 readback 테스트·36개 harness 테스트·400개 조합과 37개 공격적 입력을 확인했다. 이는 변환 품질 개선이나 FAIL 감소가 아니다. OPF 판별은 파일 이름 접미사에 기반하며 모든 형식의 메타데이터 분류를 보장하지 않는다.

C libmobi 0.12를 arm64/macOS 15 대상으로 별도로 빌드해 보존된 MOBI/AZW3 51개를 추출했다. 각 17개 비교군 중 16개는 검사한 본문 HTML 이벤트, 연결 순서의 CSS, 읽기 순서의 참조 이미지가 일치했다. 기존 MOBI 이미지 크기 FAIL 한 건은 실제 참조 관계를 따라 비교하면 그림 2개가 모두 바이트까지 같았고, 원인은 레코드 순서였다. 기존 엄격 판정은 유지한다. 이 검사는 표지·색인·NCX/OPF 식별자·미참조 리소스나 기기에서의 페이지 배치 동등성을 뜻하지 않는다.

남은 LIT→AZW3 사례에는 실제 손실이 있었다. 원본 LIT에는 목차 CSS가 있지만 Calibre 9.15의 CSSFlattener는 spine/titlepage/nav만 처리한 뒤 기존 CSS를 제거해 읽기 순서 밖 목차의 스타일 링크를 남겼다. LIT→AZW3 직접 변환도 이를 해결하지 못했다. 기존 CSS 처리기에 비-spine HTML을 포함하는 작은 패치를 적용하고, 이후 EPUB→AZW3 단계에서도 유지하도록 모든 Calibre 변환을 같은 개인 프로세스 스크립트로 실행한다. 실제 읽기 순서는 바꾸지 않았다.

독립 LIT R2는 실제 최종 AZW3를 libmobi로 다시 읽고 CSS 선택자·우선순위를 적용해 목차 제목 가운데 정렬과 1.2em/-1.2em 들여쓰기를 확인했다. 본문 DOM과 17개 요소·10개 클래스의 선언은 보존된 수정 전 결과와 같다. 38개 집중 테스트와 29개 명시적 조건 검사, 원본 PNG·TTF 리소스, TCR 캡처, 잘못된 입력·취소를 통과했다. Calibre 내장 Python의 최적화 모드가 assert를 비활성화하므로 최종 probe는 if/raise를 사용했다. 초기 assert-only 기록은 최종 증거에 포함하지 않는다. 이 수정에는 선택한 Calibre의 `ebook-convert`와 `calibre-debug`가 함께 필요하며, 내부 API 호환성은 검증한 9.15에 한정된다. 최종 849건의 실제 AZW3도 새 libmobi 추출로 검사해 목차 CSS·본문 DOM과 17개 요소 선언·10개 클래스·읽기 순서와 링크를 확인했다. 본문 HTML은 보존된 수정 전 R1과 바이트까지 같고, 원본 이미지가 없는 이 표본의 생성 표지 바이트는 다르다. 근거는 `final-lit-readback/run01/result.json`이며 Python 최적화 모드 2에서도 명시적 if/raise 검사가 실행됐다.

### AVIF 메타데이터와 비용

AVIF 전용 XMP 전달에서 Aux 필드를 보존한다. 후보 선택 가드는 문자열·배열·구조·한정자의 값을 재귀적으로 비교하고, 순서 있는 배열의 순서와 순서 없는 배열의 중복 수를 구분한다. 독립 R1이 찾은 한정자 namespace/이름 누락도 수정했으며, R2의 새 25개 검사가 통과했다. 비교는 ImageIO가 입력과 두 출력을 읽어 만든 병합 뷰에 한정된다. Exif가 다른 raw XMP 값을 가릴 수 있으므로 모든 reader가 보는 원시 메타데이터 동등성을 주장하지 않는다. EXIF 출력 크기 필드는 의도된 수정 때문에 제외한다.

정상 SwiftPM 후보 host의 이미지 161건에서 160개 성공·의도된 초과 ICC 거부 1개가 나왔고, 성공 출력 160개는 승인된 이전 결과와 바이트가 같았다. 새 Aux·중첩 XMP 표본은 관측한 태그를 보존하면서 4:4:4 출력의 입력 대비 공통 sRGB PSNR이 ImageIO 20.2179 dB에서 40.5528 dB로 개선됐다. 100,007자 EXIF 표본에서는 네이티브 후보를 버리고 ImageIO 파일을 바이트 그대로 유지했다. 컨테이너 구조도 독립적으로 검사했다. 이 네 변환은 성능 측정에 사용하지 않았다. 마지막 정상 Release를 새로 빌드한 뒤 같은 네 검사를 다시 실행했고 네 출력은 모두 앞선 승인 출력과 바이트까지 같았다. 앞선 AVIF 통합 소스와 최종 소스 사이에는 SVG 소스·테스트 세 파일만 달라 161개 이미지 매트릭스는 반복하지 않았다. `avif-host-metadata/final-run01/`은 마지막 실행 파일에 연결된 검증이다.

같은 최종 C 소스에서 스레드 수만 2/4/8로 달리한 helper를 새로 빌드해 444회 실행했다. 8.85/24/36.19 MP RGB/RGBA 입력, q60, 각 조건 3회다. 입력별 모든 비트스트림은 같고 보호 파일 해시는 유지됐다. 다음 수치는 12개 작업 묶음의 중앙 완료 시간이며 앱 전체 변환 시간은 아니다.

| 동시 작업 수 | 2스레드 (초) | 4스레드 (초) | 8스레드 (초) | 2→8 속도 비율 |
| --- | ---: | ---: | ---: | ---: |
| 1 | 21.1892 | 13.1907 | 9.1941 | 2.305× |
| 2 | 10.8820 | 6.8162 | 5.3811 | 2.022× |
| 4 | 6.8488 | 5.0008 | 4.6401 | 1.476× |
| 12 | 4.8891 | 4.4533 | 4.5429 | 1.076× |

최대 8스레드를 유지했다. 12개 동시 실행에서는 4스레드가 약 2% 빨라 보편적인 최적값이라고 말하지 않는다. CPU 사용 시간은 조건에 따라 약 5–22% 늘었다. helper의 기존 큰 이미지 피크 메모리 약 1.08 GB도 남으며, 2→8스레드 차이는 약 4.2–4.5 MB였다. 동시 프로세스별 최대 RSS를 합산한 값은 상한일 뿐 실제 시점별 전체 메모리가 아니다. 다른 사용자의 작업 부하는 조사하지 않았다. ImageIO 인코딩과 두 디코딩을 포함하는 전체 비용은 아래 최종 통합 후보 측정으로 구분한다.

### SVG와 라이브러리 선택

SVG textPath를 CoreText의 문자 묶음과 경로 기하로 배치한다. 닫힌 경로의 startOffset 이후 위치, 곡선에서 같은 문자 묶음이 함께 회전하도록 하는 처리, 제한된 기하 처리량과 cache, 양방향 선언, 숨겨진 문자의 공백·위치 목록·Unicode code point 처리를 보완했다. 마지막 소스 `a78d28c`의 독립 R3는 새 68개 검사를 통과했다. 집중 테스트는 64개(기존 Ghostscript skip 3개), 실패 0개이며, 마지막 수정의 44개 suite와 63개 보존 렌더링은 직전 수정본과 모두 바이트가 같다. 마지막 독립 검토는 자체 생성한 결과와 232개 승인 증거 사본을 포함한 481개 항목을 고정했다.

컴포넌트 실험에서 textPath 도입 전과 비교하면 보존 사례 63개 중 61개를 유지하고 두 사례가 개선됐다. C# 대비 textpath의 PSNR/SSIM은 15.94/0.0259→29.79/0.978, offset 사례는 23.00/0.136→33.69/0.956이다. 첫 사례는 PSNR 30dB 기준 미달로 여전히 FAIL이다. 같은 첫 사례의 resvg 대비 수치는 16.27/0.0279→27.64/0.9624로, C# 비교 수치와 혼용하지 않는다. 공식 suite의 잘못된 textPath 중간 공백 사례는 18.64→50.06 dB로 개선됐다. 반면 열린 경로 뒤의 텍스트가 경로 전체 끝에서 이어지는 SVG 2 규칙 때문에 `mixed-children-2`의 19.32→18.20 dB 저하는 그대로 남겼다.

최종 앱의 66개 출력과 검토된 윤곽선 입력 2개, 총 68개 변환을 별도로 확인했다. 기존 63개 중 달라진 것은 같은 textPath 두 사례이며 나머지 61개와 JP2/JPG/JXL 출력 gate는 화소가 같다. 두 윤곽선 대조군은 실제 앱 출력과 파일 바이트까지 같다. 하지만 컴포넌트에서 저장한 PNG의 수치를 그대로 앱 수치로 쓰면 안 된다. 실제 앱 PNG를 흰 배경에 합성해 C# 보존 파일과 비교하면 textpath **15.9402/0.025913→25.3557/0.938077**, offset **22.9972/0.135906→31.2188/0.921956**이다. 두 표본 모두 보충 검사의 PSNR/SSIM 결합 기준을 충족하지 못한다.

기존 raw 검사기의 앱 수치는 textpath 20.7114/1.0→30.1269/1.0, offset 22.1627/0.192854→30.3747/0.926906으로 별도 보존했다. 이 검사기는 premultiplied RGBA의 PSNR과 RGB 밝기의 SSIM을 계산하므로 투명한 검정 글자의 모양 차이가 알파에만 있으면 SSIM은 1이 될 수 있다. raw 점수나 판정은 변경하지 않았다. 흰 배경 보충 검사도 시각적 완전 동등성을 입증하지 않으며 `svg-final/`·`svg-final-white-readback/result.json`에 원래 값과 함께 남겼다.

표현할 수 없는 조합은 텍스트 전체를 기존 CoreSVG로 되돌린다. 특히 비-normal unicode-bidi는 라틴 문자만 있는 경우도 fallback하므로 기존 CoreSVG의 경로 텍스트 문제가 다시 나타날 수 있다. 이 선택은 잘못된 순서의 윤곽선을 생성하지 않는 제한이며 올바른 fallback 렌더링 보증이 아니다. 회전·RTL·세로 경로 텍스트, 상대/CSS 도형 기하와 복구 불가능한 문자 묶음도 남는다. method=stretch·spacing=auto·textLength는 미구현이며, 보이는 tspan 위치 목록의 기존 근사와 하위 writing-mode의 미확정 의미는 이번 수정 범위 밖이다. 2,097,152 단위의 기하 budget도 XML·UTF-8·CoreText shaping·모든 할당·취소 지연을 제한하지 않는다.

기존 C++ Skia를 현재 SVG 정규화와 연결한 별도 진단에서 13개 비텍스트 사례를 측정했다. 그라디언트는 resvg 대비 PSNR 24.51→49.95 dB, morphology는 18.64→55.76 dB로 개선했다. 반면 symbol 사용은 38.87→12.24 dB, 중첩/참조 SVG 이미지는 11.37→8.51 dB로 악화했고 일부가 비어 보였다. displacement도 낮은 점수에 머물렀다. 따라서 전체 SVG 경로를 Skia로 전환하지 않았다. 기능별 제한, 안전한 리소스 읽기와 참조 처리, 취소·전체 회귀 검증을 갖춘 경우에만 범위를 넓히는 편이 타당하다. 최초 raw SVG probe는 앱의 href 정규화를 생략했으므로 완전한 앱 경로의 결론으로 쓰지 않는다.

resvg 0.49의 C API를 오프라인 빌드했다. 이 구현은 Rust이며 C/C++에서 호출할 수 있다. 진단 실행 파일은 strip 후 약 3.95 MB였고 세 검사에서 CLI와 화소가 같았다. Apache-2.0 또는 MIT 라이선스이나 direction/unicode-bidi/glyph-orientation-vertical, 동기 렌더의 취소와 외부 리소스 제어를 해결해야 한다. librsvg는 문서의 textPath/세로쓰기 지원 범위와 Cairo/Pango/GLib 의존성 때문에 이번 대안으로 채택하지 않았다. 직접 빌드하지 않았으므로 성능 비교를 주장하지 않는다. LunaSVG/nanosvg의 공개 suite 점수나 측정하지 않은 ThorVG/PlutoSVG로 전체 동등성을 추정하지 않는다.

새 범용 C/C++ 변환기를 만드는 대신 기존 검증된 코덱과 CoreText의 부족한 경로 배치를 보완했다. libmobi는 독립 readback 도구로 유지하고 앱 의존성에 추가하지 않았다. loaded-document write 기능은 범용 전자책 변환기 전체와 다르며, upstream은 쓰기/직렬화 일부를 여전히 TODO로 표시한다.

주요 외부 근거: [Calibre 9.15 CSSFlattener](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/oeb/transforms/flatcss.py), [libmobi](https://github.com/bfabiszewski/libmobi/), [resvg 0.49](https://github.com/linebender/resvg/releases/tag/v0.49.0), [resvg 미지원 항목](https://github.com/linebender/resvg/blob/main/docs/unsupported.md), [SVG 2 text](https://www.w3.org/TR/SVG2/text.html).

### 최종 후보의 순차 성능 측정

모든 자식 작업과 빌드·다른 변환을 끝낸 뒤, 전용 HOME/TMP와 SDK 접근 차단 환경에서 최종 후보만 순차 실행했다. 다른 사용자의 시스템 부하는 조사하지 않았으며 M2 Max/macOS 27.0.1에서 관측한 값이다. 과거 실행 파일을 다시 실행하지 않았다.

| 입력 → 출력 | 최선 (초) | 중앙값 (초) |
| --- | ---: | ---: |
| big.pdf → TXT | 0.604878 | 0.630638 |
| big.epub → FB2 | 0.386488 | 0.390839 |
| big.docx → MD | 0.086408 | 0.093428 |
| big.docx → TXT | 0.077553 | 0.077914 |
| big.md → HTML | 0.598067 | 0.600031 |
| big.md → TXT | 0.536399 | 0.541843 |

Markdown TXT 0.60초·PDF TXT 0.84초 목표는 각각 5/5회 충족했고 최댓값은 0.566025초·0.698818초다. 30개 출력은 보존된 직전 결과와 같으며, FB2의 검증된 문서 UUID와 생성 날짜 두 필드만 비교에서 제외한다. 보호 파일 50개는 그대로이며 staging 잔여물이 없다. 근거는 `performance/summary.json`·`raw.json`·`performance-launch/`다.

AVIF는 같은 최종 host의 네이티브 후보 설정과 선택적 도구만 뺀 ImageIO 설정을 번갈아 3회씩 실행했다. 총 18건, q60이며 host 시작 시간을 제외한 변환 전체 시간이다. 아래 수치에는 최초 ImageIO 인코딩·네이티브 인코딩·후보의 두 디코딩이 포함된다.

| 입력 | ImageIO 중앙값 (초) | 후보 비교 포함 (초) | ImageIO → 후보 파일 크기 (bytes) |
| --- | ---: | ---: | ---: |
| aerial.heic | 0.280077 | 1.081242 | 385,089 → 396,284 |
| big.png | 0.410024 | 1.969556 | 502,828 → 726,806 |
| sonoma.heic | 0.284366 | 1.520232 | 64,034 → 76,353 |

설정별 세 반복은 바이트가 같았다. 입력 대비 공통 sRGB의 선택된 첫 이미지 색 SSE는 149,448,245→97,666,328, 5,026,032,863→446,462,108, 403,306,827→369,472,599이며 알파 오차는 모두 0이다. 전체 프레임 보존·다른 디코더·raw 메타데이터 동등성의 증거는 아니다. 개선된 색 오차에도 ImageIO 전용보다 시간·파일 크기가 증가한다. 별도 C helper의 2→8스레드 비율을 이 전체 비용의 속도 개선 비율로 대체하지 않는다. 이 마지막 측정에서는 메모리를 재측정하지 않았다. 근거는 `avif-cost-final/{summary,raw,integrity}.json`이다.

### 증거의 사용 범위와 절차 위반 기록

AVIF 구현 작업이 지시와 달리 과거 Swift host 7개 프로세스로 556개 변환, 과거 helper 431개를 실행했고 부하 진단 명령도 사용했다. 발견 즉시 중단했으며 해당 재실행 결과를 승인 근거에서 제외했다. C# 실행은 보고되지 않았다. 부모의 별도 해시 검사는 원래 런타임 14개·이전 849건 산출물 2,533개가 그대로임을 확인했다. 이후 성능 근거는 최종 C 소스에서 새로 빌드한 helper와 현재 후보만 사용했다. 상세 목록과 제외 범위는 `BASELINE-RUNS-NOT-PERMITTED.md`와 `incident-original-artifact-check.json`에 남겼다.

SVG 후속 작업은 원래 evidence manifest 30개 경로 중 보고서와 테스트 기록 3개를 덮어쓰거나 덧붙였다. 나머지 27개는 원래 경로에서 그대로다. 세 파일의 이전 바이트는 별도 보존본·prefix에서 SHA-256과 바이트 수가 정확히 일치하도록 회수했고 독립 R2도 확인했다. 원래 바이트에 다시 접근할 수 있다는 뜻이며 해당 세 경로가 불변이었다는 뜻은 아니다. 이후 수정·리뷰는 새 증거 디렉터리만 쓴다.

SVG R3에서도 지정한 마지막 검사 범위를 벗어난 컴포넌트 harness를 8회 빌드·실행했다(이전 1394 소스 4회, 현재 a78 소스 4회). 중단됐다는 초기 설명은 틀렸고, 명령이 끝난 시각과 각 실행 파일을 원래 로그로 확인했다. 같은 R3에서 생성한 임시 경로 11개도 삭제해 WIP 결과는 원본 산출물로 검증할 수 없다. 이 추가 실행과 WIP 수치는 모두 승인 근거에서 제외했다. 앞서 명시적으로 요청한 red 단위 테스트는 별도의 승인된 검사다. 이전 R1/R2 고정 증거에는 새 변경이 없으며, 마지막 독립 R3가 현재 소스로 새로 실행한 68개 검사와 별도로 고정한 기존 green·red·렌더링 결과로 판단했다. 부모의 `svg-r3-incident-verification.json`은 정정 보고서, 27개 파일 바인딩과 추가 실행 바이너리 해시를 확인한다.

기존 엄격 FAIL, 모든 형식의 화소·배치·원시 메타데이터 동등성, 물리 M1/macOS 15 및 외장 파일시스템/TCC/로그인/알림 실기, Developer ID 서명·공증은 이 기록만으로 해결됐다고 말하지 않는다.

## Conversion bug follow-up (2026-10-27)

이 절은 위 849건 결과 이후의 수정이다. 이전 실행 파일과 C#을 다시 실행하거나 과거 비교 점수·기준을 바꾸지 않았다. 근거는 새 `build/resume/bug-followup-20261027/`에 보존한다. 고정된 이전 실행 파일·보존 입력은 읽기만 하고, 새 Swift 소스에서 빌드한 후보와 명시적으로 선택한 현재 외부 도구만 실행했다. 전용 HOME/TMP와 .NET SDK 접근 차단을 사용하며 설치된 엔진·앱·전역 설정은 바꾸지 않았다.

### 고친 원인과 보존 범위

- **TS/M2TS 포스터:** 같은 1초 입력 두 개에서 입력 앞의 `-ss`가 성공 코드와 0바이트 결과를 냈다. 입력 뒤의 `-ss`는 기존 10% 시점의 PNG를 생성했고 첫 프레임과 바이트가 달랐다. 포스터가 비어 있을 때만 같은 시점까지 처음부터 디코딩해 한 번 재시도한다. 정상 결과·프로세스 실패·취소에는 재시도를 추가하지 않는다. 새 TS/M2TS 표본의 기대 프레임과 첫 프레임을 별도로 비교하고 성공·빈 결과·실패·반복된 빈 결과를 검사한다. `ts-probe/result.json`에 실제 입력·도구·출력 해시를 남겼다.
- **슬라이드 본문:** `PptxReader.shape`가 위치 정보가 없으면 텍스트를 읽기 전에 전체 도형을 버렸다. 위치가 없거나 크기가 0인 텍스트는 배경·그라디언트·테두리가 없는 슬라이드 크기의 상자에 담는다. 그림은 위치 정보가 아예 없을 때만 가로세로 비율을 유지해 담고, 명시적 0 크기는 기존 1×1 출력 처리를 유지한다. 정상 위치와 빈 장식은 기존 처리를 유지한다. 새 누락·0 크기 표본의 수정 전 검사는 실패했다. 실제 PPTM→FB2에서는 두 번째 문제가 드러났다. FB2 작성기가 텍스트 상자를 직렬화할 수 있는데도 문단의 가시성 판정이 상자 안을 확인하지 않아 빈 줄로 바꿨다. 기존 전체 문서 순회로 가시성을 판단하도록 수정했다. 레이아웃이 없는 슬라이드를 원본 화면과 동일하게 배치한다는 보장은 아니다.
- **그림→문서 경로:** PDF 텍스트 추출 간선에 의미를 표시해 다른 형식에서 만든 PDF의 중간 연결 단계로 선택하지 않는다. ODT·EPUB·FB2·HTMLZ·TXTZ처럼 그림을 담을 수 있는 출력은 PDF→DOCX를 거쳐 페이지를 담는다. TXTZ는 Markdown과 연결된 그림을 저장하므로 여기에 포함된다. 실제 경로는 150 dpi·품질 85의 JPEG로 페이지를 재렌더링하며 투명 배경을 흰색으로 채운다. 원래 이미지 바이트·투명도·벡터·선택 가능한 SVG 글자 보존이나 OCR을 뜻하지 않는다. 원본 PDF와 최종 TXT 요청의 경로는 유지했다. 원본 스캔 PDF의 대체 경로는 아래 남은 작업에 속한다.
- **PML:** Calibre가 실제로 생성하는 `pmlz`에서 `index.pml`과 PNG를 검증해 꺼내고 `<출력 이름>_img`와 함께 게시한다. 입력의 참조된 PNG와 본문에서 참조하지 않은 규약상 `cover.png` 표지를 격리 작업 폴더로 복사한다. 모든 본문 참조 파일이 있는 동반 폴더를 선택하고, 파일명은 ASCII 영문·숫자·`_`·`-`·`.` 조합과 소문자 `.png` 확장자로 제한하며 선행 점은 허용하지 않는다. 숨김 파일이나 URI·HTML 특수 문자가 Calibre에서 조용히 누락되는 것을 피하기 위한 명시적 입력 제한이다. 실제 파일 이름의 대소문자 해석은 입력 파일시스템을 따르며, 복사된 이름은 참조와 일치시켜 Calibre의 대문자 확장자 누락을 막는다. 경로 이탈·중복 이름·심볼릭 링크·누락 파일을 거부한다. 지원하지 않는 문자는 `?`로 바꾸기 전에 명시적으로 실패하며 `Â` 삭제와 Unicode 이스케이프 대소문자 불일치를 보완했다. 한글 PML 지원이 추가된 것은 아니다. 실제 Calibre 9.15 입력 코드는 `<이름>_img`와 `images` 모두 지원한다. 이미지 누락의 추가 원인은 테스트 작업 경로의 대괄호를 glob 패턴으로 해석하는 것이었으며, PML 자식 프로세스에서 그 디렉터리만 이스케이프한다.
- **FFmpeg 안내:** 실제 앱 3개 언어와 host 4개 언어의 안내를 `brew install ffmpeg-full`과 `brew --prefix ffmpeg-full` 아래 `bin` 폴더 선택으로 바꿨다. 호출되지 않던 중복 안내 함수는 제거했다. 자동 검색·코덱 사전 검사·관리형 FFmpeg 설치를 구현한 것은 아니며 사용자의 현재 설치본을 변경하지 않았다.

PML 원문과 구현 근거는 [공식 PML 문자 범위](https://github.com/kovidgoyal/calibre/blob/v9.15.0/format_docs/pdb/pml.txt), [Calibre PML 출력](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/conversion/plugins/pml_output.py), [PML 입력의 그림 탐색](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/conversion/plugins/pml_input.py), [규약상 표지 탐색](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/metadata/pml.py), [본문 이미지의 HTML 직렬화](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/pml/pmlconverter.py)이다. 독립 검토에서 처음 제시한 “standalone PML은 images 폴더만 읽는다”는 가설은 공식 코드와 새 `pml-diagnosis01` 실행으로 배제했다. 해당 진단은 현재 변환 스크립트를 새로 만들고 선택한 Calibre를 직접 호출했으며, 대괄호가 없는 경로에서는 본문의 120×80 그림이 실제 EPUB 리소스에 남았다.

### 검토와 검사에서 발견한 문제

`claude-dev-max`의 독립 R1은 슬라이드 본문 누락을 확인했고, R2는 PML 테스트가 생성 표지만 보고 통과할 수 있다는 점과 실제 FFmpeg 안내 위치, 원본 스캔 PDF 경계, 실제 페이지 재렌더링 경로의 검사 누락을 지적했다. PML 검사는 모든 본문 `img` 참조가 ZIP 항목으로 연결되는지, 읽은 그림 파일이 실제로 있는지와 기대 크기를 확인하도록 강화했다. 별도의 손으로 만든 PML·`fig1.png`·대괄호 작업 경로도 추가했다. 그림 문서 검사는 기존 inline PNG 바이트 보존 검사와 실제 PDF→DOCX의 floating JPEG 검사로 구분한다.

첫 PML 왕복 검사는 그리스 문자 `α`의 Unicode 이스케이프 대소문자 불일치를 발견했다. 첫 통합 검사 108개는 기존 취소 테스트의 시작 순서 경합 때문에 한 번 실패했다. 테스트가 취소 신호를 받은 뒤 판독기를 호출하도록 고쳐 그 조건을 명시했다. 이후 `swift-full`은 엔진 762개(14개 skip)와 Core 18개가 실패 없이 끝났다. 이 실행은 마지막 PML 경로·FB2 가시성 수정 전이며, 마지막 수정의 집중 검사와 구분한다. 과거 성공 기록으로 새 수정을 통과 처리하지 않는다.

새 정상 Release `candidate01`의 실제 재검사 `targeted01`은 TS 3개와 PPSX→AZW3 본문을 확인한 뒤 검사기가 과거 null preset을 처리하지 못해 중단됐다. preset이 없으면 보존된 targetFormat을 쓰도록 검사기만 고쳤다. `targeted02`는 PPTM→DOCX·EPUB 본문까지 확인했으나 FB2의 빈 본문을 검출해 중단됐다. 두 시도의 출력과 무결성 기록을 남겼고 실패 검사를 면제하지 않았다. 확장한 슬라이드 단위 검사 `slides-fb2-red`도 같은 FB2 누락 두 개를 확인했다.

프로세스 트리 종료 검사는 전체 프로세스 목록을 조회하는 대신 자신이 생성한 자식·손자·sleep PID만 기록하고 종료를 확인하도록 바꿨다. `slides-fb2-red`의 해당 검사는 SDK 차단 환경에서 통과했으며 전역 프로세스 조회나 격리 해제 없이 검사할 수 있다. R1 검토가 지정한 읽기 범위를 넘어 TS/PES 바이트를 분석한 내용은 판단 근거에서 제외했다. 해당 검토는 실행 파일을 돌리거나 소스를 수정하지 않았다고 보고했으며, 실제 TS 수정 근거는 부모의 새 통제 실행이다.

R2 반영 후 집중 검사 `review2-green`은 58개 모두 통과했다. 그 직전 `review2-focused`의 한 실패는 PML용 120×80 이미지 단언을 기존 MOBI 테스트에 잘못 넣은 검사 수정 실수였고, 올바른 PML 검사로 옮긴 뒤 다시 확인했다. R3 경계 조건 수정 전 전체 `swift-final`은 **엔진 765개(14개 skip)·Core 18개, 실패 0개**이며, 이번에는 프로세스 트리 종료 검사도 같은 SDK 차단 환경에 포함됐다. 257.79초는 빌드·테스트 전체 소요 시간이며 변환 성능 측정값이 아니다. 두 검사 모두 소스와 보존된 이전 실행 파일 해시가 유지됐다. 실제 표시 문자열 7개의 JSON/strings 구문과 FFmpeg 설치·경로 안내도 확인했다.

R3은 PML의 대문자 PNG 확장자가 Calibre에서 누락되는 문제와 위치 없는 텍스트의 배경이 기존 그림을 가릴 수 있는 문제를 지적했다. 입력 이름 제한과 fallback 텍스트의 배경 제거를 반영했으며 정상 위치의 스타일은 유지한다. R4의 숨김 그림·본문에서 참조하지 않은 표지·URI 및 HTML 특수 문자 검토를 반영해 파일명 계약과 표지 복사를 보완했다. 사용하지 않는 일반 `images` 폴더의 심볼릭 링크가 유효한 `<이름>_img` 입력까지 막지 않도록 필요한 폴더만 검증한다.

R3 반영 후 `review3-focused`는 60개, 전체 `swift-final2`는 **엔진 767개(14개 skip)·Core 18개, 실패 0개**였다. 전체 실행 253.84초는 빌드·검사 시간이다. 이 전체 검사는 마지막 PML 파일명·표지·불필요한 폴더 검사 수정 전이므로, 마지막 PML 집중 검사와 별도로 기록한다.

`pml-final2`는 Calibre·문서·경로 계획·프로세스 종료·전자책 검사 **61개, skip 0개·실패 0개**로 끝났다. 소스 해시로 전체 검사 이후 이 집중 검사까지 바뀐 파일이 `CalibreConverter.swift`와 `CalibreEbookTests.swift`뿐임을 확인했다. 검사는 `<이름>_img`와 `images` 각각의 본문 밖 표지 보존, 대괄호 작업 경로, 잘못된 이름 거부, 사용하지 않는 일반 이미지 폴더가 유효한 입력을 막지 않는 조건을 포함한다. 279.28초는 빌드를 포함한 시간이며 모든 실행에서 소스와 보존된 이전 실행 파일 해시가 유지됐다.

R5는 마지막 제품 코드의 새 회귀를 찾지 않았지만 누락 그림 검사가 다른 오류로 통과할 수 있음을 지적했다. 앞의 정상 사례에서 만든 사용하지 않는 `images` 심볼릭 링크가 남아 있어, 누락 그림 대신 폴더 링크 오류가 발생했기 때문이다. 해당 링크를 제거한 뒤 누락·링크 그림 두 경우 모두 `every referenced PNG` 오류를 확인하도록 검사만 수정했다. 수정한 검사 1개는 `pml-negative-final`에서 통과했고 소스·이전 실행 파일 해시는 유지됐다. R5의 빌드 시점 우려에 대해서는 `pml-final2`가 마지막 제품 코드 수정 이후 시작됐고 실행 중 소스가 유지됐음을 해시로 확인했다. R1–R5는 모두 `claudeAgent` / `claude-opus-5-5` / `effort=max`의 독립 작업으로 실행했다.

### 최종 실행 파일과 실제 출력 확인

현재 소스로 정상 Release `candidate04`를 만들었다. 실행 파일 SHA-256은 `0fa25c462485a580662506727b50a85fb8613123f31a7b285e1e8dddcc200e6c`이며 `capture.json`에 모든 Sources/Tests 해시·소스 diff·리소스 번들 해시를 함께 보존했다. 정상 빌드는 177.94초, 종료 코드 0이며 소스는 유지됐다. `candidate02`·`candidate03`은 빌드만 보존했고 변환에 실행하지 않았다. 마지막 제품 코드 이후 테스트만 보강했으므로 `candidate03`과 `candidate04`의 실행 파일 해시는 같다.

`candidate04`의 첫 실제 재검사 `targeted03`은 TS 3개·슬라이드 5개·그림 문서 7개를 확인한 뒤 TXTZ의 `![](<images/img0001.jpg>)`를 검사기가 처리하지 못해 중단됐다. ZIP에는 해당 파일이 실제로 있었고 변환 상태도 완료였다. Markdown의 꺾쇠 주소를 처리하도록 검사기만 고쳤으며 이 중단 기록과 원래 사용한 검사 스크립트도 보존했다. 제품 코드는 바꾸지 않았다.

새 `targeted04`는 보존 입력 32개를 끝까지 실행했다. **20개 완료·12개 실패이며, 기존 실패 중 16개가 완료로 바뀌고 기존 완료 슬라이드 4개의 빈 본문이 복구됐다.** 다음 범위의 본문·실제 이미지 참조·그림 디코딩까지 확인했다.

| 대상 | 실제 결과 | 확인한 내용 |
| --- | --- | --- |
| TS/M2TS→WebP·TIFF 3개 | 완료 3 | 출력 스트림과 크기 확인. 같은 10% 시점의 기대 프레임은 별도 실제 TS/M2TS 회귀 검사로 확인 |
| PPSX·PPTM·PPTX 문서/전자책 5개 | 완료 5 | `FileToX sample 안녕하세요` 본문 확인. AZW3·LIT는 TXT로 다시 읽어 확인 |
| AVIF·HEIC·WebP·PSD·SVG·JXL·TGA·PNG→그림을 담는 문서 11개 | 완료 11 | 출력 패키지의 실제 이미지 참조가 존재하고, 선택한 FFmpeg로 디코딩한 페이지가 비어 있지 않음을 확인 |
| 텍스트 없는 페이지의 TXT 6개 | 실패 6 | OCR을 구현한 것으로 처리하지 않고 `contains no text` 오류 확인 |
| PML 7개 | 완료 1·실패 6 | PDB 1개는 PML·EPUB readback 확인. 나머지 6개는 `PML cannot represent U+...` 오류 확인 |

`pml-publication01`은 대괄호가 있는 같은 HTML을 두 번 PML로 저장하고 `<이름>_img` 및 `<이름> (2)_img`가 각각 생성되는지, 먼저 만든 결과가 유지되는지 확인했다. 두 결과를 EPUB으로 다시 읽어 본문 텍스트와 참조된 PNG를 디코딩했다. 별도의 누락 그림 입력은 출력 없이 명시적으로 실패했다. PDB 입력→TXT와 PDB→PML→TXT도 공백을 정규화한 본문이 같았다. 보존된 PDB 원문에는 이미 물음표 7개가 있으므로 이 완료를 한글 복구로 보지 않는다.

추가 `pml-picture01`은 본문이 있는 HTML 안의 120×80 PNG까지 찾았지만 **원본 RGBA 픽셀 동일성 단언은 실패했다.** 실패 시도와 스크립트를 그대로 보존했다. `pml-pixel-diagnosis01`에서 크기 120×80·알파는 같고, RGB RMSE **13.3977/255**, 최대 성분 차이 **46/255**임을 측정했다. 원본의 단색이 네 가지 색의 점무늬로 바뀌었다. [Calibre 9.15 PML 출력 코드](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/conversion/plugins/pml_output.py#L59-L77)는 기본 `full_image_depth=false`에서 팔레트 변환과 300×300 thumbnail을 적용한다. 이 기본값은 오래된 읽기/제작 프로그램 호환을 위한 것이며, 고해상도·색 깊이 보존 정책은 아직 바꾸지 않았다. PML 그림의 연결·본문 포함을 복구했다는 결과를 픽셀 무손실로 확대하지 않으며, 이 추가 실패를 통과로 면제하지 않는다.

두 실제 실행에서 새 소스·현재 실행 파일·이전 고정 실행 파일 14개·선택한 보존 입력·명시적으로 선택한 외부 도구 실행 파일 6개의 해시가 유지됐다. 검사한 작업 폴더에 `.filee-out-*` 잔여물이 없었다. 외부 도구의 모든 전이 동적 라이브러리까지 새로 고정했다는 의미는 아니다. `final-checks.json`은 테스트 소스와 정상 Release의 연결, 실제 실행 결과, 과거 보고서 접두부 보존, 문서 링크와 `git diff --check`를 함께 확인한다.

### 남은 작업

FFmpeg의 재배치 가능한 고정 arm64 관리형 패키지와 인코더·muxer 사전 검사가 남는다. 단순 설치 안내 수정으로 기존 코덱 실패 21개를 해결했다고 세지 않는다. 텍스트 없는 원본 PDF에서 rich 문서로 가는 경로는 여전히 텍스트 추출을 우선할 수 있어, 내용 확인 뒤 한 번 재계획하는 동작과 취소·게시 보장이 필요하다. TXT 출력의 OCR, SVG의 실제 텍스트 보존과 새 raster/PDF 엔진 비교, AVIF 후보 생성 비용과 선택 이유 표시도 별도 작업이다. PML의 제한된 문자 범위와 기본 그림 축소·팔레트 처리, 슬라이드 표·전체 배치, 모든 입력의 읽기 순서·서식·이미지 보존까지 해결한 것은 아니다.

기존 849건 전체·엄격 FAIL 48개·AVIF/SVG 점수·성능 수치는 다시 계산하지 않았다. 이번 일부 재검사 결과를 빼서 전체 실패 수를 추정하지 않는다. Xcode 앱·서명·재배치 배포 검사도 이번 소스로 다시 실행하지 않았다. 물리 M1/macOS 15·외장 파일시스템·TCC·로그인/알림·공증은 계속 보류한다.

## Media codecs and original scanned PDF fallback (2026-10-27)

이 절은 위 회차 다음의 `claude-dev-max` 공동 작업이다. 실행 기록은 `build/resume/media-pdf-20261027/`에 분리한다. 앞선 보고서와 실행 파일·입력·출력은 읽기 전용으로 보존하며, 이전 C# 또는 Swift 실행 파일·검사기를 다시 실행하지 않는다. 새 소스의 검사와 변환은 각각 전용 HOME/TMP와 명시한 최소 환경, .NET SDK 경로를 차단하는 단일 sandbox에서 실행한다. 물리 환경·배포 검증 5번은 계속 보류한다.

### FFmpeg 기능 검사

선택된 FFmpeg의 `-encoders`와 `-muxers`를 읽고, 실제 변환 명령이 사용하는 인코더와 출력 컨테이너를 비교한다. [FFmpeg 공식 문서](https://ffmpeg.org/ffmpeg-all.html)는 이 목록을 빌드에 포함된 기능으로 정의한다. 실행 파일의 실제 경로·수정 시각·크기·inode로 성공한 조회만 캐시하며 오류·취소는 캐시하지 않는다. 사용자 지정 FFmpeg를 다른 설치로 몰래 바꾸거나, 일부 코덱이 빠졌다는 이유로 정상 동작하는 모든 형식을 비활성화하지 않는다.

검사는 출력 파일을 지우는 인코딩 오류 처리보다 먼저 실행한다. 실제 계획의 `-c:v`·`-c:a`와 `-f`만 비교하므로 오디오 없는 영상이나 오디오 제거 옵션에 불필요한 오디오 인코더를 요구하지 않는다. GIF 세 단계의 기존 기본 인코더인 `png`·`wrapped_avframe`·`gif`도 명시했다. CoverArt는 기존의 선택적 처리를 유지한다.

`system-ffmpeg-capabilities/`는 명시적으로 선택한 Homebrew FFmpeg 9.0.2의 버전·인코더·muxer 목록이다. `libopencore_amrnb`·`libvorbis`·`libtheora`가 없다. 새 정상 Release `candidate01`의 실행 파일 SHA-256은 `b0a693a9204e2325c6442ee67aa5664369c0a43b95d6a2d94ae0ecbeb724e52b`이다. `preflight01`은 이 제한된 설치로 AMR·OGG·OGV 세 건이 정확한 누락 인코더와 엔진 설정 안내로 실패하고, 덮어쓰기 대상으로 준비한 기존 파일의 바이트가 유지되는지 확인했다. 세 실패는 기대한 음성 검사 결과이며 **기존 코덱 실패 21건의 복구로 세지 않는다.**

기존 실패 중 출력 형식이 AMR·OGG·OGV인 것은 22건이지만, `auto-103-jp2-to-ogg`는 오디오 없는 입력이므로 제외한다. `Encoder not found`로 실패한 21건만 앱 필수 코덱을 포함한 FFmpeg의 재검증 대상으로 삼는다. 네이티브 arm64 배포본 조사에서는 일곱 필수 외부 인코더를 모두 포함한 고정 ZIP을 찾지 못했다. 고정 소스의 로컬 빌드와 실제 변환으로 검증했으며, 존재하지 않는 공개 다운로드 URL이나 관리형 설치 지원은 추가하지 않았다.

### 원본 PDF의 페이지 이미지 대체 경로

원본 PDF는 기존처럼 텍스트 추출을 먼저 시도한다. 정상적으로 읽은 페이지에 텍스트가 전혀 없을 때만 형식이 지정된 `NoTextError`를 사용해 PDF→DOCX→EPUB·FB2·HTMLZ·TXTZ·ODT 경로로 한 번 재계획한다. 최종 출력 할당 전만 허용하고, 두 번째 계획은 텍스트 추출 경로를 제외한다. 텍스트가 있는 PDF와 보이지 않는 OCR 텍스트 레이어는 기존 텍스트 경로를 유지한다. TXT와 이번 대체 경로에 포함하지 않은 Calibre 형식은 기존 오류를 유지하며 OCR을 구현한 것으로 취급하지 않는다.

`focused01`은 JobQueue 8개·Media 35개·PdfReader 16개·RoutePlanner 7개, 총 **66개·실패 0개**였다. 원본 스캔 PDF의 EPUB 그림, OCR 레이어 텍스트, TXT 실패, 취소, 선택된 FFmpeg 교체에 따른 캐시 갱신과 기존 출력 보존을 포함한다. 이때 사용한 제한된 FFmpeg 때문에 일부 미디어 형식은 개별 테스트 내부에서 건너뛰었으므로, 이 결과만으로 앱 필수 코덱을 모두 확인했다고 보지 않는다.

`pdf01`은 보존된 텍스트 없는 2쪽 PDF를 다섯 rich 형식으로 변환했다. 각 결과에서 두 페이지 이미지의 실제 참조와 디코딩, 비어 있지 않은 픽셀을 확인했다. TXT·MOBI는 `contains no text`로 실패했고, 텍스트 있는 PDF→EPUB은 한글과 `café, 12345.`를 유지했다. 주요 8건은 **완료 6·기대한 실패 2**이다. EPUB의 두 번째 저장은 다른 이름으로 게시하고 첫 결과를 유지했으며, `skip`은 기존 결과를 유지한 채 새 출력 없이 끝났다. 총 10개 작업에서 원본·이전 실행 파일·선택한 도구·현재 소스 해시가 유지되고 staging 잔여물이 없었다.

독립 검토 R1은 FFmpeg 기능 검사·GIF 기본 인코더 명시에 수정할 문제를 찾지 않았다. PDF에서는 읽은 페이지가 하나도 없을 때도 이미지 대체 경로가 빈 전자책을 완료로 처리할 수 있음을 지적했다. 읽은 문서의 section이 비어 있으면 일반 변환 오류를 유지하도록 수정하고, 대체 경로 자체가 없는 경우도 회귀 검사에 포함했다. `pdf-guard02`의 최초 검사는 0쪽 PDF가 열릴 것으로 가정해 두 단언이 실패했으나, 이 환경의 PDFKit은 그 입력 자체를 읽지 못했다. 가정을 제거하고 변환 실패와 출력 없음이라는 관찰 결과를 검사한 `pdf-guard03`은 JobQueue 8개·PdfReader 17개, 총 **25개·실패 0개**였다. 읽기 불가능한 빈 입력 거부는 확인했지만, 열린 문서의 section이 비는 분기 자체를 macOS 27에서 재현했다는 뜻은 아니다. 중단된 `pdf-guard01`과 실패한 `pdf-guard02`도 보존한다.

### 필수 코덱 빌드와 최종 실제 검증

`Tools/build-ffmpeg.py`는 FFmpeg 9.0.2와 외부 라이브러리 9개의 공식 소스 아카이브를 SHA-256으로 고정한다. 기존 시스템·Homebrew·엔진 설치 폴더를 바꾸지 않고 반드시 새 폴더에 빌드한다. 네이티브 arm64·최소 macOS 15를 대상으로 하며, 외부 코덱은 정적으로 연결하고 macOS 시스템 라이브러리만 동적으로 사용한다. 실행 파일 두 개·라이선스 고지·출처 기록과 별도의 원본 소스 ZIP을 만든다. GPLv3 구성이고 `--enable-nonfree`를 사용하지 않는다. 비트 단위 재현성이나 공증된 배포본이라는 뜻은 아니다.

독립 검토 R2는 첫 빌드의 iconv 링크 실패와 AV1 소프트웨어 디코더 누락을 찾았다. 실패한 `ffmpeg-build01`은 그대로 보존했다. 기존 문자 처리 동작을 유지하도록 시스템 `-liconv`를 명시하고, libaom 3.14.1의 디코더를 추가했다. AV1 지원을 잃는 교체본으로 끝내지 않고 디코더 목록 검사와 실제 AV1 MKV→MP4 검사를 추가했다. 이미 있던 CMake 3.31.6 실행 파일을 읽기 전용으로 사용했으며, 새 빌드에서만 소스를 컴파일했다. R2의 작은 수정은 부모가 반영했으며 별도 세 번째 검토를 요청하지 않았다.

`ffmpeg-build02`의 self-test와 빌드가 모두 성공했다. `lipo`는 두 실행 파일 모두 arm64, `vtool`은 최소 macOS 15.0을 보고했고, `otool`에는 `/usr/lib`·`/System/Library` 의존성만 있다. 앱의 명시적 인코더·muxer 집합과 `libaom-av1` 디코더가 모두 존재한다. `package-verification.json`은 ZIP 안 실행 파일의 SHA-256·0755 모드, 소스 10개와 실제 사용한 레시피의 해시도 확인한다.

- 실행 파일 ZIP: `ffmpeg-build02/work/ffmpeg-9.0.2-osx-arm64.zip`, **27,745,929 bytes**, SHA-256 `86e5ed4541ea6c0c5503843f10451d18f5d8e15c003efc031f034856a0ebdcb6`
- 소스 ZIP: `ffmpeg-build02/work/ffmpeg-9.0.2-sources.zip`, **41,357,950 bytes**, SHA-256 `b8c4d472833a80a4c772b6b95bbf08fa2d412e82b8460196c48b99049fd8dee0`
- 사용할 폴더: `ffmpeg-build02/work/ffmpeg`를 기존 **외부 엔진 실행 파일** 설정에서 선택한다. 로컬 산출물이며 기본 번들·사용자 설정·공개 관리형 다운로드는 바꾸지 않았다.

PDF 보강까지 반영한 정상 Release `candidate02`는 **180.03초**에 빌드됐고, 실행 파일 SHA-256은 `8fe8922c1d7d99ac7e39cbe6c2a9821711168ae042b81745e901f65b0125e05c`이다. 이 소스와 `pdf-guard03`의 컴파일 소스가 같음을 확인한 `media-full01`은 새 FFmpeg로 **35개·실패 0개·skip 0개**였다. 내부 인코더 부족에 따른 형식 생략 로그도 없었다. PDF 보강 전의 `regression01`은 엔진 **772개(15 skip)·Core 18개, 실패 0개**였으며, 이 전체 결과와 최종 보강 후의 관련 테스트 60개를 구분한다.

최종 `full01`은 다음 **30건**을 실행했고 **28개 완료·기대한 실패 2개**였다. EPUB 중복 이름·skip의 별도 작업 두 개까지 합하면 **32개 작업**이다.

| 대상 | 결과 | 실제 확인 |
| --- | --- | --- |
| 이전 인코더 부족 21건 | **21개 모두 완료** | AMR의 `amr_nb`, OGG의 `vorbis`, OGV의 `theora` 스트림과 전체 디코딩 |
| AV1 MKV→MP4 | 완료 1 | 보존 AVIF의 AV1 스트림을 재인코딩 없이 MKV로 옮겨 입력 코덱을 확인하고, 현재 host의 기본 디코더 선택으로 변환 후 전체 디코딩 |
| 스캔 PDF→EPUB·FB2·HTMLZ·TXTZ·ODT | 완료 5 | 각각 원본 2쪽의 실제 이미지 참조·디코딩·비어 있지 않은 픽셀 |
| 스캔 PDF→TXT·MOBI | 기대한 실패 2 | `contains no text`, 출력 없음 |
| 텍스트 PDF→EPUB | 완료 1 | `FileToX sample`, 한글 본문, `café, 12345.` 유지 |

별도 `preflight02`는 제한된 시스템 FFmpeg로 세 형식의 정확한 누락 기능 오류와 기존 출력 바이트 보존을 최종 소스에서도 재확인했다. `full01`·`preflight02`의 원본 입력·과거 실행 파일·선택한 외부 도구·현재 실행 파일·소스 해시가 모두 유지됐고, 검사한 작업 폴더에 staging 잔여물이 없다. 선택한 외부 도구의 모든 전이 동적 라이브러리까지 새로 고정한 것은 아니다.

### 이 회차의 검증 한계

텍스트 페이지와 스캔 페이지가 섞인 PDF는 여전히 텍스트 경로를 사용한다. 페이지가 읽히지만 흰색이거나 내용이 손상된 PDF와 정상적인 빈 페이지를 판별하는 검사는 추가하지 않는다. 페이지 이미지는 검색 가능한 OCR 텍스트나 원본 픽셀·색상·투명도 보존을 뜻하지 않는다. 기존 849건 전체와 엄격 FAIL 48개를 다시 실행한 결과도 아니다. 일부 변환의 성공을 전체 849건 또는 엄격 FAIL 수치에서 빼서 새 전체 결과로 추정하지 않는다.

새 FFmpeg는 앱 필수 인코더와 이번에 확인한 입력을 위한 빌드이며 모든 FFmpeg 플러그인·입력 코덱을 포함한 범용 배포본이라고 주장하지 않는다. 공개 URL·관리형 설치·기본 앱 번들 반영, 새 Xcode 앱의 서명·재배치·UI 전체 흐름은 이번 회차에서 수행하지 않았다. 물리 M1/macOS 15·외장 파일시스템·TCC·로그인/알림·공증 등 보류한 5번 검증도 그대로 남긴다.


<a id="remaining-work-final-verification-2026-10-28"></a>
## 남은 작업 보완과 전체 재검증 — 2026-10-28

이 절은 2026-10-27~28의 혼합 PDF·앱 FFmpeg 번들·PML·슬라이드·SVG·AVIF 후속 작업을 기록한다. 위의 과거 기록은 당시 바이트 그대로 유지했다. 자료는 `build/resume/remaining-20261027/` 아래에 보존한다. 사용자의 조기 재개 요청에 따라 오전 9시 예약은 비활성화했다.

실행은 최소 환경·전용 HOME/TMP·`build/isolated.sb`의 SDK 접근 차단 한 겹을 사용했다. 현재 소스에서 host·AVIF helper·검사 판독기를 새로 빌드했으며, 과거 C#/Swift 실행 파일은 실행하지 않았다. C# 기준선과 이전 Swift 산출물은 읽기 전용 비교 자료다. 원본 입력·이전 결과·명시적으로 선택한 외부 도구·현재 소스의 해시를 검사 전후 확인했다. 비교 판독기의 내부 sandbox에는 바깥 sandbox를 겹치지 않았다. 사용자 프로필·키체인·설치 앱과 시스템 엔진은 변경하지 않았다.

### 구현한 동작

- **혼합 PDF:** 원본 PDF의 EPUB·FB2·HTMLZ·TXTZ·ODT 경로에서 텍스트·스캔 페이지·기존 OCR 텍스트 층·그림을 페이지 순서대로 보존한다. 내용이 있는 이미지나 렌더링이 필요한 페이지를 발견하면 최종 출력 할당 전에 한 번 재계획한다. 텍스트만 있는 PDF와 실제 빈 페이지는 텍스트 경로를 유지한다. 읽은 페이지가 없는 오류는 일반 실패로 남기고 TXT 요청은 추출 가능한 글자만 담는다. 새 OCR은 수행하지 않는다.
- **FFmpeg와 앱:** 고정 소스 arm64 FFmpeg를 기본 앱에 포함한다. 선택한 사용자 사본이 우선한다. 필요한 인코더·muxer를 실행 전에 확인하고 부족한 이름을 오류에 담는다. staging은 `FILETOX_FFMPEG_BUNDLE` 또는 기본 `build/ffmpeg/ffmpeg`의 선언된 버전·플랫폼·고정 소스 목록, 번들 자체 출처 기록의 실행 파일 해시, 고지의 존재를 확인한다. 소스 ZIP·레시피 해시 검증과 번들 출처 인증은 하지 않는다. 관리형 FFmpeg 다운로드는 아직 제공하지 않는다.
- **PML:** BMP 문자를 Unicode escape로 보존하고 비 BMP 문자는 출력 전에 명시적으로 거부한다. Calibre의 PMLZ에서 검증한 PNG를 동반 폴더와 함께 게시한다. 대괄호를 포함한 작업 경로를 처리하고 이미지 축소·색상 수 감소를 끈다.
- **슬라이드·문서:** 위치·grid 정보가 빠진 텍스트·그림·표, 그룹 확대율과 병합 셀의 열 위치를 보완한다. FB2 텍스트 상자를 보존하고 생성 PDF의 텍스트 추출을 그림 문서의 중간 연결로 사용하지 않는다.
- **SVG:** 제한된 가로 글자에만 검색·선택 가능한 PDF 텍스트를 더한다. 원래 윤곽선의 픽셀은 유지한다. 부모 검토에서 중첩 숨김·clip/mask·잘린 글자·퇴화 변환·알 수 없는 색의 조건을 좁혔다. 복잡한 재배열·세로쓰기·textPath·emoji 등은 기존 윤곽선을 유지하며, rich 문서의 편집 가능한 SVG 텍스트 복원을 주장하지 않는다.
- **AVIF:** ImageIO 결과의 색·알파 표본 오차가 모두 0이면 추가 인코딩을 생략한다. 기존 후보 품질·메타데이터 검사를 유지한다.

### 첫 전체 실행과 새 차이 조사

`candidate01`은 정상 Release 전체 제품 빌드이며 host SHA-256은 `412ff99e50a34b566e09641af7bea35d538f85ed4a383503a2b822fbe6b1780f`이다. `regression-final01`과 별도로 새 컴파일한 `regression-fresh01`에서 각각 엔진 **782개(15 skip)·Core 18개, 실패 0개**를 확인했다. 후자의 빌드·검사 합계는 514.42초다. 생략한 검사는 외부 corpus·도구가 필요하며 개별 이유는 로그에 남겼다.

`app-final01`은 새 Debug 앱과 테스트 번들 빌드를 완료했다. Xcode의 testmanager 연결에 실패한 이전 시도는 반복하지 않았다. `app-model-final01`은 새로 컴파일한 실제 AppModel을 이 앱의 번들 host와 연결해 파일 선택·옵션 저장·AMR 변환·취소·OGG 재시도·이력·원본 보존을 확인했다. 출력 오디오 스트림은 `amr_nb`와 `vorbis`다. 실제 마우스·드래그·대화상자 조작과 동일한 검사는 아니다. 앱 Mach-O 15개는 arm64, ad-hoc deep/strict 서명 검증 성공, Homebrew 동적 링크·.NET 실행 구성요소 없음, FFmpeg 출처·고지 파일은 40개였다.

`host-rich02`는 혼합 PDF·기존 OCR·빈 페이지·SVG의 실제 host 변환 **19건**을 완료하고 출력 텍스트·읽기 순서·이미지 참조·디코딩·숨긴 SVG 글자 제외를 확인했다. 첫 `host-rich01`은 검사 도구가 정상 FB2 Base64 줄바꿈을 거부해 멈췄다. 제품 코드는 바꾸지 않고 판독기를 수정한 뒤 새 폴더에서 재실행했으며 첫 증거도 보존했다.

`full849-01`은 보존된 849개 cases를 그대로 실행해 **829 completed / 20 failed**, harness·inspection 오류 0, 기존 성공의 새 실패 0을 기록했다. 이전 786개 성공은 모두 유지되고 43개 실패가 성공으로 바뀌었다. 남은 20개는 오디오 트랙 없음 14개·추출 텍스트 없음 6개다. 실행 시간은 192.66초다.

`strict01/report/report.json`의 엄격 C# 비교는 **485 PASS / 265 WARN / 99 FAIL**이다. 이전 `quality-next-20261026/replay-validation/compare-complete-csharp/report.json`의 **598 / 203 / 48**과 thresholds·inspectionPolicy가 정확히 같고 면제는 없다. 99 FAIL은 C#에서 실패했으나 현재 성공하는 상태 불일치 43개, 기존 품질 FAIL 48개, 새 출력 차이 8개로 나뉜다. 변환 완료와 엄격 동일성 판정은 별개다.

`new-differences01~03`은 새 차이 8개를 원본과 대조했다. PPTM→DOCM·DOCX·DOTM·DOTX·EPUB 5개는 원본의 `FileToX sample 안녕하세요`가 현재 출력에 보존된 반면 C#/이전 Swift에는 없었다. POTX→AVIF도 이전 흰 화면 대신 원본 문장이 나타났다. 이미지의 PSNR 29.301964·SSIM 0.365506은 문자 복구에 따른 차이로 확인했으며 엄격 FAIL은 유지한다.

CAD→AVI·MKV 2개에서는 실제 인수를 기록한 새 wrapper로 CAD→GIF→WebM→영상 경로를 확인했다. 번들·시스템 FFmpeg 모두 정지 GIF의 WebM 결과를 100/1fps·0.1초·실제 1프레임으로 보고했다. 다음 AVI 인코딩은 같은 그림을 10프레임으로 복제했다. 같은 GIF를 MP4로 변환하면 양쪽 FFmpeg 모두 10/1fps·0.1초·1프레임이다. GIF의 중간 영상은 MP4를 우선하도록 비용을 구분하고, 직접 GIF→WebM·MOV 요청은 직접 변환하도록 유지했다. 실제 CAD 경로와 직접 GIF 목표를 검사하는 회귀 테스트를 추가했다. 이 수정 뒤 결과는 아래 최종 실행으로 구분한다.


### GIF 프레임률 수정의 범위 축소

MP4 중간 경로를 우선한 `candidate02`는 801개 검사(엔진 783개 중 15 skip·Core 18개)를 실패 없이 마쳤고, 새 앱·AppModel·rich host 19건도 통과했다. 그러나 `full849-02`의 829 completed / 20 failed와 별개로 `strict02`는 **484 PASS / 264 WARN / 101 FAIL**이었다. CAD 2건은 WARN으로 돌아왔지만 ICNS/GIF에서 시작하는 5건의 프레임률·일부 길이가 달라졌다. LIT→SNB 한 건은 PASS로 바뀌고 생성 표지 두 건은 PASS→WARN이었으나, 이 회차의 코드 변경은 영상 경로뿐이므로 전자책 문제의 안정적인 수정으로 계산하지 않는다.

독립적으로 작성하고 ffprobe로 확인한 3프레임 GIF의 지연은 0.1·0.2·0.3초다. `gif-bridge-timing02`는 MP4 중간 경로를 쓴 AVI의 10 Hz 색 표본이 `빨강·빨강·파랑·파랑·빨강·빨강`으로 바뀌어 실패했다. 원본은 `빨강·파랑·파랑·빨강·빨강·빨강`이다. 현재 host로 WebM을 명시적으로 경유한 `gif-bridge-timing03`은 원래 시점과 0.6초 길이를 유지했다. 첫 `gif-bridge-timing01`은 검사 도구가 ffprobe의 정수 tick인 `duration`을 초로 잘못 읽은 실패이며 `duration_time`으로 고쳤다. 원본·실패 증거를 유지했다.

따라서 MP4 우선 경로 변경과 그 전용 테스트는 되돌렸다. 최종 코드는 `nb_frames`를 읽고, **한 프레임으로 확인된 GIF를 WebM으로 쓸 때만** 실제 평균 프레임률을 명시한다. GIF의 경로 비용과 여러 프레임·개수 불명확 입력의 기존 처리는 유지한다. 100 Hz 시간 단위가 VP9의 프레임률로 기록되는 원인을 제한된 조건에서 바로잡으며, 소수 프레임률도 정수로 반올림하지 않는다. 해당 조건의 파싱·인코딩 회귀 테스트를 추가했다. 고정 프레임률을 요구하는 이후 영상 형식의 기존 프레임률 선택 정책을 전면 교체한 것은 아니다.


### 최종 소스의 실행 결과

최종 `candidate03`은 정상 Release 전체 제품 빌드를 184.49초에 완료했다. host SHA-256은 `26125e2ce1bb0729ba85d24217ea9b931175276b310a7d2b601de349ae85e43c`이다. `candidate01` 이후 최종 변경은 `MediaInfo.swift`·`MediaEncoding.swift`·`MediaTests.swift` 세 파일뿐이며, 경로 비용은 원래 값으로 돌아왔다. `single-frame-gif-source-delta.json`이 이 연결을 기록한다.

`app-final03`·`app-model-final03`은 최종 소스의 새 앱과 실제 AppModel 흐름을 다시 통과했다. 파일 선택·옵션 저장·AMR 변환·취소·OGG 재시도·이력·원본 보존과 실제 코덱을 확인했다. Mach-O 경로 15개(프레임워크의 심볼릭링크 별칭 포함)는 arm64이며 ad-hoc 서명·Homebrew 동적 링크 없음·FFmpeg 고지 40개를 확인했다. `host-rich04`의 혼합 PDF·기존 OCR·빈 페이지·SVG 19건도 모두 통과했다. 실제 마우스·드래그·대화상자 조작을 검사했다는 뜻은 아니다.

`gif-bridge-final02`는 독립 3프레임 가변 GIF를 MP4·MKV·AVI·WebM·MOV로 변환해 각 결과의 10 Hz 색 표본과 0.6초 길이를 확인했다. 1프레임 GIF의 0.1·0.4초 지연도 WebM에서 1프레임·같은 길이·평균 10·2.5fps로 유지했다. 첫 `gif-bridge-final01`은 소수 프레임률에서 ffprobe의 추정 기저율 `r_frame_rate`까지 평균률과 같다고 가정해 실패했다. 출력은 이미 0.4초·평균 2.5fps였으며, 초 단위 프레임 길이와 실제 평균률을 확인하도록 판독기를 바로잡았다. 공식 고정 FFmpeg 소스 `libavformat/avformat.h`도 `r_frame_rate`를 추정값으로 설명한다. **전체 엄격 비교의 r_frame_rate 판정이나 임계값은 바꾸지 않았다.**

`full849-03`은 원래 849개 cases로 **829 completed / 20 failed**, harness·inspection 오류 0을 기록했다(187.44초). 기존 성공 786개는 모두 유지되고 43개 실패가 완료로 바뀌었다. 남은 20개는 오디오 트랙 없음 14개·추출 텍스트 없음 6개이며 `state-delta.json`에 개별 오류를 남겼다. `media-bridge-final02`는 CAD→AVI·MKV 각각 10/1fps·0.1초·실제 디코딩 1프레임을 확인했다.

`strict03/report/report.json`은 **485 PASS / 260 WARN / 104 FAIL**이다. 원래 C# 비교와 thresholds·inspectionPolicy가 같고 면제는 없다. `strict-delta.json`의 104개 분류는 다음과 같다.

| 분류 | 수 | 해석 |
| --- | ---: | --- |
| C# 실패 → 현재 완료 | 43 | 상태 불일치 FAIL이며 성공 복구 수와 별개로 유지 |
| 이전 품질 FAIL 유지 | 47 | 이 실행에서도 엄격 동등성을 충족하지 못함 |
| 슬라이드 텍스트 복구 | 6 | 원본 한글이 보존된 문서 5개와 AVIF 1개, 원본 대조 완료 |
| 정지 GIF 경유 프레임률·일부 길이 변경 | 8 | ICNS→M2TS·MKV·MPG·MXF, PDF→WebM, TGA→WebM, GIF→MKV, TIFF→WebM |

마지막 8개는 단일 프레임 GIF 보정이 후속 영상 경로에 전달되며 생긴 차이다. 후속 고정 프레임률 형식에서는 프레임률 선택에 따라 길이와 복제 프레임 수도 달라지며, 아래 사례별 실제 조회에서 값을 확정한다. 모든 영상 형식의 타임스탬프 동등성을 입증한 것은 아니다. 처음 발견한 CAD 2개는 FAIL→WARN으로 돌아왔다. LIT→SNB 한 개의 FAIL→PASS와 생성 표지 관련 PASS/WARN 변동은 매 실행의 결과로 보존하며, 영상만 바뀐 소스에서 전자책 문제가 안정적으로 해결됐다고 주장하지 않는다. 이전에 알려진 48개 품질 차이 전체가 해결된 것도 아니다.

최종 소스의 전체 Swift 검사는 아래 `regression-final03`의 타이밍 실패와 검사 수정 뒤 `regression-final04`에서 통과했다. 독립 최종 리뷰는 진행 중이며 도착하면 결과를 추가한다.

### 검증 경계

페이지 이미지는 재렌더링한 내용이며 원본 이미지 바이트·ICC·투명도의 보존을 뜻하지 않는다. 새 OCR, 완전한 SVG 레이아웃·편집 가능 텍스트, 모든 형식·코덱 조합, 모든 GIF 시간 패턴을 검증한 것은 아니다. PML의 비 BMP 문자는 명시적인 실패로 남는다. 최종 성능 수치를 새로 측정하지 않았으며 이전 벤치마크·개발 인증서 Release·재배치 검증은 당시 소스의 기록이다.

물리 M1/macOS 15, exFAT·SMB·TCC 재실행·실제 로그인/알림·Developer ID 서명·공증은 계속 보류했다. 설치 앱 교체·커밋·푸시·공개 배포는 하지 않았다. 실패한 검사 도구 가정·중간 빌드·실험 결과를 삭제하지 않았다. 원래 triage 본문과 연구 문서의 바이트는 유지했다.


### 최종 단위검사에서 발견한 타이밍 의존성

`regression-final03`은 엔진 783개(15 skip)·Core 18개 중 `testHelperFailuresAndLateWritesPublishNothing` 한 개가 실패했다. 세 번째 helper를 취소하기 전 500ms만 기다렸으며, 세 번이어야 할 시작 기록이 두 번이었다. 같은 소스의 단독 재현 `avif-race-repro01`은 통과했다. 검사는 helper가 임시 출력 일부를 쓴 뒤 준비 표시를 남길 때까지 최대 5초 기다리고 취소하도록 수정했다. 기존 파일 보존·임시 파일 정리 검사는 유지했고, 준비 표시가 없으면 실패한다.

이 수정은 `Tests/Engine/Images/AvifEncoderTests.swift` 한 파일뿐이다. `avif-test-only-source-delta.json`은 정상 제품 빌드 `candidate03` 이후 제품 소스가 그대로임을 기록한다. 따라서 위 앱·19건·849건·엄격 비교는 같은 제품 코드의 결과다. AVIF 집중 검사와 전체 재검사 결과는 아래와 같다. 실패 실행과 그 로그는 보존했다.


### 최종 단위검사 통과

`avif-race-fixed01`은 AVIF 21개 검사를 실패 없이 완료했다. 이어서 `regression-final04`는 **엔진 783개(15 skip)·Core 18개, 총 801개 중 786개 통과·15개 생략·실패 0개**를 기록했다(명령 전체 230.95초). 생략은 외부 표본·도구가 필요한 기존 조건이며 개별 이유를 로그에 남겼다. 실행 전후 소스와 보호 파일 해시가 모두 같고 `candidate03` 이후 변경도 AVIF 검사 파일 하나뿐이다. README 3종과 현재 아키텍처·마이그레이션 설명을 이 결과로 갱신했다. 독립 최종 리뷰의 결과는 아직 포함하지 않는다.


### 독립 최종 리뷰와 조치

`claude-dev-max`(`claude-opus-5-5`, effort=max)의 읽기 전용 리뷰는 PDF의 OCR 전용 페이지 보존 결함과 FFmpeg staging 검증 범위를 과장한 문구를 차단 지적으로 냈다. 이 리뷰는 코드를 분석했으며 재현·테스트를 실행한 것은 아니다. 부모가 별도 회귀 검사로 재현하고 수정한다. 최종 검사 결과와 코드 범위는 후속 기록으로 연결한다.

FFmpeg 문구는 실제 검사 범위로 바로잡았다. `verify_bundle`은 버전·플랫폼·소스 pin 선언과 번들 자체 기록의 실행 파일 해시, 고지 존재를 확인한다. 소스 ZIP을 열거나 현 레시피 해시를 대조하지 않는다. 기존 번들의 레시피와 현재 파일은 검증·CLI·self-test 코드 차이가 있고 configure·빌드 명령은 같다는 리뷰 분석을 기록하되, 현재 레시피의 전체 소스 빌드를 다시 실행했다고 주장하지 않는다.

SVG의 명시적인 display/visibility/opacity·clip/mask 숨김 제외와, 나중에 그린 도형에 덮인 텍스트는 구분한다. 후자는 검색·추출될 수 있는 현재 한계이며 README 3종에 명시했다. SVG의 완전한 가림 판정·텍스트 삭제 기능을 구현한 것은 아니다. PML의 참조 PNG 파일 존재와 ASCII 이름·소문자 확장자 제한도 README 3종에 추가했다. 마이그레이션 현재 상태 날짜를 10월 28일로 갱신했다.


리뷰 B1은 부모의 `review-regressions-red02`에서 ImageMask+OCR와 SVG→PDF→EPUB 두 경우 모두 실제 그림 0개로 재현했다. `readPage`가 수집한 단어 중 mode 3 이외 글자의 존재를 추적하도록 바꿨다. 투명 OCR 글자만 남는 페이지는 텍스트 검사에서 그림 필요로 표시하고, rich 읽기에서는 `renderScan`으로 페이지 전체를 보존한다. TXT는 기존 추출 글자를 유지한다. ImageMask+OCR의 네 내장 rich 형식과 SVG PDF의 EPUB에 글자·페이지 픽셀 회귀 검사를 추가했다. ODT는 실제 host에서 글자·그림 참조·디코딩된 비어 있지 않은 이미지를 확인한다. 첫 `review-regressions-red01`은 검사 코드의 비동기 autoclosure 사용 오류로 컴파일에서 멈췄고, 실행 전에 수정했다.

대체 경로가 PDF→DOCX로 시작할 때만 `keepsPages`를 켜도록 제한해 우선순위 설정 때문에 PDF→CBZ가 선택될 때 기존 글자를 버리는 재계획을 막았다. 검사에서 최초 TXT 경로와 대체 CBZ 경로를 각각 확인한다. 첫 검사 표본은 CBZ 비용을 너무 낮춰 최초 경로부터 CBZ를 골랐으므로, 비용을 고치고 두 경로 단언을 추가했다.

권장 지적 3도 반영했다. 번들의 최상위·bin 허용 목록과 심볼릭 링크를 확인하고 FFmpeg 코드는 검증한 `ffmpeg`·`ffprobe` 두 파일만 서명·포함한다. `LICENSES`와 `BUILDING.txt`만 앱 고지로 복사하며 절대 빌드 경로가 든 `PROVENANCE.json`은 로컬 산출물에 유지한다. `staging-review01`은 self-test와 실제 staging을 6.87초에 통과했다. 손상된 probe·추가 ffplay 거부, 거부 시 기존 staging 보존, 고지·기계어·서명 검사를 포함했고 원본 파일 해시는 유지됐다. 이 변경은 소스 ZIP·현 레시피 검증을 추가한 것이 아니다.

리뷰 수정으로 제품 소스가 바뀌었으므로 위 `candidate03`·`regression-final04`·앱·849건·엄격 비교는 수정 전 결과다. 수정 후 빌드·검사 결과는 다음 기록에서 확정한다. 전체 가림 판정이나 배포·공증을 추가하지 않았다.


`review-focused01`에서 ImageMask+OCR의 네 내장 출력은 원본 페이지 픽셀과 일치했다. ODT는 단위검사의 축소된 catalog에 없어 이 검증을 실제 host로 옮겼고, `check-rich-current.py`는 기존 19건에 ImageMask+OCR 여섯 출력(TXT 포함)과 이 앱이 만든 SVG PDF→EPUB 한 건을 추가한 26건을 준비했다. 이때 회전 PDF 검사에서는 PDFKit의 NSFont nil 예외가 한 번 발생했다. 단독 `review-stamped-repro01`은 통과했지만 예외가 난 빠른 `selection.attributedString` 경로가 기존 공유 잠금을 우회하고 있었다. 두 속성 조회 경로 모두 같은 잠금에 넣고, 16페이지 균일 글꼴 PDF를 네 문서로 동시에 읽는 검사를 추가했다. 한 번의 단독 통과로 원인이나 안정성을 확정하지 않는다.

`app-final04`는 빌드 완료 전 `generate` 단계의 중간 기록만 보고 앱 검사를 시작한 조율 오류가 있었다. AppModel 컴파일은 모듈 없음, 서명 검사는 미완성 번들 오류로 중단됐다. 원래 기록을 보존하고 두 검사 도구가 `generate`와 `build` 모두 성공한 기록을 요구하도록 수정했다. 제품 코드 오류로 집계하지 않으며, 다음 앱 검사는 실제 빌드 프로세스 완료 후 실행한다.

보이는 글자가 있는 페이지의 벡터 그림과 인라인 이미지는 기존 추출 경로에서 빠질 수 있는 한계로 남는다. 이번 수정은 투명 OCR 글자만 있는 페이지의 전체 그림을 보존하며 완전한 PDF 편집 구조 복원을 뜻하지 않는다. README 3종에도 이 범위를 명시했다.


### PDFKit의 병렬 문자 처리 예외 수정

`review-focused02`와 단독 `review-uniform-repro01`에서는 속성 조회에만 잠금을 건 상태에서도 PDFKit이 nil 글꼴을 속성 사전에 넣다가 종료했다. 새로 작성·컴파일한 최소 재현(`pdf-font-diagnosis01`)에서는 부모 문서의 정보를 읽고 여러 문서의 페이지를 중첩 TaskGroup으로 처리할 때 같은 예외가 재현됐다. 단순 순차·병렬 조회의 통과만으로 충분하지 않았다.

최종 수정은 기존 공유 잠금을 `pageWords` 전체로 옮겨 문자열·글꼴 속성·글자 및 선택 영역 위치를 함께 보호한다. 문서의 페이지 배분과 이후 문단 처리는 유지한다. `review-focused03`의 PDF·작업 큐·경로 검사 39개가 통과했고, 종료되던 16페이지×4문서 검사도 통과했다. 모든 소스·보호 파일 해시를 확인했다. 더 좁게 문자열·속성 생성만 보호한 실험도 최소 재현에서 통과했지만, 제품에는 적용하지 않았다.

정상 Release 빌드 `candidate05`는 176.21초에 완료했다. host SHA-256은 `f333a7aca87b80795bfb15fabb8ce59b3b7d597ff13f3e4eb54f9b92a478f211`이다. 이 실행 파일의 `pdf-performance05`는 기존 200페이지 `big.pdf`를 다섯 번 순차 변환했다. 출력 553,101바이트의 SHA-256은 매번 기존 결과 `9607cb61e0868364146f6d76c397a254d9fb36bd95155ba68de88c2907d35761`과 같다. 시간은 0.763796·0.704616·0.688901·0.690422·0.706237초, 중앙값 0.704616초로 **다섯 번 모두 기존 0.84초 목표를 충족**했다. 이전 중앙값 0.630638초는 당시 기록이며 동시 실행한 비교 대상이 아니다. 이 측정 동안 이 작업의 다른 빌드·변환은 실행하지 않았다. Markdown 등 나머지 성능 검사를 새로 측정한 것은 아니다.

전체 검사·새 앱·26개 rich host 사례·849건 재실행은 이 소스로 진행하며, 완료된 결과만 아래에 기록한다.


### 남은 영상 8건의 실제 값

`media-frame-deltas05`는 고정 FFmpeg의 `ffprobe -count_frames`로 C#·직전 Swift·최종 `full849-05` 산출물만 읽었다. 이전 변환 실행 파일은 실행하지 않았다. C#과 직전 Swift의 아래 값은 모두 같았다. 표의 프레임률은 엄격 비교기가 쓰는 추정 기저율 `r_frame_rate`이며, 프레임 수는 실제 디코딩한 `nb_read_frames`다.

| 사례 | 기저 프레임률(이전 → 현재) | 파일 길이, 초(이전 → 현재) | 디코딩 프레임(이전 → 현재) |
| --- | --- | --- | --- |
| `auto-036-icns-to-m2ts` | 200/1 → 20/1 | 0.005000 → 0.050000 | 1 → 1 |
| `auto-036-icns-to-mkv` | 100/1 → 10/1 | 0.100000 → 0.100000 | 1 → 1 |
| `auto-036-icns-to-mpg` | 60/1 → 48000/1001 | 0.100000 → 0.062556 | 6 → 2 |
| `auto-036-icns-to-mxf` | 60/1 → 24000/1001 | 0.100000 → 0.083417 | 6 → 2 |
| `auto-055-pdf-to-webm` | 100/1 → 10/1 | 0.100000 → 0.100000 | 1 → 1 |
| `auto-093-tga-to-webm` | 100/1 → 10/1 | 0.100000 → 0.100000 | 1 → 1 |
| `auto-101-gif-to-mkv` | 100/1 → 10/1 | 0.100000 → 0.100000 | 1 → 1 |
| `auto-106-tiff-to-webm` | 100/1 → 10/1 | 0.100000 → 0.100000 | 1 → 1 |

ICNS→MKV, PDF·TGA·TIFF→WebM, GIF→MKV 다섯 건은 평균 프레임률도 100→10이고 길이 0.1초·1프레임을 유지한다. ICNS→M2TS·MPG·MXF 세 건은 길이도 바뀌었다. 이 세 출력의 평균 프레임률은 도구가 `0/0`으로 보고하므로 평균값을 확인했다고 주장하지 않는다. 특히 MPG·MXF는 이전 0.1초보다 짧다. 이 결과를 단순한 메타데이터 차이로 처리하거나 엄격 FAIL을 면제하지 않으며, 모든 영상 경로의 시간 보존은 남은 한계다. 입력·산출물·실행 도구·현재 소스 해시는 유지됐다.


### 리뷰 수정 후 최종 검증 확정

아래 결과는 `candidate05`와 동일한 현재 소스에 연결된다. `final-evidence-summary.json`은 각 실행의 source/protected 해시 결과와 최종 실행 파일 해시를 모은다. 과거 C#·Swift 실행 파일은 비교 대상으로 실행하지 않았고, 저장된 산출물만 읽었다. 전용 HOME/TMP·최소 환경과 한 겹의 .NET SDK 접근 거부 정책을 유지했다.

- `regression-final05`: **엔진 787개(15 skip)·Core 18개, 총 805개 중 790개 통과·15개 생략·실패 0개**. 명령 전체 501.94초에는 현재 소스 컴파일과 검사가 포함된다. 외부 표본·도구가 필요한 생략 조건은 유지했다.
- `app-final06`: 새 DerivedData·패키지 폴더에서 Debug 앱·테스트 번들을 305.69초에 빌드했다. `app-model-final06`은 새 앱의 실제 AppModel로 파일 선택·옵션 저장·번들 AMR 변환·취소·OGG 재시도·이력·원본 보존을 통과했다. 스트림도 `amr_nb`와 `vorbis`로 확인했다. 실제 마우스·대화상자 조작이나 Xcode 호스트 XCTest가 실행됐다는 뜻은 아니다.
- 앱의 Mach-O 경로 15개(프레임워크 별칭 포함)는 arm64이고 ad-hoc deep/strict 서명이 유효하다. Homebrew 동적 링크와 .NET 실행 구성요소가 없으며 FFmpeg 고지 파일 39개를 담는다. 이전 40개에서 로컬 빌드 경로가 든 PROVENANCE가 제외됐다.
- `host-rich06`: **26건 모두 통과**. 기존 19건에 ImageMask+OCR의 EPUB·FB2·HTMLZ·TXTZ·ODT·TXT와 SVG PDF→EPUB를 추가했다. 본문·페이지 순서·그림 참조·디코딩·비어 있지 않은 이미지를 확인했다. 단위검사에서는 네 내장 rich 형식과 SVG PDF EPUB의 페이지 픽셀까지 대조했다.
- `full849-05`: **829 completed / 20 failed**, 178.83초. harness·inspection 오류 0, 기존 성공 786건 유지, 기존 실패 43건 완료 전환. 남은 실패는 오디오 트랙 없음 14건·추출 글자 없음 6건이다. 원본과 기존 산출물은 그대로다.
- `strict05`: 같은 임계값·판독 정책으로 **483 PASS / 261 WARN / 105 FAIL**, 35.92초. 면제는 없다. **43건은 C# 실패→현재 완료 상태 차이, 48건은 기존 품질 FAIL, 6건은 원본 슬라이드 글자 복구, 8건은 위 정지 GIF 경유 영상 차이**다.

직전 `strict03`보다 LIT→SNB가 PASS→FAIL(내장 그림 유사도), RB→MD가 PASS→WARN(동반 파일 차이)으로 바뀌었다. 해당 전자책 제품 소스는 리뷰 수정에서 바뀌지 않았다. LIT→SNB의 앞선 PASS를 안정적 해결로 인정하지 않았으며, 최종 결과에서는 기존 품질 차이 48건이 모두 남는다. `strict-delta.json`에 개별 ID·판정 이유와 정책 일치를 기록했다.

독립 리뷰의 차단 두 건(PDF 보존 결함·FFmpeg 검증 문구)은 재현 검사·수정·검증과 문서 정정으로 처리했다. 권장 사항 중 실행 파일 허용 목록·PROVENANCE 배포 제외·DOCX 대체 경로 확인도 반영했다. 수정본을 별도 에이전트가 다시 승인했다는 뜻은 아니다.

105 FAIL을 모두 기능 실패로 세거나 모두 개선으로 보는 해석은 잘못이다. 기존 품질 차이, ICNS 영상 세 건의 재생 길이 변화, 보이는 글자가 있는 PDF 페이지의 벡터·인라인 그림 누락 가능성, 도형으로 덮인 SVG 글자의 검색 가능성은 남는다. 새 OCR·완전한 SVG 편집 구조·모든 형식/코덱 조합을 구현하거나 검증한 것은 아니다. 물리 M1/macOS 15·exFAT/SMB·TCC·로그인/알림·배포 서명/공증은 계속 보류했다. 설치 앱 교체·커밋·푸시·공개 배포는 하지 않았다. 이전 triage 237,708바이트와 연구 문서, 실패·실험 산출물은 보존했다.


<a id="priority-one-drawings-covered-svg-text-2026-10-29"></a>
## 텍스트 페이지의 그림 보존과 가려진 SVG 글자 — 2026-10-29

직전 최종 검증에서 남은 두 한계, 즉 보이는 글자가 있는 PDF 페이지의 벡터 그림·인라인 이미지 누락과 나중에 그린 도형에 덮인 SVG 글자의 검색 가능성을 고쳤다. 증거는 `build/resume/priority1-20261029/`에 있다. 모든 실행은 명시적 최소 환경·전용 HOME/TMP·`build/isolated.sb` 한 겹으로 했고, 과거 host·runner·프로토타입과 C#/.NET은 실행하지 않았다. 과거 산출물은 읽기 전용 비교 자료로만 썼다. 시작 시 triage 266,125바이트와 연구 문서 해시는 `task-start.json`에 남겼다.

### 수정 전 재현

- `red01`: 파란 차트 상자·빨간 선·초록 인라인 이미지·폼 안의 상자와 글자가 있는 텍스트 페이지에서 문서 모델·DOCX·HWPX·EPUB·FB2·HTMLZ·TXTZ 모두 그림이 0개였다(글자 검사는 통과). 가려진 SVG 글자는 26개 사례 모두 검색 글리프가 남았고, 실제 PDF 텍스트와 SVG→TXT에 "Covered"가 나왔다. 글자가 겹친 경우에도 덮인 "AB"가 남았다.
- `red02`: 스텐실 마스크(ImageMask) 텍스트 페이지는 판정 한 줄을 임시로 끈 상태에서 그림이 0개였다. 임시 수정은 바로 되돌렸다.
- `green01`의 실패 1건은 시험 자료의 짝 없는 `W n` 잘라내기가 글자까지 가린 문제였다. `q/Q`로 감싸 고쳤고 제품 코드와는 무관하다.

### 구현한 동작

- PDF: 내용 스캔이 경로 칠하기(`f F f* B B* b b* S s`, 잘라내기만 하는 `n` 제외)·셰이딩 `sh`·인라인 이미지 `EI`·ImageMask XObject를 기록한다. 보이는 글자가 있고 돌아가지 않은 페이지에 이런 칠하기가 있으면, PDFium의 기존 렌더링에서 불러온 사본의 글자 객체(폼 안 포함)를 빼고 150dpi로 그린다. 흰 종이가 아닌 영역(1픽셀 여백)을 PNG로 잘라 종이 기준 원래 위치의 `BEHIND_TEXT` 그림 하나로 페이지 첫 문단에 붙인다. 글자는 기존 읽기 순서·여백·서식 그대로 텍스트로 남고, 이 페이지의 이미지 XObject 추출은 렌더링으로 대신해 그림을 두 번 넣지 않는다. 흰 종이만 남으면 그림을 넣지 않는다.
- 리치 출력: `readText`가 이런 페이지 번호를 돌려주고, `PdfTextConverter`는 글자를 뺀 렌더링에 흰 종이 외의 내용이 있을 때만 `NoTextError`로 기존 PDF→DOCX 재계획을 쓴다. 순수 TXT·파일 출력 트랜잭션·취소 확인 경로는 바꾸지 않았다. `pageWords`의 페이지 전체 공유 잠금도 그대로다.
- SVG: 윤곽선 변환 뒤 그리는 순서대로 각 요소의 영역(뷰포트 픽셀)을 보수적으로 구한다. 기존 `equivalentPath`로 path·기본 도형의 제어점 경계를 쓰고, 칠한 선은 너비의 2배(miter 4)와 1픽셀을 더한다. image는 x·y·width·height를 쓴다. 측정하지 않는 그림(`use`, CoreSVG가 배치하는 text, 중첩 svg, switch, foreignObject, filter, marker·miterlimit·vector-effect, CSS transform, em·ex·% 길이, 해석되지 않는 transform, 작업 한도 초과)은 모든 곳을 덮는다고 본다. 1픽셀 여백을 둔 글자 영역과 겹칠 수 있는 것이 뒤에 그려지면 불투명도와 관계없이 그 글자의 검색 글리프 전체를 뺀다. 나중 그림의 clip·mask는 잘리기 전 영역으로 본다. defs·clipPath·mask·marker·gradient·title 같은 요소와 `display="none"`은 그 자리에 그리지 않는 것으로 본다. 윤곽선과 렌더링 픽셀은 그대로이고, SVG→TXT는 같은 PDF 글자를 따른다.

### 현재 소스 검증

- `green02`(PdfReader·Vector·Pdfium·PdfEngine·RoutePlanner·JobQueue·DocumentEngine): **146개, 3개 생략, 실패 0개**. 새 검사 5개는 그림 텍스트 페이지(6개 형식과 TXT, 각 글자 한 번, 그림 하나에 파랑·빨강·초록만 있고 글자색 없음), 흰 칠하기·잘라내기만 있는 페이지(그림 없음, 텍스트 경로 유지), 스텐실 마스크, SVG 가림 26개·비가림 8개 사례와 글자 겹침, SVG PDF·TXT의 실제 결과와 픽셀 동일성이다.
- `regression01`: **엔진 792개(15 skip)·Core 18개, 총 810개 중 795개 통과·15개 생략·실패 0개**, 245.90초. 직전 805개에 새 검사 5개를 더한 수다.
- `candidate01`: 정상 Release 빌드 181.54초. host SHA-256 `eaf898955be8480fc02a2b9ea0aca59b8651b10f0afbbfb7576387de7956abbe`, AVIF helper `012c4779dc3d787df48ea976ad43f0d718dd5c0810065f93732bafbc17d80145`. 이후 모든 host 검사는 이 실행 파일만 썼다.
- `performance01`·`performance02`: 저장된 200페이지 `big.pdf`를 다른 빌드·검사 없이 순차로 5번씩 변환했다. 출력은 매번 `9607cb61e0868364146f6d76c397a254d9fb36bd95155ba68de88c2907d35761`이다. 시간은 0.825766·0.767747·0.733336·0.713009·0.720465초(중앙값 0.733336)와 0.761554·0.676033·0.683772·0.702506·0.682842초(중앙값 0.683772)로 **모든 실행이 0.84초 목표를 충족**했다. 첫 묶음의 첫 실행은 목표와 0.014초 차이다.
- `rich01`: **38건 통과**. 기존 26건을 다시 실행하고, 그림 텍스트 페이지의 DOCX·HWPX·EPUB·FB2·HTMLZ·TXTZ·ODT·TXT, 스텐실 마스크의 DOCX·EPUB, 가려진 SVG의 PDF·TXT를 더했다. 각 글자가 한 번 나오는지, 그림이 하나이며 디코딩한 색이 기대와 같은지, HWPX의 `textWrap="BEHIND_TEXT"`, SVG 결과에 "Covered"가 없는지 확인했다.
- `replay01`: **829 completed / 20 failed**, 173.59초, harness·inspection 오류 0. 849건 모두 `full849-05`와 상태가 같다.
- `strict01`: 같은 임계값·판독 정책으로 **484 PASS / 261 WARN / 104 FAIL**, 34.68초. 면제는 없다. `strict05`와 달라진 판정은 `auto-054-pdb-to-rb`의 FAIL→PASS(내장 그림 유사도) 하나다. 이번 변경이 닿지 않는 Calibre 경로이므로 수정으로 세지 않는다. 비교 자료의 PDF 세 원본과 SVG 원본은 출력 해시 차이가 시간·UUID 같은 값뿐이었다. 따라서 849건은 새 그림층과 가림 규칙을 검증하지 않으며, 그 근거는 위 집중 검사와 rich host 12건이다. 개별 결과는 `strict01-delta.json`·`replay01-output-delta.json`에 있다.
- `green02`·`regression01`·`candidate01`·`replay01`·`strict01`의 소스 962개 해시는 현재 작업 트리와 같다(목록 digest `f05f50d16b017f3cc40577a092cd445fb46bfda62dd860d348f78919b4f3b1ba`). `evidence-summary.json`에 묶었다.

### 남은 한계

- 그림이 있는 텍스트 페이지에서는 이미지 XObject도 원래 바이트 대신 150dpi 렌더링의 일부가 된다. 그림층은 페이지마다 한 장이며 다시 흐르는 형식에서는 그 페이지 글자 앞에 놓인다. 위치는 글자 흐름이 PDF와 맞을 때만 겹쳐 보인다.
- PDFKit이 읽지 못하는 텍스트 페이지의 글자(세로쓰기, Type 3 글꼴을 포함해 유니코드 대응이 없는 글리프)는 글자 객체이므로 렌더링에서도 빠진다. 이전에도 텍스트로 나오지 않던 내용이며 이번 수정 범위 밖이다. 링크 외 주석·폼 필드의 모양은 그림이 있는 페이지의 렌더링에만 나타난다. 보이는 글자가 이미지 안에도 있는 스캔 위 직인 같은 경우에는 글자가 이미지와 텍스트에 함께 나올 수 있다.
- SVG 가림 판정은 보수적인 경계 상자 비교다. 덮지 않는 테두리 선, 투명한 칠, 다른 위치로 잘린 그림도 겹칠 수 있으면 검색 글자를 뺀다. 뒤에 `use`·필터·marker 등이 하나라도 있으면 앞 글자 전부가 검색층을 잃는다. 덮인 윤곽선은 PDF 벡터 내용에 남으므로 편집·redaction 기능이 아니다.
- Xcode 앱 빌드·AppModel 흐름·서명 검사는 이번 소스로 반복하지 않았다. 물리 M1/macOS 15·exFAT/SMB·TCC·로그인/알림·배포 서명/공증, 실제 GUI 조작도 계속 보류했다. 기존 품질 차이 48건과 영상 시간 문제는 범위 밖이다.

### 변경 파일

`Vendor/PDFium/include/module.modulemap`(FileToX 연결 파일에 `fpdf_edit.h` 추가), `Sources/Engine/Engines/Pdf/PdfiumDocument.swift`, `PdfDocumentReader.swift`, `PdfDocumentReader+Page.swift`, `PdfTextConverter.swift`, `Sources/Engine/Engines/Vector/SvgNormalizer.swift`, `SvgTextPath.swift`(`equivalentPath` 공개 범위), `Tests/Engine/Pdf/PdfReaderTests.swift`, `Tests/Engine/Vector/VectorTests.swift`, README 3종, `docs/architecture.md`, `docs/design/swift-engine-migration.md`, 이 절. 커밋·푸시·설치 앱 교체·공개 배포는 하지 않았다.


<a id="priority-one-integration-review-2026-10-29"></a>
## 그림 보존·SVG 가림 수정의 통합 검증 — 2026-10-29

앞 절의 구현을 검토해 SVG의 추가 결함 두 가지를 고친 뒤 현재 소스로 다시 검증했다. 이 절이 이번 수정의 최종 결과다. 근거는 `build/resume/priority1-review-20261029/`와 그 안의 `evidence-summary.json`에 있다. 기존 triage 274,885바이트는 그대로 접두부로 유지하며 연구 문서도 바꾸지 않았다. 전용 HOME/TMP·최소 환경·`build/isolated.sb` 한 겹을 유지했고, 과거 실행 파일·runner·C#/.NET은 실행하지 않았다.

### 검토에서 고친 두 결함

- 루트 `<svg>`의 `stroke`·`stroke-width` 등을 가림 판정에 상속하지 않아, 루트에서 물려받은 굵은 선이 덮는 글자도 검색층에 남았다. 루트와 자식에 같은 `Stroke` 초기화 경로를 적용했다.
- `<image>`의 `x`·`y`를 해석하지 못하면 0으로 처리해 `%`·`em` 좌표의 실제 위치를 놓쳤다. 속성이 없을 때만 0을 쓰며, 해석할 수 없는 좌표나 CSS의 x·y·width·height는 영역을 확정할 수 없는 그림으로 처리한다. 이런 그림이 나중에 그려지면 앞선 글자의 검색층을 제외하는 기존 보수적 정책을 따른다.

`red01`에서 `testRootStrokesAndRelativeImagePositionsCannotExposeCoveredText` 하나의 다섯 판정이 실패했다(루트 선, x 70%, y 40%, x 9em, CSS 좌표). 수정 후 같은 검사가 전체 검사에서 통과했다. 추가 제품 변경은 `SvgNormalizer.swift`, 추가 회귀 검사는 `VectorTests.swift`다. PDF 구현은 앞 절의 내용과 같으며 읽기·재계획·문서 출력 호출 경로를 확인했다.

### 현재 소스에 연결된 결과

| 검사 | 결과 |
| --- | --- |
| `regression01` | 엔진 793개(15 skip)·Core 18개. 총 811개 중 **796개 통과·15개 생략·실패 0개**, 컴파일 포함 502.08초 |
| `candidate01` | 정상 Release host·AVIF helper 빌드 성공, 174.75초 |
| `app01` | 새 DerivedData·패키지 폴더에서 Debug 앱·테스트 번들 빌드 성공, 301.72초 |
| `app-flow01` | 새 앱의 실제 AppModel로 파일 선택·옵션 저장·번들 AMR 변환·취소·OGG 재시도·이력·원본 보존 통과 |
| `rich01` | 실제 PDF·SVG 변환 **44건 모두 통과** |
| `replay01` | **829 completed / 20 failed**, 168.37초. harness·inspection 오류 0, 849건 모두 직전 상태 유지 |
| `strict01` | 같은 임계값·판독 정책으로 **484 PASS / 260 WARN / 105 FAIL**, 32.86초. 면제 없음 |

앱 내 Mach-O 경로 15개(프레임워크 별칭 포함)는 arm64이고 ad-hoc deep/strict 서명이 유효하다. Homebrew 동적 링크와 .NET 실행 구성요소는 없고 FFmpeg 고지 파일 39개를 포함한다. AppModel 산출물도 `amr_nb`(8kHz mono)와 `vorbis`로 확인했다. 실제 마우스·대화상자 조작이나 Xcode 호스트 XCTest 실행을 검증한 것은 아니다.

`rich01`은 앞 절의 38건에 루트 선 상속, x 상대 좌표 이미지, y 상대 좌표 이미지의 PDF·TXT 6건을 더한다. 출력 글자·순서·그림 참조·디코딩과 원본 보존을 검사했고, 추가 SVG 결과는 보이는 글자가 남고 `Covered`가 검색·TXT 결과에 없음을 확인했다. 그림 텍스트 페이지는 각 글자가 한 번 나오고 그림 하나에 기대 색이 있으며, HWPX는 `BEHIND_TEXT`를 유지한다. 기존 849건 자료는 새 그림층·가림 규칙을 검증하지 않으므로, 새 기능의 근거는 이 44건과 집중 단위검사다.

재실행에서 남은 20건은 오디오 트랙 없음 14건·추출 글자 없음 6건이며 모든 원본과 이전 산출물을 보존했다. 엄격 비교의 105개 FAIL 사례 ID는 2026-10-28의 `strict05`와 모두 같다. 위임 구현의 `strict01`에 비하면 PDB→RB는 내장 그림 유사도로 PASS에서 다시 FAIL, LRF→HTMLZ는 WARN에서 PASS가 됐다. 두 경로의 제품 코드는 이번 검토에서 바뀌지 않았다. 앞선 PDB→RB PASS를 안정적인 해결로 인정하거나 LRF→HTMLZ 판정 변동을 이번 수정의 성과로 세지 않는다. 기존 품질 차이 48건, C# 실패→현재 완료 상태 차이 43건, 슬라이드 글자 복구 6건, 정지 GIF 경유 영상 차이 8건은 유지된다.

### PDF 처리 시간과 소스 연결

다른 빌드·검사·변환이 끝난 뒤 `performance01`에서 저장된 200페이지 `big.pdf`를 새 Release host로 다섯 번 순차 변환했다. 시간은 **0.771606·0.711531·0.692412·0.673000·0.700662초**, 중앙값 **0.700662초**로 **다섯 번 모두 0.84초 목표를 충족**했다. 매번 출력 SHA-256은 기존 `9607cb61e0868364146f6d76c397a254d9fb36bd95155ba68de88c2907d35761`과 같았다. 차가운 캐시나 물리 M1에서의 측정은 아니다.

- host SHA-256: `5a9cb171877c14c3d2bfe04ef60cb8dc213ac05a895f249b10d38ae841c9dc89`
- AVIF helper SHA-256: `012c4779dc3d787df48ea976ad43f0d718dd5c0810065f93732bafbc17d80145`
- 소스 962개 목록 digest: `64f70ee686bd402ed19fc3dbbaaee7f6fd63b361bc46c11a4f895c4936e2f084`

`summarize.py`는 전체 검사·Release 빌드·앱 빌드·AppModel·44건·849건·엄격 비교·성능 기록을 모아 현재 소스와 보호 파일의 해시를 다시 확인했다. 위임 결과 이후 달라진 소스는 위의 SVG 파일 두 개뿐이다. README 3종과 architecture·migration 문서를 현재 결과에 맞췄고 과거 검증 수치는 해당 절에 그대로 보존했다.

### 유지되는 한계

PDF 그림층은 150dpi 이미지 한 장으로, 원래 그림 바이트·색 프로필·투명도나 편집 가능한 벡터 보존을 뜻하지 않는다. PDFKit이 읽지 못하는 세로쓰기·유니코드 대응 없는 글자는 텍스트와 이 그림층에서 빠지는 한계가 남는다. SVG 가림 판정은 보수적이어서 실제로 덮이지 않은 글자도 검색층에서 제외될 수 있으며, 윤곽선은 PDF 안에 남으므로 편집·redaction 기능이 아니다.

기존 품질 차이 48건과 ICNS 영상 세 경로의 재생 길이 문제는 이번 범위 밖이다. 실제 GUI 조작, 물리 M1/macOS 15, exFAT/SMB·TCC·로그인/알림, 배포 서명·공증은 아직 검증하지 않았다. 설치 앱 교체·커밋·푸시·공개 배포는 하지 않았다.


<a id="slow-media-duration-verification-2026-10-29"></a>
## 저속 영상의 마지막 표시 시간 — 2026-10-29

ICNS→M2TS·MPG·MXF의 길이 차이를 수정했다. 근거는 `build/resume/media-duration-20261029/`와 `evidence-summary.json`이다. 전용 HOME/TMP·최소 환경·`build/isolated.sb` 한 겹을 사용했고, 과거 host·C#/.NET을 실행하지 않았다. 이전 triage 281,263바이트와 연구 문서는 그대로 보존했다.

### 원인과 변경

새로 빌드한 수정 전 host로 원래 ICNS를 재현하고 마지막 FFmpeg 입력·명령을 저장했다(`baseline01`, `diagnosis01`). 중간 GIF·WebM은 1프레임·0.1초를 유지했다. M2TS는 한 프레임의 표시 시간은 0.1초였으나 파일 길이가 0.05초로 추정됐고, MPG·MXF는 최종 프레임률 변환 중 마지막 표시 구간이 짧아졌다.

평균 프레임률이 양수이고 24000/1001 미만인 네 대상(TS 포함)에 `fps=…:eof_action=pass`를 적용한다. 입력의 평균·명목 프레임률 중 큰 값에 맞춰 가능한 정수배 프레임률을 우선 선택하고, 맞출 수 없으면 가까운 지원 프레임률을 쓰고 끝 시각을 올림해 마지막 구간을 채운다. TS/M2TS는 필요하면 60fps보다 높은 입력 시간 단위도 사용한다. 명목 프레임률은 FFmpeg의 추정치이며 모든 VFR 입력의 정확성을 보장하는 값은 아니다.

`vfr-burst01`에서 평균 3fps인 영상의 빨강 20ms→파랑 20ms→빨강 960ms를 평균값만으로 24fps에 맞추면 첫 색이 밀렸다. `MediaInfo`가 명목 50fps도 전달하고 MPEG 인코더의 `-r`을 필터와 일치시키도록 보완했다. 새 회귀 검사는 네 형식에서 50개 시점의 색을 모두 확인한다. 작은 TS가 MPEG 프로그램 스트림으로 오인되는 사례에는 프레임마다 PAT/PMT를 넣어 자동 판독을 유지한다.

일반 영상 판독에서 TS·M2TS의 필터 뒤 `-r` 보정이 늦게 시작하는 영상의 앞부분을 추가 프레임으로 채우는 문제도 확인했다. 이 두 형식은 필터가 정한 프레임률을 그대로 인코더에 전달하고 `-fps_mode passthrough`로 두 번째 보정을 생략한다. 오디오보다 영상이 0.2초 늦게 시작하는 10fps 입력을 30fps로 바꿔, 영상이 30프레임을 유지하고 앞에 6프레임을 더하지 않는지 회귀 검사로 확인했다.

제품 변경은 `MediaEncoding.swift`·`MediaInfo.swift`, 회귀 검사는 `MediaTests.swift`다. FFmpeg나 새 의존성을 교체하지 않았다. 고정 FFmpeg 9.0.2 소스의 `doc/ffmpeg.texi`, `doc/filters.texi`의 fps/EOF 규칙, `doc/muxers.texi`의 PAT/PMT, `doc/formats.texi`의 genpts, `libavformat/avformat.h`의 r_frame_rate 설명을 근거로 삼았다. 문서는 `build/resume/media-pdf-20261027/ffmpeg-build02/work/sources/ffmpeg/ffmpeg-9.0.2/`에 보존돼 있다.

### 최종 소스로 확인한 결과

| ICNS 대상 | 수정 전 파일 길이(초) | 수정 후 파일·디코딩 길이(초) | 프레임 수 / fps |
| --- | ---: | ---: | ---: |
| M2TS | 0.050000 | 0.100000 | 3 / 30 |
| MPG | 0.062556 | 0.100000 | 3 / 30 |
| MXF | 0.083417 | 0.100000 | 3 / 30 |

| 검사 | 결과 |
| --- | --- |
| `green06` | 미디어 40·경로 계획 7·작업 큐 9, **56개 통과·생략/실패 0개**, 컴파일 포함 260.87초 |
| `candidate03` | 일반 Release 옵션의 host·AVIF helper 빌드 성공, 169.70초 |
| `routes03` | 실제 host **33건 통과**: 가변 GIF 9개 형식, 단일 GIF 지연 4종×5개 형식, ICNS 4개 형식 |
| `replay03` | **829 completed / 20 failed**, 검사 프로그램 빌드 포함 170.28초. harness·검사 오류 0 |
| `strict03` | 같은 임계값·판독 정책으로 **482 PASS / 241 WARN / 126 FAIL**, 검사 프로그램 빌드 포함 32.96초 |

정지 입력 0.1·0.25·0.4초의 마지막 표시 구간, 가변 GIF의 0.6초 길이와 색 변화, 저속 영상의 오디오와 원본 보존을 검사했다. 849건의 완료 상태는 직전 PDF·SVG 검토 시점과 모두 같으며, 남은 실패는 오디오 트랙 없음 14건·추출 가능한 글자 없음 6건이다. 상태와 엄격 동등성은 구분한다. 엄격 판정의 변화는 다음과 같다.

- `auto-020-avi-to-m2ts`: WARN → FAIL.
- `auto-020-avi-to-mpg`: PASS → FAIL.
- `auto-021-avif-to-mxf`: WARN → FAIL.
- `auto-037-jxl-to-ts`: WARN → FAIL.
- `auto-039-lrf-to-htmlz`: PASS → WARN.
- `auto-047-mov-to-m2ts`: WARN → FAIL.
- `auto-047-mov-to-mpg`: PASS → FAIL.
- `auto-054-pdb-to-snb`: FAIL → PASS.
- `auto-064-svg-to-m2ts`: WARN → FAIL.
- `auto-065-svgz-to-mpg`: WARN → FAIL.
- `auto-065-svgz-to-mxf`: WARN → FAIL.
- `auto-070-ts-to-ts`: WARN → FAIL.
- `auto-079-wmv-to-m2ts`: WARN → FAIL.
- `auto-087-svg-to-mpg`: WARN → FAIL.
- `auto-087-svg-to-mxf`: WARN → FAIL.
- `auto-092-ppm-to-ts`: WARN → FAIL.
- `auto-100-avif-to-m2ts`: WARN → FAIL.
- `auto-102-heic-to-mpg`: WARN → FAIL.
- `auto-102-heic-to-mxf`: WARN → FAIL.
- `auto-105-psd-to-ts`: WARN → FAIL.
- `auto-119-pdf-to-m2ts`: WARN → FAIL.
- `auto-121-pdf-to-mpg`: WARN → FAIL.
- `auto-121-pdf-to-mxf`: WARN → FAIL.
- `auto-122-png-to-ts`: WARN → FAIL.

변경하지 않은 전자책 경로에서 PDB→SNB는 FAIL→PASS, LRF→HTMLZ는 생성 표지 차이로 PASS→WARN이 됐다. 두 판정 변동은 이번 수정의 성과로 세지 않는다. ICNS 세 경로의 시간 수정도 C#과의 프레임률·패킷 차이를 면제하지 않으며, 기존 품질 차이 48건의 안정적인 해결을 뜻하지 않는다.

새 엄격 FAIL **22건은 모두 r_frame_rate 항목 차이**이며, 정지 그림·PDF에서 파생된 16건과 일반 영상 6건이다. `differences02`에서 이전·현재 출력을 다시 디코딩해 프레임 순서와 표시 구간을 확인했다. 64×64로 정규화한 기존 프레임마다 가장 가까운 현재 프레임을 찾으면 순서가 모두 유지됐으며 최소 PSNR은 36.82dB다. AVI·MOV·TS에서 TS/M2TS로 가는 표본은 약 1초의 영상 표시 구간을 유지한다. WMV→M2TS는 끝 시각의 프레임 단위 올림으로 약 1초에서 1.041667초로 늘며 이 차이는 남는다. 이는 축소 표본의 보조 검사이며 전체 해상도의 픽셀·지각 동등성을 입증하지 않는다. 기본 엄격 FAIL은 그대로 유지한다. WMV 원본의 프레임 지속 시간이 없는 부분은 명목 프레임 간격으로 추정했음을 기록했다.

### 시간 단위와 검증 한계

- 0.13초처럼 지원 프레임 단위로 정확히 나눌 수 없는 길이는 마지막 프레임을 잘라내지 않고 올림한다. 확인한 출력은 24000/1001fps의 4프레임, 약 0.1668초다.
- 초소형 MPG는 여러 프레임을 한 PES에 담아 파일 길이가 첫 시각만으로 추정될 수 있다. `routes03`의 작은 GIF→MPG 다섯 건은 파일 길이 추정값이 짧다. 별도 `+genpts` 디코딩으로 누락된 표시 시각을 DTS에서 복원하면 전체 표시 시간과 색 변화가 보존된다. 기본 probe와 보완 probe를 모두 저장했고, 원래 ICNS의 파일 길이 검사는 그대로 통과했다. `+genpts`는 보완 검사에만 사용하며 제품 명령과 엄격 비교 정책은 바꾸지 않았다.
- 작은 MPG의 파일 길이 추정을 피하려고 패킷 크기·B프레임·GOP를 바꾸는 실험은 제품에 적용하지 않았다. 실패·실험 산출물도 보존했다. `green04`는 파서 기대값을 갱신하기 전에 빌드를 중단한 기록이며 통과 검사로 세지 않는다.
- 전체 Swift 검사·앱 빌드/AppModel·PDF 성능은 앞선 PDF·SVG 검토 소스의 기록이다. 이번 소스로 반복한 것은 위 집중 검사·Release host·33건·849건·엄격 비교다. 실제 GUI, 물리 M1/macOS 15, 외장 파일시스템·권한·로그인/알림, 배포 서명·공증은 여전히 미검증이다.

### 소스와 산출물 연결

- host SHA-256: `928753ab6cafc2174c4ebccea5b7b3320376ebf0a46a97eced33959979cb6195`
- AVIF helper SHA-256: `012c4779dc3d787df48ea976ad43f0d718dd5c0810065f93732bafbc17d80145`
- 소스 962개 목록 digest: `ac1204582faa4fae9b56bfe5b45d7516e4b69ce348732faa073edb5f6fff69a7`

`summarize.py`는 최종 소스·실행 파일·검사·원본·기존 산출물의 해시와 보존 여부를 확인한다. README 3종과 architecture·migration 문서에 현재 결과를 추가하고 이전 전체 검사·앱·성능 기록의 시점을 명시했다. 설치 앱 교체·커밋·푸시·공개 배포는 하지 않았다.


<a id="legacy-quality-loss-verification-2026-10-29"></a>
## 기존 품질 차이 48건과 실제 문자 손실 — 2026-10-29

기존 48건의 엄격 차이를 원본·본문·그림·파일 구조로 분류하고, 확인한 DWG 저장 결함과 목록 밖의 PDB 문자 손실을 수정했다. 근거는 `build/resume/quality-loss-20261029/`다. `consult01/ledger.json`은 사례별 증거와 당시 판정을 보존하며, 비교 정책이나 임계값을 낮추지 않았다. 과거 host·C#/.NET 실행 없이 저장된 기준선과 고정 판독기를 사용했다. 모든 실행은 전용 HOME/TMP·최소 환경과 `build/isolated.sb` 한 겹을 사용했다.

### 48건의 분류

| 원인 | 건수 | 확인한 내용 |
| --- | ---: | --- |
| 생성값 | 35 | Calibre UUID·ASIN·날짜, LRF BookID, OPF 항목 순서와 자동 생성 표지. 본문·실제 참조 대상은 보존되며 표지의 시각적 동등성은 주장하지 않는다. |
| 앞선 보존 개선 | 9 | 비어 있던 PPTX→LIT 본문, 끊긴 HTML/Markdown 그림 참조 4건, HTML→TCR의 잘못된 끝 글자, HWPX→RB의 문단 구분, LIT→AZW3 목차 CSS, M4V→AVIF 색 손실 개선. 이번 회차의 새 수정 성과로 세지 않는다. |
| 끝 공백 | 1 | SNB→TCR의 본문 뒤 줄바꿈 하나. |
| 리소스 저장 순서 | 1 | 만화 MOBI의 JPEG 레코드 순서. 본문·표지·썸네일 참조가 같은 그림 바이트로 연결된다. |
| 기존부터 있던 DWG 결함 | 2 | `auto-086-dxf-to-dwg`, `builtin-to-dwg`. GUID·시각 외에 내부 여유 공간 정보와 페이지 수가 잘못 기록된다. C# 기준선에도 같은 결함이 있다. |

검토 당시 48건의 raw 판정은 47 FAIL·1 PASS(`auto-054-pdb-to-snb`)였다. 이 분류에서 새 본문·그림 누락은 확인하지 못했지만 DWG 형식 결함은 별도로 수정했다. 생성 표지·메타데이터 차이도 엄격 비교에서 면제하지 않는다. LIT→AZW3의 동일 payload와 M4V→AVIF의 동일 출력은 앞선 독립 검증·원본 대비 판독 증거를 재사용했다. 모든 파일을 실제 기기에서 표시해 동등성을 검증한 것은 아니다.

### DWG 구조 수정

`DwgWriter.writeObjFreeSpace`는 지원하는 AC1024·AC1027·AC1032(R2010 이후)에 53바이트의 예전 구조를 쓰고 있었다. 고정 LibreDWG 0.14의 `src/objfreespace.spec`와 AutoCAD에서 생성된 세 버전의 표본을 읽어 89바이트 구조를 확인했다. 0 값·핸들 수를 64비트로 쓰고 날짜 쌍과 개수 4 뒤에 128비트 값 네 개를 기록하며, 예전 객체 오프셋 필드를 제거했다. `DwgFileHeaderWriter`의 페이지 수에는 페이지 맵 자신도 포함한다.

기존 ACadSharp fixture는 다시 만들지 않았다. AC1032의 다른 압축 해제 섹션은 그대로 비교하고, 세 버전의 89바이트 여유 공간 내용과 페이지 수를 검사한다. 독립 LibreDWG 판독으로 새 실제 host 출력 두 건도 확인한다. AutoCAD·ODA 앱에서 여는 검증은 아직 없다. 헤더 생성 시각의 로컬/UTC 해석 차이는 생성 메타데이터 문제로 남기며 이번 변경에 포함하지 않았다.

### PDB의 조용한 문자 대체 차단

48건 밖의 HWP·EML·TSV·RTF→PDB 네 건은 C#과 Swift 모두 한글을 `?`로 바꿔 엄격 비교에서 PASS였다. Calibre 9.15.0의 [PalmDoc writer](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/pdb/palmdoc/writer.py)는 `encode(..., 'replace')`를 사용하고, [PDB 출력 플러그인](https://github.com/kovidgoyal/calibre/blob/v9.15.0/src/calibre/ebooks/conversion/plugins/pdb_output.py)의 기본 인코딩은 cp1252다. 849건 재변환에서 AZW3·PDF·RB→PDB 세 건도 같은 손실을 확인해 총 7건으로 정정했다. `pdb-history-audit.json`은 일곱 건 모두의 과거 C#·Swift PDB를 직접 압축 해제해 한글 대신 물음표가 들어 있음을 확인한다. 원문은 `calibre-source/`에 URL·해시와 함께 보존했다. Context7의 Calibre 문서는 PalmDoc의 이 내부 동작을 충분히 다루지 않아 이 고정 공식 소스로 확인했다.

출력 형식을 PalmDoc·Windows-1252로 명시하고 자식 프로세스에서 `TXTMLizer.extract_content`가 반환한 본문을 strict 인코딩으로 검사한다. 표현할 수 없으면 `PDB cannot represent U+…` 오류와 EPUB 안내를 내고 출력 할당 전에 끝낸다. 출처·기존 출력 파일은 보존하며 호환성을 검증하지 않은 UTF-8 PalmDoc로 바꾸지 않는다. 이 보장은 본문 문자에 대한 것으로, PalmDoc 자체가 지원하지 않는 서식·그림·메타데이터 전체의 보존을 뜻하지 않는다. Calibre 내부 API 보완은 고정 9.15.0에서 검증했으며 다른 버전은 재검증이 필요하다.

수정 전 `red01`의 검사 5개에서 DWG·PDB 관련 assertion 21개 실패를 재현했다. 같은 검사에 포함한 서유럽 문자 저장은 통과했다. 수정 후 `green01`은 CAD 3·전자책 19·작업 큐 9·경로 계획 7, 총 38개가 실패·생략 없이 통과했다. 긴 본문의 첫 PalmDoc 레코드 이후에 있는 한글, 일본어, 이모지 거부·출력 할당 0회·기존 출력과 원본 보존, cp1252의 악센트·유로·긴 대시·물음표를 포함한 여러 레코드 본문을 검사했다.


### 최종 소스 검증

| 검사 | 결과 |
| --- | --- |
| `green01` | 관련 회귀 검사 **38개 통과**, 생략·실패 0개, 빌드 포함 264.96초 |
| `candidate01` | 일반 Release 옵션으로 host·AVIF helper 빌드 성공, 202.98초 |
| `full01` | 같은 소스로 빌드한 검사 바이너리 전체 실행: **엔진 800개(15 skip)·Core 18개, 실패 0개**, 243.78초 |
| `host01` | 실제 host의 서유럽 PDB 본문 복원 1건·한글/일본어/이모지 명시 거부 3건·독립 DWG 판독 2건, **6개 검사 통과** |
| `replay01` | 849건 중 **822 completed / 27 failed**, harness·inspection 오류 0개, 재변환 179.03초 |
| `strict01` | 같은 임계값·판독 정책의 C# 비교 **474 PASS / 241 WARN / 134 FAIL**, 비교 30.46초 |
| `app01` | 새 Debug 앱·테스트 빌드 성공(325.32초), Mach-O 15개 모두 arm64·ad-hoc 서명 검증·Homebrew 동적 링크와 .NET 파일 없음 |
| `model01` | 이 앱의 실제 AppModel과 번들 엔진으로 파일 선택·옵션 저장·AMR 변환·취소·OGG 재시도·이력·원본 보존 통과(실행 17.98초) |

전체 검사의 15개 생략은 별도 외부 corpus·C# 기준선·ACadSharp 표본 경로 미설정, 개발용 Pandoc 부재, Ghostscript 부재에 따른다. 선택한 Calibre 사본을 쓰는 PDB 검사는 생략하지 않았다. 실제 GUI 클릭·대화상자나 Xcode 호스트 XCTest 실행을 했다는 뜻은 아니다.

DWG의 두 실제 host 출력은 LibreDWG에서 모두 **객체 72개·페이지 15개**, 여유 공간 값 4개로 읽힌다. `Invalid sections` 경고가 사라지고, 페이지 맵 항목 수와 헤더 수가 일치한다. 원본·기존 fixture·판독기 바이너리는 보존했다.

직전 829 completed / 20 failed와 비교하면 다음 **7건만 completed → failed**로 바뀌었다. 모두 `PDB cannot represent U+…` 오류이며 출력·동반 파일·staging 잔여물을 남기지 않고 원본을 보존한다.

- `auto-022-azw3-to-pdb`
- `auto-034-hwp-to-pdb`
- `auto-055-pdf-to-pdb`
- `auto-062-rb-to-pdb`
- `auto-094-eml-to-pdb`
- `auto-109-tsv-to-pdb`
- `auto-114-rtf-to-pdb`

나머지 842건의 완료 상태는 그대로다. 기존 실패 20건은 오디오 트랙 없음 14건·추출 가능한 글자 없음 6건이며, 위 7건은 손실을 막기 위한 명시적 거부다. 변환 완료 수의 감소를 새로운 내용 손상으로 해석하지 않는다.

엄격 비교에서는 위 7건이 PASS → FAIL이다. 추가로 변경하지 않은 `auto-054-pdb-to-snb`가 생성 그림 유사도로 PASS → FAIL로 변동했으며 이번 수정 성과나 제품 회귀로 단정하지 않는다. 다른 raw 판정은 모두 직전과 같고 기존 48건도 현재 raw FAIL로 남는다. DWG도 잘못된 C# 기준선과 다르므로 FAIL을 면제하지 않았다. `evidence-summary.json`에 상태·판정의 정확한 변화와 원인을 저장했다.

### 범위와 재현 근거

- 제품 변경은 DWG reader의 검사 접근 범위, 두 DWG writer, Calibre 변환기이며 회귀 검사 두 파일을 포함해 소스·검사 **6개 파일**이다. 앞선 영상·PDF·SVG 구현은 이번에 수정하지 않았다.
- host SHA-256: `400cadf642ee016b20e20420507ce117770b16b9799b2d39de3e794627a910db`
- AVIF helper SHA-256: `012c4779dc3d787df48ea976ad43f0d718dd5c0810065f93732bafbc17d80145`
- 소스 962개 목록 digest: `c674f4815e66a9c889da712fb636760e2efa663149a410ea26ab623d37a897e1`
- `summarize.py`는 모든 최종 검사와 현재 소스의 일치, 단계별 실행·보호 파일 해시, 엄격 정책, 기존 보고서·연구 문서와 이번 회차 전 triage 289,845바이트 보존을 확인한다. `run-swift.py`·`check-replay.py`·`check-host.py`·`check-app-build.py`·`check-bundle-current.py`·`check-model-flow.py`를 새 label로 실행하며 과거 산출물을 덮어쓰지 않는다.
- 영상의 프레임 단위 올림과 초소형 MPG 길이 추정, PDF의 읽지 못하는 글자·150dpi 그림 렌더링, SVG의 보수적인 검색 글자 제외는 남아 있다. 이 회차는 그 한계를 해결한 작업이 아니다. PDF 성능 수치는 앞선 PDF·SVG 검토 시점의 기록을 유지하며 이번에 반복 측정하지 않았다.
- M2 Max/macOS 27에서 검증했다. AutoCAD·ODA 앱, 물리 M1/macOS 15, 외장 exFAT·SMB·권한, 실제 로그인/알림과 Developer ID 서명·공증은 미검증이다. 설치 앱 교체·커밋·푸시·공개 배포는 하지 않았다.


<a id="pdf-text-preservation-integration-2026-11-02"></a>
## PDF에서 읽지 못한 글자의 그림 보존 — 2026-11-02

PDFKit가 읽지 못한 글자를 그림층에서도 지워 버리던 경로를 수정했다. 근거는 `build/resume/pdf-text-preservation-20261029/`에 보존한다. 고정 PDFium의 글자 객체와 PDFKit가 남기는 단어의 선택 영역을 대조해, 텍스트로 남긴 글자만 그림에서 제외한다. 한 객체에서 일부만 추출되면 나머지 글자의 그림을 합성하고 중첩 폼 안도 처리한다. 다른 그림이 없는 페이지와 EPUB·FB2·HTMLZ·TXTZ·ODT의 텍스트 중간 경로에서도 누락될 글자가 보이면 그림을 보존하는 경로로 재계획한다.

PDFKit의 합자·태국어·힌디어 문자 묶음 뒤에서 `characterBounds`가 어긋나 페이지 끝 글자를 버리던 기존 문제도 확인했다. 글자 경계가 없으면 그 글자의 선택 영역을 사용해 버려지던 문자를 복구한다. TXT의 본문이 추가될 수 있으며, 합자 뒤의 단어 간격·배치 오차 전체를 해결한 것은 아니다. 세로 글자가 항상 사라진다는 앞선 설명은 부정확했다. PDFKit가 읽는 회전 글자는 종전처럼 재정렬된 텍스트로 남고, 읽지 못하는 글자를 그림으로 보존한다.

### 독립 검토와 보완

`review01/REVIEW.md`의 재현 파일로 큰 좌표를 Int로 바꾸다 엔진이 종료되는 새 경로를 확인해 범위를 검사했다. PDFium 글자 목록에서 생략된 줄 끝의 글리프도 객체 경계와 대조해 남긴다. 겹친 글자의 알려진 글자 영역을 지우면서 모르는 글자의 획까지 지우지 않도록 누락 글자의 실제 잉크 영역을 마지막에 복원한다. 줄바꿈에 붙은 결합 문자가 두 줄을 한 단어 선택 영역으로 묶는 문제를 막고, 본문에서 빠진 독립 악센트도 그림에 남긴다.

구현자의 초기 전체 검사·94건·성능·실문서 검증은 `full05`·`rich02`·`sweep03`에 보존돼 있으며, 독립 검토 후 보완된 소스의 검증과 구분한다. 검토자의 진단 빌드만 통과한 결과를 최종 엔진 검사로 세지 않는다.

### 최종 소스 검증

| 검사 | 결과 |
| --- | --- |
| `root-green02` | PDF **52개 통과**, 생략·실패 0개 |
| `root-full01` | 엔진 **812개(15 skip)·Core 18개, 실패 0개** |
| `root-candidate01` | 일반 Release host·AVIF helper 빌드 성공 |
| `root-rich01` | 실제 host **94건 통과**, 기존 그림·OCR·SVG·문서 경로와 새 글리프 보존 사례 |
| `review01/root-host01` | 큰 좌표 DOCX/EPUB·줄 끝 글리프 DOCX/EPUB·겹친 획·인접 객체·멀리 떨어진 악센트·독립 악센트, **8건 완료·원본 보존** |
| `root-replay02` | **822 completed / 27 failed**, harness·inspection 오류 0개, 이전 849건의 사례별 상태와 모두 일치 |
| `root-reference01`·`root-strict01` | 이전 출력 재판독과 새 출력 모두 **474 PASS / 241 WARN / 134 FAIL**, 사례별 판정 변화 0개 |
| `root-txt-sweep01` | 실제 PDF 27건 중 21건 완료·기존과 같은 6건 실패. 완료 20건의 TXT 바이트 동일, 힌디어 한 건은 U+093F 모음 기호 1개 추가·비공백 문자 삭제 0개 |
| `root-app01`·`root-model01` | 새 Debug 앱 빌드·ad-hoc 서명·Mach-O 15개 arm64·Homebrew 동적 링크/.NET 파일 없음; AppModel 파일 선택·옵션 저장·AMR 변환·취소·OGG 재시도·이력·원본 보존 통과 |
| `root-perf01` | 200쪽 PDF TXT 순차 5회 **0.684~0.747초**, 중앙값 **0.692초**, 모두 0.84초 목표 충족·기존 출력 바이트 유지; DOCX/EPUB 중앙값 각각 1.105/1.117초 |

전체 검사의 15개 생략은 기존 외부 corpus·기준선·표본 경로 미설정과 개발용 Pandoc/Ghostscript 부재에 따른다. 이번 PDF 회귀 검사는 생략하지 않았다. 실제 GUI 클릭·대화상자와 Xcode 호스트 XCTest를 실행한 결과는 아니다. 849건의 실패 27건은 기존 오디오 트랙 없음 14건·추출 가능한 글자 없음 6건·PDB 문자 손실 방지 거부 7건이다. 기존 엄격 FAIL을 이번 수정으로 해결했다고 세지 않으며 정책·임계값을 유지한다.

### 환경과 증거 보존

2026-11-02 현재 M2 Max/macOS 27.0.1·Xcode/SDK 27.2에서 검증했다. `root-green01`은 이전 SDK 27.0 헤더 경로가 남은 캐시 때문에 컴파일에서 실패했고, `root-scratch-20261102`의 새 빌드로 통과했다. 제품 코드 오류나 통과 검사로 세지 않는다. 처음 재변환 준비도 검사 도구의 없어진 Homebrew JPEG 3.2.0 경로에서 중단됐다. 현재 3.2.1 경로·해시를 `root-poppler-binding.json`에 기록하고, 저장된 이전 Swift 출력과 새 출력을 같은 현재 도구로 재판독했다. 이전 보고서와의 사례별 판정 차이도 없다. Homebrew 설치나 앱의 JPEG 코덱을 교체하지 않았다.

- host SHA-256: `2e96a3d23e1d98d27a17594565bed9b5537bceaef558829e7c0fa3cef65af741`
- 최종 소스 목록 digest: `35db0c6e72220384fc49b7e7844a31d8371f5adc2c9a7b181d6991a100953bbb`
- 제품·검사 변경은 PDF 관련 기존 5개 파일이며, root의 보완 이후 소스가 바뀌지 않은 상태로 빌드·검사했다. 위임 구현의 이전 검사나 검토자의 진단 결과와 최종 소스 결과를 구분한다.
- `root-summary.py`와 `root-evidence-summary.json`은 현재 소스·실행 파일·검사·원본·기존 산출물 보존과 상태/판정 비교를 확인한다. 이 회차 전 triage 299,706바이트는 그대로 보존했다. 기존 C#/.NET이나 이전 host를 실행하지 않고 저장된 이전 출력만 판독했다. 설치 앱 교체·커밋·푸시·공개 배포는 하지 않았다.

### 보존 범위와 한계

그림은 150dpi 픽셀이며 검색 가능한 문자 복원이나 새 OCR은 수행하지 않는다. 재배치되는 전자책에서는 해당 페이지 텍스트의 시작에 그림이 놓인다. 누락 글자가 있는 페이지의 원본 그림은 한 장의 렌더링으로 합쳐져 해상도·원본 바이트·투명도 보존이 제한될 수 있다. 기울어진 글자 영역이나 겹친 텍스트에서 위치만으로 글리프 대응을 판단하는 한계가 남는다. 겹친 획의 복원은 알려진 이웃 글자의 작은 픽셀 조각도 포함할 수 있다. PDFKit만 열 수 있고 PDFium이 열지 못하는 파일은 해당 리치 경로에서 오류가 날 수 있다.

텍스트 PDF 읽기는 유지하되 리치 출력에는 PDFium 대조 비용이 더해진다. 합자 뒤 배치·글자 전체의 의미 복원, 원본 그림의 무손실 보존, 모든 PDF의 시각적 동등성을 보장하지 않는다. 영상·SVG·DWG 외부 앱 호환성과 실제 GUI·물리 M1/macOS 15·외장/네트워크 저장소·권한·로그인/알림·배포 서명/공증은 이번 수정의 검증 범위 밖이다.


<a id="pdf-geometry-integration-2026-11-06"></a>
## PDF 기하·이미지 보존 후속 통합 검증 (2026-11-06)

검증 기록은 `build/resume/pdf-geometry-20261105/`에 있다. 2026-11-05 구현·성능 보완 후 사용자의 이동 요청으로 중지했고, 11월 6일 재개해 독립 검토의 세 지적을 root가 보완했다. `review02/REVIEW.md`와 제안 변경은 검토 당시 candidate03의 결과이며 최종 제품 검증과 구분한다.

### 최종 동작과 검토 반영

- 기울임·겹침의 누락 글자는 글리프별 프레임과 추출 단어의 글자 수로 대응한다. 호환 분해가 여러 글자인 한글 음절·말줄임표도 모두 소비해, 그 위의 Unicode 없는 도형 글자가 여분의 글자로 잘못 지워지지 않게 했다.
- 누락 글자 때문에 그림층을 추가하는 페이지에서는, 합성이 불필요한 일반 사진·표본 이미지만 원본 바이트·해상도로 분리한다. 마스크(`/SMask`, `/Mask`, `/SMaskInData`), 페이지 밖 영역과 다른 이미지와의 겹침을 검사한다. 스캔에서 클리핑·ExtGState·폼 또는 이미지 회전/반사/전단을 만나면 해당 페이지의 이미지 분리를 보수적으로 생략한다. 클립 경로·그래픽 상태를 새로 완전히 해석하는 구현은 추가하지 않았다.
- 180도 회전 페이지도 분리를 생략해 그림 위의 누락 글자와 사진을 한 합성에 유지한다. 기존의 180도 그림과 추출 텍스트 좌표 차이까지 고친 것은 아니다.
- `root-red01`은 candidate03 제품 코드에 새 검사 3개를 넣어 20개 assertion 실패를 재현했다. 최종 검사는 일반 읽기와 `allText` 양쪽에서 마스크·투명도·클리핑·페이지 밖 그림·겹침·숨겨진 이미지·행렬/투명도가 있는 폼·180도 합성의 실제 위치와 픽셀을 대조한다. 기존 JPEG 원본 바이트·표본 이미지 해상도 검사는 계속 통과했다.
- 소스·검사는 PDF 관련 기존 4개 파일만 이번 단계 시작과 다르다. PDFium API/header는 추가하지 않았다. 기존 pinned 소스·헤더를 재사용했고 새 라이브러리 문서 조회는 필요하지 않았다.

### 최종 소스에서 실행한 검증

| 기록 | 결과 |
|---|---|
| `root-green01` | PDF 61개, 실패 0개 |
| `root-full01` | 엔진 821개(기존과 같은 15 skip)·Core 18개, 실패 0개 |
| `root-candidate01` | 정상 Release 빌드, 캡처 소스와 현재 소스 일치 |
| `root-rich01` | 실제 리치/TXT 변환 142건 통과; 이전 candidate03과 텍스트·그림 유지 |
| `root-boundary01` | 기존 추가 경계 사례 25건 통과, 관찰 기록 유지 |
| `root-review-host01` | 검토 PDF 18개 × DOCX/EPUB 36건 완료; 한글·말줄임표 위의 빨간 누락 글자와 초록 대조군 모두 보존, 합성이 필요한 그림은 한 층 유지 |
| `root-txtsweep01` | 실제 PDF 27개 × TXT/DOCX/EPUB 81건, 완료 TXT 21건 모두 저장된 이전 출력과 바이트 동일·문자 삭제 없음; 기존 실패 12건(TXT 6건·DOCX/EPUB 6건)의 상태 유지 |
| `root-replay05` | 849건: 완료 822·실패 27, 모든 사례 상태 유지; harness·검사 오류 0 |
| `root-strict02` | 엄격 C# 비교 **474 PASS / 241 WARN / 134 FAIL**, 기존 134개 FAIL 집합 유지 |
| `root-app02`·`root-model02` | 새 Debug 앱 build-for-testing·ad-hoc 서명·arm64 Mach-O 15개·Homebrew 링크/.NET 없음·FFmpeg 고지 39개; 실제 AppModel 선택·옵션·AMR·취소·OGG 재시도·이력·원본 보존과 PDF→DOCX/EPUB의 400×400 원본 사진·45×45 글자 그림 확인 |
| `root-perf01` | 200쪽 TXT 5회 0.738~0.817초, 중앙값 0.754초, 모두 0.84초 이내·저장된 TXT 바이트 유지; DOCX/EPUB 중앙값 1.269/1.247초 |

사례별 판정 변화는 없다. 실패 27건은 기존 오디오 트랙 없음 14건·추출 가능한 텍스트 없음 6건·PDB 문자 손실 방지 거부 7건이다. 변환 완료와 C# 동등성은 구분한다. 849건의 기존 PDF 사례만으로 새 기하·합성 경계를 검증했다고 보지 않으며 별도 회귀 PDF와 검토 재현을 포함했다.

### 환경·실행 파일·보존

- 최종 host SHA-256: `abc27a9a80916fd98274225ce918ca40376b82ddc8ba104f6dac522da735d2a3`
- 최종 소스 목록 digest: `627ae856459fe61ef1668d7015f6c7540d2b8cd0c0dc9e77011b2cc00c9bcd0a`
- M2 Max/macOS 27.0.1, Xcode/SDK 27.2·Swift 6.4.2. 각 실행은 별도 HOME/TMP·최소 PATH와 `isolated.sb` 한 층을 사용했다. 소스·실행 파일·원본·기존 산출물 해시를 전후 대조했다.
- 최초 root 재변환 준비(`root-replay01`)는 삭제된 검사 도구 NSS 3.132 경로에서 host 실행 전 중단됐다. 현재 NSS 3.133 네 라이브러리만 경로·해시를 갱신했고 나머지 판독기 binding은 유지했다. `root-inspection-change.json`에 경위를 기록했다. 11월 6일 준비(`root-replay03`·`root-replay04`·`root-reference02`)도 삭제된 HarfBuzz 15.0.0_1 경로에서 host 실행 전에 중단됐다. 격리 환경의 라이브러리 목록 수집을 보완해 실제 로드 목록에서 15.1.0 두 라이브러리만 추가 갱신했다. `root-tool-binding-20261106/`에 전체 로드 목록과 전후 해시를 보존했다. `root-reference03`은 저장된 이전 Swift 출력을 같은 현재 도구로 다시 판독한다. 앱 라이브러리 설치나 비교 임계값 변경은 하지 않았다.
- 위임 구현의 candidate02·candidate03, 초기 성능 미달 `perf01`과 미채택 실험도 그대로 보존한다. 최종 root 소스의 검증은 위 표의 새 기록이며 이전 버전의 결과를 대신 세지 않는다.
- `root-summary.py`·`root-evidence-summary.json`이 최종 캡처와 검사 연결을 검증한다. 이 회차 전 triage 306,689바이트를 그대로 보존하고 이 절만 덧붙였다. 기존 C#/.NET 또는 이전 host 실행 없이 저장된 출력만 비교했다. 기존 dirty 변경은 보존했으며 설치·커밋·푸시·공개 배포는 하지 않았다.

### 남은 한계

그림은 150dpi 픽셀이며 OCR이나 편집 가능한 글자 복원이 아니다. 전자책에서는 그림이 해당 페이지 텍스트 앞에 놓인다. 보수적 합성 경로의 이미지에는 리샘플링이 남고, 그림층을 추가하지 않는 일반 이미지 추출 경로에는 기존 마스크·클리핑·배치 한계가 남는다. 겹친 획·stroke 모서리의 작은 글자 조각 중복, 합자 뒤 배치와 180도 텍스트/그림 프레임 차이는 별도다. PDFKit은 읽지만 PDFium이 읽지 못하는 파일의 리치 변환 오류도 여전히 가능하다. 모든 PDF의 시각적 동등성을 보장하지 않는다.

실제 GUI 클릭·대화상자 및 Xcode 호스트 XCTest 실행, 물리 M1/macOS 15, 외장/네트워크 저장소·TCC·로그인/알림·Developer ID 서명/공증과 영상·SVG·DWG 외부 앱 호환성은 이번 검증 범위 밖이다.

<a id="unreachable-targets-2026-11-06"></a>
## 엄격 FAIL 134건 재분류, 결과가 나올 수 없는 대상 제외와 OCR — 2026-11-06

근거는 `build/resume/quality-routes-20261106/`다. 직전 `root-strict02`의 FAIL 134건을 사례별로 다시 분류했다. 1단계에서는 실패 27건 중 원본에 없는 내용을 요구해 항상 실패하던 19건을 경로 계획에서 제외했고, 2단계에서는 사용자 요청에 따라 macOS Vision 글자 인식(OCR)을 PDF→TXT에 더해 그림·만화의 TXT를 다시 허용했다. 비교 임계값·판독 정책은 바꾸지 않았고 과거 C#/.NET·이전 host를 실행하지 않았다.

### FAIL 134건의 원인

| 원인 | 건수 | 판단 |
| --- | ---: | --- |
| C#은 실패, Swift는 완료 | 43 | 개선. 출력 43개를 열어 오디오·영상 코덱과 길이, 그림 크기, ZIP 무결성과 포함 그림, FB2 그림, PML 본문, AZW3 헤더를 확인했다. |
| 저속·정지 영상의 프레임률 | 30 | 의도한 수정. C#은 정지 그림 0.1초를 0.05초처럼 잘랐고, Swift는 마지막 프레임 표시 시간을 지키는 방송 프레임률을 쓴다. |
| PDB 한글 거부 | 7 | 의도한 거부. C#은 한글을 `?`로 바꿔 저장했다. |
| 슬라이드 글자 보존 | 6 | 개선. C# 출력에서 빠진 원문 문장이 남는다. |
| 2026-10-29 기존 48건 | 48 | Calibre 생성값 35·앞선 보존 개선 9·끝 줄바꿈 1·리소스 순서 1·DWG 2 ([사례별 장부](#legacy-quality-loss-verification-2026-10-29)) |

Swift가 C#보다 나빠진 사례는 이 집합에서 찾지 못했다. WARN 중 이미지 투명도·DPI·색 모델 메타데이터 차이 28건은 GIF 팔레트 1건(PSNR 35.7dB, SSIM 0.997)을 빼면 모두 PSNR 50dB 이상이다. 사례별 분류는 `fail134-classification.json`에 있다. 비교기가 측정하지 않는 화면 배치·외부 앱 호환성까지 동등하다는 뜻은 아니다.

### 결과가 나올 수 없는 대상

변환 가능 대상 목록이 그림·PDF·SVG·CAD에 오디오 형식 18개를, 그림·영상·만화(CBZ 등)에 TXT를 표시했다. 정지 영상을 거치는 오디오에는 소리가 없고, OCR이 없던 때는 그림에서 만든 PDF에 추출할 글자가 없어 항상 실패했다. C#도 같은 대상을 표시했으며 849건 중 오디오 14건과 TXT 5건이 여기에 해당했다.

`RoutePlanner.plan`은 원본 형식 분류로 두 경우의 경로를 만들지 않는다. 오디오 출력은 영상·오디오 원본에서만 만들고, 영상의 TXT는 정지 프레임 하나의 글자 인식이 되므로 만들지 않는다. 홈 화면 형식 목록과 원형 메뉴는 이 대상을 기존 이유("이 변환을 할 수 있는 엔진이 없어요")와 함께 비활성화하고, 작업 큐는 변환을 시작하지 않고 `error.no_route`로 끝낸다. 1단계에서는 그림·만화의 TXT도 제외했으나 2단계의 OCR로 다시 허용했다. 소리가 없는 영상의 오디오 추출, 글자 층과 인식할 글자가 모두 없는 PDF·그림의 TXT처럼 파일 내용에 따라 실패하는 경우는 읽기 전에는 알 수 없어 기존 오류를 쓴다.

### Vision 글자 인식(OCR)

`PdfTextConverter`는 글자를 추출할 수 없는 페이지(스캔, PDF 페이지로 만든 그림·만화)를 PDFium으로 300dpi, 긴 변 4,000px 이하로 렌더링해 `RecognizeTextRequest`(정확도 우선)로 읽는다. 네 페이지까지 동시에 처리한다. 인식한 줄을 공백 단위 단어 상자로 나눠 기존 줄·문단·2단 읽기 순서·머리말 제거 처리에 넣으므로 "English가"처럼 붙은 단어가 분리되지 않는다. 같은 문단 안에서도 줄 상자 높이가 몇 pt씩 달라 페이지 중앙값의 ±25% 안은 같은 크기로 본다. 글자가 있는 페이지와 기존 OCR 글자 층은 그대로 추출하므로, 글자 PDF의 TXT 출력은 이전과 바이트까지 같다. EPUB·FB2·HTMLZ·TXTZ·ODT처럼 페이지 그림을 담는 출력은 기존처럼 그림 경로로 재계획하고 인식 글자를 더하지 않는다.

인식 언어는 macOS 언어 순서 중 Vision이 지원하는 언어이며 한중일 언어를 앞에, 영어를 끝에 둔다. Vision은 첫 언어의 문자 모델만 쓴다. 한국어 모델은 영어를 읽었지만 일본어 페이지는 잘못 읽었고, 영어 모델은 한글을 하나도 읽지 못했다. 자동 언어 감지는 첫 사용이 20~43초였고 영어가 많은 페이지의 한글 줄을 놓쳐 쓰지 않았다. 최소 글자 높이는 기본값(이미지 높이의 1/32)에서 6~8pt 글자를 틀렸고, 0.005 이하에서는 확대된 11pt 스캔을 틀려 0.01로 정했다. 시험 이미지 4종을 원래 크기와 1.5배로 읽은 8개 조합 중 확대하지 않은 200dpi 시험 페이지의 한 줄("tollows")만 틀렸다. 새 실행 파일의 첫 인식은 시스템이 모델을 준비하느라 20~45초 걸린 사례가 있었고, 이후 같은 6쪽은 2.01초였다. 이 지연의 정확한 조건은 확인하지 못했다.

한글·영어·일본어가 섞인 README.ko.md를 0.4° 기울이고 종이 잡음을 넣은 300dpi A4 6쪽으로 만들어 TIFF→TXT로 변환했다. 단어 재현율 96.5%, 정밀도 94.3%, 공백을 뺀 글자 유사도 97.6%다. 일본어 "日本語"는 한국어 모델에서 읽지 못했고, 가운데점 "·"는 "•"로 바뀌었다. 글자 단위로 줄이 바뀐 한글 단어는 기존 PDF 텍스트 경로와 같이 줄 끝을 공백으로 이어 "메 뉴의"처럼 된다.

### 검증

| 기록 | 결과 |
| --- | --- |
| `red01`·`green01`·`full01` | 1단계: 규칙을 끈 소스에서 assertion 15개 실패, 집중 검사 20개 통과, 전체 엔진 822개(15 skip)·Core 18개 실패 0개 |
| `replay01`·`strict01` | 1단계: 849건 822 완료·27 실패, 상태가 바뀐 사례는 19건(`state-delta.json`), 엄격 비교 457 PASS / 239 WARN / 153 FAIL |
| `ocr-red01`·`ocr-green03` | 최소 높이 설정을 뺀 소스에서 스캔 순서 검사 실패, 되돌린 소스에서 OCR·경로 계획 13개 통과 |
| `ocr-pdf01` | PDF·만화·벡터 관련 128개 통과(Ghostscript 없음 3 skip) |
| `full03` | 전체 엔진 827개·Core 18개 실패 0개. 생략 17개 중 2개는 높은 시스템 부하로 AVIF helper 시작이 늦어 생략됐고, 같은 환경의 `avif-rerun01`에서 21개 모두 통과 |
| `replay02` | 849건 822 완료·27 실패, harness·검사 오류 0. 수정 전과 상태가 다른 사례는 오디오 14건·영상→TXT 1건뿐이며 나머지 834건은 상태·오류 키·출력 이름이 같다(`state-delta-ocr-vs-before.json`) |
| `strict02` | 엄격 C# 비교 460 PASS / 240 WARN / 149 FAIL. 수정 전 대비 PASS→FAIL 15건은 위 사례, WARN→PASS 1건은 RB→ODT의 Calibre 표지 변동 |
| `before.txt`·`after.txt` | 1단계 대표 입력 15개의 대상 목록 차이. 2단계에서 그림·만화의 TXT는 다시 허용 |

엄격 비교의 FAIL 증가 15건은 C#이 변환을 시도한 뒤 `error.conversion_failed`로, Swift가 시작 전에 `error.no_route`로 끝나 오류 키가 달라진 사례다. 바이트가 다른 기존 출력 304개 중 표본으로 연 ZIP 계열은 압축 시각만, EPUB은 문서 UUID·수정 시각만 달랐다. 수정 전 replay와 비교해 2단계에서만 바이트가 달라진 LIT→SNB·TCR→SNB는 PDF를 거치지 않는 Calibre 무작위 표지다. 실행 파일 SHA-256은 `candidate01/sha256.txt`·`candidate02/sha256.txt`에 있다.

### PDB 저장 제거, 누운 페이지, 다른 OCR 엔진 — 2026-11-06~10

**PDB.** PalmDoc은 Windows-1252 글자만 담아 한글을 저장할 수 없으므로 PDB를 읽기 전용으로 바꿨다(`FormatRegistry`, `CalibreConverter.outputs`). PDB를 대상으로 저장해 둔 프리셋은 `Validation.retiredTargets`로 유효성 검사를 통과해 목록에 남고 사용할 수 없음으로 표시된다. `replay03`에서 상태가 바뀐 사례는 PDB로 저장하던 7건(`error.conversion_failed` → `error.no_route`)뿐이고, `strict03`은 459 PASS / 243 WARN / 147 FAIL이다(직전과 다른 3건은 Calibre 무작위 표지).

**누운 페이지.** Vision은 90°·180°·270° 돌아간 페이지의 글자도 읽고 줄의 네 꼭짓점을 글 방향대로 준다. 이전에는 이미지 좌표를 그대로 배치 단계에 넣어 글 순서가 무너졌다. `TextRecognition.lines`는 줄마다 글 방향을 글자 수로 가중해 페이지의 회전을 정하고 상자를 바로 세운 페이지 좌표로 바꾼다. README.ko.md 1쪽 스캔의 단어 순서 일치는 180°에서 0.08 → 0.88, 90°에서 0.13 → 0.90이며 바로 선 페이지는 0.89 그대로다. 6쪽 스캔의 단어 재현율 96.5%·정밀도 94.3%도 그대로다. 한 페이지 안에서 방향이 다른 일부 줄(세로 라벨)은 페이지 방향을 따른다.

**다른 엔진.** 같은 시험 페이지로 쟀고 제품에는 넣지 않았다.

| 엔진 | 한국어 6쪽 스캔 단어 재현율 | 한·일·중·영 혼합 페이지 | 누운 페이지 | 비고 |
| --- | ---: | --- | --- | --- |
| Vision `RecognizeTextRequest` (사용 중) | 96.5% | 첫 언어의 문자만 | 읽음(위 수정) | 쪽당 약 0.33초, 줄·단어 위치 제공 |
| VisionKit Live Text | 95.9% | 네 언어 모두 읽음 | 읽음 | 6쪽 5.7초, 위치 없이 글만 제공 |
| Vision `RecognizeDocumentsRequest` (macOS 26+) | 재지 않음 | 언어를 지정하면 일·중 문단이 빠짐 | 자동 언어에서 줄 누락 | 자동 언어 첫 호출 44초 |
| RapidOCR 3.10 · 한국어 PP-OCRv5 mobile | 52.3% | 영어 줄만 | 순서 무너짐(글자 유사도 0.11~0.14) | 6쪽 8.0초, Python·onnxruntime 약 280MB |
| RapidOCR 3.10 · 기본 PP-OCRv6 다국어 | 6.1% | 일·중·영만, 한글 누락 | 재지 않음 | |

RapidOCR은 mobile 모델만 쟀고 server 모델과 Tesseract는 재지 않았다. 한국어 정확도·속도·배포 크기 모두 Vision이 앞서 엔진을 바꾸지 않는다. 한 페이지에 한중일 문자가 섞인 문서는 Live Text만 모두 읽었지만 위치를 주지 않아 2단 읽기 순서·머리말 제거에 쓸 수 없으므로 적용하지 않았다.

| 기록 | 결과 |
| --- | --- |
| `pdb-green02`·`replay03`·`strict03` | PDB: Calibre 18개 통과, 849건 중 7건만 상태 변경 |
| `turn-red01` | OCR 검사 7개 통과(누운 세 방향의 TXT가 바로 선 페이지와 같음) |
| `full04`·`calibre-rerun04` | 전체 엔진 828개(15 skip)·Core 18개. 이전 실행의 fixture 폴더를 재사용해 Calibre 3개가 실패했고, 새 폴더에서 Calibre 18개 모두 통과 |
| `app02-build.log` | 격리 환경 Xcode `build-for-testing` 성공 |

### 영상·오디오의 TXT: 음성 받아쓰기 — 2026-11-10

남은 실패 27건을 원본 앱 기록(`baseline-lo/run-optional`)과 대조했다. PDB 7건을 뺀 20건은 C#에서도 실패했다(오디오 트랙 없음 14, 글자 없음 6). 그림·PDF의 오디오와 글자 없는 그림의 TXT는 원본에 내용이 없어 해결할 수 없고, 영상의 TXT만 말소리 받아쓰기로 해결할 수 있었다.

`FfmpegConverter`는 영상·오디오 → TXT에서 소리를 16kHz 모노 WAV로 뽑아 `SpeechText`(Speech 프레임워크의 `SpeechAnalyzer`·`SpeechTranscriber`, macOS 26 이상, 기기 내 처리)로 받아쓴다. 쉬는 구간으로 나뉜 발화마다 한 줄이다. 언어는 macOS 언어 순서에서 지원하는 첫 언어이고 모델이 없으면 시스템이 내려받는다. `RoutePlanner`는 이 경로를 영상·오디오 원본이 TXT를 직접 요청할 때만 쓰고, 영상의 PDF→TXT(정지 프레임 OCR)는 계속 만들지 않는다. 영상 → DOCX·HWPX 등은 이전처럼 정지 프레임 그림이다. macOS 15에서는 경로가 없다.

`say`로 만든 한국어 음성과 그 음성을 넣은 MP4는 문장 3개 중 한 단어("변환 앱" → "편한 랩")만 틀렸다. 한국어 Mac에서 영어 음성은 틀린 글자로 나왔다(언어 하나만 듣는다). 849건의 MXF 시험 영상은 말소리가 없어 `error.no_route`에서 "No speech was recognised" 오류로 바뀌었고, `replay04`에서 직전과 다른 사례는 이 1건뿐이다(822 완료·27 실패, harness·검사 오류 0). 누운 페이지 수정도 이 실행에 포함된다. 자막 트랙 추출, 화자 구분, 시간 표시는 하지 않는다. 언어 모델이 없는 Mac의 첫 다운로드는 시험하지 못했다.

지원하지 않는 변환과 이유는 README의 "지원하지 않는 변환" 절에 표로 적었다.

### 남은 실패와 한계

849건 실패 27건은 경로 없음 21건(그림·PDF의 오디오 14, PDB 저장 7), 말소리 없는 영상→TXT 1건, 글자 층도 인식할 글자도 없는 그림·스캔 PDF→TXT 5건이다(시험 입력은 96×64 그라디언트 그림). OCR은 세로쓰기, 기울어진 페이지(90° 단위 회전은 읽는다), 손글씨, 글자가 있는 페이지 안의 스캔 영역, 첫 언어와 다른 한중일 문자를 보장하지 않으며 표를 표로 복원하지 않는다. 한글 PDB 저장, 849건 비교 범위 밖의 SVG 글자 배치, PDF 미추출 글자의 150dpi 그림, AutoCAD·ODA에서 DWG를 여는 검증, 실제 GUI 클릭과 배포 서명·공증도 남아 있다. 설치 앱 교체·커밋·푸시는 하지 않았다.
