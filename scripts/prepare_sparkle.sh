#!/bin/bash
set -euo pipefail

# Pinned, checksum-verified tooling for both local builds and release signing.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPOKEN_SPARKLE_VERSION=2.10.0
SPOKEN_SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPOKEN_DEPS="$SPOKEN_ROOT/build/dependencies"
SPOKEN_SPARKLE="$SPOKEN_DEPS/Sparkle-$SPOKEN_SPARKLE_VERSION"
SPOKEN_ARCHIVE="$SPOKEN_DEPS/Sparkle-$SPOKEN_SPARKLE_VERSION.tar.xz"
mkdir -p "$SPOKEN_DEPS"
if [[ ! -f "$SPOKEN_ARCHIVE" ]]; then
  curl -fLsS --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$SPOKEN_SPARKLE_VERSION/Sparkle-$SPOKEN_SPARKLE_VERSION.tar.xz" -o "$SPOKEN_ARCHIVE.download"
  mv "$SPOKEN_ARCHIVE.download" "$SPOKEN_ARCHIVE"
fi
printf '%s  %s\n' "$SPOKEN_SPARKLE_SHA256" "$SPOKEN_ARCHIVE" | shasum -a 256 -c - >&2
if [[ ! -f "$SPOKEN_SPARKLE/.verified-$SPOKEN_SPARKLE_SHA256" ]]; then
  mkdir -p "$SPOKEN_SPARKLE"
  tar -xJf "$SPOKEN_ARCHIVE" -C "$SPOKEN_SPARKLE"
  touch "$SPOKEN_SPARKLE/.verified-$SPOKEN_SPARKLE_SHA256"
fi
printf '%s\n' "$SPOKEN_SPARKLE"
