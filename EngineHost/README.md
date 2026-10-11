# FileToX engine host

C# conversion helper (`FileToXEngine`) for the SwiftUI app, communicating over NDJSON on stdio. Contract: `docs/design/host-wire-v1.md`; design: `docs/design/engine-host.md`.

## Files

| File | Role |
| --- | --- |
| `Program.cs` | Startup order (fd isolation → process group → `TMPDIR` → `core/.lock` → staging journal cleanup → Filee → `hello`), request loop, `StagingJournal` |
| `Native.cs` | `fcntl(F_DUPFD_CLOEXEC)`, `dup2`, `/dev/null` on fd 0, `setpgid` |
| `Wire.cs` | Strict JSON options, line reader (4 MiB), the single bounded writer |
| `Host.cs` | Methods, job tracking under one `gate`, `job.updated` coalescing (100 ms), `job.finished` + history |
| `Selection.cs` | `selection.resolve`: profile, slices, all targets (`PresetAvailability.Check` + package guidance) |
| `Validation.cs` | Paths, preset/profile/settings ranges |
| `Localizer.cs` | en/ko/zh-CN from Filee `Assets/i18n` (embedded) |
| `SelfTest.cs` | `FileToXEngine --selftest` (starts itself with `--fake-engines` for the protocol checks) |
| `smoke.py` | Real-engine G3 samples against a published host |

Patches to the pinned Filee sources live in `Vendor/Filee.patches/`:

- `0001-jobqueue-staged-outputs.patch`: `OutputCommit.cs`, `JobQueue` final allocator staging/commit/abort, `JobQueueStagingTests`.
- `0002-engines-final-output-paths.patch`: Markdown and Pandoc ask `OutputCommit.FinalPathOf` where a staged result ends up.

## Arguments

`--data <dir>` (default `~/Library/Application Support/FileToX/core`), `--engines <dir>` (default sibling `engines`), `--tmp <dir>` (default sibling `tmp`; the host sets `TMPDIR` itself), `--lang en|ko|zh-CN` (default: settings language). `--selftest` runs the checks; `--fake-engines` is for the selftest only.

## Build and check

```sh
Tools/build-engine-host.sh --prepare-only                      # stage Filee + patches into build/filee-src
cd build/toolchain && ~/.dotnet/dotnet build ../../EngineHost/FileToX.EngineHost.csproj
DOTNET_ROOT=~/.dotnet ../../EngineHost/bin/Debug/net10.0/FileToXEngine --selftest
python3 EngineHost/smoke.py <published FileToXEngine> <new empty dir>
```

The patch tests run in Filee's own suite: apply the patches to the staged sources from `Vendor/Filee`, then `dotnet test tests/Filee.Core.Tests`.
