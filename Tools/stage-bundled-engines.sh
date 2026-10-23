#!/bin/bash
# Xcode build phase of the FileToXEngine helper: puts the pinned rhwp and 7-Zip (Tools/fetch-bundled-engines.py,
# downloaded once into build/) into FileToXEngine.app/Contents/MacOS/engines and signs them before Xcode signs the
# helper. EngineEnvironment.findBundled looks for them next to the executable.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
case "${ARCHS:-$(uname -m)}" in
    arm64) rid=osx-arm64 ;;
    x86_64) rid=osx-x64 ;;
    *) echo "Build one architecture at a time (ARCHS=arm64 or ARCHS=x86_64)." >&2; exit 1 ;;
esac
: "${TARGET_BUILD_DIR:?run from Xcode}" "${EXECUTABLE_FOLDER_PATH:?run from Xcode}"

python3 -I "$root/Tools/fetch-bundled-engines.py" --rid "$rid" >/dev/null
source="$root/build/engines/$rid"
destination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/engines"
notices="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Notices"
rm -rf "$destination" "$notices"
mkdir -p "$destination" "$notices"
# Only executables go next to the helper (code); licences and manuals are resources.
while IFS= read -r -d '' file; do
    relative=${file#"$source/"}
    if file -b "$file" | grep -q 'Mach-O'; then
        mkdir -p "$destination/$(dirname "$relative")"
        cp -p "$file" "$destination/$relative"
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime "$destination/$relative"
    elif [[ "$(basename "$file")" != .filee-component ]]; then
        mkdir -p "$notices/$(dirname "$relative")"
        cp -p "$file" "$notices/$relative"
    fi
done < <(find "$source" -type f -print0)
cp "$root/Resources/Filee.LICENSE" "$notices/Filee.LICENSE"
# LibRaw and libjpeg-turbo are compiled into the helper (their licences and notices ship with the binary).
cp "$root/docs/upstream/LibRaw.LICENSE" "$root/docs/upstream/LibRaw.THIRD-PARTY-NOTICES.md" "$notices/"
cp "$root/docs/upstream/PDFium.LICENSE" "$root/docs/upstream/PDFium.THIRD-PARTY-NOTICES.md" "$notices/"
cp "$root/docs/upstream/libjpeg-turbo.LICENSE" "$root/docs/upstream/libjpeg-turbo.THIRD-PARTY-NOTICES.md" "$notices/"
echo "Bundled engines staged: $destination"
