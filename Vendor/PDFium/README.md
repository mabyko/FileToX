# PDFium in FileToX

PDF rasterization uses **PDFium 147.0.7690.0**, the exact build used by the old C# helper:
Filee pins PDFtoImage **5.2.1**, whose macOS dependency is bblanchon.PDFium.macOS **147.0.7690**.
The installed C# helper's `.deps.json` confirms both versions. The arm64 executable `__text` section
of this release, its universal slice, and the installed dylib is identical (SHA-256 of `otool -s
__TEXT __text` rows: `ad4bf12d44c5822760723a8c9597179d94811300be148eb153b9144c95046792`).

## Provenance

- Release: <https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F7690>
- Checked-in asset: <https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7690/pdfium-mac-univ.tgz>
- Archive SHA-256: `e6252b865c6c7dda8c6d69ebb299b0cb54243172a0304f026bd25203c41a17db`, verified against
  the release asset's GitHub API `digest`, before extraction.
- Cross-check asset: <https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7690/pdfium-mac-arm64.tgz>,
  SHA-256 `0617e90556273ebe484d5f4a9981f366e10b4874f997896a4d27fe87d3c71ecf`, also verified against GitHub's digest.
- PDFium source branch: `chromium/7690`, <https://pdfium.googlesource.com/pdfium/+/refs/heads/chromium/7690>.
- `include/`, `VERSION`, `args.gn` are unmodified release files. `CPDFium.c` and `include/module.modulemap`
  are FileToX glue (MIT). PDFium is BSD-3-Clause; the binary packaging is MIT. The complete archive licences,
  including all bundled third-party notices, are in `docs/upstream/PDFium.LICENSE` and
  `docs/upstream/PDFium.THIRD-PARTY-NOTICES.md` and ship in the helper's `Contents/Resources/Notices`.
- No V8, JavaScript or XFA (`args.gn`); no .NET or Skia dependency.

The sole dylib modification is `install_name_tool -id @rpath/libpdfium.dylib`, followed by ad-hoc signing.
Checked-in dylib SHA-256: `e09fa5c6c9ac1baa56b6e8b25257eb402f644312d983d3e23b714e4de1e80079`.
Both macOS arm64 and x86_64 slices are retained. The app builds one native architecture at a time,
with macOS 15 deployment (`project.yml`). No PDFium downloads or generation occur at build time.

## Build and embedding

SwiftPM's `CPDFium` C target imports the public headers and links the vendored dylib with an absolute
repository rpath, so `swift build`, `swift test` and the helper work directly from a checkout. Relocating
that command-line build requires this library path or an equivalent rpath; use the Xcode app for distribution.
Existing libwebp/libjxl Swift package dependencies still need their ordinary first-time package resolution.

XcodeGen imports the same module in EngineKit and explicitly links, embeds and code-signs the dylib in
`FileToXEngine.app/Contents/Frameworks` and in the engine test bundle. Their rpaths use the executable/loader's
`../Frameworks`, without a vendor-source rpath. Xcode also injects a Debug package-products rpath;
PDFium loads from the embedded library, verified after relocating the helper to `/tmp`.
Xcode signs nested code before signing the helper. The staging
script copies PDFium's licences alongside LibRaw's. Regenerate with `xcodegen generate` after project edits.

## Rendering contract

`Sources/Engine/Engines/Pdf/PdfiumDocument.swift` follows the audited
[PDFtoImage v5.2.1 source](https://github.com/sungaila/PDFtoImage/tree/v5.2.1/src/PDFtoImage)
(`Conversion.GetRenderFlags`, `Internals/PdfFile`, `Internals/PdfDocument.RenderSubset`):

- One process-wide lock covers initialization, document/page/form/bitmap calls and teardown.
- Load the original PDF bytes, no PDFKit reserialization. PDFium determines page count, crop/media intersection,
  and intrinsic rotation using `FPDF_GetPageSizeByIndex`.
- Convert page dimensions to Float; multiply by `Float(dpi) / 72`. Truncate bitmap dimensions to integers;
  **ceil** the native drawing rectangle. Rotation argument is 0 (intrinsic rotation is handled by PDFium).
- `FPDFBitmap_BGRA` (4), premultiplied BGRA8888, 4×width stride; opaque white `0xFFFFFFFF` fill.
- Only `FPDF_ANNOT` (1) is set: no LCD_TEXT, grayscale, print flags or NO_SMOOTH flags. All default antialiasing stays on.
- Form-fill environment version 1, zero callbacks; highlight color `0xFFE4DD`, alpha 100; load text page,
  `FORM_OnAfterLoadPage`, render, remove highlight, `FPDF_FFLDraw`, `FORM_OnBeforeClosePage`, close text/page.
- No explicit bounds, tiling, additional rotation, aspect-ratio or DPI-relative-to-bounds options.
- Copy pixels before destroying the bitmap; label them sRGB without resampling. Existing image encoders handle
  the output format/DPI, and existing `open(2)`-based writes preserve NFC names.

All raster routes share this code: PDF images, PDF comic pages, scans and fallback image crops in PDF document
reading. PDFKit remains for text/layout extraction and PDF page editing/merging, which used PdfPig/PDFsharp in C#.

## Updating

Choose an upstream build deliberately: a new PDFium version can change pixels. Download into a temporary directory,
verify its release digest, replace the public headers and universal dylib, update VERSION/args.gn and **all** notices,
apply the install-name/signature change, update hashes/version here and in Swift, and run both build systems plus the
43-case differential replay. Keep the retained C# pixel fixture unchanged unless the rendering contract changes.
