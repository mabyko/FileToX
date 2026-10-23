# libjpeg-turbo in FileToX

FileToX writes JPEG with libjpeg-turbo so the files are the same as the C# helper's, which wrote JPEG through
Magick.NET 14.17.2 (ImageMagick 7.1.2-32 Q8, libjpeg-turbo 3.2.0). LibRaw uses the same library to decode lossy
DNG and Kodak JPEG RAW files.

| | |
| --- | --- |
| Version | libjpeg-turbo 3.2.0 (`strings` of the C# helper's `Magick.Native-Q8-arm64.dll.dylib`: "libjpeg-turbo version 3.2.0") |
| Source | <https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz> (official release tarball) |
| SHA-256 of the tarball | `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e` (the digest GitHub publishes for the release asset) |
| Cross-check | Every vendored file is byte-identical to the GitHub tag `3.2.0` (<https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.2.0.tar.gz>, SHA-256 `980dd81f425082aa6d7c9e47fef27554ce7a9ffc8e2f6e863b97d263c5c50858`) |
| Licence | IJG License (`README.ijg`) for the libjpeg API library FileToX compiles; `LICENSE.md` explains the licences of the whole project |
| Bundled notices | `docs/upstream/libjpeg-turbo.LICENSE` and `docs/upstream/libjpeg-turbo.THIRD-PARTY-NOTICES.md`, copied into the helper's `Contents/Resources/Notices` |

## What is here

- From the release, unmodified: `LICENSE.md`, `README.ijg`, `README.md` and, from `src/`, exactly the files the
  libjpeg API library (`jpeg-static`) compiles or includes: the `JPEG_SOURCES` of `CMakeLists.txt` with arithmetic
  coding (`jaricom.c`, `jcarith.c`, `jdarith.c`), their `src/wrapper/*-{8,12,16}.c` precision wrappers, the sources
  and headers those include, and the `jconfig.h.in`, `jconfigint.h.in`, `jversion.h.in` templates.
- Removed from the release: everything else (CMake, `simd/`, the TurboJPEG API, `cjpeg`/`djpeg`/`jpegtran` and the
  other programs with their readers and writers, libspng, zlib, tests, test images, fuzzers, Java, packaging and
  documentation).
- `FileToX/`: FileToX's files, not part of libjpeg-turbo (MIT, like the rest of FileToX). `config/` holds the three
  headers CMake would generate from the templates for this build. `encode.c` repeats ImageMagick's
  `coders/jpeg.c` `WriteJPEGImage_` with Filee's settings; `include/` is the Clang module `CJpegTurbo` Swift imports.
- `Package.swift`: the local Swift package that builds the `CJpegTurbo` library from these files.

## Build

`CJpegTurbo` is built from source by SwiftPM: the root `Package.swift` depends on this folder as a local package,
and Xcode consumes the root package through `project.yml`:

- The `JPEG_SOURCES` of upstream's CMake build, 8-, 12- and 16-bit, with arithmetic coding, `JPEG_LIB_VERSION` 62
  (upstream's default), in-memory source and destination managers.
- No SIMD (`WITH_SIMD` undefined): the build needs no NASM or GAS, and the C code paths give the same files as the
  C# helper's ImageMagick. Measured: 90 encodings (six pictures × 15 qualities, gray and colour) and the C# helper's
  video-frame JPEGs are byte-identical.
- Cost (2026-10-23, Apple silicon, clean `swift build -c release --product FileToXEngine` with packages already
  fetched): 124 s → 126 s; the helper executable grows by 466 KB (12.30 → 12.77 MB) including LibRaw's JPEG paths.

## Updating

Download the new release into an empty folder, check it against the GitHub tag, replace the vendored files with the
same subset (follow `JPEG_SOURCES` in the new `CMakeLists.txt` and the files they include), regenerate
`FileToX/config` from the templates, update this file and the notices, and compare JPEG output with the C# helper's
ImageMagick (see `Tests/Engine/Images/JpegEncoderTests.swift`).
