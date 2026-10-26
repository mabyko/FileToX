# libavif for FileToX

`FileToXAvifEncoder` is the helper process the image engine starts to write 8-bit colour AVIF
(`Sources/Engine/Engines/Images/AvifEncoder.swift`). It is built from `FileToX/avifenc.c` and the
static `lib/libavif.a`. The archive contains libavif 1.4.2, its bundled libyuv subset and the libaom
3.14.1 AV1 encoder. It is arm64-only, targets macOS 15 and links only libSystem.

- **Pins and hashes:** `PROVENANCE.json`. `headers/avif/avif.h` is the release header, unchanged.
- **Rebuilding:** `build.py` rebuilds the archive from the pinned source tarball and libaom
  checkout. It runs offline and needs only CMake and Xcode's command line tools.
- **Builds:** SwiftPM builds the helper as the `FileToXAvifEncoder` executable target, next to
  `FileToXEngine`. Xcode builds it as a tool target; `Tools/stage-bundled-engines.sh` then copies it
  into `FileToXEngine.app/Contents/MacOS` and signs it with the hardened runtime.
- **Licences:** shipped as `Notices/LibAVIF`.
  - `libavif.LICENSE`: libavif BSD-2-Clause, plus the dav1d (`src/obu.c`) and libyuv notices.
  - `libaom.LICENSE` and `libaom.PATENTS`: AOMedia BSD-2-Clause and the AOMedia patent licence.
  - `libaom-fastfeat.LICENSE` and `libaom-vector.LICENSE`: the only libaom third-party code
    compiled in.

## Selection

The engine (`AvifEncoder.improve`) always writes ImageIO's AVIF first and runs the helper only for 8-bit colour pictures
that are not all gray. It keeps the helper's file only when, with both files decoded by ImageIO and compared with the
encoder's input as premultiplied 8-bit samples, its summed squared error is no larger for colour and for alpha and
smaller for one of them. This bounds that one measure; it does not establish visual, SSIM or metadata equivalence.

## Encoder settings

- the AV1 quantizers ImageIO's AVIF encoder uses for the preset quality: colour `floor((100 - quality) * 63 / 100)`;
  alpha 7, or the colour quantizer where that is finer (ImageIO keeps alpha at 7 for every quality)
- YUV 4:4:4, BT.601 matrix, full range
- speed 6, two threads
- colour tuned for SSIM (libavif's linear quantizer scale); alpha keeps libavif's default PSNR tuning
- `nclx` sRGB primaries and transfer for untagged pictures; an ICC profile otherwise
- Exif and XMP as items, without `irot`/`imir`: the engine already wrote the pixels upright
