#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
rid=osx-arm64
configuration=Debug
destination=
prepare_only=false
force=false
while (($#)); do
    case "$1" in
        --rid) rid=${2:?--rid requires a value}; shift 2 ;;
        --configuration) configuration=${2:?--configuration requires a value}; shift 2 ;;
        --destination) destination=${2:?--destination requires an app path}; shift 2 ;;
        --prepare-only) prepare_only=true; shift ;;
        --force) force=true; shift ;;
        --help)
            echo "Usage: build-engine-host.sh [--rid osx-arm64|osx-x64] [--configuration Debug|Release] [--destination FileToXEngine.app] [--prepare-only] [--force]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$rid" in osx-arm64|osx-x64) ;; *) echo "Unsupported RID: $rid" >&2; exit 2 ;; esac
case "$configuration" in Debug|Release) ;; *) echo "Unsupported configuration: $configuration" >&2; exit 2 ;; esac
bundle_id=${PRODUCT_BUNDLE_IDENTIFIER:-forked.filetox.local}
if [[ -z "${PRODUCT_BUNDLE_IDENTIFIER:-}" && "$configuration" == Debug ]]; then
    bundle_id=forked.filetox.local.dev
fi
bundle_id="$bundle_id.enginehost"
case "$bundle_id" in *[!A-Za-z0-9.-]*) echo "Invalid helper bundle identifier" >&2; exit 2 ;; esac
if [[ -n "$destination" && "$(basename "$destination")" != FileToXEngine.app ]]; then
    echo "Destination must name FileToXEngine.app" >&2
    exit 2
fi

python3 "$root/Tools/verify-filee-vendor.py"
mkdir -p "$root/build/toolchain"
cp "$root/Config/EngineHost.global.json" "$root/build/toolchain/global.json"
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
# Xcode exports TARGETNAME. MSBuild imports it as the case-insensitive TargetName
# property, giving Core and Engines the same DLL filename and dropping references.
unset TARGETNAME
dotnet="$DOTNET_ROOT/dotnet"
if [[ ! -x "$dotnet" ]]; then
    echo "Missing .NET SDK: $dotnet. Install the SDK version in Config/EngineHost.global.json into ~/.dotnet." >&2
    exit 1
fi
cd "$root/build/toolchain"
sdk=$("$dotnet" --version)

source_fingerprint=$(python3 - "$root" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); checksum=hashlib.sha256()
for path in [root/'Vendor/filee-manifest.json', *sorted((root/'Vendor/Filee.patches').glob('*.patch'))]:
    checksum.update(str(path.relative_to(root)).encode()); checksum.update(path.read_bytes())
print(checksum.hexdigest())
PY
)
source_stamp="$root/build/filee-src.stamp"
if [[ ! -f "$source_stamp" || "$(cat "$source_stamp")" != "$source_fingerprint" || ! -d "$root/build/filee-src" ]]; then
    python3 - "$root" <<'PY'
