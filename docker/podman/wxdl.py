#!/usr/bin/env python3
"""Download Channels videos that were opened in WeChat, at the highest quality.

The injected page records every video it shows into browse history together
with its URL and decode key. This tool reads that list through the API
(never the SQLite file, which the container owns), downloads through /play
(which decrypts on the fly) into "<name>.mp4.part", verifies it, renames it to
"<name>.mp4" and posts a macOS notification showing where it was saved.
With terminal-notifier installed, clicking the notification plays the video.
A file without the .part suffix is always complete.

  wxdl.py [-r] [-n COUNT] [INDEX]   list recent videos and download one
  wxdl.py watch                     download every newly watched video

Env: API (default http://127.0.0.1:2022), DOWNLOAD_DIR (default ~/Downloads),
STATE (watch state file, default ./data/autodl_state.json next to this file),
NOTIFY_DIR (queue notifications as files for a host agent instead of posting),
HOST_DOWNLOAD_DIR / HOST_HOME (host paths, when running in a container).
Python 3.9+, standard library only.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
API = os.environ.get("API", "http://127.0.0.1:2022").rstrip("/")
DOWNLOAD_DIR = Path(os.environ.get("DOWNLOAD_DIR", str(Path.home() / "Downloads"))).expanduser()
STATE = Path(os.environ.get("STATE", str(HERE / "data" / "autodl_state.json")))
SPECS = ["xWT111", "xWT112", "xWT113", "xWT156", "xWT157", "xWT158"]
# On first start, watch mode only picks up videos seen this recently, so it
# does not try to fetch an old backlog whose signed URLs have expired.
FIRST_RUN_LOOKBACK_MS = 2 * 3600 * 1000
POLL_SECONDS = 3
MAX_ATTEMPTS = 3

# Bypass every proxy, including the macOS system proxy that urllib would pick
# up: the API is on loopback and video CDN requests do not need the MITM proxy.
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class DownloadError(Exception):
    pass


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def api_post(path, body, timeout=10):
    req = urllib.request.Request(
        API + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    with OPENER.open(req, timeout=timeout) as resp:
        payload = json.load(resp)
    if payload.get("code") != 0:
        raise DownloadError(f"API {path}: {payload.get('msg')}")
    return payload.get("data") or {}


def recent_videos(count):
    data = api_post("/api/browse_history/list", {"page": 1, "page_size": count})
    items = [
        it for it in data.get("list") or []
        if it.get("platform_id") == "wxchannels" and it.get("type") == "video" and not it.get("deleted_at")
    ]
    items.sort(key=lambda it: it.get("updated_at") or 0, reverse=True)
    return items


def author_of(item):
    for acc in item.get("accounts") or []:
        if acc.get("nickname"):
            return acc["nickname"].strip()
    return ""


def one_line(text):
    return re.sub(r"\s+", " ", text or "").strip()


def file_stem(item):
    author, title = author_of(item), one_line(item.get("title"))
    head = title.split("#", 1)[0].strip() or title or item.get("external_id", "")
    name = f"{author}_{head}" if author else head
    name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", name)
    name = re.sub(r"\s+", " ", name).strip(" ._-")
    return name[:60] or "wx_video"


def content_length_total(url):
    req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
    try:
        with OPENER.open(req, timeout=15) as resp:
            m = re.search(r"/(\d+)$", resp.headers.get("Content-Range", ""))
            return int(m.group(1)) if m else 0
    except Exception:
        return 0


def best_spec(url):
    with concurrent.futures.ThreadPoolExecutor(len(SPECS)) as pool:
        sizes = dict(zip(SPECS, pool.map(lambda s: content_length_total(f"{url}&X-snsvideoflag={s}"), SPECS)))
    spec = max(SPECS, key=lambda s: sizes[s])
    return spec, sizes[spec]


def unique_path(stem):
    out = DOWNLOAD_DIR / f"{stem}.mp4"
    n = 1
    while out.exists() or Path(f"{out}.part").exists():
        out = DOWNLOAD_DIR / f"{stem} ({n}).mp4"
        n += 1
    return out


def looks_like_video(path):
    if shutil.which("ffprobe"):
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
            capture_output=True,
        )
        return r.returncode == 0 and r.stdout.strip() != b""
    with open(path, "rb") as f:
        return f.read(8)[4:8] == b"ftyp"


def video_name(item):
    """Human-readable "author：title" for notifications."""
    author, title = author_of(item), one_line(item.get("title"))
    head = title.split("#", 1)[0].strip() or title or item.get("external_id", "")
    name = f"{author}：{head}" if author else head
    return name if len(name) <= 80 else name[:79] + "…"


def host_path(out):
    """Path of a downloaded file as the macOS host sees it.

    Inside the container DOWNLOAD_DIR is a bind mount; HOST_DOWNLOAD_DIR is
    where it lives on the host.
    """
    host_dir = os.environ.get("HOST_DOWNLOAD_DIR")
    if host_dir:
        return Path(host_dir) / Path(out).relative_to(DOWNLOAD_DIR)
    return Path(out).resolve()


def tilde(path):
    s = str(path)
    home = os.environ.get("HOST_HOME") or str(Path.home())
    return "~" + s[len(home):] if s.startswith(home.rstrip("/") + "/") else s


def notify(ok, item, message, out=None):
    """Post "下载完成/失败" with the video name; clicking a success plays it.

    In the container (NOTIFY_DIR set) the notification is queued as a file in
    NOTIFY_DIR for the host agent to post. Format, one field per line:
    title, subtitle, message, sound, URL to open on click (may be empty).
    """
    title = "✅ 视频号下载完成" if ok else "❌ 视频号下载失败"
    subtitle = video_name(item) if item else ""
    sound = "Glass" if ok else "Basso"
    open_url = host_path(out).as_uri() if out else ""
    fields = [title, subtitle, message, sound, open_url]
    fields = [re.sub(r"[\r\n]+", " ", f) for f in fields]

    notify_dir = os.environ.get("NOTIFY_DIR")
    if notify_dir:
        qdir = Path(notify_dir)
        qdir.mkdir(parents=True, exist_ok=True)
        stem = f"{time.time_ns()}-{(item or {}).get('external_id', 'x')}"
        tmp = qdir / f".{stem}.tmp"
        tmp.write_text("\n".join(fields) + "\n", encoding="utf-8")
        tmp.rename(qdir / f"{stem}.notify")
        return
    if sys.platform != "darwin":
        return
    if shutil.which("terminal-notifier"):
        cmd = ["terminal-notifier", "-title", title, "-subtitle", subtitle, "-message", message, "-sound", sound]
        if open_url:
            cmd += ["-open", open_url]
        if subprocess.run(cmd, capture_output=True).returncode == 0:
            return
    # Fallback without click action; argv avoids quoting issues with titles.
    subprocess.run(
        ["osascript", "-e", "on run argv",
         "-e", "display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv) sound name (item 4 of argv)",
         "-e", "end run", title, message, subtitle, sound],
        capture_output=True,
    )


def download(item, progress=True):
    """Download one browse-history item. Returns the final path."""
    url = item.get("url") or ""
    try:
        key = str(json.loads(item.get("extra_data") or "{}").get("decode_key") or "")
    except ValueError:
        key = ""
    if not url or not key:
        raise DownloadError("这条记录缺少视频地址或解密 key")

    spec, size = best_spec(url)
    if size <= 0:
        raise DownloadError("视频地址已失效（签名过期），请在微信里重新打开这个视频")

    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    out = unique_path(file_stem(item))
    part = Path(f"{out}.part")
    log(f"↓ {spec} {size / 1048576:.1f} MB → {out}")
    query = urllib.parse.urlencode({"url": f"{url}&X-snsvideoflag={spec}", "key": key})
    try:
        with OPENER.open(f"{API}/play?{query}", timeout=60) as resp, open(part, "wb") as f:
            if resp.status not in (200, 206):
                raise DownloadError(f"下载失败（HTTP {resp.status}）")
            got = 0
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)
                if progress and sys.stderr.isatty():
                    sys.stderr.write(f"\r  {got * 100 // size:3d}%  {got / 1048576:.1f}/{size / 1048576:.1f} MB")
                    sys.stderr.flush()
        if progress and sys.stderr.isatty():
            sys.stderr.write("\n")
        if part.stat().st_size != size:
            raise DownloadError(f"文件不完整（{part.stat().st_size} / {size} 字节）")
        if not looks_like_video(part):
            raise DownloadError("解密后的文件无法识别为视频")
        part.rename(out)
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    log(f"✓ 完成：{out}")
    notify(True, item, f"已保存到 {tilde(host_path(out))} · 点击播放", out)
    return out


def cmd_pick(args):
    try:
        items = recent_videos(args.n)
    except Exception as e:
        sys.exit(f"✗ API {API} 连不上，容器在运行吗？（{e}）")
    if not items:
        sys.exit("✗ 还没有记录到视频：先在微信里打开要下载的视频")
    for i, it in enumerate(items, 1):
        at = time.strftime("%m-%d %H:%M", time.localtime((it.get("updated_at") or 0) / 1000))
        print(f"{i:2d}. [{at}] {author_of(it) or '?'} — {one_line(it.get('title'))[:30]}")
    pick = args.index
    if pick is None:
        try:
            with open("/dev/tty") as tty:
                sys.stdout.write("选择序号 [1]: ")
                sys.stdout.flush()
                pick = tty.readline().strip() or "1"
        except OSError:
            pick = "1"
    if not str(pick).isdigit() or not 1 <= int(pick) <= len(items):
        sys.exit(f"✗ 序号无效: {pick}")
    item = items[int(pick) - 1]
    try:
        out = download(item)
    except DownloadError as e:
        notify(False, item, str(e))
        sys.exit(f"✗ {e}")
    if args.r and sys.platform == "darwin":
        subprocess.run(["open", "-R", str(out)])


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return None


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1))
    tmp.replace(STATE)


def cmd_watch(_args):
    """Poll browse history and download every newly watched video, oldest first.

    State per external_id: {"status": ok|failed|skipped, "seen": updated_at,
    "attempts": n}. A failed item is retried when it is opened again (its
    updated_at changes) or, for transient errors, up to MAX_ATTEMPTS times.
    """
    state = load_state()
    first_run = state is None
    state = state or {"items": {}}
    log(f"watching {API} → {DOWNLOAD_DIR}")
    api_down = False
    while True:
        try:
            items = recent_videos(50)
            if api_down:
                log("API back online")
            api_down = False
        except Exception as e:
            if not api_down:
                log(f"API unavailable, waiting: {e}")
            api_down = True
            time.sleep(POLL_SECONDS * 5)
            continue

        if first_run:
            cutoff = time.time() * 1000 - FIRST_RUN_LOOKBACK_MS
            for it in items:
                if (it.get("updated_at") or 0) < cutoff:
                    state["items"][it["external_id"]] = {"status": "skipped", "seen": it.get("updated_at")}
            save_state(state)
            first_run = False

        for it in sorted(items, key=lambda x: x.get("updated_at") or 0):
            eid, seen = it["external_id"], it.get("updated_at") or 0
            rec = state["items"].get(eid)
            if rec and rec["status"] in ("ok", "skipped"):
                continue
            if rec and rec["status"] == "failed":
                reopened = seen > (rec.get("seen") or 0)
                if not reopened and rec.get("attempts", 0) >= MAX_ATTEMPTS:
                    continue
                if reopened:
                    rec["attempts"] = 0
            rec = rec or {"attempts": 0}
            try:
                out = download(it, progress=False)
                state["items"][eid] = {"status": "ok", "seen": seen, "file": str(out)}
            except DownloadError as e:
                attempts = rec.get("attempts", 0) + 1
                state["items"][eid] = {"status": "failed", "seen": seen, "attempts": attempts, "error": str(e)}
                log(f"✗ {eid}: {e} (attempt {attempts})")
                if attempts >= MAX_ATTEMPTS or "签名过期" in str(e):
                    state["items"][eid]["attempts"] = MAX_ATTEMPTS
                    notify(False, it, str(e))
            except Exception as e:  # network hiccup: retry next round
                attempts = rec.get("attempts", 0) + 1
                state["items"][eid] = {"status": "failed", "seen": seen, "attempts": attempts, "error": repr(e)}
                log(f"✗ {eid}: {e!r} (attempt {attempts})")
            save_state(state)
        time.sleep(POLL_SECONDS)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0], epilog="Run `wxdl.py watch` to auto-download."
    )
    parser.add_argument("-r", action="store_true", help="reveal the finished file in Finder")
    parser.add_argument("-n", type=int, default=10, help="how many recent videos to list")
    parser.add_argument("index", nargs="?", help="pick the INDEX-th most recent video (1 = latest)")
    argv = sys.argv[1:]
    if argv[:1] == ["watch"]:
        return cmd_watch(None)
    args = parser.parse_args(argv)
    return cmd_pick(args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
