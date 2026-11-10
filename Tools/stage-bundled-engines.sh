#!/bin/bash
# Xcode build phase of the FileToXEngine helper: puts pinned rhwp, 7-Zip and locally built FFmpeg
# into FileToXEngine.app/Contents/MacOS/engines and signs them before Xcode signs the
# helper. EngineEnvironment.findBundled looks for them next to the executable. The AVIF encoder process, built by the
# FileToXAvifEncoder target, goes next to the helper executable (AvifEncoder.helper).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
case "${ARCHS:-arm64}" in
    arm64) rid=osx-arm64 ;;
    *) echo "FileToX supports Apple Silicon M1 and newer only (ARCHS=arm64)." >&2; exit 1 ;;
esac
: "${TARGET_BUILD_DIR:?run from Xcode}" "${EXECUTABLE_FOLDER_PATH:?run from Xcode}"
ffmpeg_bundle=${FILETOX_FFMPEG_BUNDLE:-$root/build/ffmpeg/ffmpeg}
if [[ ! -d "$ffmpeg_bundle" ]]; then
    echo 'Build FFmpeg first: python3 Tools/build-ffmpeg.py --work build/ffmpeg --jobs 6' >&2
    echo 'For an existing verified bundle, set FILETOX_FFMPEG_BUNDLE to its ffmpeg folder.' >&2
    exit 1
fi
ffmpeg_bundle=$(cd "$ffmpeg_bundle" && pwd -P)
python3 -I "$root/Tools/build-ffmpeg.py" --verify-bundle "$ffmpeg_bundle"

stage_code() {
    local code_source=$1 code_destination=$2
    cp -p "$code_source" "$code_destination"
    if [[ "$(lipo -archs "$code_destination")" != arm64 ]]; then
        lipo "$code_destination" -thin arm64 -output "$code_destination"
    fi
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$code_destination"
}

python3 -I "$root/Tools/fetch-bundled-engines.py" --rid "$rid" >/dev/null
source="$root/build/engines/$rid"
destination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/engines"
notices="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Notices"
rm -rf "$destination" "$notices"
mkdir -p "$destination" "$notices"
# Only executables go next to the helper (code); licences and manuals are resources.
stage_tree() {
    local tree=$1 prefix=$2 file relative
    while IFS= read -r -d '' file; do
        relative=$prefix${file#"$tree/"}
        if [[ -z "$prefix" && "$relative" == ffmpeg/* ]]; then continue; fi
        if file -b "$file" | grep -q 'Mach-O'; then
            mkdir -p "$destination/$(dirname "$relative")"
            stage_code "$file" "$destination/$relative"
        elif [[ "$(basename "$file")" != .filee-component ]]; then
            mkdir -p "$notices/$(dirname "$relative")"
            cp -p "$file" "$notices/$relative"
        fi
    done < <(find "$tree" -type f -print0)
}
stage_tree "$source" ""
mkdir -p "$destination/ffmpeg/bin" "$notices/ffmpeg"
for program in ffmpeg ffprobe; do
    stage_code "$ffmpeg_bundle/bin/$program" "$destination/ffmpeg/bin/$program"
done
# Build provenance contains local paths; keep it with the build artifacts, not in the app.
cp -R "$ffmpeg_bundle/LICENSES" "$notices/ffmpeg/"
if [[ -f "$ffmpeg_bundle/BUILDING.txt" ]]; then cp -p "$ffmpeg_bundle/BUILDING.txt" "$notices/ffmpeg/"; fi
# Replace the embed phase's universal copy and sign the selected slice before the helper is signed.
: "${FRAMEWORKS_FOLDER_PATH:?run from Xcode}" "${BUILT_PRODUCTS_DIR:?run from Xcode}"
stage_code "$root/Vendor/PDFium/lib/libpdfium.dylib" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libpdfium.dylib"
stage_code "$BUILT_PRODUCTS_DIR/FileToXAvifEncoder" "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/FileToXAvifEncoder"
cp "$root/Resources/Filee.LICENSE" "$notices/Filee.LICENSE"
# LibRaw and libjpeg-turbo are compiled into the helper (their licences and notices ship with the binary).
cp "$root/docs/upstream/LibRaw.LICENSE" "$root/docs/upstream/LibRaw.THIRD-PARTY-NOTICES.md" "$notices/"
cp "$root/docs/upstream/PDFium.LICENSE" "$root/docs/upstream/PDFium.THIRD-PARTY-NOTICES.md" "$notices/"
cp "$root/docs/upstream/libjpeg-turbo.LICENSE" "$root/docs/upstream/libjpeg-turbo.THIRD-PARTY-NOTICES.md" "$notices/"
# libavif (with its libyuv subset) and libaom are compiled into the AVIF encoder.
mkdir -p "$notices/LibAVIF"
cp "$root"/Vendor/LibAVIF/LICENSES/* "$notices/LibAVIF/"
echo "Bundled engines staged: $destination"
