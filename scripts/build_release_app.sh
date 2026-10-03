#!/bin/bash
set -euo pipefail

# Check before building; a missing certificate must never produce an ad-hoc release.
SPOKEN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SPOKEN_SIGNING_MODE=developer-id
exec bash "$SPOKEN_ROOT/scripts/build_local_app.sh"
