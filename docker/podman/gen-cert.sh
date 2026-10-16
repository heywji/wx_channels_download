#!/bin/sh
# Generate a per-machine root CA for the MITM proxy into ./data/certs.
# Use this instead of the built-in SunnyNet certificate, whose private key is
# public. CERT_NAME must match `cert.name` in data/config.yaml.
set -e
W="$(cd "$(dirname "$0")" && pwd)"
CERT_NAME="${CERT_NAME:-wx_channels_download_local}"
DIR="$W/data/certs"
mkdir -p "$DIR"
if [ -f "$DIR/wx_channels_download.key" ]; then
  echo "certificate already exists in $DIR, refusing to overwrite" >&2
  exit 1
fi
openssl genrsa -out "$DIR/wx_channels_download.key" 2048 2>/dev/null
if ! head -1 "$DIR/wx_channels_download.key" | grep -q "RSA PRIVATE KEY"; then
  openssl rsa -in "$DIR/wx_channels_download.key" -traditional -out "$DIR/wx_channels_download.key" 2>/dev/null
fi
openssl req -x509 -new -key "$DIR/wx_channels_download.key" -sha256 -days 3650 \
  -subj "/O=wx_channels_download/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" \
  -out "$DIR/wx_channels_download.crt"
chmod 600 "$DIR/wx_channels_download.key"
echo "generated $DIR/wx_channels_download.crt ($CERT_NAME)"
if [ "$(uname)" = "Darwin" ]; then
  echo "trusting it in the macOS System keychain (admin password required)"
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$DIR/wx_channels_download.crt"
else
  echo "install $DIR/wx_channels_download.crt into your system/browser trust store manually"
fi
