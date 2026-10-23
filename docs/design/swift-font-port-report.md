# P7 font engine port

Implemented on `feat/port-font-engine`, from `b69962235a4fabb568aed13b02759fa4f4e5b791`.
Implementation commit: `093a017` (signed, with DCO sign-off).
Behavior reference: patched Filee `21fdd05` at `/tmp/ftx-ref/filee-patched`.

## Scope

All 14 Filee font source files are ported under `Sources/Engine/Engines/Fonts/`:
`BigEndian.swift`, `FontConverter.swift`, `FontFile.swift`, `SfntFont.swift`,
`TrueTypeGlyph.swift`, `CffToTrueType.swift`, `Woff.swift`, `Woff2.swift`,
`Woff2Transforms.swift`, `Eot.swift`, and `Cff/{CffFont,CffStandardData,CubicToQuadratic,Type2Interpreter}.swift`.

`FontConverter` is registered at the font position in `EngineRegistry.createAll`.
The 20 edges, costs and order, id, display name, availability detail, allocation
extension, progress slices and cancellation points follow Filee. CFF outline
conversion includes name-keyed and CID fonts, font matrices, local/global
subroutines, flex, arithmetic, seac accents, winding reversal, quadratic
approximation, post names, horizontal metrics and VORG-to-vmtx conversion.
WOFF2 includes glyf/loca and hmtx transforms, overlap bitmaps, untransformed
fallback, and first-font collection decoding. EOT includes name headers and XOR
decoding. SFNT also reads the first member of TTC collections.

No foundation, package, dependency or third-party source changes were needed.
No external executable is used by the converter. Tests retain the four small
OFL fixtures and their `OFL.txt`; fixture loading uses `#filePath`.

## Compatibility results

The installed C# host reported host version `0.1.0`, Filee commit
`21fdd05ef7181b032ed83ec895cc9bbc4b198985`, and font engine `Filee 1.8.1`.
It ran with fresh `--data`, `--engines`, and `TMPDIR` directories under
`/tmp/ftx-font-baseline-p7-20261023b`. The installed application and existing
FileToX user data were not changed.

The complete 20-direction matrix was compared for each of six fonts:
FileeTest-TrueType, FileeTest-CID, FileeTest-NameKeyed, and temporary copies of
macOS Arial.ttf, Times New Roman.ttf and STIXGeneral.otf. Four further cases
used the Google reference WOFF2 fixture as input. For each matrix, the source
containers were produced by C# and the exact same input bytes were fed to Swift.

All 124 cases have identical flavor, table tags and raw decoded table bytes,
including `head` without normalization. All 75 TTF/OTF/EOT outputs are also
byte-identical. The 25 WOFF and 24 WOFF2 outputs differ only in compression.

Every direction is represented as follows (each listed direction has six fonts;
WOFF2-source directions have one additional Google case):

- TTF -> OTF, EOT: byte-identical; TTF -> WOFF, WOFF2: table-identical.
- OTF -> TTF, EOT: byte-identical; OTF -> WOFF, WOFF2: table-identical.
- WOFF -> TTF, OTF, EOT: byte-identical; WOFF -> WOFF2: table-identical.
- WOFF2 -> TTF, OTF, EOT: byte-identical; WOFF2 -> WOFF: table-identical.
- EOT -> TTF, OTF: byte-identical; EOT -> WOFF, WOFF2: table-identical.

Per-case sizes, byte-equality flags, table diffs (all empty) and both SHA-256
hashes are retained in `Tests/Engine/Fonts/BaselineComparison.json`.
Original C#/Swift outputs remain in the temporary comparison directory.

## Deliberate platform differences and limits

Apple Compression's installed public header documents Brotli **level 2 only**;
there is no public quality/window setting. Filee uses quality 11/window 22.
Swift WOFF2 files were 11.9–20.9% larger than C# across these comparisons.
For TTF-source conversions, C# -> Swift sizes in bytes were:

- FileeTest-TrueType: 6,348 -> 7,540 (Google fixture: 6,440).
- FileeTest-CID converted to TrueType: 2,700 -> 3,032.
- FileeTest-NameKeyed converted to TrueType: 968 -> 1,144.
- Arial: 320,676 -> 380,904.
- Times New Roman: 362,064 -> 425,984.
- STIXGeneral converted to TrueType: 180,356 -> 207,636.

The WOFF zlib level stays 9 (`SmallestSize`). macOS's system zlib and .NET's
compressor produce different valid Deflate streams for some tables, even when
sizes match. Total WOFF size differences ranged from -1,960 to +4 bytes
(-0.687% to +0.050%). Every decompressed table is byte-identical.

Chrome for Testing 153 loaded and rendered all **99/99 browser-supported outputs**
(25 TTF, 25 OTF, 25 WOFF, 24 WOFF2), with no font sanitizer/load failures.
The browser used its own FontFace decoder, independent of this Swift decoder.
EOT is checked through header fields and exact C# byte equality, since Chrome
does not support EOT. The browser result is retained in the comparison JSON.

Filee's original WOFF2 size assertions (<80% of WOFF and <105% of Google) are
inapplicable to Apple's fixed level 2. The port asserts WOFF2 is smaller than
WOFF for the TrueType fixture and reports all three sizes; the format/transform
assertions remain unchanged. Matching quality 11 would require relaxing the
platform/dependency constraint. No fallback codec or feature was silently dropped.

The foundation's `EngineVersions.builtIn` displays `FileToX 0.1.0`, where C#
displays `Filee 1.8.1`. The converter uses that shared version API, as Filee does.
CoreText/CoreGraphics replace Skia in test loading, outlines and raster coverage.
This foundation branch has no Swift job queue or NDJSON host implementation, so
tests exercise `FontConverter` directly and comparisons exercise `FontFile`.
Full application/helper integration remains the parent port's responsibility.

The C# unsupported cases remain unsupported with the same messages: CFF2-to-TTF,
Type 1 charstrings and MicroType Express EOT. Expert CFF charset names remain
unknown, matching Filee. An empty CID dictionary set now throws a readable font
error instead of trapping on a Swift array subscript; this affects damaged inputs.
Other malformed fixed-size fields use the font reader's bounds-checked error.

## Verification

- `swift build --build-tests`: passed.
- `swift test --filter FontTests`: 19 XCTest methods passed; grouped parameter
  cases include 60 direct-container combinations and all Filee FontTests cases.
- `FILETOX_FONT_BASELINE=/tmp/ftx-font-baseline-p7-20261023b swift test --filter Font`:
  20 XCTest methods passed, including all 124 differential comparisons.
- `swift test --skip-build --filter FileToXEngineTests`: 39 methods, 38 passed,
  one optional baseline test skipped without its environment variable, no failures.
- Browser FontFace load plus canvas-ink validation: 99 passed, including 24 WOFF2.
- SwiftPM emits unhandled fixture/evidence file warnings because these are read
  via `#filePath`, intentionally not Package.swift resources.

Reproduce the differential check with:

```sh
python3 Tests/Engine/Fonts/compare_baseline.py /tmp/ftx-font-baseline-new
FILETOX_FONT_BASELINE=/tmp/ftx-font-baseline-new swift test --filter Font
```

The script requires the existing installed C# helper and the named system fonts;
it installs nothing. Browser automation used the T3 preview first, then the
shared Chrome for Testing workflow after two preview snapshot timeouts.
