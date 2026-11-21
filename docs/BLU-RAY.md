# 蓝光 ISO 原盘：解析与选集

> 2026-11-19。目标：直接播 `*.iso` 原盘，能列出并选择正片/花絮（mpls 播放列表）。

## 1. 结论

mpv 的官方 Windows 构建带 **libbluray**（`--bluray-device`、`--bluray-angle`、
`--bluray-region`、`--bluray-min-title-length` 等选项齐全）。实测结论：

- ISO 可以直接作为 `--bluray-device` 传入，**不需要挂载**，也不需要我们的代码解析 UDF；
- 选集用 `bd://mpls/<纯数字>`（**不能**带 `.mpls` 后缀）或 `--edition=<n>`；
- 播放列表时长可以自己读 `BDMV/PLAYLIST/*.mpls` 算出来，和 libbluray 报的一致。

```powershell
# 默认（libbluray 选第一个 title）
mpv --bluray-device=D:\dvplayer\iso\hush2in1.iso bd://

# 按 mpls 编号选集：纯数字，mpv 自己补 .mpls
mpv --bluray-device=D:\dvplayer\iso\hush2in1.iso bd://mpls/1
mpv --bluray-device=D:\dvplayer\iso\hush2in1.iso bd://mpls/2

# 按 edition 选（0 起）：libbluray 把每个 title 暴露成一个 edition
mpv --bluray-device=D:\dvplayer\iso\hush2in1.iso --edition=1 bd://

# 按 title / 章节
mpv --bluray-device=D:\dvplayer\iso\hush2in1.iso bd://title/2
mpv --bluray-device=D:\dvplayer\iso\hush2in1.iso bd://title/2/chapter/3
```

## 2. 选集怎么做

`bd://` 本身不负责"列出有哪些 title"，这要自己读播放列表。两条路：

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| A. 挂载 ISO 读 mpls | `Mount-DiskImage`（本地路径，不需要管理员）→ 遍历 `BDMV\PLAYLIST\*.mpls` | 需要挂载；ISO 在网络上时要先下载 |
| B. 直接读 UDF | 自己实现 UDF 2.50 读取 | 工作量大，不值得 |

M0 用 A。mpls 解析很轻：`PlayListStart` 处的 `PlayItem` 列表，每项有
`IN_time` / `OUT_time`（45 kHz 刻度），累加就是时长。

**所有多字节字段都是大端**（BD 规范），PowerShell 的 `[BitConverter]`
按主机小端读会全部读错，必须自己按字节拼。

```text
+0   "MPLS"
+8   PlayListStart (4, BE)
+12  PlayListMarkStart (4, BE)
PlayListStart:
+0   length (4, BE)          段内容长度，不含自身 4 字节
+6   numberOfPlayItems (2, BE)
+10  第一项 PlayItem:
     +0  length (2, BE)      项长度，不含自身 2 字节
     +2  clip name (5)
     +7  codec id (4)
     +11 flags (2)   reserved(11) + is_multi_angle(1) + connection_condition(4)
     +13 若 is_multi_angle: number_of_angles(1) + reserved(3)
     then STC_sequence_id (1)
     then IN_time (4, BE)
     then OUT_time (4, BE)
     下一项 = 当前位置 + 2 + length
```

`scripts/windows/iso-titles.ps1` 按这个结构枚举，输出每个 playlist 的
时长、PlayItem 数、章节数，按长度排序，并单独列出 >30 分钟的正片候选。

**为什么不用 mpv 自己的列表**：libbluray 只在日志里打印 title 列表，没有机器可读
接口。自己读 mpls 才能做选集 UI。

## 3. 章节

章节在 `BDMV/PLAYLIST/*.mpls` 的 `PlayListMark` 段（`PlayListMarkStart`）。

**每条 mark 是定长 14 字节，没有逐项 length 字段**，mark 数在段头 `+4`：

```text
PlayListMark 段:
+0  length (4, BE)
+4  numberOfPlayListMarks (2, BE)
+6  第一条 mark（14 字节，定长）:
    +0 reserved (1)
    +1 mark_type (1)             1 = 章节，2 = link point
    +2 ref_to_PlayItem_id (2, BE)
    +4 mark_time_stamp (4, BE, 45 kHz)
    +8 entry_ES_PID (2, BE)
    +10 duration (4, BE)         到下一个 mark 的时长
```

