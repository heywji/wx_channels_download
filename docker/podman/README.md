# 容器部署（Podman / Docker）

把 wx_video_download 跑在容器里，MITM 代理对局域网开放。宿主机上不需要以管理员身份运行程序，也不用写系统证书库（除了一次性信任根证书）。

适用场景：macOS（Apple Silicon，用 `podman machine`）上的微信 PC 端，也可以给局域网里的其他电脑提供代理。

## 工作原理

```
微信 ──系统代理──▶ 容器 :2023 (MITM 代理，只改 channels.weixin.qq.com)
页面脚本 ────────▶ 127.0.0.1:2022 (API) ──▶ 下载 + 解密 ──▶ 下载目录
```

本地 MITM 代理会在视频号页面里插入脚本。脚本把视频地址和解密 key 回传给本地 API，由 API 下载视频并解密。

## 文件

| 文件 | 说明 |
|---|---|
| `Containerfile` | debian-slim 镜像，构建时从 Releases 下载对应架构的 Linux 二进制 |
| `config.example.yaml` | 容器用的配置模板。第一次运行 `run.sh` 时会复制到 `data/config.yaml` |
| `gen-cert.sh` | 生成本机专属根证书，放到 `data/certs/`；在 macOS 上还会把它加入系统钥匙串并设为信任 |
| `run.sh` | 启动或重启容器；在 macOS 上会把系统代理指向 `127.0.0.1:2023` |
| `stop.sh` | 停掉容器，并关闭系统代理 |
| `autodl.sh` | 安装或卸载自动下载的后台服务（launchd），以及查看状态和日志 |
| `dl.sh` | 从最近看过的视频里挑一个手动下载 |
| `wxdl.py` | 前两者共用的下载逻辑：选最高画质、校验、发通知 |
| `data/` | 运行时数据：配置、证书私钥、SQLite。**已在 `.gitignore` 里忽略，不要提交** |

容器里的挂载：`/data` 对应 `./data`，`/downloads` 对应 `$DOWNLOAD_DIR`（默认是 `~/Downloads`）。

## 快速开始

```sh
cd docker/podman
podman build -t localhost/wx-channels-download:v260907 --build-arg VERSION=v260907 -f Containerfile .
./gen-cert.sh   # 只需要做一次，macOS 会要求输入管理员密码
./run.sh
```

接下来：

1. **⌘Q 完全退出微信再重新打开**，不然微信不会走新的系统代理。
2. 在微信里打开视频号的视频。分享链接 `https://weixin.qq.com/sph/xxx` 可以先发到「文件传输助手」再点开。
3. 点页面里的下载按钮。如果按钮没出现，用下面的 `autodl.sh` 或 `dl.sh` 下载。

不用的时候运行 `./stop.sh`。

`run.sh` 可以用这些环境变量调整：`IMAGE`、`PROXY_BIND`（默认 `0.0.0.0`）、`NETWORK_SERVICE`（默认 `Wi-Fi`）、`DOWNLOAD_DIR`。

## 端口

| 端口 | 绑定 | 用途 |
|---|---|---|
| 2023 | `$PROXY_BIND`（默认 `0.0.0.0`） | MITM 代理 |
| 2022 | `127.0.0.1` | API 和页面 WebSocket，只开在本机 |

`config.example.yaml` 和直接在宿主机上运行时的配置不同：`proxy.system: false`（容器没法改宿主机的系统代理，由 `run.sh` 来设）、`proxy.skipInstallRootCert: true`（证书由 `gen-cert.sh` 负责信任）、`proxy.hostname` / `api.hostname` 都是 `0.0.0.0`（要监听所有地址，宿主机的端口映射才能连进来）。

## 自动下载：`autodl.sh`（推荐）

装好以后就是全自动的：**在微信里看到的每一个视频**（包括首页推荐里刷到的）都会自动下载最高画质到 `~/Downloads`，每下完一个就弹一条通知。

```sh
./autodl.sh install     # 安装成 launchd 后台服务：登录后自动启动，进程退出会被自动拉起
./autodl.sh status      # 看服务是否在运行
./autodl.sh log         # 实时查看日志（data/autodl.log）
./autodl.sh uninstall   # 关掉自动下载
```

- 原理：插入页面的脚本会把每个显示过的视频（地址和解密 key）记进浏览记录。`wxdl.py watch` 每 3 秒通过 API（`POST /api/browse_history/list`）拉一次列表，发现新视频就下载。
  它不会直接去读 `data.db`，因为数据库由容器里的程序在写，跨虚拟机直接读写 SQLite 的 WAL 文件不安全。
- 已经下载过的视频记在 `data/autodl_state.json` 里，不会重复下载。
- 第一次启动时，只处理最近 2 小时内看过的视频，不会去下更早的历史记录。
- 下载失败时：遇到网络问题会自动重试，最多 3 次；遇到「签名过期」会弹失败通知，在微信里重新打开这个视频就会再试一次。
- 容器没运行时它会静静地等着，容器起来后自动继续，不会刷屏报错。
- 注意：刷得越多，下得越多。不想要了就运行 `./autodl.sh uninstall`。

