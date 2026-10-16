#!/bin/bash
# Download a Channels video that was opened in WeChat, at the highest quality.
#
# Reads the video URL and decode key from browse_history in data/data.db,
# downloads through the API's /play endpoint (which decrypts on the fly) into
# "<name>.mp4.part", verifies it, renames it to "<name>.mp4", then posts a
# macOS notification. A file without the .part suffix is always complete.
#
# Usage: ./dl.sh [-r] [-n COUNT] [INDEX]
#   INDEX     pick the INDEX-th most recent video without prompting (1 = latest)
#   -n COUNT  how many recent videos to list (default 10)
#   -r        reveal the finished file in Finder
# Env: DB, API (default http://127.0.0.1:2022), DOWNLOAD_DIR (default ~/Downloads)
set -euo pipefail

W="$(cd "$(dirname "$0")" && pwd)"
DB="${DB:-$W/data/data.db}"
API="${API:-http://127.0.0.1:2022}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
SPECS="xWT111 xWT112 xWT113 xWT156 xWT157 xWT158"
SEP=$'\x1f'

count=10
reveal=0
while getopts "rn:h" opt; do
  case "$opt" in
    r) reveal=1 ;;
    n) count="$OPTARG" ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
pick="${1:-}"

notify() {
  # notify TITLE MESSAGE SOUND; argv avoids quoting issues with video titles.
  [ "$(uname)" = "Darwin" ] || return 0
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)' \
    -e 'end run' "$1" "$2" "$3" >/dev/null 2>&1 || true
}

fail() {
  echo "✗ $1" >&2
  notify "视频号下载失败" "$1" "Basso"
  exit 1
}

[ -f "$DB" ] || fail "找不到数据库 $DB（先 ./run.sh 并在微信里打开视频）"
curl -s --noproxy '*' -m 5 -o /dev/null "$API/api/status" || fail "API $API 连不上，容器在运行吗？"

rows=$(sqlite3 -separator "$SEP" "$DB" "
  select h.external_id,
         coalesce(a.nickname, ''),
         replace(replace(coalesce(h.title, ''), char(10), ' '), char(13), ' '),
         strftime('%m-%d %H:%M', h.updated_at / 1000, 'unixepoch', 'localtime'),
         substr(replace(replace(coalesce(h.title, ''), char(10), ' '), char(13), ' '), 1, 30)
  from browse_history h
  left join browse_history_account ba on ba.browse_history_id = h.id and ba.role = 'author'
  left join account a on a.id = ba.account_id
  where h.platform_id = 'wxchannels' and h.type = 'video' and h.deleted_at is null
  group by h.id
  order by h.updated_at desc
  limit $((count))")
[ -n "$rows" ] || fail "还没有记录到视频：先在微信里打开要下载的视频"

i=0
while IFS="$SEP" read -r _id author _title at short; do
  i=$((i + 1))
  printf '%2d. [%s] %s — %s\n' "$i" "$at" "${author:-?}" "$short"
done <<< "$rows"

if [ -z "$pick" ]; then
  read -r -p "选择序号 [1]: " pick </dev/tty
  pick="${pick:-1}"
fi
case "$pick" in ''|*[!0-9]*) fail "序号无效: $pick" ;; esac
line=$(sed -n "${pick}p" <<< "$rows")
[ -n "$line" ] || fail "序号超出范围: $pick"
IFS="$SEP" read -r id author title _at _short <<< "$line"

url=$(sqlite3 "$DB" "select url from browse_history where platform_id='wxchannels' and external_id='$id'")
key=$(sqlite3 "$DB" "select json_extract(extra_data, '$.decode_key') from browse_history where platform_id='wxchannels' and external_id='$id'")
[ -n "$url" ] && [ -n "$key" ] || fail "这条记录缺少视频地址或解密 key"

# Pick the largest available spec by probing Content-Range totals.
best=""
best_size=0
for spec in $SPECS; do
  size=$(curl -s --noproxy '*' -m 15 -r 0-0 -o /dev/null -D - "$url&X-snsvideoflag=$spec" \
    | tr -d '\r' | awk -F/ 'tolower($0) ~ /^content-range:/ {print $2}')
  if [ -n "$size" ] && [ "$size" -gt "$best_size" ]; then
    best="$spec"
    best_size="$size"
  fi
done
[ "$best_size" -gt 0 ] || fail "视频地址已失效（签名过期），请在微信里重新打开这个视频再试"

name=$(python3 -I - "$author" "$title" <<'EOF'
import re, sys
author, title = sys.argv[1].strip(), sys.argv[2].strip()
head = title.split("#", 1)[0].strip() or title
name = f"{author}_{head}" if author else head
name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", name)
name = re.sub(r"\s+", " ", name).strip(" ._")
print(name[:60] or "wx_video")
EOF
)
out="$DOWNLOAD_DIR/$name.mp4"
n=1
while [ -e "$out" ] || [ -e "$out.part" ]; do
  out="$DOWNLOAD_DIR/$name ($n).mp4"
  n=$((n + 1))
done
part="$out.part"
trap 'rm -f "$part"' EXIT

echo "↓ $best $(awk -v b="$best_size" 'BEGIN{printf "%.1f MB", b/1048576}') → $out"
code=$(curl --noproxy '*' -m 3600 -G "$API/play" \
  --data-urlencode "url=$url&X-snsvideoflag=$best" \
  --data-urlencode "key=$key" \
  -o "$part" -w '%{http_code}' --progress-bar) || fail "下载中断：$name"
[ "$code" = "200" ] || [ "$code" = "206" ] || fail "下载失败（HTTP $code）：$name"

got=$(stat -f %z "$part" 2>/dev/null || stat -c %s "$part")
[ "$got" -eq "$best_size" ] || fail "文件不完整（$got / $best_size 字节）：$name"
if command -v ffprobe >/dev/null 2>&1; then
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$part" >/dev/null 2>&1 \
    || fail "解密后的文件无法识别为视频：$name"
else
  [ "$(dd if="$part" bs=1 skip=4 count=4 2>/dev/null)" = "ftyp" ] \
    || fail "解密后的文件无法识别为视频：$name"
fi

mv "$part" "$out"
trap - EXIT
echo "✓ 完成：$out"
notify "视频号下载完成" "$(basename "$out")" "Glass"
[ "$reveal" -eq 1 ] && [ "$(uname)" = "Darwin" ] && open -R "$out"
exit 0
