#!/bin/bash
set -euo pipefail
# An isolated real-Carbon harness with a mock recording state. Never reads the app's saved configuration.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SPOKEN_ROOT"
SPOKEN_HOTKEY_BUILD="$SPOKEN_ROOT/build/hotkey-smoke"
SPOKEN_HOTKEY_APP="$SPOKEN_ROOT/build/SpokenHotkeySmoke.app"
mkdir -p "$SPOKEN_HOTKEY_BUILD" "$SPOKEN_HOTKEY_APP/Contents/MacOS"
SPOKEN_SOURCES=()
while IFS= read -r source; do SPOKEN_SOURCES+=("$source"); done < <(find Spoken -type f -name '*.swift' ! -path 'Spoken/App/main.swift' | LC_ALL=C sort)
xcrun clang -fobjc-arc -c Spoken/Services/ObjCExceptionCatcher.m -o "$SPOKEN_HOTKEY_BUILD/ObjCExceptionCatcher.o"
xcrun swiftc -swift-version 5 -module-cache-path "$SPOKEN_HOTKEY_BUILD/module-cache" \
  -import-objc-header Spoken/Spoken-Bridging-Header.h \
  "${SPOKEN_SOURCES[@]}" SpokenTests/Offline/HotKeySmoke.swift \
  "$SPOKEN_HOTKEY_BUILD/ObjCExceptionCatcher.o" -o "$SPOKEN_HOTKEY_APP/Contents/MacOS/SpokenHotkeySmoke"
cat > "$SPOKEN_HOTKEY_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.spoken.hotkey-smoke</string>
<key>CFBundleExecutable</key><string>SpokenHotkeySmoke</string>
<key>CFBundleName</key><string>Spoken 快捷键隔离冒烟</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$SPOKEN_HOTKEY_APP"
printf 'Built isolated hotkey smoke app: %s\n' "$SPOKEN_HOTKEY_APP"
