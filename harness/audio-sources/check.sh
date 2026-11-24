#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tweak/Sources"
OUT="$ROOT/harness/audio-sources/build"
mkdir -p "$OUT"
# Foundation fixture executable runs on the Mac host, without Spotify or an IPA.
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-parameter \
  -I"$SRC" "$ROOT/harness/audio-sources/protocol.m" \
  "$SRC/Shared/AudioSources/SGAddonProtocol.m" "$SRC/Shared/AudioSources/SGAddonSegments.m" -framework Foundation -o "$OUT/protocol"
"$OUT/protocol"
bash "$ROOT/harness/audio-sources/diagnostics-check.sh"
bash "$ROOT/harness/audio-sources/settings-check.sh"
bash "$ROOT/harness/audio-sources/progressive-check.sh"
bash "$ROOT/harness/lossless/anchor-check.sh"
bash "$ROOT/harness/lossless/wired-check.sh"
# Compile the actual iOS sources using Apple's SDK, both with and without the tunnel.
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
LOGOS="${LOGOS:?Set LOGOS to a theos/logos checkout}"
for name in Lossless SGSourceEvents SpeedPitch SpeedPitchMenu WireGuardProxy; do
  part=Lossless
  if [ "$name" = SpeedPitchMenu ] || [ "$name" = SpeedPitch ]; then part=Player; fi
  if [ "$name" = WireGuardProxy ]; then part=NetworkProxy; fi
  perl "$LOGOS/bin/logos.pl" -c generator=internal "$SRC/Shared/$part/$name.x" > "$OUT/$name.m"
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" \
    -fobjc-arc -fblocks -fsyntax-only -Wall -Werror -Wno-deprecated-declarations \
    -include Foundation/Foundation.h -I"$SRC" -I"$SRC/Shared/$part" "$OUT/$name.m"
done
perl "$LOGOS/bin/logos.pl" -c generator=internal "$SRC/Shared/AudioSources/SGAddonPlaybackWait.x" > "$OUT/SGAddonPlaybackWait.m"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" \
  -fobjc-arc -fblocks -fsyntax-only -Wall -Werror -Wno-deprecated-declarations \
  -include Foundation/Foundation.h -I"$SRC" -I"$SRC/Shared/AudioSources" "$OUT/SGAddonPlaybackWait.m"
for relative in Native/Player/InlineLyrics.x Redesigned/Player/InlineLyrics.x Redesigned/Player/PlayerMorph.x Native/Player/PlaybackQuality.x Native/Player/FullArtwork.x Native/Player/Player.x \
                Redesigned/Player/PlaybackQuality.x Redesigned/Player/PlayerField.x Redesigned/Player/PlayerMotion.x; do
  generated="$OUT/${relative//\//_}.m"
  perl "$LOGOS/bin/logos.pl" -c generator=internal "$SRC/$relative" > "$generated"
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" \
    -fobjc-arc -fblocks -fsyntax-only -Wall -Werror -Wno-deprecated-declarations \
    -include Foundation/Foundation.h -I"$SRC" -I"$SRC/$(dirname "$relative")" "$generated"
done
for enabled in 0 1; do
  for source in "$SRC"/Shared/AudioSources/*.m "$SRC/Shared/Lossless/SGLosslessEngine.m" \
                "$SRC/Shared/Lossless/SGSegmentedDecode.m" \
                "$SRC/Shared/Lossless/SGWiredOutput.m" \
                "$SRC/Native/Player/PlayerSettings.m" "$SRC/Redesigned/Player/PlayerSettings.m" \
                "$SRC/App/Pages.m" "$SRC/Redesigned/Player/PlayerMenu.m" "$SRC/Redesigned/Player/PlayerHistory.m"; do
    # Match the release's strict deprecation policy for the newly added code.
    deprecations=-Wno-deprecated-declarations
    case "$source" in */Shared/AudioSources/*) deprecations=-Werror=deprecated-declarations ;; esac
    xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" \
      -fobjc-arc -fblocks -fsyntax-only -Wall -Werror "$deprecations" \
      -DSG_WIREGUARD="$enabled" '-DSG_VERSION="test"' -I"$SRC" \
      -I"$ROOT/vendor/wireguard/build" "$source"
  done
done
bash "$ROOT/scripts/check-layers.sh" "$SRC"

xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 -sdk "$SDK" \
  "$SRC/Shared/AudioSources/AudioPipelineSheet.swift"
