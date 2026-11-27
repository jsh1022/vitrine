#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/audio-sources/build/hosted"
mkdir -p "$OUT"
clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$ROOT/tweak/Sources" \
  "$ROOT/harness/audio-sources/hosted.m" \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGHostedLossless.m" \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGHostedAuthPolicy.m" \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGAddonProtocol.m" \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGAddonSegments.m" \
  -framework Foundation -framework Security -o "$OUT/check"
"$OUT/check"
