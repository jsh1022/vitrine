#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/audio-sources/build/hosted-media"
INSTALL="$ROOT/vendor/hosted-media/build/simulator/install"
BIN="$OUT/check-ios"
mkdir -p "$OUT"
PLATFORM=simulator bash "$ROOT/vendor/hosted-media/build.sh"
test -f "$INSTALL/lib/libavformat.a" && test -f "$INSTALL/include/libavformat/avformat.h" || {
  echo "Missing simulator FFmpeg install; run PLATFORM=simulator vendor/hosted-media/build.sh" >&2; exit 1;
}
ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=42:r=44100:d=3' \
  -ac 2 -c:a flac -sample_fmt s16 -compression_level 0 "$OUT/source.flac"
mkdir -p "$OUT/hires"
ffmpeg -v error -y -f lavfi -i 'anoisesrc=color=white:seed=42:r=96000:d=3' \
  -ac 2 -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 "$OUT/hires/source.flac"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios17.0-simulator" -isysroot "$SDK" \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -I"$SRC" -I"$INSTALL/include" "$ROOT/harness/audio-sources/hosted-media.m" \
  "$SRC/Shared/AudioSources/SGHostedMedia.m" "$SRC/Shared/AudioSources/SGProgressiveFLAC.m" \
  "$INSTALL/lib/libavformat.a" "$INSTALL/lib/libavcodec.a" "$INSTALL/lib/libavutil.a" \
  -lz -lm -framework Foundation -framework AudioToolbox -framework CoreAudio -framework Security \
  -o "$BIN"
codesign --force --sign - "$BIN"
python3 - "$BIN" "$OUT" "${SG_HOSTED_MEDIA_SIMULATOR:-}" <<'PY'
from pathlib import Path
import json,subprocess,sys
binary,out,requested=sys.argv[1],Path(sys.argv[2]),sys.argv[3]
def run(args,timeout=30):
    return subprocess.run(args,capture_output=True,text=True,timeout=timeout)
listed=run(['xcrun','simctl','list','devices','available','-j'])
if listed.returncode or not listed.stdout.strip():
    raise SystemExit('FAIL: CoreSimulator service unavailable; media test compiled and fixtures were generated but simulator execution could not start')
devices=json.loads(listed.stdout)['devices']
rows=[d for runtime,ds in devices.items() if '.iOS-' in runtime for d in ds if d.get('isAvailable') and 'iPhone' in d['name']]
rows.sort(key=lambda d:d['state']!='Booted')
device=next((d for d in rows if d['udid']==requested),None) if requested else (rows[0] if rows else None)
if not device: raise SystemExit('FAIL: no available iPhone Simulator matching SG_HOSTED_MEDIA_SIMULATOR')
udid=device['udid']; was_booted=device['state']=='Booted'
try:
    if not was_booted:
        for args,timeout in [(['xcrun','simctl','boot',udid],30),(['xcrun','simctl','bootstatus',udid,'-b'],120)]:
            result=run(args,timeout)
            if result.returncode: raise SystemExit('FAIL: simulator boot failed: '+result.stdout+result.stderr)
    result=run(['xcrun','simctl','spawn',udid,binary,str(out/'source.flac'),str(out/'hires/source.flac'),str(out)],60)
    print(result.stdout+result.stderr,end='')
    if result.returncode: raise SystemExit(f'FAIL: hosted media assertions exited {result.returncode}')
finally:
    if not was_booted: run(['xcrun','simctl','shutdown',udid],20)
PY
