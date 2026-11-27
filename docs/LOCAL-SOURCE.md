# 本地文件夹源

把「不在服务器上的东西」也放进媒体库：一个目录（或单个 ISO）就是一个源，
卡片墙、详情、选集、续播、继续观看全走媒体库那一套，不再有一个单独的
「打开原盘」入口。

实现放在共享核心 `core/media/src/sources/local.rs`，两端界面只调
`MediaSource`，所以季集推断、标题清理、进度格式只有一份。

## 1. 怎么加

- **Windows / macOS**：「服务器」页 → 添加 → 类型选「本地文件夹」→
  「浏览…」选目录（ISO 也可以直接在地址框里填完整路径）；
  相邻的 SMB / NFS / WebDAV 三个类型填共享地址，见 §6。
  侧栏不再有单独的本地文件夹入口，加源的地方只有服务器页。

源的类型是 `local`，`base` 是目录或文件的绝对路径，`dataDir` 是进度文件
所在目录（界面自动填成配置目录，不用手写）。添加后和飞牛 / Emby 并列在
侧栏「服务器」列表里，状态点同样区分连上 / 失败。

## 2. 目录怎么读

根目录下每一项单独判断：

| 情况 | 结果 |
| --- | --- |
| 视频 / ISO 文件 | 一个电影条目 |
| 目录里 ≥2 个视频，或有季子目录，或唯一视频带集号 | 一部剧（剧集） |
| 目录里只有一个视频且不像剧 | 一个电影，标题取视频文件名 |

剧的下面：

- 季目录认 `Season 01`、`S02`、`第 3 季`、`第二季`；认不出季的子目录
  里的视频并进第一季；
- 集号从文件名认 `S01E02`、`第 12 集`、`EP06`；认不出就按文件名排序编号，
  顺序不会乱；
- 只有一季时详情页直接列集（`singleChildId` 指向那一季），有第二季才先列季。

标题清理：去掉扩展名和常见发布标签（`2160p`、`BluRay`、`x265`、`DDP5.1`…），
把 `.` `_` 换成空格，`(2021)` 这种年份同时作为条目年份。

海报：视频同目录找 `<视频文件名>.jpg`、`poster.jpg`、`folder.jpg`、
`cover.jpg`（`jpg/jpeg/png/webp`）。找不到就用渐变占位，不联网刮削。

解开的蓝光目录（含 `BDMV/STREAM`）**不展开**，一个原盘应该打成 ISO 再加进库，
否则一个原盘会变成几千个「集」。

## 3. 怎么播

- 普通视频：`playSource` 直接给绝对路径，mpv 当本地文件打开；
- ISO：`playSource` 带 `disc: true`，界面走原来的原盘流程——
  Windows 用 `mpv.com` 读 title 后 `bd://mpls/<n>`（`BLU-RAY.md` §5.1），
  macOS `hdiutil` 挂载 + `mpls` → EDL（§5.2）。
  打开先进盘里自带的菜单（`--disc-menu` + `discnav`，`BLU-RAY.md` §5.4），
  选完按钮 mpv 自己切正片；起播后其它标题在播放器右侧「标题」面板切，
  播完直接关窗。
  续播点仍按这一集的条目 id 回写。

### 同目录外挂字幕

视频旁边的字幕文件由客户端自己找、自己 `sub-add`，同时关掉 mpv 的
`sub-auto`（它只认和视频完全同名的文件，且会和这里的规则冲突、加载两次）。

| 规则 | 说明 |
| --- | --- |
| 位置 | 视频所在目录，**不递归**子目录；网络直链 / 原盘 EDL 不找 |
| 扩展名 | `srt` / `ass` / `ssa` / `vtt` / `sup` / `idx` |
| 名字配对 | 两边去掉分隔符后相等，或互为前缀；多出来的部分**全是数字**才拒绝 |
| 语言 | 从字幕名比视频名多出来的整词认（`chs` / `zh-Hans` / `简中` / `eng`…） |
| 签名 | 「外挂」+ 语言标签（`中文 · 简体`、`英语`、`强制`…）；认不出语言写「外挂」 |

名字配对举例：`Movie.2024.srt` 配得上 `Movie.2024.1080p.mkv`；
`E01.srt` **不配** `E010.mkv`（多出来的 `0` 全是数字）；`Movie.2025.srt`
不配 `Movie.2024.1080p.mkv`。

