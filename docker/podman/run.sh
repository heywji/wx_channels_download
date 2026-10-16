#!/bin/sh
# (Re)start the container. Proxy listens on $PROXY_BIND:2023 (LAN by default),
# the API on 127.0.0.1:2022 (local only). On macOS also points the system proxy
# of $NETWORK_SERVICE at the container.
set -e
W="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-localhost/wx-channels-download:v260907}"
PROXY_BIND="${PROXY_BIND:-0.0.0.0}"
NETWORK_SERVICE="${NETWORK_SERVICE:-Wi-Fi}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

if [ ! -f "$W/data/certs/wx_channels_download.key" ]; then
  echo "no certificate in $W/data/certs, run ./gen-cert.sh first" >&2
  exit 1
fi
[ -f "$W/data/config.yaml" ] || cp "$W/config.example.yaml" "$W/data/config.yaml"

podman machine start 2>/dev/null || true
podman rm -f wx-channels-download 2>/dev/null || true
podman run -d --name wx-channels-download --restart=unless-stopped \
  -p "$PROXY_BIND:2023:2023" -p 127.0.0.1:2022:2022 \
  -v "$W/data:/data" -v "$DOWNLOAD_DIR:/downloads" \
  "$IMAGE"

if [ "$(uname)" = "Darwin" ]; then
  networksetup -setwebproxy "$NETWORK_SERVICE" 127.0.0.1 2023
  networksetup -setsecurewebproxy "$NETWORK_SERVICE" 127.0.0.1 2023
fi
