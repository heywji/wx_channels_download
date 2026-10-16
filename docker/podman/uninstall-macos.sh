#!/bin/sh
# Undo install-macos.sh: stop the agent, turn the system proxy off and remove
# the container. Pass --purge to also delete the data volume (database, root CA
# private key) and untrust the root CA. Downloaded videos are never touched.
NETWORK_SERVICE="${NETWORK_SERVICE:-Wi-Fi}"
LABEL=com.wxchannels.agent
CTR=wx-channels-download
VOLUME=wx-channels-data

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Caches/wx-channels"
networksetup -setwebproxystate "$NETWORK_SERVICE" off
networksetup -setsecurewebproxystate "$NETWORK_SERVICE" off

if [ "${1:-}" = "--purge" ]; then
  name="$(podman run --rm -v "$VOLUME:/data:ro" docker.io/library/debian:bookworm-slim \
    sh -c "sed -n '/^cert:/,/^[^ ]/s/^  name: *\"\\{0,1\\}\\([^\"]*\\)\"\\{0,1\\}/\\1/p' /data/config.yaml" 2>/dev/null)"
fi
podman rm -f "$CTR" >/dev/null 2>&1
if [ "${1:-}" = "--purge" ]; then
  podman volume rm "$VOLUME" >/dev/null 2>&1
  [ -n "$name" ] && sudo security delete-certificate -c "$name" /Library/Keychains/System.keychain
fi
echo "uninstalled"