实测 Hush 2in1 的两个正片各 13 章，与 libbluray 的 `chapter-list/count` 一致；
`00000.mpls` 有 1 个 mark。解析结果在 `iso-titles.ps1` 里按 `mark_type == 1` 计数。

## 4. 实测（2026-11-19，Hush 2016 2in1）

样本：`HUSH_2IN1_PURE.ISO`，35,972,448,256 字节（33.5 GiB），卷标
`HUSH_2IN1_PURE`，未加密（`AACS\Unit_Key_RO.inf` 打开失败属正常，代表没有 AACS）。

### 4.1 播放列表枚举

```
3 playlists, total 03:14:07
01:21:47  4907.0s  items=1  ch=13  00002.mpls
01:21:47  4907.0s  items=1  ch=13  00001.mpls
00:30:33  1833.1s  items=30 ch=1   00000.mpls
```

libbluray 自己的列表完全对上：

```
[bd] List of available titles:
[bd] idx:   0 duration: 01:21:46 angles:  1 (playlist: 00001.mpls)
[bd] idx:   1 duration: 01:21:46 angles:  1 (playlist: 00002.mpls)
[bd] First play: 1, Top menu: 1, HDMV Titles: 2, BD-J Titles: 0, Other: 0
```

- 脚本算 4907.0s，libbluray 报 01:21:46.985，差 0.015s（45 kHz 取整），
  说明**大端读取和 PlayItem 偏移是对的**；
- 两个 81:47 的正片正是 2in1 的两个剪辑版本；
- `00000.mpls` 是 30 段花絮拼起来的 30:33；
- 章节数 13 与 libbluray 的 `chapter-list/count` 一致。

### 4.2 选集落到哪个 clip

用 `--msg-level=bd=trace` 看实际打开的文件：

| 目标 | 最终打开的流 |
| --- | --- |
| `bd://`（默认） | `BDMV\STREAM\00001.m2ts` |
| `bd://mpls/1` | `BDMV\STREAM\00001.m2ts` |
| `bd://mpls/2` | `BDMV\STREAM\00002.m2ts` |
| `--edition=1 bd://` | title 2（`cfg_title=1`） |

**两个版本是独立 clip**（00001 与 00002），不是同一段的章节跳转。

### 4.3 解码与轨道

```
VO: [gpu-next] 1920x1080 d3d11[nv12]
Using hardware decoding (d3d11va).
duration=01:21:46 res=1920x1080 codec=H.264 / AVC fps=23.976 hwdec=d3d11va
```

- 1080p H.264 走 `d3d11va` 硬解，`gpu-next` 渲染；
- 音轨：1 条 DTS（`0x1100`）；
- 字幕：3 条 PGS（`0x1200` eng、`0x1201` zho、`0x1202` zho）；
- 三条 PGS 在 `ffmpeg/demuxer` 阶段有 "Could not find codec parameters ...
  unspecified size"，属于 libbluray 未预读字幕头，播放时正常，可忽略。

### 4.4 下载

NAS `10.0.0.100` 上的原盘通过 `pscp`/`psftp` 拉到 `D:\dvplayer\iso\`。
`pscp` 不支持断点续传，中断后改用 `psftp` 的 `reget`，从 10.7% 接着下完。
NAS 的 SSH 用户名是 `admin`，ISO 在 `/vol1/1000/`（中文目录建了 ASCII 硬链接）。

## 5. 差距清单

已经验证的：

- ISO 直读、不挂载（`--bluray-device`）；
- 播放列表枚举、时长计算与 libbluray 一致；
- 章节枚举（13 章与 libbluray 一致）；
- `bd://mpls/N` 与 `--edition=N` 两种选集方式；
- 1080p AVC 硬解、PGS 字幕轨识别。

还差的，按优先级：

