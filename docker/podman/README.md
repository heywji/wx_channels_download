# 容器部署（macOS + Podman）

所有东西都跑在一个容器里：MITM 代理、下载服务，以及自动下载器。Mac 上只留一个开机自启的 LaunchAgent。
装好以后是全自动的：**在微信里看到的每一个视频都会自动下载最高画质到 `~/Downloads`**，每下完一个，弹一条带视频名字的通知，点击通知直接播放。

## 架构

```
┌───────────── 容器 wx-channels-download（内存上限 128 MB）─────────────┐
│ wx_video_download  :2023 MITM 代理（只改 channels.weixin.qq.com）      │
│                    :2022 API（只开在本机 127.0.0.1）                    │
│ wxdl.py watch      每 3 秒拉一次浏览记录 → 下载 + 解密 → /downloads      │
│                    完成或失败时，把通知写进 /notify 队列                 │
│ 卷 wx-channels-data:/data   配置、本机根证书私钥、SQLite、下载状态      │
└────────────────────────────────────────────────────────────────────────┘
        ▲ 系统代理 127.0.0.1:2023              │ ~/Downloads  ~/Library/Caches/wx-channels
微信 ───┘                                       ▼
LaunchAgent com.wxchannels.agent（登录时启动，常驻）
  · 虚拟机或容器没在运行 → 先关掉系统代理，再拉起 podman machine 和容器
  · 代理端口可用 → 打开系统代理
  · 读取通知队列 → 用 terminal-notifier 弹出 macOS 通知（点击后播放视频）
```

插入页面的脚本会把每个显示过的视频（地址和解密 key）记进浏览记录。`wxdl.py` 通过 API（`POST /api/browse_history/list`）读取这些记录，再通过 `/play` 边下载边解密（视频只加密了开头 131072 字节：用 decode_key 作种子跑 ISAAC64，生成的字节流和数据做 XOR）。

## 安装

前提：Podman（`brew install podman && podman machine init`），以及 python3。
可选但推荐装 `brew install terminal-notifier`，没有它的话，点击通知不会打开视频。

```sh
git clone https://github.com/heywji/wx_channels_download && cd wx_channels_download/docker/podman
./install-macos.sh
```

它会依次：构建镜像 → 创建卷 → 以 128 MB 内存上限运行容器 → 把容器生成的根证书加入系统钥匙串并设为信任（需要管理员密码，同一张证书只需一次）→ 安装并启动 LaunchAgent。
**装完之后可以把这个 checkout 删掉**，运行不再需要它。

然后 **⌘Q 完全退出微信再重新打开**，让微信用上系统代理。之后正常刷视频号就行。

可以用环境变量调整：`NETWORK_SERVICE`（默认 `Wi-Fi`）、`DOWNLOAD_DIR`（默认 `~/Downloads`）、`MEMORY`（默认 `128m`）、`PROXY_BIND`（默认 `0.0.0.0`）、`VERSION`（Release tag，默认 `v260907`），以及 `IMPORT_DATA_DIR`（把已有的数据目录一次性导入卷里）。

## 下载行为

- **看过的全都下**，包括首页推荐里刷到的视频。刷得越多，下得越多。
- 自动选最高画质：逐个探测各档的文件大小，挑最大的那档。
- 先写成 `<作者>_<标题>.mp4.part`，校验通过后（字节数对得上，文件头是 `ftyp`），再改名成 `.mp4`。**文件名不是 `.part` 结尾，就说明已经完整下完了。**
- 通知：标题是「✅ 视频号下载完成」或「❌ 视频号下载失败」，副标题是「作者：视频标题」，正文写保存位置，点击后播放。
- 已经下载过的视频记在卷里的 `autodl_state.json`，不会重复下载。第一次启动时只处理最近 2 小时内看过的视频。
- 遇到网络问题会自动重试，最多 3 次。「签名过期」时会弹失败通知，在微信里重新打开这个视频就会再试一次。

手动挑一个下载（例如自动下载失败的那个）：

```sh
podman exec -it wx-channels-download python3 /usr/local/share/wx_channels/wxdl.py      # 列出最近的视频，按序号选择
podman exec wx-channels-download python3 /usr/local/share/wx_channels/wxdl.py 1        # 直接下载最近看的那个
```

## 内存

在 Apple Silicon 上实测（v260907）：空闲时约 80 MB（Go 服务约 64 MB，python 下载器约 20 MB）。同时跑 3 个 `/play` 下载、每个 40 MB 时，峰值约 92 MB，没有触发 OOM。
所以上限设成 `--memory 128m`（同时设了 `--memory-swap 128m`，不让它用 swap），另外设了 `GOMEMLIMIT=90MiB`，让 Go 在碰到容器上限之前就开始 GC。

