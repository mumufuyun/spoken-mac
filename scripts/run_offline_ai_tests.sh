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
xcrun swiftc -swift-version 5 -module-cache-path "$SPOKEN_TEST_BUILD/module-cache" \
  -import-objc-header Spoken/Spoken-Bridging-Header.h \
  "${SPOKEN_SOURCES[@]}" SpokenTests/Offline/AIProcessingRegression.swift \
  "$SPOKEN_TEST_BUILD/ObjCExceptionCatcher.o" -o "$SPOKEN_TEST_BUILD/offline-ai-tests"
"$SPOKEN_TEST_BUILD/offline-ai-tests"
