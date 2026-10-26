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
