#!/bin/sh
# Stop the container and, on macOS, turn the system proxy back off.
NETWORK_SERVICE="${NETWORK_SERVICE:-Wi-Fi}"
podman stop wx-channels-download
if [ "$(uname)" = "Darwin" ]; then
  networksetup -setwebproxystate "$NETWORK_SERVICE" off
  networksetup -setsecurewebproxystate "$NETWORK_SERVICE" off
fi
