#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/addon-wait/build"
APP="$OUT/AddonWait.app"
mkdir -p "$OUT/module-cache" "$APP"
if [[ -n "${LOGOS:-}" ]]; then
  if [[ "$LOGOS" == */logos.pl ]]; then LOGOS_TOOL="$LOGOS"; else LOGOS_TOOL="$LOGOS/bin/logos.pl"; fi
elif [[ -n "${THEOS:-}" ]]; then
  LOGOS_TOOL="$THEOS/bin/logos.pl"
else
  echo "Set LOGOS (Logos directory or logos.pl) or THEOS before building." >&2
  exit 1
fi
perl "$LOGOS_TOOL" -c generator=internal \
  "$ROOT/tweak/Sources/Shared/AudioSources/SGAddonPlaybackWait.x" > "$OUT/SGAddonPlaybackWait.m"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang \
  -target "$(uname -m)-apple-ios17.0-simulator" -isysroot "$SDK" \
  -fobjc-arc -fblocks -fmodules -fmodules-cache-path="$OUT/module-cache" \
  -ffunction-sections -fdata-sections -DSG_WIREGUARD=0 \
  -I"$ROOT/harness/addon-wait/stubs" -I"$ROOT/tweak/Sources" \
  -I"$ROOT/tweak/Sources/Shared/AudioSources" \
  "$ROOT/harness/addon-wait/main.m" \
  -framework Foundation -framework UIKit -framework AudioToolbox \
  -Wl,-dead_strip -o "$APP/addon-wait"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
info = {
    "CFBundleExecutable": "addon-wait",
    "CFBundleIdentifier": "dev.vitrine.addon-wait-harness",
    "CFBundleName": "AddonWaitHarness",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "UILaunchScreen": {},
}
(app / "Info.plist").write_bytes(plistlib.dumps(info))
PY
echo "Built simulator app at $APP (not launched)."
