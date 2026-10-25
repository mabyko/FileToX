# FileToX native SVG raster bridge

This is an arm64 **static** library for Apple Silicon Macs (M1 or later) running
macOS 15 or later, with one exported C function, `ftx_svg_render`.
The engine admits only a conservative DOM/attribute capability set in
`Sources/Engine/Engines/Vector/NativeSvgRasterizer.swift`. Text, CSS, resources,
references, gradients, filters, transforms and other SVG features retain CoreSVG.
PDF always uses CoreSVG. This intentionally solves primitive stroke raster quality
without replacing the complete SVG renderer.

The caller owns a tightly packed RGBA8 premultiplied sRGB buffer. All pointers are
borrowed synchronously; no memory or callback is retained. The bridge validates
input/buffer/geometry limits, catches C++ exceptions, and checks cancellation
before and after parsing and between recorded drawing commands using SkPicture's
abort callback. Parsing, recording and a single drawing command remain synchronous;
cancellation discards the result before any output is committed. The default null
resource provider cannot read network or local resources. Swift retains existing
SVGZ decompression, viewport resolution, raster scaling/limits and fallback.

## Provenance and build

- rust-skia binary release **0.153.3**, CPU-only feature key **b7f043e0b1e2a850e702**.
- Matching Skia source/headers **m153-0.101.2**; headers are unmodified. Exact URLs,
  header hashes, upstream archive hashes and compilation flags are in
  `PROVENANCE.json`.
- The release's arm64 static archive is checksum verified. Only
  `libsvg`, `libskshaper`, `libskresources`, `libskia`, `libskunicode_icu`
  and `libskunicode_core` enter the partial link.
  No installed app, SkiaSharp/.NET binary or home runtime is used.
- A partial static link followed by `nmedit -s` localizes all implementation
  symbols, including parser/font/codec symbols, before making the arm64
  archive. Only `_ftx_svg_render` remains external. This prevents coupling to the
  engine's libjpeg-turbo, libwebp, Brotli or other native dependencies.
- Minimum macOS 15, C++20, `-O2 -DNDEBUG -DSK_BUILD_FOR_MAC`; public bridge types
  use C scalar/pointer types only. No C++ ABI crosses into Swift.
- The checked-in archive was thinned with `lipo -thin arm64` from FileToX's
  previous universal bridge. The arm64 archive bytes are unchanged;
  `PROVENANCE.json` records the previous output hash and size and the current
  thin output hash and size. This derives a FileToX output, without modifying
  the pinned upstream archive, headers or notices.

Rebuild on macOS with Xcode's command-line tools and Python 3:

```sh
python3 Vendor/SkiaSVG/build.py
```

Downloads/extraction/build outputs stay in `build/skia-svg` (override with
`--cache PATH`). No global install, source sync or large Skia compilation occurs.
The script verifies hashes, header provenance, exports and the thin arm64 archive,
then links and executes the arm64 C self-check without requiring dead stripping.
Run it on Apple Silicon; Intel and Rosetta are outside the build and validation
scope. Source archives and their licenses are not fetched from the old C# app.

## Distribution

`lib/libFileToXSvg.a` is linked into the helper through `Package.swift`; it needs
no dylib, runtime path, copy phase or separate code signature. Keep the engine's
Swift resource bundle: `Skia.LICENSES.txt` is copied into it by the package and
contains the upstream Skia and third-party notices with pinned source URLs.
The root notice file is `Sources/Engine/Engines/Vector/Skia.LICENSES.txt`; it includes
conservative notices for the complete upstream codec/parser/font feature set,
even when the linker does not retain all those objects. No upstream source was
modified; `FileToX/bridge.cpp` is the new adapter.
