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
VERSION="1.1" # Reliability release on top of 1.0: explicit mic-device selection fixed (was capturing silence), translate works on any model (Turbo auto-swaps to a translate-capable model for audio-translate sessions), Indonesian translate restored, system-capture data-race fixed, plus a "1 speaker" option and instant bilingual originals. See CHANGELOG.md for the full history.

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

# App icon (Finder / notifications) + the in-app brand logos (light/dark SVGs,
# loaded at runtime by the brand row).
if [ -f "$REPO/Resources/AppIcon.icns" ]; then
  cp "$REPO/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d "$REPO/Resources/Logo" ]; then
  cp -R "$REPO/Resources/Logo" "$APP/Contents/Resources/Logo"
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
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
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Blablacadabra uses on-device speech recognition to turn what you hear into captions. Audio never leaves your Mac.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Used once to compute exact sunrise and sunset times for the Sun theme. Never stored anywhere but this Mac.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local use and stable TCC identity per machine.
codesign --force --sign - "$APP"

# Force LaunchServices to re-index the bundle. Without this, ad-hoc signed
# rebuilds at the same path keep serving the icon cache from the previous
# bundle (or no icon at all in dialogs like the screen-recording picker).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

# Bust the per-user IconServices cache too. ScreenCaptureKit's content-sharing
# picker (and several other system dialogs) render icons via a separate daemon
# from Finder/Dock, and that daemon caches by bundle path. After an ad-hoc
# re-sign the cache still serves the old (often blank) icon until the agent
# is restarted. launchd respawns it on demand, so no service interruption.
killall iconservicesagent 2>/dev/null || true
killall iconservicesd 2>/dev/null || true

echo "Done: $APP"
echo "First launch: right-click > Open (ad-hoc signed, Gatekeeper will ask once)."
