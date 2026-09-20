#!/bin/bash
# Builds a disk image you can hand to someone else.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
STAGE="build/dmg"
DMG="build/Shady-$VERSION.dmg"

# Ad-hoc, not the local development certificate: that certificate is trusted only on this Mac,
# so signing with it would mean nothing on anyone else's and only leak this machine's identity.
SHADY_ADHOC=1 ./build.sh

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Shady.app "$STAGE/Shady.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Shady — a pull-down notification shade for your Mac
===================================================

1. Drag Shady onto the Applications folder beside it.

2. Open it. macOS will refuse, saying it cannot verify the app — Shady is not
   notarized, which macOS blocks regardless of what an app does. Click Done,
   then go to System Settings > Privacy & Security, scroll to Security, and
   click "Open Anyway" beside "Shady was blocked".

   Once only. If you prefer the Terminal:

       xattr -dr com.apple.quarantine /Applications/Shady.app

3. Grant Accessibility when asked. Shady runs without it, but it is what lets
   the curtain suppress scrolling underneath and close on Escape.

NOTE

hdiutil create -volname "Shady $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "Built $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "Note: ad-hoc signed, NOT notarized. On macOS 15+ the recipient must approve it"
echo "      once in System Settings > Privacy & Security > \"Open Anyway\" — the"
echo "      right-click > Open shortcut no longer works. The disk image explains this."
echo "      Removing the step entirely needs a paid Apple Developer ID + notarization."
