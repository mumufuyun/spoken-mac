#!/bin/bash
set -euo pipefail

# Builds a local app with Command Line Tools. Does not install or launch it.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SPOKEN_ROOT"
SPOKEN_BUILD="$SPOKEN_ROOT/build/local"
SPOKEN_APP="$SPOKEN_ROOT/build/Spoken.app"
SPOKEN_TARGET="$(uname -m)-apple-macosx14.0"
mkdir -p "$SPOKEN_BUILD" "$SPOKEN_APP/Contents/MacOS" "$SPOKEN_APP/Contents/Resources"

SPOKEN_SOURCES=()
while IFS= read -r source; do SPOKEN_SOURCES+=("$source"); done < <(find Spoken -type f -name '*.swift' | LC_ALL=C sort)
xcrun clang -target "$SPOKEN_TARGET" -fobjc-arc -c Spoken/Services/ObjCExceptionCatcher.m -o "$SPOKEN_BUILD/ObjCExceptionCatcher.o"
xcrun swiftc -target "$SPOKEN_TARGET" -swift-version 5 -O \
  -module-cache-path "$SPOKEN_BUILD/module-cache" \
  -import-objc-header Spoken/Spoken-Bridging-Header.h \
  "${SPOKEN_SOURCES[@]}" "$SPOKEN_BUILD/ObjCExceptionCatcher.o" \
  -o "$SPOKEN_APP/Contents/MacOS/Spoken"
cp Spoken/Assets.xcassets/AppIcon.appiconset/icon.icns "$SPOKEN_APP/Contents/Resources/AppIcon.icns"

/usr/bin/python3 - <<'PY'
import plistlib
import re
from pathlib import Path
project = Path('Spoken.xcodeproj/project.pbxproj').read_text()
version = re.search(r'MARKETING_VERSION = ([^;]+);', project).group(1)
build = re.search(r'CURRENT_PROJECT_VERSION = ([^;]+);', project).group(1)
info = plistlib.loads(Path('Spoken/Info.plist').read_bytes())
info.update(CFBundleExecutable='Spoken', CFBundleIdentifier='com.moss.spoken', CFBundleName='Spoken',
            CFBundleShortVersionString=version, CFBundleVersion=build + '.1',
            CFBundleIconFile='AppIcon.icns', LSMinimumSystemVersion='14.0',
            CFBundleGetInfoString='Spoken local development build')
info.pop('CFBundleIconName', None)
Path('build/Spoken.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - --timestamp=none --entitlements Spoken/Spoken.entitlements "$SPOKEN_APP"
codesign --verify --strict "$SPOKEN_APP"
printf 'Built local app: %s\n' "$SPOKEN_APP"
