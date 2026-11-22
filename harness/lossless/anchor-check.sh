#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/lossless/build/anchor"
mkdir -p "$OUT"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios16.0-simulator" \
  -isysroot "$SDK" -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$SRC" "$ROOT/harness/lossless/anchor.m" \
  "$SRC/Shared/Lossless/SGLosslessEngine.m" \
  "$SRC/Shared/AudioSources/SGProgressiveFLAC.m" \
  -framework Foundation -framework UIKit -framework AudioToolbox -framework Accelerate \
  -o "$OUT/anchor-sim"
codesign --force --sign - "$OUT/anchor-sim"

# Independent noise recordings make accidental/periodic matches unlikely. Keep them well beyond
# the 4 s capture and hint-local window so the harness also exercises bounded prefix decoding.
ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=42:r=44100:d=32' \
  -ac 2 -c:a flac -sample_fmt s16 "$OUT/fixture.flac"
ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=73:r=44100:d=32' \
  -ac 2 -c:a flac -sample_fmt s16 "$OUT/wrong.flac"

DEVICE="${SG_ANCHOR_SIMULATOR:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
items=[d for runtime,ds in json.load(sys.stdin)["devices"].items() if ".iOS-" in runtime for d in ds if d.get("isAvailable") and "iPhone" in d["name"]]
items.sort(key=lambda d:d["state"]!="Booted")
if not items: raise SystemExit("No available iPhone Simulator for lossless anchor tests")
print(items[0]["udid"])
')"
fi
WAS_BOOTED="$(xcrun simctl list devices -j | python3 -c 'import json,sys; key=sys.argv[1]; print(next(d["state"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["udid"]==key))' "$DEVICE")"
cleanup() {
  if [ "$WAS_BOOTED" != Booted ]; then xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
if [ "$WAS_BOOTED" != Booted ]; then
  xcrun simctl boot "$DEVICE"
  xcrun simctl bootstatus "$DEVICE" -b
fi
xcrun simctl spawn "$DEVICE" "$OUT/anchor-sim" "$OUT/fixture.flac" "$OUT/wrong.flac"
