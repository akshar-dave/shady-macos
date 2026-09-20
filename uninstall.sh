#!/bin/bash
set -euo pipefail
BUNDLE_ID="com.akshardave.notificationshade"
launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
rm -rf "$HOME/Applications/Shady.app"
rm -f "$HOME/.shady-debug" "$HOME/Library/Logs/Shady.log"
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
echo "Removed app, launch agent, logs and the Accessibility grant."
