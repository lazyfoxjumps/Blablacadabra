#!/bin/bash
# Builds a styled installer DMG: Blablacadabra.app side-by-side with an
# Applications symlink, a navy background image with the wordmark, and a
# centered Finder window the user can just drag from. Layout is baked into
# the DMG's .DS_Store so it looks the same on every mount.
#
# Usage: Scripts/make-dmg.sh                   -> ./Blablacadabra-<ver>.dmg
#        Scripts/make-dmg.sh /tmp/out          -> /tmp/out/Blablacadabra-<ver>.dmg
#        Scripts/make-dmg.sh "" 1.2            -> override version on a one-off
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO}"
VERSION="${2:-1.1}"
APP="$REPO/Blablacadabra.app"
DMG="$OUT_DIR/Blablacadabra-${VERSION}.dmg"
VOL_NAME="Blablacadabra ${VERSION}"
STAGE="$(mktemp -d -t blablacadabra-dmg)"
# Sibling scratch dir for the RW DMG so hdiutil doesn't try to include the
# in-progress DMG file in its own srcfolder scan.
SCRATCH="$(mktemp -d -t blablacadabra-dmg-scratch)"

if [ ! -d "$APP" ]; then
  echo "App bundle missing at $APP — run Scripts/make-app.sh first." >&2
  exit 1
fi

trap 'rm -rf "$STAGE" "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# 1. Stage: app + Applications symlink + .background/background.png
# ---------------------------------------------------------------------------
echo "Staging DMG contents at $STAGE..."
cp -R "$APP" "$STAGE/Blablacadabra.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"

# Render the install-window background image inline via Swift + AppKit. Navy
# gradient, brand wordmark + version, simple "Drag to install" hint. Lives
# inside the DMG only — not shipped in the app bundle.
echo "Rendering DMG background image..."
BG_OUT="$STAGE/.background/background.png"
WORDMARK_SVG="$REPO/Resources/Logo/BlablacadabraLogo-Dark.svg"
if [ ! -f "$WORDMARK_SVG" ]; then
  echo "Missing wordmark SVG at $WORDMARK_SVG" >&2
  exit 1
fi
swift - "$WORDMARK_SVG" "$BG_OUT" <<'SWIFT'
import AppKit
import Foundation

let args = CommandLine.arguments
let wordmarkURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let size = NSSize(width: 700, height: 440)
let dark = NSColor(srgbRed: 0x03/255.0, green: 0x2B/255.0, blue: 0x41/255.0, alpha: 1) // Abyssal
let edge = NSColor(srgbRed: 0x35/255.0, green: 0x5A/255.0, blue: 0x69/255.0, alpha: 1) // Steel
let cream = NSColor(srgbRed: 0xF0/255.0, green: 0xE0/255.0, blue: 0xC3/255.0, alpha: 1)

let image = NSImage(size: size)
image.lockFocus()
defer { image.unlockFocus() }
let ctx = NSGraphicsContext.current!.cgContext

// Diagonal navy gradient.
let gradient = NSGradient(colors: [dark, edge])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 35)

// Centered wordmark, ~40% width.
if let wordmark = NSImage(contentsOf: wordmarkURL) {
    let targetWidth = size.width * 0.36
    let aspect = wordmark.size.height / max(1, wordmark.size.width)
    let drawSize = NSSize(width: targetWidth, height: targetWidth * aspect)
    let rect = NSRect(
        x: (size.width - drawSize.width) / 2,
        y: size.height - drawSize.height - 60,
        width: drawSize.width,
        height: drawSize.height
    )
    wordmark.draw(in: rect)
}

// Centered tagline.
let tagline = "Drag Blablacadabra into Applications"
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: cream.withAlphaComponent(0.85),
    .paragraphStyle: para,
]
let textRect = NSRect(x: 0, y: 110, width: size.width, height: 24)
(tagline as NSString).draw(in: textRect, withAttributes: attrs)

// Save PNG.
let cgImage = ctx.makeImage()!
let bitmap = NSBitmapImageRep(cgImage: cgImage)
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: outURL)
SWIFT

# ---------------------------------------------------------------------------
# 2. Create a read-write DMG, mount it, write the .DS_Store with osascript
# ---------------------------------------------------------------------------
echo "Creating read-write DMG..."
RW_DMG="$SCRATCH/rw.dmg"
# Auto-size by source + slack: avoids "No space left on device" when the
# fixed size guess is wrong (HFS+ overhead bloats small images noticeably).
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -ov "$RW_DMG" >/dev/null

echo "Mounting read-write DMG to set layout..."
MOUNT_INFO="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
MOUNT_POINT="$(echo "$MOUNT_INFO" | tail -n 1 | awk '{ $1=$2=""; sub(/^ +/, ""); print }')"

# Give the volume a beat to settle so Finder sees it before AppleScript runs.
sleep 2

# Lay out the install window: centered, sized to the background, icons sized
# big, app on the left and Applications on the right with an arrow implied by
# the background image.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 900, 640}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Blablacadabra.app" of container window to {200, 240}
        set position of item "Applications" of container window to {500, 240}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# Hide the .background dir from Finder.
SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true
chmod -Rf go-w "$MOUNT_POINT" 2>/dev/null || true
sync

# ---------------------------------------------------------------------------
# 3. Unmount + convert to compressed, read-only final DMG
# ---------------------------------------------------------------------------
echo "Unmounting read-write DMG..."
hdiutil detach "$MOUNT_POINT" >/dev/null || hdiutil detach "$MOUNT_POINT" -force >/dev/null

echo "Compressing final DMG..."
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# Ad-hoc sign the DMG too so Gatekeeper has a stable identity for it. Real
# release would be Developer ID; this is enough for local testing.
codesign --force --sign - "$DMG" 2>/dev/null || true

echo "Done: $DMG"
echo "Size: $(du -h "$DMG" | awk '{print $1}')"