| # | 缺什么 | 影响 | 计划 |
| --- | --- | --- | --- |
| 1 | ~~壳没有 ISO 入口与选集 UI~~ | 两端已做：侧栏「打开原盘…」→ 读 title → 选集 | Windows 走 libbluray（§5.1），macOS 挂载 + EDL（§5.2） |
| 2 | `Mount-DiskImage` 只支持本地 ISO | NAS 上的原盘要先下载 | 产品里应支持"边读边播"或缓存到本地；mpv 的 `bd://` 配 UNC 路径需要 Windows 先能读该路径 |
| 3 | BD-J 菜单不支持 | 不能点原盘菜单 | mpv/libbluray 不带 Java 运行时；只能直接选 title，产品 UI 用选集列表替代 |
| 4 | 无缝分支（seamless branching） | 多版本剪辑的衔接可能不完美 | 依赖 libbluray，暂不承诺 |
| 5 | ~~音轨/字幕轨切换未接 IPC~~ | 播放页的 `track-list` / `set_property aid/sid` 已在正式壳里 | 原盘和网络片共用同一套 |
| 6 | 4K UHD 蓝光 ISO 未测 | 当前样本都是 1080p AVC | 需要 UHD BD 原盘（HEVC + HDR10/DV） |
| 7 | AACS / BD+ 加密盘 | 加密原盘可能打不开 | mpv 不带解密；需要 MakeMKV/抽流，产品上要么不支持，要么提示 |
| 8 | ~~播放进度记忆~~ | Windows 已做：`%LOCALAPPDATA%\dvplayer\local-progress.json`，按 ISO + mpls 记 | — |

## 5.1 正式壳入口（Windows）

侧栏底部「打开原盘…」→ 选 `*.iso` → 弹标题列表（正片 / 花絮 + 时长）→ 播放。

- **列 title 不自己解析 UDF**：用 `mpv.com --frames=1 --bluray-device=<iso> bd://`
  读 libbluray 打在日志里的 `--edition=N 'title: N (时长) (xxxxx.mpls)'`。
  title 号和 mpls 编号不一定对应（真实原盘常见 title 1 → 00800.mpls），
  读这行最准，也不用挂载。
- **播放**：`--bluray-device=<iso>` + `bd://mpls/<n>`；音频/字幕/章节/seek
  全部复用播放页现有 IPC。
- **不是媒体库条目**：原盘不查核心的播放源、不拉媒体信息、不回写进度；
  续播点写本地 JSON，播完自动清掉。
- **自检**：`--play-iso <iso> --play-iso-title 1 --play-check <目录>
  --play-features overlay --play-start 0`；只截标题框用
  `--disc-list <iso> --disc-shot <目录>`。

## 5.2 正式壳入口（macOS）

macOS 随包的 mpv 没有 libbluray（`--list-options` 里没有 `--bluray-device`），
所以不能复用 §5.1 的 `bd://`。做法是：

- `hdiutil attach -readonly -nobrowse -mountpoint <临时目录> <iso>` 挂载；
- 自己解析 `BDMV/PLAYLIST/*.mpls`（大端，`IN_time`/`OUT_time` 按 45 kHz），
  时长与 Windows 的 libbluray 结果一致；
- 选标题后把每一段写成 mpv EDL：
  `edl://!no_chapters;<m2ts>,<起始秒>,<时长>;...`（落成临时 `.edl` 文件，
  避免路径转义），这样多段播放列表也能连起来播；
- 关播放窗时 `hdiutil detach` 并删掉临时 EDL / 挂载点；
- 原盘进度同样存本地 JSON（`~/Library/Application Support/DvPlayer/local-progress.json`）。
- 自检：`DVPLAYER_DISC=<iso> DVPLAYER_DISC_TITLE=N DVPLAYER_PLAY_SHOT=<png>`。


## 6. 与 4K/8K/HDR 的关系

蓝光原盘本身是 1080p AVC / HEVC，**不会**带来 8K 或 120 fps 的额外需求；
但 4K UHD 原盘是 HEVC + HDR10（或 DV），要复用 `docs/DECODE.md` 里已验的
硬解和 HDR 元数据链路。

所以两条线是叠加关系，不是替代：

- 解码矩阵（`DECODE.md`）：4K/8K、120 fps、HDR10/HDR10+/HLG；
- 原盘（本文）：容器与播放列表，不改变解码要求。

## 7. 脚本

| 脚本 | 作用 |
| --- | --- |
| `scripts/windows/iso-titles.ps1` | 挂载 ISO，枚举 mpls 的时长/章节 |
| `scripts/windows/iso-play.ps1` | 跑一次 `--bluray-device` 播放并抓日志 |
| `scripts/windows/iso-verify.ps1` | 对多个 target（mpls/edition）批量验证 |
| `scripts/windows/iso-fetch.ps1` | 计划任务里用 `psftp reget` 断点续传 ISO |
