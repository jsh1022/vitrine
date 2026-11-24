#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/audio-sources/build"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -I"$SRC" "$ROOT/harness/audio-sources/diagnostics.m" \
  "$SRC/Shared/AudioSources/SGAddonDiagnostics.m" -framework Foundation -o "$OUT/diagnostics-storage"
"$OUT/diagnostics-storage"