import pathlib,shutil,sys
root=pathlib.Path(sys.argv[1]); source=root/'build/filee-src'
if source.exists(): shutil.rmtree(source)
shutil.copytree(root/'Vendor/Filee', source)
PY
    if [[ -d "$root/Vendor/Filee.patches" ]]; then
        for patch_file in "$root"/Vendor/Filee.patches/*.patch; do
            [[ -f "$patch_file" ]] || continue
            git -C "$root/build/filee-src" apply --check "$patch_file"
            git -C "$root/build/filee-src" apply "$patch_file"
        done
    fi
    printf '%s\n' "$source_fingerprint" > "$source_stamp"
fi
if $prepare_only; then
    echo "Prepared pinned Filee source with patches (SDK $sdk): $root/build/filee-src"
    exit 0
fi

project=$(python3 - "$root" <<'PY'
import pathlib,sys
projects=list((pathlib.Path(sys.argv[1])/'EngineHost').glob('*.csproj'))
if len(projects)!=1: sys.exit('Expected exactly one EngineHost/*.csproj; the C# host must be present before publishing.')
print(projects[0])
PY
)
fingerprint() {
    python3 - "$root" "$source_fingerprint" "$sdk" "$rid" "$configuration" "$bundle_id" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); checksum=hashlib.sha256('\0'.join(sys.argv[2:]).encode())
inputs=list((root/'EngineHost').rglob('*')) + list((root/'Config').glob('EngineHost.*'))
inputs += list((root/'Vendor/Filee.patches').glob('*.patch'))
inputs += [root/'Tools/build-engine-host.sh',root/'Tools/fetch-bundled-engines.py']
for path in sorted(inputs):
    if path.is_file() and not any(p in ('bin','obj','__pycache__') for p in path.relative_to(root).parts):
        checksum.update(str(path.relative_to(root)).encode()); checksum.update(path.read_bytes())
print(checksum.hexdigest())
PY
}
build_fingerprint=$(fingerprint)
output="$root/build/engine-host/$rid/$configuration"
app="$output/FileToXEngine.app"
stamp="$output/publish.stamp"
if $force || [[ ! -f "$stamp" || "$(cat "$stamp")" != "$build_fingerprint" || ! -x "$app/Contents/MacOS/FileToXEngine" ]]; then
    publish="$output/publish"
    python3 - "$publish" <<'PY'
import pathlib,shutil,sys
publish=pathlib.Path(sys.argv[1])
if publish.exists(): shutil.rmtree(publish)
PY
    mkdir -p "$publish"
    "$dotnet" publish "$project" -c "$configuration" -r "$rid" --self-contained true \
        -p:PublishReadyToRun=false -p:PublishTrimmed=false \
        -p:PublishSingleFile=false -p:PublishAot=false -o "$publish"
    [[ -x "$publish/FileToXEngine" ]] || { echo "Missing published FileToXEngine apphost" >&2; exit 1; }
    python3 "$root/Tools/fetch-bundled-engines.py" --rid "$rid"
    python3 - "$app" <<'PY'
import pathlib,shutil,sys
app=pathlib.Path(sys.argv[1])
if app.exists(): shutil.rmtree(app)
PY
    mkdir -p "$app/Contents/MacOS/engines" "$app/Contents/Resources/Notices"
    ditto "$publish" "$app/Contents/MacOS"
    ditto "$root/build/engines/$rid" "$app/Contents/MacOS/engines"
    cp "$root/Config/EngineHost.Info.plist" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
    cp "$root/Vendor/Filee/LICENSE" "$app/Contents/Resources/Notices/Filee.LICENSE"
    cp "$root/Vendor/Filee/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/Notices/Filee.THIRD-PARTY-NOTICES.md"
    cp "$root/Vendor/filee-manifest.json" "$app/Contents/Resources/upstream-manifest.json"
    python3 - "$app" "$root" <<'PY'
import pathlib,subprocess,sys
app=pathlib.Path(sys.argv[1]); root=pathlib.Path(sys.argv[2]); executable=app/'Contents/MacOS/FileToXEngine'
# Both compiler configurations produce local ad-hoc artifacts. Their dylibs have
# no Team ID, so hardened runtime needs this development-only exception.
entitlements=root/'Config/EngineHost.AdHoc.entitlements'
for path in sorted((app/'Contents/MacOS').rglob('*'), key=lambda p:len(p.parts), reverse=True):
    if path.is_file() and not path.is_symlink() and path!=executable:
        subprocess.run(['codesign','--force','--sign','-',str(path)],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['codesign','--force','--sign','-','--options','runtime','--entitlements',str(entitlements),str(executable)],check=True)
subprocess.run(['codesign','--force','--sign','-','--options','runtime','--entitlements',str(entitlements),str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
PY
    [[ "$(fingerprint)" == "$build_fingerprint" ]] || { echo "Engine host inputs changed during publishing; run the build again." >&2; exit 1; }
    printf '%s\n' "$build_fingerprint" > "$stamp"
fi
if [[ -n "$destination" ]]; then
    if [[ "$destination" != "$app" ]]; then
        python3 - "$destination" <<'PY'
import pathlib,shutil,sys
destination=pathlib.Path(sys.argv[1])
if destination.is_symlink(): sys.exit('Helper destination must not be a symlink')
if destination.exists(): shutil.rmtree(destination)
PY
        ditto "$app" "$destination"
    fi
    codesign --verify --deep --strict "$destination"
fi
echo "Engine host ready: $app (SDK $sdk, $rid)"
