#!/bin/sh
# Manage the launchd agent that runs `wxdl.py watch`: every video you watch in
# WeChat is downloaded automatically at the highest quality.
# Usage: ./autodl.sh install|uninstall|status|log
set -e
W="$(cd "$(dirname "$0")" && pwd)"
LABEL="${AUTODL_LABEL:-com.wxchannels.autodl}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$W/data/autodl.log"
PY="$(command -v python3)"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
  install)
    mkdir -p "$W/data" "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string><string>-I</string><string>-u</string>
    <string>$W/wxdl.py</string><string>watch</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>DOWNLOAD_DIR</key><string>${DOWNLOAD_DIR:-$HOME/Downloads}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "installed $PLIST (log: $LOG)"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled $LABEL"
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state =|pid =|last exit" || echo "$LABEL not loaded"
    ;;
  log)
    tail -n 50 -f "$LOG"
    ;;
  *)
    sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
