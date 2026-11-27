#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/audio-sources/build/source-race"
mkdir -p "$OUT"
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$ROOT/tweak/Sources" "$ROOT/harness/audio-sources/source-race.m" \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGAddonSourceRace.m" \
  -framework Foundation -o "$OUT/check"
"$OUT/check"
