# Engine host implementation status (for the parent)

Date 2026-10-11, SDK 10.0.401, osx-arm64.

## Done and verified

- Host implements every host-wire-v1 method and event with the frozen field names. All engines come from `EngineRegistry.CreateAll`, with the PDF/TIFF/combine mergers from the pinned Filee sources, `ConverterCatalog` priority, `ProfileSelector`, `UserDataStore` and `JobQueue`. The catalog has all 172 entries (171 + `folder`). Targets cover every writable format plus `folder` and `*`. Nothing is filtered or mocked.
- `--selftest` passes on both `bin/Debug` and a self-contained publish. It covers:
  - localizer and strict JSON, including built-in round trips, null/array preservation, and rejection of missing or unknown fields, nulls, integer enums and null elements
  - validation ranges
  - a real child host: hello, `data_locked`, bad JSON, unknown method, missing params, wrong `v`, lines over 4 MiB, catalog, resolve (unknown, folder, rejected), library save and revision conflict
  - overwrite through a symlinked folder → `error.output_is_source` with the source unchanged
  - 1,000 instant jobs in the order response → updates → exactly one finished; history capped at 200
  - native `write(1)` and `Console.Write` noise only on stderr; every stdout line is JSON
  - journal cleanup
  - `settings.save` drops blank `engineOwnCopies` entries (a cleared path field in the app)
- `smoke.py` (real engines, published host): 20 of 20 pass. The samples were png→jpg, heic→png, png→pdf, PDF merge, 2-page pdf→png, multi-page TIFF, ZIP of png + unknown + folder, zip→folder, md→docx, docx→html/pdf/epub, Korean txt→hwpx→hwp (rhwp)→pdf, csv↔xlsx, svg→png, dxf→svg, ttf→woff2, and mp4→mp3 availability. No `.filee-out-*` folders were left, and nothing was written under `~/Library/Application Support/Filee` or `$TMPDIR/Filee`.
- Missing-package guidance checked with an EPS file: `needsPackage: ghostscript`, `canDownload: false`, `guidanceKey: engines.guidance.macos.ghostscript`, Korean `reasonText`.
- Patches: `git apply --check` is clean on pristine `Vendor/Filee` for 0001 then 0002; the patched tree is byte-identical to the one the tests below ran on.
  - Filee.Core.Tests: baseline 154 passed / 0 failed / 2 skipped → patched 164 / 0 / 2 (10 new: staging, side-folder conflict).
  - Filee.Engines.Tests: baseline 445 passed / 43 skipped / 3 failed → patched 445 / 47 / 3. The 4 extra skips are the new real-engine tests (3 Pandoc, 1 LibreOffice cancel) when the engines aren't on `PATH`; with `PATH` set they run and pass (3 and 1). The 3 failures are unchanged and not caused by the patches: `MediaTests.Wav_converts_to_audio_formats(ogg/vorbis)`, `MediaTests.Cover_art_and_tags_are_kept` and `MediaTests.Every_target_format_is_written_with_the_planned_codecs` (amr, ogg, ogv), because the local Homebrew FFmpeg lacks those codecs.
- `optional-smoke.py` (patched debug host, real Pandoc 3.12, LibreOffice, Calibre, FFmpeg): 11 of 11 pass, including the new Pandoc media case. Samples only, not all format pairs.

## Build notes (platform items resolved, confirmed by root)

The global `-p:AssemblyName` and the ad-hoc `--options runtime` signing problems are fixed by platform; the signed hardened bundle, Swift tests and `optional-smoke.py` on the bundled helper pass. Two standing notes:

- A launched apphost needs `DOTNET_ROOT` only for the framework-dependent `bin/Debug` build. The self-contained publish runs without it.
- `EngineHost/bin` and `EngineHost/obj` are build outputs (excluded from the fingerprint); keep them out of version control.

## Final-file sidecars: all staged (0002)

JobQueue writes every final output into a hidden `.filee-out-xxxxxxxx` folder next to its final path, under the final file name, and `OutputCommit` moves the output and everything else in that folder into place at the end. Sidecars are therefore staged by construction when an engine writes next to the path it was given. I checked every engine that writes more than the one file:

- Staged and committed with the output: Calibre/Ebook Markdown images (`<name>_files`, relative links), `ArchiveConverter` folder extraction, Ghostscript pages, multi-output engines.
- Scratch only (work directory, never published): the HWPX/DOCX/PPTX/HTML/PDF readers' media folders, the Pandoc AST reader's `--extract-media`, LibreOffice's `lo-*` output folder.
- **Was not staged: `PandocConverter` (md/html/rst/tex output).** `--extract-media` pointed at the *final* folder (0002 r1 used `FinalPathOf`), so Pandoc wrote media there while converting. A cancelled or failed job left partial `<name>_files`, and the files of an existing `<name>_files` (and anything with the same name) were overwritten even with the Rename or Skip policy and without any source check.

