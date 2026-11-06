#!/bin/zsh
# Builds Narrate.app (release) into ./dist. Usage: scripts/build-app.sh [--open]
#
# Signing: set NARRATE_SIGN_IDENTITY to a stable code-signing identity so macOS keeps the
# Screen Recording permission between rebuilds. Without it the app is ad-hoc signed and you
# may need to re-allow it after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=dist/Narrate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Narrate "$APP/Contents/MacOS/Narrate"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Narrate</string>
    <key>CFBundleDisplayName</key><string>Narrate</string>
    <key>CFBundleIdentifier</key><string>com.ash.narrate</string>
    <key>CFBundleExecutable</key><string>Narrate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Narrate reads the text on your screen so it can speak it and highlight each word.</string>
</dict>
</plist>
PLIST

codesign --force --sign "${NARRATE_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--open" ]]; then
    pkill -x Narrate 2>/dev/null || true
    open "$APP"
fi
