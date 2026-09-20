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
Shady — a curtain for your mac
==============================

Installing
----------
1. Drag Shady onto the Applications folder shown beside it.

2. Double-click it. macOS will refuse to open it, saying Apple "could not verify
   this app is free of malware". This is expected — see below. Click Done.

3. Open System Settings > Privacy & Security, scroll down to Security, and you
   will see "Shady was blocked to protect your Mac". Click "Open Anyway", then
   confirm with your password or Touch ID.

   You only do this once.

   On macOS 14 you can instead right-click the app and choose Open. That
   shortcut was REMOVED in macOS 15 (Sequoia) — on Sequoia and later, System
   Settings is the only way through.

   The one-command alternative, if you prefer Terminal:

       xattr -dr com.apple.quarantine /Applications/Shady.app

   Then it opens on a normal double-click.

Why macOS does this
-------------------
Shady is not signed with a paid Apple Developer ID and has not been notarized by
Apple. macOS blocks every app in that position, regardless of what it does. It is
a statement about the absence of a $99/year certificate, not about the app.

This is separate from the permissions below. It applies even if you grant Shady
nothing at all, because it is about whether the app is allowed to launch.

Using it
--------
Shady has no window. It lives in the menu bar as a clock icon.

Swipe down with TWO FINGERS from just beyond the top edge of the trackpad — start
with your fingers off the pad and move onto it. A curtain follows your fingers
down. Drag back up, press Escape, or click it to dismiss.

The menu bar icon toggles the same curtain.

Shady adds itself to your Login Items the first time it runs, so it comes back
after a restart. Turn that off from the menu bar icon ("Open at Login"), or in
System Settings > General > Login Items.

Permissions
-----------
Shady asks for Accessibility on first launch. It works without it, but two things
need it:

  * scroll suppression, so pulling the curtain does not also scroll the page under it
  * the Escape key closing the curtain from any app

Grant it in System Settings > Privacy & Security > Accessibility.

Requirements
------------
macOS 14 (Sonoma) or later, on an Apple silicon Mac (M1 or later).
The gesture needs a trackpad; with only a mouse, use the menu bar icon.

Uninstalling
------------
Quit from the menu bar icon, turn off "Open at Login" first (or remove it in
System Settings > General > Login Items), then drag Shady to the Trash.
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
