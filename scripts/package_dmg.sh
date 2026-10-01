#!/bin/bash
set -euo pipefail

# Package the verified local build; never installs or changes system security.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOKEN_APP="$SPOKEN_ROOT/build/Spoken.app"
SPOKEN_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPOKEN_APP/Contents/Info.plist")
SPOKEN_ARCH=$(lipo -archs "$SPOKEN_APP/Contents/MacOS/Spoken")
SPOKEN_OUTPUT="$SPOKEN_ROOT/build/Spoken-$SPOKEN_VERSION-$SPOKEN_ARCH.dmg"
if [[ -e "$SPOKEN_OUTPUT" ]]; then
  printf 'Refusing to overwrite existing package: %s\n' "$SPOKEN_OUTPUT" >&2
  exit 1
fi
codesign --verify --deep --strict "$SPOKEN_APP"
SPOKEN_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/spoken-dmg.XXXXXX")
trap 'rm -rf "$SPOKEN_STAGE"' EXIT
ditto "$SPOKEN_APP" "$SPOKEN_STAGE/Spoken.app"
ln -s /Applications "$SPOKEN_STAGE/Applications"
cp "$SPOKEN_ROOT/docs/安装与首次打开.txt" "$SPOKEN_STAGE/"
cp "$SPOKEN_ROOT/docs/打不开 Spoken？点这里.html" "$SPOKEN_STAGE/"
find "$SPOKEN_STAGE" -name '._*' -delete
hdiutil create -quiet -srcfolder "$SPOKEN_STAGE" -volname "Spoken $SPOKEN_VERSION" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$SPOKEN_OUTPUT"
hdiutil verify "$SPOKEN_OUTPUT"
cd "$SPOKEN_ROOT/build"
shasum -a 256 "$(basename "$SPOKEN_OUTPUT")" > "$SPOKEN_OUTPUT.sha256"
printf 'Packaged: %s\n' "$SPOKEN_OUTPUT"
