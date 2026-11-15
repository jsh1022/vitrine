#!/usr/bin/env bash
# Upload a finished IPA and verify the entire downloaded file, not only a response header.
set -euo pipefail
IPA="${1:?usage: upload-filebin.sh IPA BIN}"
BIN="${2:?usage: upload-filebin.sh IPA BIN}"
NAME="$(basename "$IPA")"
URL="https://filebin.net/$BIN/$NAME"
BEFORE="$(shasum -a 256 "$IPA" | awk '{print $1}')"
curl -fsS --retry 2 -X POST -H 'Content-Type: application/octet-stream' --data-binary "@$IPA" "$URL" >/dev/null
CHECK="$(mktemp -d)"
curl -fsSL --retry 3 "$URL" -o "$CHECK/$NAME"
AFTER="$(shasum -a 256 "$CHECK/$NAME" | awk '{print $1}')"
[ "$BEFORE" = "$AFTER" ] || { echo 'Filebin SHA-256 mismatch' >&2; exit 1; }
cmp -s "$IPA" "$CHECK/$NAME"
printf 'SHA-256: %s\nDownload: %s\n' "$BEFORE" "$URL"
