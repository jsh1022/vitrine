#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/addon-transfer/build"
APP="$OUT/AddonTransfer.app"
mkdir -p "$APP" "$OUT/module-cache"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$OUT/module-cache"
xcrun --sdk iphonesimulator clang \
  -target "$(uname -m)-apple-ios17.0-simulator" -isysroot "$SDK" \
  -fobjc-arc -fblocks -fmodules -fmodules-cache-path="$OUT/module-cache" \
  -ffunction-sections -fdata-sections \
  -DSG_WIREGUARD=0 '-DSG_VERSION="harness"' \
  -I"$ROOT/harness/addon-transfer/stubs" -I"$ROOT/tweak/Sources" \
  -I"$ROOT/tweak/Sources/Shared/AudioSources" \
  "$ROOT/harness/addon-transfer/main.m" \
  -framework Foundation -framework UIKit -framework Network -framework AudioToolbox \
  -Wl,-dead_strip -o "$APP/addon-transfer"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
info = {
    "CFBundleExecutable": "addon-transfer",
    "CFBundleIdentifier": "dev.vitrine.addon-transfer-harness",
    "CFBundleName": "AddonTransferHarness",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1.0",
    "UILaunchScreen": {},
}
(app / "Info.plist").write_bytes(plistlib.dumps(info))
PY
echo "Built simulator app at $APP (not launched)."
