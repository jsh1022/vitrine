#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/harness/player-history/build"
APP="$OUT/PlayerHistory.app"
"$ROOT/harness/player-history/build.sh"
DEVICE="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds))')"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console "$DEVICE" dev.vitrine.player-history 2>&1 | tee "$OUT/result.log"
rg -q 'PASS player-history:' "$OUT/result.log"
