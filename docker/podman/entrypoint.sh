#!/bin/sh
# Container entrypoint: prepare /data on first start, run the auto-download
# watcher in the background (AUTODL=1), then exec the downloader service.
set -e
SHARE=/usr/local/share/wx_channels
CERT_DIR=/data/certs
CERT_NAME="${CERT_NAME:-wx_channels_download_local}"

[ -f /data/config.yaml ] || cp "$SHARE/config.example.yaml" /data/config.yaml

# Per-installation root CA; the built-in SunnyNet key is public. The host has
# to trust $CERT_DIR/wx_channels_download.crt (install-macos.sh does that).
if [ ! -f "$CERT_DIR/wx_channels_download.key" ]; then
  mkdir -p "$CERT_DIR"
  openssl genrsa -out "$CERT_DIR/wx_channels_download.key" 2048 2>/dev/null
  openssl rsa -in "$CERT_DIR/wx_channels_download.key" -traditional \
    -out "$CERT_DIR/wx_channels_download.key" 2>/dev/null
  openssl req -x509 -new -key "$CERT_DIR/wx_channels_download.key" -sha256 -days 3650 \
    -subj "/O=wx_channels_download/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" \
    -out "$CERT_DIR/wx_channels_download.crt"
  chmod 600 "$CERT_DIR/wx_channels_download.key"
  # Only the `name:` line right after cert.key, not other sections' names.
  sed -i "/^  key: \"\/data\/certs\//{n;s/^  name: .*/  name: \"$CERT_NAME\"/}" /data/config.yaml
  echo "generated root CA $CERT_NAME; trust $CERT_DIR/wx_channels_download.crt on the host"
fi

if [ "${AUTODL:-1}" = "1" ]; then
  (
    # Restart the watcher if it ever exits; it waits for the API on its own.
    while :; do
      python3 -I -u "$SHARE/wxdl.py" watch || true
      sleep 5
    done
  ) &
fi

exec /usr/local/bin/wx_video_download "$@"
