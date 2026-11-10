# FileToX

[English](README.md) | [한국어](README.ko.md) | [日本語](README.jp.md)

FileToX is a Mac-only file converter inspired by [Filee](https://github.com/KnifeLemon/Filee). Drop a file and pick a format to convert it.

Built with SwiftUI and AppKit for Apple Silicon Macs (M1 or later, arm64) running macOS 15 or later. Intel Macs and Rosetta execution are outside the support and validation scope. English is the default language, with Korean and Japanese also available.

## See it in action

[![FileToX demo: hold Option and drag a PNG in Finder, then drop on JPG](docs/media/filetox-demo.gif)](docs/media/filetox-demo.mp4)

[Watch the 20-second video](docs/media/filetox-demo.mp4) · Finder Option-drag, English captions, no audio.

With FileToX running in the menu bar, drag a file in Finder, then hold Control (⌃). Drop it on a format in the radial menu; the main app window can stay closed. Under **Settings → Activation**, choose Control, Option, Shift and Command in any combination, optionally with a letter, number, function or arrow key (or Space), then click **Save**. Below the shortcut editor, choose whether to hold the keys before dragging, press them after dragging starts, or allow either order (the default). In the after-dragging mode, keys already held at the start must be released and pressed again. The shortcut and activation order persist on this Mac; existing shortcuts keep allowing either order. Warnings identify enabled macOS system shortcuts and Finder drag gestures; shortcuts registered by other apps are outside this check.

The radial menu has two modes: **Control (⌃)** opens **Convert formats**, and **Control+Shift (⌃⇧)** opens **File tools**. You can release the keys after the menu opens and press the other combination to switch during the same drag. Activation order applies to opening a menu. Configure each shortcut separately under **Activation**; duplicate key combinations cannot be saved. Existing primary shortcuts are preserved. If an existing primary uses Control+Shift, the new secondary defaults to Control+Option+Shift instead.

Under **Radial toolbar → File tools**, automatic mode selects relevant tools such as resizing, grayscale, PDF splitting/merging and archive packing, followed by **Show in Finder**, **Copy files** and **Copy paths**. Turn automatic mode off to arrange any saved preset and these file actions together, up to 12 items. Copy files places file URLs on the clipboard for pasting in Finder. File tools use the same conversion engine checks and source protection as other presets. File actions do not run a conversion.

Home keeps file selection, preset selection and execution in the main window. Choose **Open radial menu…** to use the popup. In the popup's click mode, arrow keys select an item, Enter runs it, **M** switches modes, and Escape closes it. The conversion menu continues to use your existing file-type profiles.

## Features

- Open a radial conversion menu by dragging in Finder and holding the configured shortcut (Control by default), or choose files and folders in the app and run them from Home.
- Convert images, documents, video, audio and archives through a catalog of 172 formats and 23 engines.
- Create presets, arrange your radial toolbar and choose where converted files are saved.
- Follow progress, cancel a job, retry failures and revisit recent conversions.
- Choose English, Korean or Japanese, and customize the accent with the native macOS color picker.
- Keep source files protected, with clear handling of name conflicts and multiple outputs.

## Screenshots

![FileToX home screen with file selection and recent conversions](docs/images/filetox-home.png)

<table>
<tr><th>Radial conversion menu</th><th>Theme and accent color</th></tr>
<tr><td width="40%" align="center"><img src="docs/images/filetox-radial.png" width="340" alt="Radial conversion menu"></td><td width="60%"><img src="docs/images/filetox-theme.png" width="620" alt="Theme and accent color"></td></tr>
</table>

Home and both radial menus are captured from native SwiftUI views using an isolated engine data folder. The theme screenshot is from the earlier English Release build. [File tools menu](docs/images/filetox-tools.png).

## Getting started

1. Drop a file onto Home, or choose files and folders.
2. Pick a preset or file tool on Home and click its Run button, open the radial menu, or select an output from **All output formats**.
3. Find the result beside the source, or in your chosen output folder.

On first launch, a setup guide explains Accessibility access for Finder drag activation and checks access when you return from System Settings. Choose **Later** to keep converting through Home, or reopen the guide through **Activation → Show setup guide**. The app includes native conversion components and uses no .NET runtime.

Under **Settings → General**, configure launch at login, menu bar visibility, whether login launches open the main window, and separate completion/failure notifications. These options apply immediately; automatic startup and notifications are off by default, and the menu bar icon is on. Hiding the icon keeps drag activation running; open FileToX again to reach its settings. Manual launches always open the main window. Notification clicks reveal available outputs in Finder, or open FileToX when there are no outputs. Partial failures follow the failure notification option; cancelled jobs do not notify. **Settings → Activation → Exclude apps from drag activation** lets you add or remove apps immediately; drags started in those apps do not open the radial menu. Login approval and notification permissions are managed by macOS, with links to System Settings when access is blocked.

This does not guarantee conversion between every registered format. The route planner determines available presets and targets from the inputs and engine status. The 58 read-only formats are excluded from output choices. Missing engines and unavailable macOS routes show a reason.

The default bundle includes built-in libraries, rhwp, 7-Zip and FFmpeg. Under **Conversion engines → Managed engines**, download the pinned arm64 versions of Pandoc, LibreOffice and Calibre for FileToX. Downloads are checked against their size and SHA-256 before installation, with progress and cancellation. Existing engine folders are preserved, and copies selected under **External engine executables** take priority. Selected FFmpeg copies override the bundle; Ghostscript uses a system installation or selected copy. Quitting cancels active downloads and waits for cleanup; partial downloads are not resumed.

Before encoding, FileToX checks that the selected FFmpeg provides the required encoders and output formats. A missing capability produces a specific error and preserves existing outputs. A pinned Apple Silicon build recipe is available below; FFmpeg is not yet offered as a managed download.

PDF conversions to EPUB, FB2, HTMLZ, TXTZ and ODT retain text and scan images in page order, including mixed text/scan documents and existing OCR text. Pages containing only invisible OCR text also retain a full-page rendering. Text-only PDFs retain the text route; empty pages do not trigger image fallback. These outputs put the text that macOS text recognition (Vision) reads in a scanned page before its picture, so it can be searched and copied. TXT reads pages without text, such as scans and pictures, the same way, first with the model of the Mac's first language and then with the Korean, Japanese and Chinese models for the lines it left out, and fails only when nothing can be read.

Outputs are written to a hidden staging folder beside each final destination, then published individually. Source files stay protected even with Overwrite; the default conflict policy chooses a new name. If publishing multiple outputs fails partway through, already published results are reported accurately. The whole batch is not an atomic transaction. App data is separated under `~/Library/Application Support/FileToX/{core,engines,tmp}`.

<details>
<summary>Development, build instructions and verification</summary>

## Build and run

Use Xcode 27 / Swift 6.4 and XcodeGen 2.46 or later. Python 3 runs the standard-library build scripts; the bundled FFmpeg build also needs CMake and pkg-config. The app and conversion helper build with Swift and native libraries; no .NET SDK, runtime or NuGet restore is required.

The current app version is **0.0.1 (build 2)**, an internal development version with no published release. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the app version source of truth; generated Info.plist values and both About views use those values. Increment the build number for a new build of the same version, and reset it to 1 when changing the version. Run `xcodegen generate` after editing the version. Git tags (`v0.0.1`) and GitHub Releases are created separately when publication is intended. The embedded engine host has its own version.

Build FFmpeg once in a new work directory before the first app build; reuse that verified bundle for later builds.

```sh
python3 Tools/build-ffmpeg.py --work "$PWD/build/ffmpeg" --jobs 6
xcodegen generate
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData build
open 'build/DerivedData/Build/Products/Debug/FileToX Dev.app'
```

Xcode consumes the engine and Core products from the root `Package.swift`, then signs and embeds the Swift helper, PDFium and bundled tools. App, helper and tests target arm64; download tools reject x64. Initial package resolution fetches pinned libwebp/libjxl sources, and staging fetches pinned rhwp/7-Zip archives only when the verified cache is missing. LibRaw, libjpeg-turbo and OpenJPEG sources, the original universal PDFium dylib and an arm64-only static Skia SVG bridge are checked in. Staging extracts arm64 from PDFium and bundled tools before signing, preserving the verified source copies. Native SVG covers a conservative primitive subset; other SVG features and vector PDF retain CoreSVG. Vendor records preserve provenance and license notices. The arm64 `FileToXAvifEncoder` tool is also embedded, using the pinned libavif 1.4.2/libaom 3.14.1 static archive and its preserved notices.

```sh
swift build -c release --product FileToXAvifEncoder
swift build -c release --product FileToXEngine
python3 Tools/fetch-optional-engines.py --help
```

Staging rejects extra files at the bundle root or in `bin`, and symbolic links anywhere in the bundle, embeds only `ffmpeg` and `ffprobe`, and copies license notices and `BUILDING.txt`. Full build provenance, including local build paths, stays with the local build artifacts.

The FFmpeg recipe requires a new work directory and produces `ffmpeg/bin/{ffmpeg,ffprobe}`, binary/source ZIPs and provenance from pinned sources, including the app’s required codecs and an AV1 software decoder. App staging expects `build/ffmpeg/ffmpeg` by default and checks the declared version/platform, pinned source list, executable hashes against the bundle’s own provenance, and presence of license notices before embedding. This is a consistency check; staging does not inspect the source ZIP or compare the recipe hash, and does not authenticate the bundle’s origin. To reuse an existing verified build elsewhere, set `FILETOX_FFMPEG_BUNDLE` to its `ffmpeg` folder when running Xcode. System installations and managed downloads are unchanged.

```sh
FILETOX_FFMPEG_BUNDLE="$PWD/build/ffmpeg-new/ffmpeg" xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData build
```

The Debug bundle ID is `forked.filetox.local.dev`; Release uses `forked.filetox.local`. Keep personal settings in the Git-excluded `Config/Local.xcconfig`. Debug and Release default to local ad-hoc signing. The earlier arm64 Release also passed an actual Xcode build with the existing team's development certificate, deep/strict signature verification and 23 relocated checks with repository and .NET SDK access denied. Developer ID signing and notarization remain unverified. Validation ran on an M2 Max/macOS 27; physical M1 or macOS 15 execution is not claimed. See the [earlier packaging verification](docs/design/engine-differential-triage.md#remaining-work-integration-2026-10-26) for scope and remaining differences.

## Unsupported conversions

These targets are not offered, or end with an error because of what the file contains. The original app (Filee) failed on them too; only writing PDB was removed in FileToX.

| Conversion | Behaviour | Reason |
| --- | --- | --- |
| Pictures, PDF, SVG, CAD, documents → audio formats | Not offered | The source has no sound. Audio comes only from video and audio files. |
| Writing PDB (PalmDoc) | Not offered | It holds Windows-1252 text only, so Korean, Japanese and emoji break. Reading PDB works. |
| Video → a transcript in DOCX, MD or other documents | Not supported | A video's documents and pictures are a still frame; its text is written as TXT and SRT only. A recording (audio) also gives its transcript as DOCX, MD, PDF, EPUB and other documents. |
| Video without a subtitle track, and any audio → TXT or SRT on macOS 15 | Error for video, not offered for audio | Transcription uses the on-device speech recognition of macOS 26 or later. A video with a subtitle track works on macOS 15. |
| Subtitles of a video that has only picture subtitles (DVD, Blu-ray) | Not read | Only text subtitle tracks are taken out; such a video is transcribed instead. |
| Video or audio → TXT on a Mac without any speech recognition language installed | "No speech recognition language is installed" error | Download the languages you need in the settings. |
| Video or audio without speech → TXT | "No speech was recognised" error | Music, effects and silence give no text. |
| Pictures or scanned PDFs without text → TXT | "The PDF contains no text" error | There is no text layer and nothing to recognise. Pictures and scans with text are read with OCR. |

A video with a text subtitle track is not transcribed: its first subtitle track is taken out as it is. SRT holds the subtitles or the transcribed stretches of speech with their times.

Limits of transcription and OCR: the transcription language is chosen among the macOS models downloaded in **Settings → Conversion engines → Speech recognition languages**. With several installed, the one that understands the first 45 seconds of the file best transcribes all of it. A language that is not installed cannot be chosen, a file that changes language is heard in one, and nothing is downloaded during a conversion. There are no speakers or timestamps. OCR does not promise vertical writing, skewed pages or handwriting, and does not rebuild tables. Another script inside a line (a Japanese word in a Korean line) stays as the first language's model read it. DOCX and HWPX keep a scanned page as its picture only.

## Verification

```sh
swift test
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData test
python3 -I Tools/engine-compare/test_harness.py
python3 -I Tools/test-engine-entitlements.py
```

Build the helper before running real helper integration tests; those tests alone are skipped if it is absent. Set `FILETOX_TEST_HOST` to use another helper path. The scripts below reproduce real-engine samples. Use a new absolute path for the work directory.

```sh
FILETOX_SMOKE_HOST="$PWD/build/DerivedData/Build/Products/Debug/FileToX Dev.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine"
python3 Tools/engine-smoke.py "$FILETOX_SMOKE_HOST" "$PWD/build/smoke-new"
python3 Tools/engine-optional-smoke.py "$FILETOX_SMOKE_HOST" "$PWD/build/optional-smoke-new"
```

During earlier app verification on Apple silicon, 32 Xcode tests, 12 Swift Package tests, 22 built-in engine checks (20 actual conversions and 2 selection checks), and 11 additional samples covering optional engines, video, audio, in-flight cancellation and attached-image collisions passed. Swift communication also verified PNG→JPG, PDF merge→multiple PNGs, unknown files and folders→ZIP→extraction, and history. In the running app, clicking the donut's JPG preset produced an output and a recent-history entry. Actual Finder Option-drag checks covered slow movement, source preservation and Finder focus after dropping. Korean HWP and DOCX→PDF text extraction and PNG rendering were also verified. Language switches between English, Korean and Japanese update the running app and host. The native color picker, saved colors after relaunch, localized built-in names and preservation of custom names were also verified.

Under **Settings → Watch folders**, choose an input folder and preset, enable the rule and save. Wait for **Watching** before adding files. Monitoring leaves existing files untouched at startup and processes new or changed files while FileToX is running. Output defaults to `converted`; originals stay in place unless you select moving successful, unchanged inputs to `originals`. Packages and temporary download folders are excluded. The three-second settling window is a heuristic: producers with longer write pauses should publish completed files by atomic rename. A scan is limited to 10,000 entries and a job to 128 inputs.

Not every format pair or codec has been tested. Ghostscript is absent on this machine. The system FFmpeg lacks some encoders; the separate pinned build passed all 21 previously failing AMR/OGG/OGV cases, 35 media tests and an AV1-input conversion. [Media and scanned PDF verification](docs/design/engine-differential-triage.md#media-codecs-and-original-scanned-pdf-fallback-2026-10-27). Login registration and notification delivery across a real logout/login remain unverified. External exFAT and SMB volumes, distribution notarization and TCC relaunch checks remain unverified.

The 2026-10-27–28 follow-up preserves mixed PDF content, slide tables with incomplete geometry, merged-cell positions and group scaling, and text boxes in FB2. PML keeps Korean/Japanese and other BMP text through Unicode escapes and retains full-depth PNG companions; non-BMP characters fail explicitly. PML image references must name existing PNG files using ASCII letters, digits, underscores, hyphens or dots, with no leading dot and a lowercase `.png` suffix. Plain visible horizontal SVG text can be searched and selected in PDF and extracted to TXT while its rendered outlines stay unchanged. Complex, explicitly hidden, clipped or unsupported text keeps outlines only; SVG-to-rich-document conversion retains page pictures rather than editable SVG text. Text that anything drawn after it may cover, wholly or partly, opaque or see-through, gets no searchable layer; so does text followed by paint whose area isn’t measured (references, CoreSVG-laid-out text, nested viewports, filters, markers, CSS transforms). The covered outlines remain in the PDF’s vector content, so covering text is still not redaction. AVIF avoids a second encoding when ImageIO already has zero decoded colour/alpha error. Short TS/M2TS poster extraction retains its single retry from the start when fast seeking returns an empty image.

The full suite at the 2026-10-29 PDF/SVG review revision, before the later media-duration change, completed with **793 engine tests (15 skips) and 18 Core tests, zero failures**. A fresh normal Release build produced both the host and AVIF helper. At that revision, a new Debug app and a separately compiled AppModel flow verified file selection, saved options, bundled AMR conversion, cancellation, OGG retry, history and source preservation. The app’s Mach-O files are arm64, with valid ad-hoc signatures and no Homebrew dynamic links. The actual mouse/dialog flow and Xcode-hosted XCTest execution were not repeated.

The 849-case replay at that PDF/SVG review revision completed **829 jobs, with 20 failures**: 14 inputs lack an audio track and six have no extractable text. Every case keeps the previous final state; 786 jobs that completed before the previous round remain completed, and its 43 recovered failures still complete. Harness and inspection errors are zero. With unchanged thresholds and inspection policy, strict C# comparison is **484 PASS / 260 WARN / 105 FAIL**. This includes 43 state mismatches where C# failed and the current engine succeeds; those differences are not waived. Compared with the delegated implementation’s run, PDB→RB returned to FAIL on embedded-picture similarity and LRF→HTMLZ moved from WARN to PASS. Neither path was changed by this review, and neither result is counted as a fix. All 105 FAIL case IDs match the 2026-10-28 final comparison. The corpus’s PDF and SVG cases do not exercise the new drawing layer or coverage rule. Conversion completion and output equivalence are separate results.

That PDF/SVG review host passed 44 conversions with output text/order, image-reference and pixel-decoding checks: the previous 26 mixed-PDF, existing-OCR, blank-page and SVG cases, a text page with a vector chart, an inline image and form text to DOCX, HWPX, EPUB, FB2, HTMLZ, TXTZ, ODT and TXT, a stencil-mask page to DOCX and EPUB, and covered SVG text, including inherited root strokes and relative image coordinates, to PDF and TXT. A PDF page with visible text that paints vector drawings, shadings, inline images or stencil masks keeps them as one picture of the page rendered without its text, behind the text at its place on the paper; reflowable outputs show it at the start of that page’s text. The text stays text and is not repeated, TXT stays text only, and paint that leaves only white paper adds no picture. On such pages the other pictures are part of that 150-dpi rendering, not their original bytes, and that earlier implementation removed every text object from the drawing. The PDF preservation update below addresses glyphs missing from extraction; vertical text is not uniformly unreadable. Page images are rendered content, not original image-byte, colour-profile or transparency preservation. These checks do not establish full SVG/C# equality, OCR recognition or every possible format/codec combination. See [final follow-up verification](docs/design/engine-differential-triage.md#remaining-work-final-verification-2026-10-28) and [text-page drawings and covered SVG text](docs/design/engine-differential-triage.md#priority-one-integration-review-2026-10-29) for evidence and remaining differences. The PDF text check at that revision preserved the saved output bytes and met the 0.84-second target in all five sequential runs (0.673–0.772 seconds, median 0.701). Other earlier development-certificate, relocation and timing results remain historical; physical M1/macOS 15, external filesystems, TCC, login/notifications and notarization remain unverified.

The 2026-10-29 media-duration update fills the last display interval of slow TS/M2TS/MPG/MXF video and also uses the input's nominal timing rate for brief changes hidden by a low average. The original ICNS cases now have 0.1-second format and decoded presentation durations in M2TS, MPG and MXF. That media revision passed **56 focused tests** and **33 actual conversions**; the 849-case replay completed **829 jobs with 20 failures**, with zero harness/inspection errors. Strict C# comparison with unchanged policy is **482 PASS / 241 WARN / 126 FAIL**; 22 additional FAILs are differences in the frame rate field. Two verdicts also changed on ebook paths untouched by this update and are not counted as fixes. Completion is separate from equivalence. Non-integral output-frame lengths round up (0.13 seconds to about 0.1668), and tiny MPG files can still underestimate format duration while decoded frames retain their display time. The full suite, app/AppModel and PDF timing results above belong to the earlier PDF/SVG review revision and were not repeated on this media source. [Media-duration verification](docs/design/engine-differential-triage.md#slow-media-duration-verification-2026-10-29).

PalmDoc (`.pdb`) is read only since 2026-11-06. It can hold only Windows-1252 text, so Korean, Japanese and emoji could not be written; the earlier output rejected such books rather than replacing the characters with `?`. A saved preset that targets PDB stays in the library and shows as unavailable. DWG output now writes the R2010+ free-space layout and includes the page map itself in the page count. [Legacy difference and data-loss review](docs/design/engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29).

The 2026-10-29 DWG/PDB revision passed **800 engine tests (15 skips) and 18 Core tests, with zero failures**. Its 849-case replay completed **822 jobs with 27 failures**: the previous 20 plus seven PDB inputs now rejected to prevent character loss. Every other job kept its state, with zero harness/inspection errors. Strict C# comparison remains unmodified at **474 PASS / 241 WARN / 134 FAIL**; seven new FAILs are those deliberate PDB rejections and one is a fluctuating generated-cover comparison on unchanged PDB→SNB. Independent DWG readback and the new Debug app’s signature, arm64 binaries and AppModel conversion/cancellation/retry/history flow passed. Actual GUI interaction, Xcode-hosted XCTest, physical M1/macOS 15 and distribution verification remain outstanding. [Current evidence and limits](docs/design/engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29).

The 2026-11-02 PDF preservation update adds page pictures for visible glyphs missed by text extraction, including nested forms and partially extracted text objects. It also recovers letters previously dropped after ligatures or character clusters and prevents extreme coordinates from terminating the engine. The final source passed **812 engine tests (15 skips) and 18 Core tests, with zero failures**, **94 rich conversions** and **8 additional boundary conversions**. All 849 job states remain **822 completed / 27 failed**; strict comparison remains **474 PASS / 241 WARN / 134 FAIL** with no case verdict changes. The new Debug app’s signature, arm64 binaries and AppModel flow passed. Pixels remain 150 dpi; diagonal/overlapping text matching, native image resolution and ligature layout still have limits. [2026-11-02 PDF evidence and limits](docs/design/engine-differential-triage.md#pdf-text-preservation-integration-2026-11-02).

The 2026-11-06 PDF update keeps missed glyphs in diagonal and overlapping text by comparing the letters of each glyph with the extracted words. It includes compatibility characters such as Korean syllables and ellipses. On pages where missed glyphs require a drawing, separate photos retain their original bytes and resolution when the page is upright and they need no compositing. Masks, graphics state, clipping, forms, image transforms, overlapping/off-page pictures and rotated pages conservatively retain the composite drawing. Preserved glyphs remain 150 dpi pixels; small overlap fragments, ligature layout and the existing drawing/text alignment on 180-degree pages still have limits. The plain image-extraction path keeps its older mask and clipping limits.

The final sources passed **821 engine tests (15 skips) and 18 Core tests, with zero failures**, **142 rich/TXT conversions, 25 boundary cases and 36 review conversions**. All 849 job states remain **822 completed / 27 failed**; strict comparison is **474 PASS / 241 WARN / 134 FAIL**, with the same FAIL cases. The new Debug app's signature, arm64 binaries and AppModel flow passed, including DOCX/EPUB output with the native 400×400 photo and the missed-glyph picture. [Latest PDF evidence and limits](docs/design/engine-differential-triage.md#pdf-geometry-integration-2026-11-06).

A 2026-11-06 reclassification of the 134 strict FAILs found no case where Swift is worse than C#: 43 jobs C# failed now complete, 30 are the fix for the last video frame's display time, 7 are PDB rejections of Korean text, 6 keep slide text C# lost, and 48 are the earlier ledger. The 18 audio targets offered for pictures, PDF, SVG and CAD, and TXT for video, cannot produce a result; route planning now excludes them, so the format list and radial menu disable them. PDF to TXT reads scanned and picture pages without text with macOS Vision, so pictures and comics can become TXT again. A six-page 300 dpi Korean/English scan was read with 96.5% word recall and 97.6% character similarity, at about 0.33 s per page. All **827 engine tests and 18 Core tests pass**; the 849 jobs end **822 completed / 27 failed** (15 without a route, 7 PDB, 5 picture/scan TXT with no text) and the other 834 keep their states. Strict comparison is **460 PASS / 240 WARN / 149 FAIL** because those 15 now stop before converting with a different error key. Korean PDB is not supported. [Reclassification, excluded targets and OCR](docs/design/engine-differential-triage.md#unreachable-targets-2026-11-06).

Every Calibre conversion requires `calibre-debug` beside the resolved `ebook-convert` in a complete installation. The child-process patch is verified with pinned Calibre 9.15.0 for auxiliary-document styles and TCR/PML preservation; other selected versions need validation. No separate Python installation is needed.

## Source and design

Development reference: [KnifeLemon/Filee](https://github.com/KnifeLemon/Filee) commit `21fdd05ef7181b032ed83ec895cc9bbc4b198985`. Current Core, host and engine implementations are in `Sources/Engine`; the app-facing Core package is in `Sources/Core`. Upstream licences and notices are retained under `docs/upstream`. The current build does not reference Filee C# projects.

- [Full format list](docs/formats.md), [architecture](docs/architecture.md)
- [Wire contract](docs/design/host-wire-v1.md), [host implementation](Sources/Engine/Host/Host.swift)
- [UI design](docs/design/swiftui-port.md), [packaging and signing](docs/design/macos-packaging.md)
- [Claude design review](docs/design/review.md), [engine implementation and verification](docs/design/engine-differential-triage.md)

Mockups from the earlier conversation are kept in `docs/archive/pre-filetox/`. A notch shelf, file storage, moving and copying are outside the current scope.

</details>

## Acknowledgments

FileToX is a Mac-only file converter inspired by [Filee](https://github.com/KnifeLemon/Filee), built with SwiftUI and AppKit for macOS. It is an independent project, not an official Filee release.

FileToX is licensed under the [MIT License](LICENSE). Filee's [MIT license](docs/upstream/Filee.LICENSE) and [third-party notices](docs/upstream/Filee.THIRD-PARTY-NOTICES.md) are preserved. MIT does not replace the licenses of external engines. Camera RAW is decoded with [LibRaw](https://www.libraw.org) 0.22.2, used under the [CDDL-1.0](docs/upstream/LibRaw.LICENSE) ([notices](docs/upstream/LibRaw.THIRD-PARTY-NOTICES.md)); its unmodified source is in `Vendor/LibRaw`. JPEG files are written, and lossy DNGs decoded, with [libjpeg-turbo](https://libjpeg-turbo.org) 3.2.0 under the IJG License ([licence](docs/upstream/libjpeg-turbo.LICENSE), [notices](docs/upstream/libjpeg-turbo.THIRD-PARTY-NOTICES.md)); this software is based in part on the work of the Independent JPEG Group. Its unmodified source is in `Vendor/libjpeg-turbo`. Notices for the actual bundle are included in the helper's `Contents/Resources/Notices`. PDF pages are rasterized with bundled [PDFium](Vendor/PDFium/README.md) 147.0.7690.0 (arm64 distribution copy), matching the former C# renderer; its [BSD-3 license](docs/upstream/PDFium.LICENSE) and [bundled third-party notices](docs/upstream/PDFium.THIRD-PARTY-NOTICES.md) ship with the helper.
