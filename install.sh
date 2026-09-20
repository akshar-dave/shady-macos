#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.akshardave.notificationshade"
DEST="$HOME/Applications/Shady.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

./build.sh

# Install to a stable location. TCC keys the grant to this path, so it must not move.
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/Shady.app "$DEST"

# Launch via launchd rather than from a terminal. This matters: macOS attributes a permission
# request to the *responsible process*, so an app started from a shell inside VS Code or
# Terminal makes macOS ask for VS Code / Terminal instead of this app. Under launchd the app
# is responsible for itself and the prompt names it correctly.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/Shady</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$AGENT"

# Confirm it actually came up, rather than claiming success and leaving the user to find out.
sleep 2
if pgrep -f "$DEST/Contents/MacOS/Shady" >/dev/null; then
  echo
  echo "Installed to $DEST and started. It will also start at login."
else
  echo
  echo "warning: the app was installed but is not running. Check:" >&2
  echo "           launchctl print gui/$UID/$BUNDLE_ID" >&2
fi

echo
echo "  Look for the clock icon in your menu bar."
echo "  Swipe down with two fingers from just beyond the top edge of the trackpad."
echo

# Accessibility is optional, so explain rather than demand. Deliberately not conditional: the
# obvious test is to read TCC.db, but it is SIP-protected and an unreadable database looks
# exactly like a denied permission, so the check reports "not granted" even when it is.
cat <<'NOTE'
  Accessibility: Shady works without it -- the curtain opens and closes as normal -- but
  two things need it:

    * scroll suppression, so pulling the curtain does not also scroll the page underneath
    * the Escape key closing the curtain from any app

  Grant it in System Settings > Privacy & Security > Accessibility, enabling "Shady".
  If macOS prompted you just now, that does the same thing. Already granted? Nothing to do.

NOTE
