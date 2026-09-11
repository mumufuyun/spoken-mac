#!/bin/bash
set -euo pipefail

# Uses Command Line Tools; all HTTP responses are supplied by URLProtocol.
# Does not read Keychain, use live model tests, or write application settings.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOKEN_TEST_BUILD="$(mktemp -d /tmp/spoken-offline-tests.XXXXXX)"
trap 'rm -rf "$SPOKEN_TEST_BUILD"' EXIT
cd "$SPOKEN_ROOT"

SPOKEN_SOURCES=()
while IFS= read -r source; do SPOKEN_SOURCES+=("$source"); done < <(find Spoken -type f -name '*.swift' ! -path 'Spoken/App/main.swift' | LC_ALL=C sort)
xcrun clang -fobjc-arc -c Spoken/Services/ObjCExceptionCatcher.m -o "$SPOKEN_TEST_BUILD/ObjCExceptionCatcher.o"
xcrun swiftc -swift-version 5 -D SPOKEN_OFFLINE_TESTS -module-cache-path "$SPOKEN_TEST_BUILD/module-cache" \
  -import-objc-header Spoken/Spoken-Bridging-Header.h \
  "${SPOKEN_SOURCES[@]}" SpokenTests/Offline/AIProcessingRegression.swift \
  "$SPOKEN_TEST_BUILD/ObjCExceptionCatcher.o" -o "$SPOKEN_TEST_BUILD/offline-ai-tests"
if [[ "${1:-}" == "--build-ui-smoke" ]]; then
  SPOKEN_SMOKE_APP="$SPOKEN_ROOT/build/SpokenSmoke.app"
  mkdir -p "$SPOKEN_SMOKE_APP/Contents/MacOS"
  cp "$SPOKEN_TEST_BUILD/offline-ai-tests" "$SPOKEN_SMOKE_APP/Contents/MacOS/SpokenSmoke"
  cat > "$SPOKEN_SMOKE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.spoken.offline-smoke</string>
<key>CFBundleExecutable</key><string>SpokenSmoke</string>
<key>CFBundleName</key><string>Spoken 本地冒烟</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
  codesign --force --sign - --timestamp=none "$SPOKEN_SMOKE_APP"
  printf 'Built isolated UI smoke app: %s\n' "$SPOKEN_SMOKE_APP"
else
  "$SPOKEN_TEST_BUILD/offline-ai-tests" "$@"
fi
