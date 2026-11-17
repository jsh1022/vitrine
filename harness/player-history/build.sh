#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/player-history/build"
APP="$OUT/PlayerHistory.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios17.0-simulator" -isysroot "$SDK" \
  -fobjc-arc -fblocks -Wall -Werror -Wno-deprecated-declarations \
  -I"$SRC" -I"$SRC/Redesigned/Player" \
  "$ROOT/harness/player-history/main.m" "$ROOT/harness/player-history/stubs.m" "$ROOT/harness/scene.m" \
  "$SRC/Redesigned/Player/PlayerHistory.m" \
  "$SRC/Core/SGGlass.m" \
  -framework UIKit -framework Foundation -framework QuartzCore -o "$APP/PlayerHistory"
python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f: plistlib.dump(dict(CFBundleExecutable='PlayerHistory',CFBundleIdentifier='dev.vitrine.player-history',CFBundleName='PlayerHistory',CFBundleVersion='1',CFBundleShortVersionString='1.0',UILaunchScreen={},UIApplicationSceneManifest={'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Default','UISceneDelegateClassName':'SGRHarnessScene'}]}}),f)
PY
echo "built $APP"
