#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/player-morph/build"
mkdir -p "$OUT/Morph.app"
perl "${THEOS:?Set THEOS}/bin/logos.pl" -c generator=internal "$ROOT/tweak/Sources/Redesigned/Player/PlayerMorph.x" > "$OUT/PlayerMorph.m"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Werror -Wno-deprecated-declarations \
  -I"$ROOT/tweak/Sources" -I"$ROOT/tweak/Sources/Redesigned/Player" \
  "$ROOT/harness/player-morph/main.m" "$ROOT/harness/scene.m" "$OUT/PlayerMorph.m" -framework UIKit -framework CoreGraphics -framework Foundation -framework QuartzCore -o "$OUT/Morph.app/Morph"
python3 - "$OUT/Morph.app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f: plistlib.dump(dict(CFBundleExecutable='Morph',CFBundleIdentifier='dev.vitrine.morph',CFBundleVersion='1',CFBundleShortVersionString='1.0',UILaunchScreen={},UIApplicationSceneManifest={'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Default','UISceneDelegateClassName':'SGRHarnessScene'}]}}),f)
PY
DEVICE="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds))')"
xcrun simctl install "$DEVICE" "$OUT/Morph.app"
xcrun simctl launch --console "$DEVICE" dev.vitrine.morph 2>&1 | tee "$OUT/result.log"
rg -q 'PASS morph: 20' "$OUT/result.log"
