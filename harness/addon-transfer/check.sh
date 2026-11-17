#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/addon-transfer/build"
APP="$OUT/AddonTransfer.app"
DEVICE="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds))')"
"$ROOT/harness/addon-transfer/build-sim.sh"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console "$DEVICE" dev.vitrine.addon-transfer-harness 2>&1 | tee "$OUT/result.log"
if rg -q 'FAIL:' "$OUT/result.log"; then
  echo "Addon transfer fixture reported a failure." >&2
  exit 1
fi
rg -q 'PASS: SGAddonTransfer delegate fixtures' "$OUT/result.log"
