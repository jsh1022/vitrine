#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/audio-sources/build/progressive"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$ROOT/tweak/Sources" "$ROOT/harness/audio-sources/progressive.m" \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGProgressiveFLAC.m" \
  -framework Foundation -framework AudioToolbox -o "$OUT/check"
ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=42:r=44100:d=12' \
  -ac 2 -c:a flac -sample_fmt s16 "$OUT/fixture.flac"
"$OUT/check" "$OUT/fixture.flac" "$OUT"
