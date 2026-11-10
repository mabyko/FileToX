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
that are not all gray. It keeps the helper's file only when both hold:

- With both files decoded by ImageIO and compared with the encoder's input as premultiplied 8-bit samples, its summed
  squared error is no larger for colour and for alpha, and smaller for one of them.
- Read back by ImageIO, it keeps every top-level tag of the picture's metadata that ImageIO's file kept.
  - The whole value must be kept: equal text, and every item, field and qualifier (such as a language) of arrays,
    alternatives and structures, in order where the array is ordered.
  - Qualifiers and fields count by namespace and local name, whatever prefix spells them.
  - This is ImageIO's reading, one view of Exif and XMP together: dc:creator, for one, also comes back from the Exif
    Artist. It does not compare the raw Exif and XMP containers, or what other readers see.
  - The pixel dimensions are the exception: the helper's file records the picture's own size, while ImageIO copies
    the source's.

  For example, Exif that does not fit the shared serializer's 64 KB JPEG segment keeps ImageIO's file.

This bounds these measures only; it does not establish visual, SSIM or full metadata equivalence.

## Encoder settings

- the AV1 quantizers ImageIO's AVIF encoder uses for the preset quality: colour `floor((100 - quality) * 63 / 100)`;
  alpha 7, or the colour quantizer where that is finer (ImageIO keeps alpha at 7 for every quality)
- YUV 4:4:4, BT.601 matrix, full range
- speed 6, two to eight threads (the processors online, at most eight). libaom's `test/ethread_test.cc` finds the same
  bitstream with 2, 4 and 64 row-multithreaded threads for one 640×480 4:2:0 clip at all-intra speed 6, cq-level 18;
  that is not proof for every 4:4:4, alpha, size or thread-count input
- colour tuned for SSIM (libavif's linear quantizer scale); alpha keeps libavif's default PSNR tuning
- `nclx` sRGB primaries and transfer for untagged pictures; an ICC profile otherwise
- Exif and XMP as items, without `irot`/`imir`: the engine already wrote the pixels upright. The XMP also carries the
  Exif auxiliary tags (`aux:`, lens and serial number), which Exif cannot hold, as ImageIO's own AVIF does
