#!/bin/bash
set -euo pipefail
BUNDLE_ID="com.akshardave.notificationshade"
# NOTE: this restarts the *installed* copy in ~/Applications. After changing the source you
# must run ./install.sh — a rebuild alone leaves build/Shady.app unused.
if ! launchctl kickstart -k "gui/$UID/$BUNDLE_ID" 2>/dev/null; then
  echo "Not installed yet. Run ./install.sh first." >&2
  exit 1
fi
echo "Restarted the installed copy. (Source changes need ./install.sh, not this.)"
