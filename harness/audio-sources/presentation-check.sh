#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/audio-sources/build"
APP="$OUT/AudioPresentation.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
perl "${LOGOS:?Set LOGOS to a theos/logos checkout}/bin/logos.pl" -c generator=internal \
  "$SRC/Shared/NetworkProxy/WireGuardProxy.x" > "$OUT/WireGuardProxy.m"
OBJ="$OUT/presentation-objects"
mkdir -p "$OBJ"
SOURCES=("$ROOT/harness/audio-sources/presentation.m" "$ROOT/harness/audio-sources/presentation-stubs.m"
  "$ROOT/harness/scene.m" "$SRC/Shared/AudioSources/AudioSourcesSettings.m"
  "$SRC/Shared/AudioSources/PlaybackDetails.m" "$SRC/Shared/AudioSources/SGAudioPresentation.m"
  "$SRC/Shared/AudioSources/SGAudioPipeline.m" "$SRC/Core/SGGlass.m" "$OUT/WireGuardProxy.m")
for index in "${!SOURCES[@]}"; do
  xcrun --sdk iphonesimulator clang -target "$(uname -m)-apple-ios17.0-simulator" \
    -isysroot "$SDK" -fobjc-arc -fblocks -Wall -Werror -Wno-deprecated-declarations \
    -I"$SRC" -c "${SOURCES[$index]}" -o "$OBJ/$index.o"
done
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-ios17.0-simulator" \
  -sdk "$SDK" "$SRC/Shared/AudioSources/AudioPipelineSheet.swift" "$OBJ"/*.o \
  -framework Foundation -framework UIKit -framework SwiftUI -framework QuartzCore \
  -framework UniformTypeIdentifiers -framework AVFoundation -framework AudioToolbox \
  -o "$APP/AudioPresentation"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib,sys
info={'CFBundleExecutable':'AudioPresentation','CFBundleIdentifier':'dev.vitrine.audio-presentation',
 'CFBundleName':'AudioPresentation','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','UILaunchScreen':{},
 'UIApplicationSceneManifest':{'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[
 {'UISceneConfigurationName':'Default','UISceneDelegateClassName':'SGRHarnessScene'}]}}}
(Path(sys.argv[1])/'Info.plist').write_bytes(plistlib.dumps(info))
PY
DEVICE="$(xcrun simctl list devices available -j | python3 -c 'import sys,json; ds=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime,devices in ds.items() if ".iOS-" in runtime for d in devices if d.get("isAvailable") and "iPhone" in d["name"]))')"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
python3 "$ROOT/harness/audio-sources/run-presentation.py" "$DEVICE" "$OUT"
