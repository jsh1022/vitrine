#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/audio-sources/build/settings"
mkdir -p "$OUT"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM=simulator bash "$ROOT/vendor/hosted-media/build.sh"
MEDIA="$ROOT/vendor/hosted-media/build/simulator/install"
TEST_SOURCE="$ROOT/harness/audio-sources/settings.m"
EXTRA=()
ARGS=()
if [ "${SG_STREAMING_QUALITY_TEST:-0}" = 1 ]; then
  TEST_SOURCE="$ROOT/harness/audio-sources/source-race-download.m"
  EXTRA=("$SRC/Shared/AudioSources/SGProgressiveFLAC.m")
  ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=42:r=44100:d=12' -ac 2 -c:a flac -sample_fmt s16 "$OUT/low.flac"
  ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=42:r=96000:d=12' -ac 2 -c:a flac -sample_fmt s32 "$OUT/high.flac"
  ARGS=("$OUT/low.flac" "$OUT/high.flac")
fi
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios16.0-simulator" \
  -isysroot "$SDK" -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
  -Wno-deprecated-declarations -I"$SRC" -I"$MEDIA/include" "$TEST_SOURCE" ${EXTRA[@]+"${EXTRA[@]}"} \
  "$SRC/Shared/AudioSources/SGAddons.m" \
  "$SRC/Shared/AudioSources/SGAddonPolicy.m" \
  "$SRC/Shared/AudioSources/SGAddonProtocol.m" \
  "$SRC/Shared/AudioSources/SGAddonSourceRace.m" \
  "$SRC/Shared/AudioSources/SGAddonSegments.m" \
  "$SRC/Shared/AudioSources/SGHostedLossless.m" \
  "$SRC/Shared/AudioSources/SGHostedMedia.m" \
  "$MEDIA/lib/libavformat.a" "$MEDIA/lib/libavcodec.a" "$MEDIA/lib/libavutil.a" -lz \
  -framework Foundation -framework UIKit -framework AudioToolbox -framework Network \
  -o "$OUT/settings-sim"
codesign --force --sign - "$OUT/settings-sim"
DEVICE="${SG_SETTINGS_SIMULATOR:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
items=[d for runtime,ds in json.load(sys.stdin)["devices"].items() if ".iOS-" in runtime for d in ds if d.get("isAvailable") and "iPhone" in d["name"]]
items.sort(key=lambda d:d["state"]!="Booted")
if not items: raise SystemExit("No available iPhone Simulator for addon settings tests")
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
xcrun simctl spawn "$DEVICE" "$OUT/settings-sim" ${ARGS[@]+"${ARGS[@]}"}

if [ "${SG_STREAMING_QUALITY_TEST:-0}" = 1 ]; then
  xcrun simctl spawn "$DEVICE" "$OUT/settings-sim" "${ARGS[@]}" deezer
fi
