#!/bin/bash
# Builds dist/Fast Narrate.app and signs it with the stable "Fast Narrate Dev" certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product FastNarrate
BIN="$(swift build -c "$CONFIG" --show-bin-path)/FastNarrate"

APP="dist/Fast Narrate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FastNarrate"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="Fast Narrate Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "warning: '$IDENTITY' certificate not found, signing ad-hoc." >&2
  echo "         Permissions will reset on every rebuild. Run scripts/make-cert.sh once." >&2
  codesign --force --sign - "$APP"
fi

codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)" || true
echo "Built: $APP"
