#!/bin/sh
# One-shot macOS setup. Everything runs in the container; the only thing left
# on the Mac is a LaunchAgent (and the trusted root CA in the System keychain).
# After this finishes, this checkout can be deleted.
#
# The LaunchAgent starts at login and keeps running. It:
#   - starts the podman machine and the container, and restarts them if they stop
#   - turns the system proxy on only while the proxy port answers, so the Mac
#     never loses network because the container is down
#   - posts the notifications the container queues in ~/Library/Caches/wx-channels
#     (not under ~/Downloads: macOS privacy protection hides that from agents)
#     (with terminal-notifier, clicking one plays the video)
#
# Env: NETWORK_SERVICE (default Wi-Fi), DOWNLOAD_DIR (default ~/Downloads),
#      MEMORY (container limit, default 128m), PROXY_BIND (default 0.0.0.0),
#      VERSION (release tag, default v260907),
#      IMPORT_DATA_DIR (copy an existing data dir into the volume, once).
set -e
W="$(cd "$(dirname "$0")" && pwd)"
VERSION="${VERSION:-v260907}"
IMAGE="localhost/wx-channels-download:$VERSION"
CTR=wx-channels-download
VOLUME=wx-channels-data
LABEL=com.wxchannels.agent
NETWORK_SERVICE="${NETWORK_SERVICE:-Wi-Fi}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
MEMORY="${MEMORY:-128m}"
PROXY_BIND="${PROXY_BIND:-0.0.0.0}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
NOTIFY_HOST_DIR="$HOME/Library/Caches/wx-channels"

podman machine start 2>/dev/null || true
podman build -t "$IMAGE" --build-arg VERSION="$VERSION" -f "$W/Containerfile" "$W"

podman volume exists "$VOLUME" || podman volume create "$VOLUME" >/dev/null
if [ -n "${IMPORT_DATA_DIR:-}" ]; then
  echo "importing $IMPORT_DATA_DIR into volume $VOLUME"
  podman run --rm -v "$VOLUME:/data" -v "$IMPORT_DATA_DIR:/import:ro" \
    docker.io/library/debian:bookworm-slim sh -c 'cp -a /import/. /data/'
fi

podman rm -f "$CTR" >/dev/null 2>&1 || true
mkdir -p "$NOTIFY_HOST_DIR"
# GOMEMLIMIT keeps the Go runtime's GC under the cgroup limit.
podman run -d --name "$CTR" --restart=always \
  --memory "$MEMORY" --memory-swap "$MEMORY" -e GOMEMLIMIT=90MiB \
  -p "$PROXY_BIND:2023:2023" -p 127.0.0.1:2022:2022 \
  -v "$VOLUME:/data" -v "$DOWNLOAD_DIR:/downloads" -v "$NOTIFY_HOST_DIR:/notify" \
  -e HOST_DOWNLOAD_DIR="$DOWNLOAD_DIR" -e HOST_HOME="$HOME" \
  "$IMAGE" -c /data/config.yaml >/dev/null

# Trust the container's root CA on the Mac (once per certificate).
i=0
until podman exec "$CTR" test -f /data/certs/wx_channels_download.crt 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo "container did not create its certificate" >&2; exit 1; }
  sleep 1
done
CERT_NAME="$(podman exec "$CTR" sh -c "openssl x509 -in /data/certs/wx_channels_download.crt -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p'")"
if ! security find-certificate -c "$CERT_NAME" /Library/Keychains/System.keychain >/dev/null 2>&1; then
  tmp="$(mktemp -t wxca).crt"
  podman exec "$CTR" cat /data/certs/wx_channels_download.crt > "$tmp"
  echo "trusting root CA $CERT_NAME (admin password required)"
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$tmp"
  rm -f "$tmp"
fi

# The agent script lives inside the plist, so nothing else stays on disk.
AGENT_SCRIPT=$(cat <<EOF
SVC='$NETWORK_SERVICE'; CTR='$CTR'; Q='$NOTIFY_HOST_DIR'; state=unknown
while :; do
  if nc -z -G 1 127.0.0.1 2023 >/dev/null 2>&1; then
    if [ "\$state" != up ]; then
      networksetup -setwebproxy "\$SVC" 127.0.0.1 2023
      networksetup -setsecurewebproxy "\$SVC" 127.0.0.1 2023
      state=up; echo "\$(date '+%F %T') proxy on"
    fi
  else
    if [ "\$state" != down ]; then
      networksetup -setwebproxystate "\$SVC" off
      networksetup -setsecurewebproxystate "\$SVC" off
      state=down; echo "\$(date '+%F %T') proxy off, starting container"
    fi
    podman machine start >/dev/null 2>&1
    podman start "\$CTR" >/dev/null 2>&1
    sleep 8
  fi
  for f in "\$Q"/*.notify; do
    [ -f "\$f" ] || continue
    { IFS= read -r t; IFS= read -r s; IFS= read -r m; IFS= read -r snd; IFS= read -r u; } < "\$f"
    rm -f "\$f"
    if command -v terminal-notifier >/dev/null 2>&1; then
      if [ -n "\$u" ]; then
        terminal-notifier -title "\$t" -subtitle "\$s" -message "\$m" -sound "\$snd" -open "\$u" >/dev/null 2>&1
      else
        terminal-notifier -title "\$t" -subtitle "\$s" -message "\$m" -sound "\$snd" >/dev/null 2>&1
      fi
    else
      osascript -e 'on run argv' -e 'display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv) sound name (item 4 of argv)' -e 'end run' "\$t" "\$s" "\$m" "\$snd" >/dev/null 2>&1
    fi
  done
  sleep 2
done
EOF
)

mkdir -p "$HOME/Library/LaunchAgents"
AGENT_SCRIPT="$AGENT_SCRIPT" python3 -I - "$PLIST" "$LABEL" <<'EOF'
import os, plistlib, sys
plist, label = sys.argv[1], sys.argv[2]
with open(plist, "wb") as f:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": ["/bin/sh", "-c", os.environ["AGENT_SCRIPT"]],
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "StandardOutPath": "/tmp/wx-channels-agent.log",
        "StandardErrorPath": "/tmp/wx-channels-agent.log",
    }, f)
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

command -v terminal-notifier >/dev/null 2>&1 || echo "tip: brew install terminal-notifier (click a notification to play the video)"
echo "done: container $CTR ($MEMORY), agent $PLIST"
