#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/player-history/build/abi"
APP="$OUT/QueueABI.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="$(uname -m)-apple-ios17.0-simulator"
cat "$ROOT/tweak/Sources/Redesigned/Player/PlayerHistoryRows.swift" "$ROOT/harness/player-history/abi.swift" > "$OUT/main.swift"
xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -Wall -Werror -c "$ROOT/tweak/Sources/Redesigned/Player/PlayerHistoryABI.m" -o "$OUT/abi.o"
xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -c "$ROOT/harness/scene.m" -o "$OUT/scene.o"
xcrun --sdk iphonesimulator swiftc -warnings-as-errors -target "$TARGET" -sdk "$SDK" -module-cache-path "$OUT/module-cache" "$OUT/main.swift" "$OUT/abi.o" "$OUT/scene.o" -o "$APP/QueueABI"
python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f: plistlib.dump(dict(CFBundleExecutable='QueueABI',CFBundleIdentifier='dev.vitrine.queue-abi',CFBundleName='QueueABI',CFBundleVersion='1',CFBundleShortVersionString='1.0',UILaunchScreen={},UIApplicationSceneManifest={'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Default','UISceneDelegateClassName':'SGRHarnessScene'}]}}),f)
PY
DEVICE="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds))')"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console "$DEVICE" dev.vitrine.queue-abi 2>&1 | tee "$OUT/result.log"
rg -q 'PASS queue-abi:' "$OUT/result.log"