## 手动挑一个下载：`dl.sh`

```sh
./dl.sh          # 列出最近看过的视频，按序号选择，回车默认选第 1 个
./dl.sh 1        # 不提示，直接下载最近看的那个
./dl.sh -r 2     # 下载第 2 个，完成后在 Finder 里定位到文件
./dl.sh -n 20    # 列出最近 20 个
```

## 自动和手动下载的共同行为

- 自动选最高画质：逐个探测各档的文件大小，挑最大的那档。
- 先下载到 `<作者>_<标题>.mp4.part`，校验通过后（字节数对得上，`ffprobe` 能识别成视频），再改名成 `.mp4`。
  **所以文件名不是 `.part` 结尾，就说明已经完整下完了。**
- 完成后弹出 macOS 通知，带 Glass 提示音，通知里会写文件保存在哪里（例如 `已保存到 ~/Downloads/xxx.mp4`），**点击通知就会用默认播放器打开这个视频**。
  失败时也会弹通知，用 Basso 提示音，同时删掉 `.part` 文件。
- 点击打开视频需要先装 `terminal-notifier`：`brew install terminal-notifier`。第一次弹通知时，macOS 会问要不要允许它发通知，选允许。
  没装的话会退回用 `osascript` 发通知：一样会显示保存位置，但点击没有反应。
- 可以用环境变量调整：`API`（默认 `http://127.0.0.1:2022`）、`DOWNLOAD_DIR`（默认 `~/Downloads`）。
- 依赖：python3（3.9 以上，只用标准库）；`ffprobe` 可选，用来校验视频。

## 手动用 curl 下载（排障用）

微信前端改版后，插入的脚本可能匹配不上（例如报 `finderGetCommentDetail is not a function`）。
不过只要在微信里打开过视频，地址和 key 就会记到 `data/data.db` 的 `browse_history` 表里，可以直接取出来下载：

```sh
DB=./data/data.db

# 1. 列出最近打开过的视频
sqlite3 $DB "select external_id, substr(replace(title,char(10),' '),1,40) from browse_history order by updated_at desc limit 10"

# 2. 取出地址和 key（把 <external_id> 换成上一步列出的值）
ID=<external_id>
URL=$(sqlite3 $DB "select url from browse_history where external_id='$ID'")
KEY=$(sqlite3 $DB "select json_extract(extra_data,'$.decode_key') from browse_history where external_id='$ID'")

# 3. 下载并解密。xWT111 通常是最高画质
curl --noproxy '*' -G http://127.0.0.1:2022/play \
  --data-urlencode "url=$URL&X-snsvideoflag=xWT111" \
  --data-urlencode "key=$KEY" \
  -o video.mp4
```

可选的画质有 `xWT111` / `xWT112` / `xWT113` / `xWT156` / `xWT157` / `xWT158`。不加参数时，默认是体积最小的那一档。
想看每档的大小，可以用 `curl -r 0-0 -D - "$URL&X-snsvideoflag=<spec>" -o /dev/null`，看返回头里的 `Content-Range`。

## 局域网里的其他设备

1. 把系统代理（HTTP 和 HTTPS）设成 `<宿主机IP>:2023`。
2. 导入 `data/certs/wx_channels_download.crt`，并设为始终信任。
3. 局限：插入页面的脚本把 API 写死成 `127.0.0.1:2022`，所以其他设备上的页面连不回服务。要完整可用，得在那台设备上把它本机的 2022 端口转发到宿主机，例如 `ssh -NL 2022:127.0.0.1:2022 <user>@<宿主机IP>`。

## 安全注意事项

- **不要使用内置的 SunnyNet 证书**：它的私钥就在本仓库的 `pkg/certificate/certs/` 里，所有用户共用。把它加入信任，等于任何人都能对你做 HTTPS 中间人攻击。`gen-cert.sh` 会为每台机器单独生成证书。
- 代理端口**没有任何认证**。只在可信的局域网里绑定 `0.0.0.0`，否则用 `PROXY_BIND=127.0.0.1 ./run.sh`。
- 不再使用时删除证书（macOS）：
  ```sh
  sudo security delete-certificate -c wx_channels_download_local /Library/Keychains/System.keychain
  ```

## 排障

| 现象 | 检查 |
|---|---|
| 页面没有任何反应 | 用 `scutil --proxy` 看系统代理是不是 `127.0.0.1:2023`；微信有没有 ⌘Q 完全重开 |
| 页面有没有连上服务 | `curl --noproxy '*' http://127.0.0.1:2022/api/channels/status`，结果是 `available:true` 才算连上 |
| 查看日志 | `podman logs -f wx-channels-download` |
| `podman` 连不上 | 先运行 `podman machine start` |
| 其他网站打不开 | 先跑 `./stop.sh` 恢复直连，再排查 |

## 升级

```sh
podman build -t localhost/wx-channels-download:<ver> --build-arg VERSION=<ver> -f Containerfile .
IMAGE=localhost/wx-channels-download:<ver> ./run.sh
```
