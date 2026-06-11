#!/bin/bash
# Builds the release binary and wraps it in a proper .app bundle so macOS
# treats Blablacadabra as a real app: its own TCC permission rows, LSUIElement
# (no Dock icon), usage strings for the mic and location prompts.
#
# Usage: Scripts/make-app.sh            -> ./Blablacadabra.app
#        Scripts/make-app.sh /tmp/out   -> /tmp/out/Blablacadabra.app
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$REPO}"
APP="$DEST/Blablacadabra.app"
VERSION="0.3.1" # Phase 3 + mockup-match UI pass

echo "Building release binary..."
swift build -c release --package-path "$REPO" --product Blablacadabra

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/.build/release/Blablacadabra" "$APP/Contents/MacOS/Blablacadabra"

# Bundle Nunito (body) + Jua (headings) so ATSApplicationFontsPath (=Fonts)
# registers them at launch. Same pattern as Loft Hours.
if [ -d "$REPO/Resources/Fonts" ]; then
  cp -R "$REPO/Resources/Fonts" "$APP/Contents/Resources/Fonts"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Blablacadabra</string>
    <key>CFBundleIdentifier</key>
    <string>com.lazyfox.blablacadabra</string>
    <key>CFBundleName</key>
    <string>Blablacadabra</string>
    <key>CFBundleDisplayName</key>
    <string>Blablacadabra</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>ATSApplicationFontsPath</key>
    <string>Fonts</string>
    <key>NSHumanReadableCopyright</key>
    <string>Now you hear it, now you read it.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>With the mic I can also caption people in the room with you. Optional, your call.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Used once to compute exact sunrise and sunset times for the Sun theme. Never stored anywhere but this Mac.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local use and stable TCC identity per machine.
codesign --force --sign - "$APP"

echo "Done: $APP"
echo "First launch: right-click > Open (ad-hoc signed, Gatekeeper will ask once)."
