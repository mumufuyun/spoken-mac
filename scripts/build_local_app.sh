#!/bin/bash
set -euo pipefail

# Builds with Command Line Tools. Does not install or launch the app.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SPOKEN_ROOT"
export SPOKEN_SIGNING_MODE="${SPOKEN_SIGNING_MODE:-local}"
case "$SPOKEN_SIGNING_MODE" in
  local)
    SPOKEN_BUILD="$SPOKEN_ROOT/build/local"
    export SPOKEN_APP="$SPOKEN_ROOT/build/Spoken.app"
    ;;
  developer-id)
    /usr/bin/python3 scripts/sign_release_app.py --check
    SPOKEN_BUILD="$SPOKEN_ROOT/build/release/objects"
    export SPOKEN_APP="$SPOKEN_ROOT/build/release/Spoken.app"
    ;;
  *) printf 'Unknown signing mode: %s\n' "$SPOKEN_SIGNING_MODE" >&2; exit 1 ;;
esac
SPOKEN_TARGET="$(uname -m)-apple-macosx14.0"
SPOKEN_SPARKLE="$(bash scripts/prepare_sparkle.sh)"
# 清空旧产物，避免遗留的 ._* AppleDouble 文件被签入包内
rm -rf "$SPOKEN_APP"
mkdir -p "$SPOKEN_BUILD" "$SPOKEN_APP/Contents/MacOS" "$SPOKEN_APP/Contents/Resources"

SPOKEN_SOURCES=()
while IFS= read -r source; do SPOKEN_SOURCES+=("$source"); done < <(find Spoken -type f -name '*.swift' ! -name '._*' | LC_ALL=C sort)
xcrun clang -target "$SPOKEN_TARGET" -fobjc-arc -c Spoken/Services/ObjCExceptionCatcher.m -o "$SPOKEN_BUILD/ObjCExceptionCatcher.o"
xcrun swiftc -target "$SPOKEN_TARGET" -swift-version 5 -O \
  -F "$SPOKEN_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -module-cache-path "$SPOKEN_BUILD/module-cache" \
  -import-objc-header Spoken/Spoken-Bridging-Header.h \
  "${SPOKEN_SOURCES[@]}" "$SPOKEN_BUILD/ObjCExceptionCatcher.o" \
  -o "$SPOKEN_APP/Contents/MacOS/Spoken"
cp Spoken/Assets.xcassets/AppIcon.appiconset/icon.icns "$SPOKEN_APP/Contents/Resources/AppIcon.icns"
mkdir -p "$SPOKEN_APP/Contents/Frameworks"
ditto "$SPOKEN_SPARKLE/Sparkle.framework" "$SPOKEN_APP/Contents/Frameworks/Sparkle.framework"

/usr/bin/python3 - <<'PY'
import plistlib
import os
import re
from pathlib import Path
project = Path('Spoken.xcodeproj/project.pbxproj').read_text()
version = re.search(r'MARKETING_VERSION = ([^;]+);', project).group(1)
build = re.search(r'CURRENT_PROJECT_VERSION = ([^;]+);', project).group(1)
info = plistlib.loads(Path('Spoken/Info.plist').read_bytes())
info.update(CFBundleExecutable='Spoken', CFBundleIdentifier='com.moss.spoken', CFBundleName='Spoken',
            CFBundleShortVersionString=version, CFBundleVersion=build,
            CFBundleIconFile='AppIcon.icns', LSMinimumSystemVersion='14.0',
            CFBundleGetInfoString=('Spoken Developer ID build' if os.environ['SPOKEN_SIGNING_MODE'] == 'developer-id'
                                   else 'Spoken local development build'))
info.pop('CFBundleIconName', None)
(Path(os.environ['SPOKEN_APP']) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
# 外置卷会为文件生成 ._* AppleDouble 垃圾，签名前必须清除，否则会被当作包组件
find "$SPOKEN_APP" -name '._*' -delete 2>/dev/null || true
if [[ "$SPOKEN_SIGNING_MODE" == developer-id ]]; then
  /usr/bin/python3 scripts/sign_release_app.py --sign "$SPOKEN_APP"
else
  codesign --force --sign - --timestamp=none --entitlements Spoken/Spoken.entitlements "$SPOKEN_APP"
fi
find "$SPOKEN_APP" -name '._*' -delete 2>/dev/null || true
codesign --verify --deep --strict "$SPOKEN_APP"
printf 'Built app (%s): %s\n' "$SPOKEN_SIGNING_MODE" "$SPOKEN_APP"
