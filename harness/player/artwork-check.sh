#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
bash harness/player/build.sh
DEVICE="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds))')"
OUT="$ROOT/harness/player/build"
ffmpeg -v error -y -f lavfi -i color=c=black:s=360x480:d=4 -c:v libx264 -pix_fmt yuv420p "$OUT/motion.mp4"
xcrun simctl terminate "$DEVICE" com.vojta.playerharness 2>/dev/null || true
xcrun simctl install "$DEVICE" "$OUT/PlayerHarness.app"
SIMCTL_CHILD_HARNESS_SCENARIO=inline-art xcrun simctl launch --console "$DEVICE" com.vojta.playerharness > "$OUT/inline-art.log" 2>&1
rg -q 'PASS inline artwork:' "$OUT/inline-art.log"
SIMCTL_CHILD_HARNESS_SCENARIO=motion SIMCTL_CHILD_HARNESS_CANVAS_FILE="$OUT/motion.mp4" SIMCTL_CHILD_HARNESS_DIM=0.10 SIMCTL_CHILD_HARNESS_BLACK_FOOT=1 SIMCTL_CHILD_HARNESS_EXIT_AFTER_CHECKS=1 \
  xcrun simctl launch --console "$DEVICE" com.vojta.playerharness > "$OUT/motion.log" 2>&1
rg -q 'motion checks: 26 of 26 right -- PASS' "$OUT/motion.log"
cat "$OUT/inline-art.log"
rg 'motion check|motion checks:' "$OUT/motion.log"
"$(dirname "$0")/main.m" "$(dirname "$0")/../scene.m" "$(dirname "$0")/stubs.m" "$(dirname "$0")/../player-history/stubs.m" "$(dirname "$0")/../tabbar/touch.m" \
