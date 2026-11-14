#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
sh "$ROOT/harness/lossless/handoff-build.sh"
DEVICE="$(xcrun simctl list devices available -j | python3 -c 'import sys,json; ds=json.load(sys.stdin)["devices"]; print(next(d["udid"] for runtime,devices in ds.items() if ".iOS-" in runtime for d in devices if d.get("isAvailable") and "iPhone" in d["name"]))')"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$ROOT/harness/lossless/build/handoff/LosslessHandoff.app"
python3 "$ROOT/harness/audio-sources/run-presentation.py" "$DEVICE" "$ROOT/harness/lossless/build/handoff" --handoff
