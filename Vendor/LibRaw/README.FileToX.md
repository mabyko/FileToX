# LibRaw in FileToX

FileToX develops camera RAW with LibRaw so the colours are the same as in the C# helper, which read RAW through
Magick.NET 14.17.2 (ImageMagick 7.1.2-32 Q8, LibRaw 0.22.2-Release).

| | |
| --- | --- |
| Version | LibRaw 0.22.2-Release |
| Source | <https://www.libraw.org/data/LibRaw-0.22.2.tar.gz> (official release tarball) |
| SHA-256 of the tarball | `de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa` |
| Cross-check | Every vendored file is byte-identical to the GitHub tag `0.22.2` (<https://github.com/LibRaw/LibRaw/archive/refs/tags/0.22.2.tar.gz>, SHA-256 `627928088300ecde6ca91ffd202e189203f04ad61ad12f0fe9dc57b9a7a0fb3c`) |
| Licence | LibRaw is dual-licensed LGPL-2.1 / CDDL-1.0. **FileToX uses it under CDDL-1.0** (`LICENSE.CDDL`). `LICENSE.LGPL` is kept only because LibRaw's notices refer to it. |
| Bundled notices | `docs/upstream/LibRaw.LICENSE` (CDDL-1.0) and `docs/upstream/LibRaw.THIRD-PARTY-NOTICES.md` (COPYRIGHT, dcraw, DCB/FBDD, X3F tools, Adobe DNG SDK), copied into the helper's `Contents/Resources/Notices` |

## What is here

- From the release, unmodified: `libraw/` (public headers), `internal/`, `src/`, `COPYRIGHT`, `LICENSE.CDDL`,
  `LICENSE.LGPL`, `README.md`.
- Removed from the release: everything else (the autotools, qmake, Visual Studio and make build files, `samples/`,
  `doc/`, `RawSpeed/`, `RawSpeed3/`, `GoPro/`, `bin/`, `lib/`, `object/`, `buildfiles/`, `m4/`, `Changelog.txt`,
  `CONTRIBUTING.md`, `INSTALL` and the `README.*` files other than `README.md`) and, from `src/`, `src/Makefile` and the
  placeholder sources that would clash with the real ones
  (`src/postprocessing/postprocessing_ph.cpp`, `src/preprocessing/preprocessing_ph.cpp`, `src/write/write_ph.cpp`,
  which ImageMagick's own LibRaw build excludes as well).
- `FileToX/`: FileToX's shim, not part of LibRaw (MIT, like the rest of FileToX). `develop.c` repeats ImageMagick's
  `coders/dng.c` call sequence with Filee's read defines: `libraw_open_file` → orientation from `sizes.flip` →
  `libraw_unpack` → parameters (`max_raw_memory_mb` 8192, `user_flip` 0, `output_bps` 16, `use_camera_wb` 1,
  `use_auto_wb` 0, `no_auto_bright` 0, `output_color` 1 = sRGB, `user_qual` 3 = AHD) → `libraw_dcraw_process` →
  `libraw_dcraw_make_mem_image` → 16 → 8 bits as `(v + 128) / 257` (ImageMagick Q8 `ScaleShortToQuantum`).
  `include/` is the Clang module `CLibRaw` that Swift imports.

## Build

Built from source as the `CLibRaw` target of the root `Package.swift` (Xcode consumes that package through `project.yml`; there is no separate Xcode target):

- Defines: `LIBRAW_NODLL`, `USE_ZLIB` (deflate-compressed DNG; links the system `libz`), `USE_JPEG` (lossy-JPEG DNGs
  and old Kodak JPEG RAWs, decoded by the same libjpeg-turbo 3.2.0 as in ImageMagick, `Vendor/libjpeg-turbo`; its
  headers come from `src/` and `FileToX/config/` there).
- Not defined: `LIBRAW_NOTHREADS` (that build keeps decoder state in statics; FileToX converts files in parallel),
  `USE_X3FTOOLS` (Sigma X3F; `src/x3f/` compiles to nothing, like in ImageMagick's build), OpenMP, LCMS, RawSpeed,
  DNG SDK, GPR SDK.
- LibRaw's own warnings are silenced for this target only (`-w`).

## Updating

Download the new release into an empty folder, check it against the GitHub tag, replace `libraw/`, `internal/`,
`src/` and the licence files, delete the files listed above again, update this file and the notices, and run the RAW
differential test (`FILETOX_RAW_SAMPLES`, see `Tests/Engine/Images/CameraRawTests.swift`) against C# captures.
