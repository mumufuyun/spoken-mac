#!/bin/bash
set -e

DMG_NAME="Spoken-v1.0.0"
APP_PATH="../Release/Spoken.app"
OUTPUT_DIR=".."
ASSETS_DIR=".dmg-assets"

echo "Building fancy DMG..."

create-dmg \
  --volname "Spoken Installer" \
  --background "$ASSETS_DIR/background.png" \
  --window-pos 200 120 \
  --window-size 600 450 \
  --icon-size 80 \
  --icon "Spoken.app" 150 220 \
  --hide-extension "Spoken.app" \
  --app-drop-link 450 220 \
  --no-internet-enable \
  "$OUTPUT_DIR/$DMG_NAME.dmg" \
  "$APP_PATH"

echo "Done! Created $OUTPUT_DIR/$DMG_NAME.dmg"
