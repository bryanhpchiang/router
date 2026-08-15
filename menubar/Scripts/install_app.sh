#!/usr/bin/env bash
# Package Router.app, install it to ~/Applications, start it at login.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.bryan.router"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="$HOME/Applications/Router.app"

APP_NAME=Router BUNDLE_ID="$LABEL" MENU_BAR_APP=1 SIGNING_MODE=adhoc \
  MACOS_MIN_VERSION=15.0 "$ROOT/Scripts/package_app.sh" release

pkill -x Router 2>/dev/null || true
rm -rf "$DEST"
mkdir -p "$HOME/Applications"
cp -R "$ROOT/Router.app" "$DEST"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>Program</key><string>$DEST/Contents/MacOS/Router</string>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

for _ in {1..10}; do
  pgrep -x Router >/dev/null && { echo "Router.app is running."; exit 0; }
  sleep 0.4
done
echo "ERROR: Router.app did not start. Check Console.app." >&2
exit 1
