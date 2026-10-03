#!/bin/bash
set -euo pipefail

# Package the verified local build; never installs or changes system security.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOKEN_OUTPUT_DIR="$SPOKEN_ROOT/build"
case "${1:-}" in
  --release) SPOKEN_OUTPUT_DIR="$SPOKEN_ROOT/build/release" ;;
  '') ;;
  *) printf 'Usage: package_dmg.sh [--release]\n' >&2; exit 1 ;;
esac
SPOKEN_APP="$SPOKEN_OUTPUT_DIR/Spoken.app"
if [[ "${1:-}" == --release ]]; then
  /usr/bin/python3 "$SPOKEN_ROOT/scripts/sign_release_app.py" --verify "$SPOKEN_APP"
fi
SPOKEN_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SPOKEN_APP/Contents/Info.plist")
SPOKEN_ARCH=$(lipo -archs "$SPOKEN_APP/Contents/MacOS/Spoken")
SPOKEN_OUTPUT="$SPOKEN_OUTPUT_DIR/Spoken-$SPOKEN_VERSION-$SPOKEN_ARCH.dmg"
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
if [[ "${1:-}" == --release ]]; then
  /usr/bin/python3 - "$SPOKEN_STAGE" <<'PY'
import sys
from pathlib import Path
stage = Path(sys.argv[1])
for filename, old in [
    ('安装与首次打开.txt', '当前测试版仅采用本地签名，尚未完成 Apple Developer ID 签名与公证。'),
    ('打不开 Spoken？点这里.html', '当前测试版采用本地签名，尚未完成 Apple Developer ID 签名与公证。'),
]:
    path = stage / filename
    text = path.read_text()
    if old not in text:
        raise ValueError(f'Installation guide needs a signing status review: {filename}')
    path.write_text(text.replace(old, '当前安装包已使用 Developer ID 签名，尚未完成 Apple 公证。'))
PY
fi
find "$SPOKEN_STAGE" -name '._*' -delete
hdiutil create -quiet -srcfolder "$SPOKEN_STAGE" -volname "Spoken $SPOKEN_VERSION" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$SPOKEN_OUTPUT"
hdiutil verify "$SPOKEN_OUTPUT"
cd "$SPOKEN_OUTPUT_DIR"
shasum -a 256 "$(basename "$SPOKEN_OUTPUT")" > "$SPOKEN_OUTPUT.sha256"
printf 'Packaged: %s\n' "$SPOKEN_OUTPUT"
