#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/lossless/build/wired"
mkdir -p "$OUT"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios16.0-simulator" \
  -isysroot "$SDK" -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -Wno-deprecated-declarations -I"$SRC" "$ROOT/harness/lossless/wired.m" \
  "$SRC/Shared/Lossless/SGWiredOutput.m" \
  -framework Foundation -framework UIKit -framework AVFoundation -framework AudioToolbox \
  -o "$OUT/wired-sim"
codesign --force --sign - "$OUT/wired-sim"
ffmpeg -v error -y -f lavfi -i 'aevalsrc=0.08*sin(2*PI*440*t)|0.06*sin(2*PI*997*t):s=44100:d=4' \
  -c:a flac -sample_fmt s16 "$OUT/fixture-44100.flac"
ffmpeg -v error -y -f lavfi -i 'aevalsrc=0.08*sin(2*PI*440*t)|0.06*sin(2*PI*997*t):s=48000:d=4' \
  -c:a flac -sample_fmt s16 "$OUT/fixture-48000.flac"
DEVICE="${SG_WIRED_SIMULATOR:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
items=[d for runtime,ds in json.load(sys.stdin)["devices"].items() if ".iOS-" in runtime for d in ds if d.get("isAvailable") and "iPhone" in d["name"]]
items.sort(key=lambda d:d["state"]!="Booted")
if not items: raise SystemExit("No available iPhone Simulator for wired output tests")
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
xcrun simctl spawn "$DEVICE" "$OUT/wired-sim" "$OUT/fixture-44100.flac" "$OUT/fixture-48000.flac"