Fix (`PandocConverter`): Pandoc runs with the staging folder as its working directory, `-o` is the staged output, `--extract-media=<name>_files` is *relative* and `--resource-path=<input folder>` keeps what the old working directory gave it (relative images in HTML/Markdown/LaTeX input). Pandoc links the media relatively (`doc_files/media/rId9.png`), which stays correct wherever the output ends up, so Markdown/HTML keep working relative links. `FinalPathOf` stays only for `MarkdownConverter.ToHtml` (built-in Markdown, compares the source folder with where the result will be).

Commit (`StagedOutputs.Commit`): the output's side files are now checked with `OutputCommit.Check` (the checks `Move` would do: exists without overwrite → `error.output_exists`, a source → `error.output_is_source`, a link or file in the way of a folder) *before* the output moves, so a conflicting `<name>_files` publishes nothing and touches nothing. With Overwrite a folder is merged: same-named files are replaced, others stay, sources are never replaced (inode comparison, so links and NFD/NFC spellings count). A crash between moving the output and its side files leaves the output without media (the journal removes the unmoved staging folder at the next start); the order output first, then side files, keeps the no-clobber move as the first decision.

Regression tests (run against the previous 0002, the Pandoc staging and conflict tests fail: media went into the final folder and an existing file was overwritten; the Overwrite merge test passes either way): `JobQueueStagingTests.A_conflicting_side_folder_publishes_nothing_of_the_file` (Core, any platform) and `PandocStagingTests` (media staged, relative link, nothing next to the source; a media folder in the way is untouched and nothing is published; Overwrite merges and keeps unrelated files) against the real Pandoc (`build/optional-engines/osx-arm64/pandoc/bin/pandoc`, put it on `PATH`; skipped when Pandoc isn't found). The original `MarkdownTests` pass.

## Cancellation (G5), verified

- `ProcessRunner` kills the whole process tree on cancel or timeout and raises `OperationCanceledException`, so the file ends `cancelled`, `Abort` removes the staging folder and nothing is published. On macOS LibreOffice is one `soffice` process (no `soffice.bin` child). `CancelEngineTests` cancels a running LibreOffice and checks the job state, no output, no staging folder and no surviving process.
- `optional-smoke.py` also cancels FFmpeg and LibreOffice through the host and kills the host's process group with an encoder running (all pass, no leftovers).
- Commit is not interruptible: the cancel token is checked once before it. A cancel that arrives during a multi-output commit keeps the outputs already moved (they are in the file's `outputs`).

## Wire notes for Swift (all within host-wire-v1)

- FileToX language/theme defaults: `en`, `#3478F6`. Startup maps old `auto`/blank language to `en`; explicit `ko`/`ja`/`zh-CN` and custom colors remain. Old default purple migrates only before `core/.filetox-defaults-v1` is written, so a later user choice of the same purple survives restart.
- Japanese helper resources are `EngineHost/i18n/ja.json` (151 conversion/engine/preset/profile/format/donut/status keys). Other upstream Avalonia keys fall back to English. English/Korean/Chinese staging-error extras are separate resources; the 236 vendored Filee files stay as pinned (patches apply only to the staged copy).
- The app omits `--lang` so `settings.save` changes host language immediately. `ja-JP` resolves to `ja`; unknown/automatic/blank codes resolve to `en`. Built-in `nameKey` values and user names remain untouched in persisted presets/profiles. `catalog.get` localizes the virtual folder label; technical format and engine brand names remain unchanged.

- `fatal` data is `{code, message}`. Codes: `data_locked`, `internal`, and `message_too_large`. `message_too_large` is sent when a `job.finished` would exceed 4 MiB. The history is already saved; the host closes the protocol and exits, so treat it as a crash.
- An RPC result over 4 MiB becomes `error {code: internal}` for the same id. An oversized `job.updated` is resent with `files: []`.
- A line the host can't attribute (bad JSON, over 4 MiB, invalid UTF-8) gets `error` with `id: null`.
- Folders in `selection.resolve` appear in `unknown[]`, as they have no format. They count toward the ZIP slice only.
- `job.updated` files carry `source, state, progress, errorKey`. `job.finished` adds `outputs` and `errorDetail`, plus `historyEntry`, and also `retrySources` and `preset` when something can be retried. Progress is always 0…1.
- Enums are camelCase everywhere, including inside presets and settings (`"conflict":"rename"`, flags like `"modifiers":"ctrl, alt"`). The host reads exactly that and rejects integers.
- `library.get` revision starts at 1 per host process. `library.save` and `settings.save` each increment it.
- `settings.save`: blank `engineOwnCopies` values mean "not set" and are dropped (the stored map never holds `""`). Engine probing runs after the response data is built, outside the host's lock, so slow probes no longer hold up job events.
- Getter-only Filee properties (`renames[].isBlank`, `watchFolders[].resolvedOutputFolder`, `originalsFolder`) are written out and ignored on input. Send them back unchanged or omit them.

## Not verified yet (gates)

- G4: exFAT/SMB `RENAME_EXCL` (the hard-link fallback for files exists; folders have none).
- osx-x64 build.
- `staging.journal` only shrinks at startup (one line per output during a session).
- A client that waits more than 30 s for `catalog.get`/`settings.save` kills the host; engine probing normally takes seconds, a cold Calibre/LibreOffice first run is the slow case.