外挂字幕必须在文件真正加载之后 `sub-add`（macOS `@file-loaded` 事件、
Windows 观察 mpv 的 `path` 属性）：`loadfile` 之后立即加会被静默丢掉。
加完再查一次 `track-list`，按 `external-filename` 找到对应轨，用文件名认出的
语言 / 标题补上 mpv 猜不出的部分。字幕偏好（记住的「第 N 张字幕」）要等
外挂轨全部到齐再套用，否则会把外挂偏好套到内嵌轨上。

## 4. 进度和记录

本地源没有服务器可回写，进度落
`<dataDir>/local-library-progress.json`（Windows `%LOCALAPPDATA%\dvplayer`，
macOS `~/Library/Application Support/DvPlayer`）。

**注意文件名**：侧栏直接打开原盘的续播点用的是 `local-progress.json`
（`LocalProgressStore` / `LocalProgress.cs`，结构是 `{ 条目 id: {...} }`），
这里的文件多一层 `items` 且带标题、季集号，两者不能混用一个文件。

有了进度文件，「记录 → 观看」里会自然出现本地条目（剧会显示
「剧名 · 第 N 集」），点进去按条目 id 续播。

## 5. 自检

核心自带一个只看扫描结果的命令行：

```bash
cd core
~/.cargo/bin/cargo run -p dvplayer-media --example local -- /path/to/dir
```

打印库、条目、季集和 `play_source` 的 URL / `disc` 标志，不启动界面。

端上自检：本地源的条目和服务器条目一样，用 `DVPLAYER_DETAIL` /
`DVPLAYER_PLAY`（macOS）、`--play`（Windows）指定
`<源 id>:f/<相对路径>` 或 `<源 id>:d/<目录>` 即可。

文件协议源（SMB / NFS / WebDAV）挂载以后也是本地目录，同样用上面的命令：

```bash
DVPLAYER_PLAY='smb-1:f/某部电影/某部电影.mkv' \
DVPLAYER_PLAY_SECONDS=10 \
apps/macos/DvPlayer/build/DvPlayer.app/Contents/MacOS/DvPlayer
```

## 6. 文件协议源（SMB / NFS / WebDAV）

最初定的协议类型在同一个「添加」表单里：类型选 SMB / NFS / WebDAV，
填共享地址（可带账号密码）。

做法是**让系统先挂载，再把挂载后的本地路径交给核心**（核心看到的仍是
`kind=local`）：

| 平台 | SMB | NFS | WebDAV |
| --- | --- | --- | --- |
| macOS | `mount_smbfs`，挂到 `~/Library/Caches/DvPlayer/mounts/<源 id>` | `mount -t nfs -o vers=3,resvport,nolocks,soft` | `mount_webdav` |
| Windows | `WNetAddConnection2`（mpr.dll），直接用 `\\host\share` | `mount -o anon` 到盘符 | `net use` 到盘符 |

地址写法：

- `smb://192.168.1.10/影视`、`//192.168.1.10/影视`、`\\192.168.1.10\影视`；
- `nfs://192.168.1.10:/volume1/media`；
- `https://192.168.1.10:5006/dav`。

SMB / WebDAV 的账号密码可以填在表单里，也可以随地址一起写（地址里的账号密码会做百分号解码）；NFS 一般匿名，账号密码留空。

为什么不把 SMB 客户端编进核心：随包 mpv 没有 libsmbclient，核心能列目录也
打不开 `smb://`。挂载以后扫描、播放、ISO 原盘都只认本地路径，和本地文件夹
源完全一样（§2–§4 全部适用）。

Windows 的 NFS / WebDAV 依赖系统组件：NFS 需要在「启用或关闭 Windows 功能」
里装「NFS 客户端」，WebDAV 需要启动「WebClient」服务；缺组件时表单直接回
对应提示。SMB 不需要额外组件。

> 实测：macOS 上 `smb://<账号>@10.0.0.134/影视` 挂载后列出 12 个条目
> （剧 3 部、电影 9 部，含 ISO），普通视频与 UHD 原盘都能从条目起播。
> 扫描一个 12 项、其中一部 579 集的共享约 7–8 秒：顶层目录并发，且用
> `readdir` 自带的类型，不再每个文件 `stat` 一次。
>
> Windows 侧已完成编译与界面回归：类型行、SMB / NFS / WebDAV 三种表单、
> 失败回显都验证过（SMB 报「找不到网络名」；NFS 先探 `mount` 命令，直接提示
> 装「NFS 客户端」；WebDAV 报 `net use` 的系统错误并提示 WebClient 服务）。
> 测试机的网段连不到 NAS，所以「Windows 成功挂载 SMB」还差一次有 NAS 的机器实测。