## 常用命令

| 目的 | 命令 |
|---|---|
| 看容器状态和内存 | `podman stats --no-stream wx-channels-download` |
| 下载日志 | `podman logs -f wx-channels-download` |
| LaunchAgent 日志 | `cat /tmp/wx-channels-agent.log` |
| 页面有没有连上服务 | `curl --noproxy '*' http://127.0.0.1:2022/api/channels/status`，`available:true` 才算连上 |
| 暂停（关掉代理，停掉容器） | `launchctl bootout gui/$(id -u)/com.wxchannels.agent && podman stop wx-channels-download && networksetup -setwebproxystate Wi-Fi off && networksetup -setsecurewebproxystate Wi-Fi off` |
| 恢复 | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.wxchannels.agent.plist` |
| 卸载（保留数据卷） | `./uninstall-macos.sh` |
| 彻底卸载（删除数据卷和证书） | `./uninstall-macos.sh --purge` |

LaunchAgent 会把停掉的容器自动拉起来，所以只用 `podman stop` 停不住，要先 `bootout` 掉 LaunchAgent。

## 文件

| 文件 | 说明 |
|---|---|
| `Containerfile` | debian-slim + python3 + openssl，构建时从 Releases 下载对应架构的 Linux 二进制 |
| `entrypoint.sh` | 第一次启动时生成配置和本机根证书；在后台运行 `wxdl.py watch`，退出了会自动重启；最后 exec 下载服务 |
| `wxdl.py` | 自动和手动下载的逻辑（只用标准库） |
| `config.example.yaml` | 容器内的默认配置：`proxy.system: false`、`proxy.skipInstallRootCert: true`、监听 `0.0.0.0` |
| `install-macos.sh` / `uninstall-macos.sh` | 在 Mac 上安装或卸载。LaunchAgent 的脚本内嵌在 plist 里，不会在 Mac 上留下别的文件 |

## 在 Mac 上留下了什么

- `~/Library/LaunchAgents/com.wxchannels.agent.plist`
- `~/Library/Caches/wx-channels/`：通知队列，弹出后就删除，平时是空的。不放在 `~/Downloads` 下，是因为 macOS 的隐私保护（TCC）不让后台 agent 读取「下载」文件夹
- 系统钥匙串里的根证书
- `/tmp/wx-channels-agent.log`

数据（数据库、根证书私钥、下载状态）都在 Podman 卷 `wx-channels-data` 里，也就是在虚拟机内部，不在 Mac 的文件系统上。
SQLite 以 WAL 模式写入时，不要让它跨虚拟机放在 bind mount 上：实测出现过 WAL 文件头被清零、数据丢失的情况。
**私钥只存在这个卷里**：如果删掉卷或者重建 podman machine，私钥就没了，重新运行 `install-macos.sh` 会生成新证书并重新信任。

## 安全注意事项

- **不要使用内置的 SunnyNet 证书**：它的私钥在本仓库的 `pkg/certificate/certs/` 里，所有用户共用。容器第一次启动时会生成本机专属证书。
- 代理端口**没有任何认证**。只在可信的局域网里绑定 `0.0.0.0`，否则用 `PROXY_BIND=127.0.0.1 ./install-macos.sh`。
- 局域网里的其他设备：系统代理设成 `<Mac IP>:2023`，并信任证书（证书可以用 `podman exec wx-channels-download cat /data/certs/wx_channels_download.crt` 导出）。插入页面的脚本把 API 写死成 `127.0.0.1:2022`，所以要完整可用，得在那台设备上把它本机的 2022 端口转发到这台 Mac。

## 排障

| 现象 | 检查 |
|---|---|
| 刷视频没有任何反应 | 用 `scutil --proxy` 看系统代理是不是 `127.0.0.1:2023`；微信有没有 ⌘Q 完全重开；`api/channels/status` 是不是 `available:true` |
| 有下载但没有通知 | `ls ~/Library/Caches/wx-channels` 里有没有积压的文件；看 `/tmp/wx-channels-agent.log`；在系统设置里确认允许 terminal-notifier 发通知 |
| 其他网站打不开 | 看 LaunchAgent 日志；按「暂停」那条命令关掉代理 |
| `podman` 连不上 | `podman machine start` |

## 升级

```sh
VERSION=<新的 tag> ./install-macos.sh   # 重新构建镜像并替换容器，数据卷会保留
```
