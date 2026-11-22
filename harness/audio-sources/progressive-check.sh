#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/audio-sources/build/progressive"
mkdir -p "$OUT"
# This is an iOS decoder test. macOS AudioToolbox can parse the FLAC header yet
# reject PCM conversion (fmt?), including for a complete URL-backed file. Run
# the unchanged decode/continuation/truncation/cancellation assertions on iOS.
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios16.0-simulator" \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$ROOT/tweak/Sources" "$ROOT/harness/audio-sources/progressive.m" \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGProgressiveFLAC.m" \
  -framework Foundation -framework AudioToolbox -o "$OUT/check-ios"
codesign --force --sign - "$OUT/check-ios"
ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=42:r=44100:d=12' \
  -ac 2 -c:a flac -sample_fmt s16 "$OUT/fixture.flac"
DEVICE="${SG_PROGRESSIVE_SIMULATOR:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
items=[d for runtime,ds in json.load(sys.stdin)["devices"].items() if ".iOS-" in runtime for d in ds if d.get("isAvailable") and "iPhone" in d["name"]]
items.sort(key=lambda d:d["state"]!="Booted")
if not items: raise SystemExit("No available iPhone Simulator for FLAC decoder tests")
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
xcrun simctl spawn "$DEVICE" "$OUT/check-ios" "$OUT/fixture.flac" "$OUT"
