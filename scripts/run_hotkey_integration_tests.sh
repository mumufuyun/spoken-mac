#!/bin/bash
set -euo pipefail
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOKEN_HOTKEY_BUILD="$(mktemp -d /tmp/spoken-hotkey-integration.XXXXXX)"
trap 'rm -rf "$SPOKEN_HOTKEY_BUILD"' EXIT
cd "$SPOKEN_ROOT"
xcrun swiftc -swift-version 5 -module-cache-path "$SPOKEN_HOTKEY_BUILD/module-cache" \
  Spoken/Models/ConfigurationStore.swift Spoken/Services/HotKeyService.swift \
  SpokenTests/Offline/HotKeyIntegration.swift -o "$SPOKEN_HOTKEY_BUILD/hotkey-integration"
"$SPOKEN_HOTKEY_BUILD/hotkey-integration"
