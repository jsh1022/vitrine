#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/addon-wait/build"
APP="$OUT/AddonWait.app"
DEVICE="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds))')"
"$ROOT/harness/addon-wait/build-sim.sh"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console "$DEVICE" dev.vitrine.addon-wait-harness 2>&1 | tee "$OUT/result.log"
if rg -q 'FAIL:' "$OUT/result.log"; then
  echo "Addon playback wait fixture reported a failure." >&2
  exit 1
fi
rg -q 'PASS: addon playback wait fixtures' "$OUT/result.log"
