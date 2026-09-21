#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.akshardave.notificationshade"
APP="build/Shady.app"
MIN_MACOS="14.0"

# --- preflight ------------------------------------------------------------------------------
if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Command Line Tools with:" >&2
  echo "         xcode-select --install" >&2
  exit 1
fi

have=$(sw_vers -productVersion)
if [ "$(printf '%s\n%s\n' "$MIN_MACOS" "$have" | sort -V | head -1)" != "$MIN_MACOS" ]; then
  echo "error: Shady needs macOS $MIN_MACOS or later (this is $have)." >&2
  echo "       It uses CADisplayLink on AppKit, which does not exist before Sonoma." >&2
  exit 1
fi

pkill -f "MacOS/Shady" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# --- compile --------------------------------------------------------------------------------
if [ "$(uname -m)" != "arm64" ]; then
  echo "error: Shady is built for Apple silicon only (this machine is $(uname -m))." >&2
  exit 1
fi

# --- icon ---------------------------------------------------------------------------------
# iconutil wants a full iconset; the source art is a single 512pt PNG, so scale it into place.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" "512:icon_256x256@2x" \
            "512:icon_512x512" "1024:icon_512x512@2x"; do
  sips -z "${spec%%:*}" "${spec%%:*}" Resources/icon.png --out "$ICONSET/${spec#*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

swiftc -O \
  -target "arm64-apple-macosx${MIN_MACOS}" \
  -framework AppKit -framework AVFoundation -framework QuickLookThumbnailing \
  -o "$APP/Contents/MacOS/Shady" \
  Sources/*.swift

# --- sign -----------------------------------------------------------------------------------
# The certificate keeps its original name; renaming it would invalidate the permission grant.
if [ "${SHADY_ADHOC:-0}" = "1" ]; then
  # Packaging for other machines: a local self-signed certificate means nothing on someone
  # else's Mac, so sign ad-hoc and let them clear the quarantine flag on first run.
  codesign --force --deep --sign - "$APP"
  echo "Ad-hoc signed for distribution."
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Notification Shade Dev"; then
  # Stable identity: the Accessibility grant survives rebuilds.
  codesign --force --sign "Notification Shade Dev" "$APP"
else
  # Ad-hoc: macOS keys the grant to the binary's hash, so this rebuild just invalidated it.
  # Clear the stale entry so the app can prompt again instead of silently doing nothing.
  codesign --force --sign - "$APP"
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "note: ad-hoc signed — you'll be prompted for Accessibility again."
  echo "      Run ./setup-signing.sh once to stop that happening on every rebuild."
fi

echo "Built $APP"
