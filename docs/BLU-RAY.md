# 蓝光 ISO 原盘：解析与选集

> 2026-11-19。目标：直接播 `*.iso` 原盘，能列出并选择正片/花絮（mpls 播放列表）。
>
> 2026-11-22 起入口统一：打开 ISO 走同一套播放器。
> 2026-11-27 起 **Windows** 改成进盘里自带的菜单（HDMV，见 §5.4）：mpv 0.42 的
> `--disc-menu` 打开 libbluray 的导航模式，菜单画面和按钮高亮由 mpv 自己
> 渲染（`discnav` 驱动）；点按钮后 mpv 自己切标题，壳不重开播放器。
> 菜单收起后，右侧的「标题」面板仍可切换其它标题。
> Windows 用 `bd://mpls/<n>` 切标题；macOS 重新生成 EDL 再重启 mpv，盘不卸载。
>
> **macOS 同样进菜单**（HDMV 盘）：实测 I.Saw.The.Devil（`BD-J Titles: 0`）
> 在进程内 libmpv 下能画出 BLUE KINO 菜单和按钮。
> **BD-J 盘例外**：菜单要 Java VM + libbluray 的 BD-J jar，随包的 libbluray
> 没有，mpv 只会 "Playing without menus"。这种盘（`BDMV/JAR/*.jar`）两端都
> 跳过菜单直接播最长正片，否则会卡在菜单背景视频 + 控制条被收掉。
>
> 2026-11-27 补：`.iso` 也可能是 **DVD-Video**（`VIDEO_TS`）。两端都会先认出
> 盘的类型再决定走蓝光还是 DVD，不再一律报「没有 BDMV」（见 §5.5）。

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

**`mark_time_stamp` 是源流时间，不是 playlist 时间**（2026-11-27 实测确认）。
它相对当前 PlayItem 的 `IN_time`：

```text
playlist 时间 = 该 PlayItem 之前各段时长之和 + (mark_time_stamp - PlayItem.IN_time)
```

真实盘 `00001.mpls` 的 `IN_time` 是 600 s、第一条 mark 也是 600 s，而
libbluray / mpv 报的第一章是 0：不减去 `IN_time` 的话，菜单里点第一章会跳到 10 分钟。
换算后和 mpv 的 `chapter-list` 逐条对上（`0, 438.772, 834.0, … 4906.944`）。

最后一条 mark 常落在片尾（时间等于时长），点它就是直接结束，菜单里按
`time < 时长 − 1` 滤掉。

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
- 盘里自带的 HDMV 菜单（`--disc-menu` + `discnav`，两端，§5.4）；
  BD-J 盘跳过菜单直接播正片；
- DVD-Video 镜像（`VIDEO_TS`）：Windows 进 DVD 菜单，macOS 按 VOB 连播（§5.5）；
- 播放列表枚举、时长计算与 libbluray 一致；
- 章节枚举（13 章与 libbluray 一致）；
- `bd://mpls/N` 与 `--edition=N` 两种选集方式；
- 1080p AVC 硬解、PGS 字幕轨识别。

还差的，按优先级：

| # | 缺什么 | 影响 | 计划 |
| --- | --- | --- | --- |
| 1 | ~~壳没有 ISO 入口与选集 UI~~ | 两端已做：ISO 放进「本地文件夹源」后就是媒体库条目（见 `LOCAL-SOURCE.md`） | Windows 走 libbluray（§5.1），macOS 挂载 + EDL（§5.2） |
| 2 | `Mount-DiskImage` 只支持本地 ISO | NAS 上的原盘要先下载 | 产品里应支持"边读边播"或缓存到本地；mpv 的 `bd://` 配 UNC 路径需要 Windows 先能读该路径 |
| 3 | ~~原盘自带菜单（HDMV）不跑~~ | 点不了盘里画的那套菜单 | 已做（§5.4）：mpv 0.42 的 `--disc-menu` + `discnav` 跑 HDMV 导航，菜单是盘自己的画面。BD-J 盘仍不跑 JVM，回退到直接播正片 |
| 4 | 无缝分支（seamless branching） | 多版本剪辑的衔接可能不完美 | 依赖 libbluray，暂不承诺 |
| 5 | ~~音轨/字幕轨切换未接 IPC~~ | 播放页的 `track-list` / `set_property aid/sid` 已在正式壳里 | 原盘和网络片共用同一套 |
| 6 | 4K UHD 蓝光 ISO 未测 | 当前样本都是 1080p AVC | 需要 UHD BD 原盘（HEVC + HDR10/DV） |
| 7 | AACS / BD+ 加密盘 | 加密原盘可能打不开 | mpv 不带解密；需要 MakeMKV/抽流，产品上要么不支持，要么提示 |
| 8 | ~~播放进度记忆~~ | Windows 已做：`%LOCALAPPDATA%\dvplayer\local-progress.json`，按 ISO + mpls 记 | — |

## 5.1 正式壳（Windows）

入口在媒体库里：把一个目录（里面有 `*.iso`）加成「本地文件夹源」
（见 `LOCAL-SOURCE.md`），点 ISO 条目 → 弹原盘菜单（§5.4，标题 + 章节）
→ 选标题或章节起播。自检仍可直接指定 ISO，不必先建源。

- **列 title 不自己解析 UDF**：用 `mpv.com --frames=1 --bluray-device=<iso> bd://`
  读 libbluray 打在日志里的 `--edition=N 'title: N (时长) (xxxxx.mpls)'`。
  title 号和 mpls 编号不一定对应（真实原盘常见 title 1 → 00800.mpls），
  读这行最准，也不用挂载。
- **读章节**：`mpv.com --bluray-device=<iso> bd://mpls/<n> --pause --vo=null`
  加一段 Lua，在 `file-loaded` 后打印 `chapter-list` 再 `quit`。libbluray
  已经换算好时间，直接用；按标题懒加载（选中哪个读哪个），一次 1～2 秒。
- **播放**：`--bluray-device=<iso>` + `bd://mpls/<n>`；音频/字幕/章节/seek
  全部复用播放页现有 IPC。
- **打包注意**：随包的 mpv 要同时带 `mpv.com`。GUI 版 `mpv.exe` 没有 stdout，
  列不出 title（`MpvProcess` 仍回落到 `mpv.exe`，但只用于播放）。
- **进度**：从媒体库点开的 ISO，进度回写核心（本地源）；自检直接开 ISO 时
  续播点写 `local-progress.json`，播完自动清掉。原盘都不拉媒体信息。
- **自检**：进盘内菜单 `--disc-menu <iso> --disc-shot <目录>`；
  按菜单按钮 `--disc-menu-keys=select,down,down,select`（逗号分隔，
  逐个交给 `discnav`），`--disc-menu-select` 是只按一次回车的简写；
  按坐标点按钮可加 `--disc-menu-clicks=0.22,0.94;0.33,0.94`
  （默认把事件抛给 WPF，`--disc-menu-click-mode=post` 改走真实窗口消息，
  `=discnav` 跳过 WPF 直接发按钮坐标）；查「点了没反应」加
  `--disc-menu-trace`，libbluray 的 IG 命中日志会进 mpv 的 log-file；
  直接播某个标题 `--play-iso <iso> --play-iso-title 1 --play-check <目录>
  --play-features overlay --play-start 0`；只截播放器的「标题」面板用
  `--disc-list <iso> --disc-shot <目录>`。

## 5.2 正式壳入口（macOS）

macOS 用随包的 libmpv（`scripts/build-deps-macos.sh` 带 `-Dlibbluray=enabled`），
HDMV 盘和 Windows 一样走 §5.1 的 `bd://` + `--disc-menu` 进菜单；切标题和
BD-J 盘按 mpls 拼 EDL 直接播。做法是：

- `hdiutil attach -readonly -nobrowse -mountpoint <临时目录> <iso>` 挂载；
- 自己解析 `BDMV/PLAYLIST/*.mpls`（大端，`IN_time`/`OUT_time` 按 45 kHz），
  时长与 Windows 的 libbluray 结果一致；
- 选标题后把每一段写成 mpv EDL：
  `edl://!no_chapters;<m2ts>,<起始秒>,<时长>;...`（落成临时 `.edl` 文件，
  避免路径转义），这样多段播放列表也能连起来播；
- 打开 ISO 进菜单（HDMV）或直接播最长正片（BD-J，§5.4）；关播放窗时
  `hdiutil detach` 并删掉临时 EDL / 挂载点（还没起播就关窗也直接卸盘）；
- 原盘进度同样存本地 JSON（`~/Library/Application Support/DvPlayer/local-progress.json`）。
- 自检：`DVPLAYER_DISC=<iso>` 进菜单（HDMV）或直接播正片（BD-J）；
  按菜单按钮 `DVPLAYER_DISC_MENU_KEYS=select,down,down,select`（逗号分隔）；
  直接播某个标题 `DVPLAYER_DISC=<iso> DVPLAYER_DISC_TITLE=N
  DVPLAYER_DISC_START=<秒> DVPLAYER_PLAY_SHOT=<png>`。

## 5.3 Android / TV

- 原盘统一走 mpv：本地 / SAF 的 ISO、BDMV 目录用 `--bluray-device=<path>`，
  不自己解析 UDF。
- 选集与章节：`:player-disc`（libbluray JNI）直接读 title / chapter，不再解析 mpv 日志；
  libbluray 1.5 还会给出 HDR / DV 标记与章节名，可直接喂徽标和章节面板。
- NAS 原盘：v1 先下载到缓存（和 Windows 口径一致）；「边读边播」用
  `bd_open_stream` + `mpv_stream_cb_add_ro`，排在 M2-B 之后。
- 边界与桌面一致：AACS / BD+ 不支持；AACS2（UHD）没有开源方案；BD-J 菜单不跑 JVM，
  用标题列表代替；3D MVC 不做。
- Media3 不参与原盘（没有 UDF / MPLS 这一层），见
  [ADR-0014](adr/0014-android-dual-engine.md)。

## 5.4 盘内菜单（HDMV，两端）

打开 ISO 不再直接播正片，而是进**盘里自带的那套菜单**：画面、按钮位置、
高亮、子菜单全部来自盘自己的 IG（交互图形）流。选完按钮，mpv 自己切到
正片，壳不重开播放器。

适用的是 **HDMV 菜单盘**；BD-J 菜单盘直接播正片（见本节末「BD-J 盘」）。
macOS 判断 BD-J 的办法是挂载后看 `BDMV/JAR/*.jar`；Windows 看 probe 时
mpv 日志里的 `BD-J Titles: N` / `Playing without menus`。

### 怎么做到

mpv 0.42 自带 HDMV 菜单引擎，不用自己渲染：

| 环节 | 用什么 |
| --- | --- |
| 打开导航模式 | 选项 `--disc-menu`（配合 `--bluray-device=<iso>` 和 URL `bd://`，**不带** mpls） |
| 菜单画面 | mpv 把 libbluray 解码出的 IG overlay 当成 `OSDTYPE_DISC_MENU` 画到画面上 |
| 键盘 | 命令 `discnav up\|down\|left\|right\|select\|prev\|menu\|popup` |
| 鼠标 | 命令 `discnav mouse-move\|mouse-click`，坐标是 0..1 的画面相对位置 |
| 菜单在不在 | 属性 `disc-menu-active`（true = 菜单正显示） |

**之前判断"mpv 没有菜单引擎"是错的**：只查了 `--bluray-menu`（不存在），
没查 `--disc-menu`。

两端都是这一条路，差别只在 mpv 怎么带 libbluray：

| | Windows | macOS |
| --- | --- | --- |
| mpv | 官方构建自带 libbluray（`--list-options` 有 `--bluray-device`） | 必须自己编：`scripts/build-deps-macos.sh` 里 `-Dlibbluray=enabled` |
| 依赖打包 | 无需额外处理 | `libbluray.4.dylib` + `libudfread.3.dylib` 进 `Contents/Frameworks` |
| 起播 | `--bluray-device=<iso>` + `--disc-menu` + `bd://` | 同上（先 `set_property bluray-device` / `disc-menu`，再 `loadfile bd://`）；BD-J 盘走 EDL 直连 `mpls<N>` |
| 键鼠转发 | `OnKeyDown` / `OnMouseMove` → `discnav` | `handleKey` / `onContinuousHover` → `discnav` |

**macOS 不用手动编**：`scripts/build-deps-macos.sh` 会先编 libudfread 1.2.0 +
libbluray 1.5.0（tarball 从 download.videolan.org 取，`-Dbdj_jar=disabled`、
元数据 / 字体全关），再带 `-Dlibbluray=enabled` 编 mpv。`.mpv-disc-menu`
标记文件记着这份 mpv 带导航；老 prefix 里没这个标记（v0.1.6 之前的构建）
会自动重编，不会静默用到没菜单的 mpv。

要单独排查时，两条库也可以手编：

```bash
meson setup build-udfread src/libudfread --prefix=<prefix> --default-library=shared
ninja -C build-udfread install
meson setup build-libbluray src/libbluray --prefix=<prefix> --default-library=shared \
  -Dbdj_jar=disabled -Dlibxml2=disabled -Dfreetype=disabled -Dfontconfig=disabled \
  -Denable_tools=false -Denable_examples=false -Denable_docs=false
ninja -C build-libbluray install
# mpv 这边
meson configure build/src/mpv/_build -Dlibbluray=enabled
```

### 菜单期间壳的 UI

菜单是盘自己的界面，壳的控制条叠上去就是两层 UI，鼠标还要用来点菜单按钮。
所以 `disc-menu-active=true` 期间：

- 片名、缓存速度、底部控制条、右侧截图 / 选集按钮全部收掉；
- 右上角最小化 / 最大化 / 关闭**保留**（窗口装饰，菜单里也要能关窗）；
- 收掉不只是透明度：WPF 里 `Opacity=0` 的元素**仍然参与命中测试**。
  控制条就压在盘的菜单条上，点 CHAPTERS / SETUP 会命中看不见的音轨 /
  字幕按钮，菜单反而收不到这次点击（还会弹出字幕菜单）。所以收控制条
  时同时关掉 `IsHitTestVisible`，只留右上角三个窗口按钮；自动隐藏的
  控制条也一样处理（否则点画面底部会点到看不见的按钮）。mac 那边是
  直接不渲染，不存在这个问题；
- 进度条的「点轨道直接跳」是按几何范围算的（`SliderAt`），不看
  `IsHitTestVisible`，而且在 `Root` 的预览阶段就把点击标成已处理、
  把鼠标捕获走。盘的菜单条正好压在进度条那一行上，所以这一路也要
  跟着控制条的命中测试一起关：控制条不可点时不接管点击。顺带修掉
  「控制条藏起来时点画面底部会莫名跳进度」；
- 菜单期间顶栏那一行不再拖动窗口、四边也不再改大小，整块画面都归菜单；
- 菜单期间按下 / 抬起之间动了多少都不算拖拽：菜单按钮是一大块图形，
  手抖几像素不该吞掉这次点击；
- 菜单出现时把已经弹出来的壳菜单（字幕 / 音轨 / 倍速）收掉，
  否则菜单期间点不掉它；
- 鼠标移动转发给 `discnav mouse-move`（按钮高亮跟着走），单击转发
  `mouse-click`（不是"暂停"）；光标保持箭头，不跟着控制条一起藏；
- 坐标是 0..1 相对**视频画面**（去掉 letterbox 黑边），不是窗口：
  按 `video-params/aspect`（或用户选的 16:9 / 4:3 / 填充）算画面矩形再换算。
  直接除窗口宽高，在窗口比例和片源不一致时会把按钮点偏；
- 菜单里双击等于连点两次按钮，**不**当成"切全屏"（两端都拦了）；
- 方向键 / 回车 / Esc 转发给 `discnav`，壳自己的左右 seek、回车全屏让路。

菜单收起后恢复控制条，并把进度改记到实际播放的标题上（见下）。

### 有的菜单页只能用键盘

libbluray 的鼠标命中要求按钮有**选中态（selected）图形**：`_mouse_move()`
拿这个图形的矩形当热区，找不到就跳过该按钮。有的盘只给正片选择页
（底部条）定义了选中态，切到章节页后那一页的按钮区域只剩缩略图，
底部条上的 PLAY / SETUP 不在任何按钮矩形里。

表现：鼠标点底部条完全没反应。加 `--disc-menu-trace` 跑，libbluray 的
日志会写 `_user_input(): BD_VK_MOUSE_ACTIVATE outside of valid buttons`，
而键盘正常（走 `_user_input` 的光标分支），方向键 + 回车能正常操作。

这是盘里的数据决定的，壳这一层没法用坐标绕过去（VLC 等同样用
libbluray 的播放器也一样）。所以不做「点不动就瞎猜一个按钮」的兜底，
免得误触发别的按钮。

### 换页时的 `disc-menu-active` 抖动

一级菜单 → 二级菜单时，mpv 会**瞬间**报一次 `disc-menu-active=false`
再报 `true`（实测只隔 20～40 ms）。直接照着恢复控制条会闪一下，
所以两端都加了 700 ms 去抖：只有 `false` 稳住才算菜单真收起、进正片。

### 续播点记到哪个标题

菜单期的条目 id 是 `iso:<盘>:menu`，菜单 playlist 的时长只有几分钟；
正片是 `iso:<盘>:mpls<N>`，几十分钟。若一直用 `menu` 记进度，下次从菜单
重开时按菜单时长去比，续播点直接失效。

菜单收起后按 mpv 的 `duration` 去匹配 `BluRayProbe` 里的标题（±5 秒），
命中就把条目 id 换成那条正片的 `mpls<N>`，之后再记进度。

### 实测（2026-11-27）

测试盘：真实 1080p 原盘，HDMV 菜单（libbluray 日志 `BD-J Titles: 0`）。

- **Windows**（远程会话用计划任务跑在交互式桌面）：
  `--disc-menu` 后 `disc-menu-active=true`，截图是盘自带菜单
  （`CHOOSE VERSION: ORIGINAL VERSION / SHUSH CUT`）；`discnav down`
  高亮从 ORIGINAL 移到 SHUSH CUT；回车进二级菜单
  （`CHOOSE VERSION / PLAY / CHAPTERS / SETUP`）；按到 PLAY 回车后
  `disc-menu-active=false`、画面变正片、条目 id 从 `iso:hush2in1:menu`
  绑成 `iso:hush2in1:mpls1`（4907 s）。菜单期间晃鼠标
  `chrome=False`，控制条没冒出来。
- **macOS**（合成的 55 MB 精简盘，正片流是空文件）：
  `disc-menu-active=true`，截图确认菜单画面、方向键高亮移动、回车进下级菜单。
  菜单期间 `discMenu=true chrome=false`。
- **macOS + 真实 HDMV 盘**（I.Saw.The.Devil，1080p，`BD-J Titles: 0`）：
  `--disc-menu` 打开后画面是盘自己的 BLUE KINO 菜单，底下四个按钮由 mpv
  的 `discnav` 画出（截图确认）；菜单期 `discMenu=true chrome=false`。

### BD-J 盘：直接播正片

真实 UHD 盘（Mulholland Drive）的菜单是 BD-J（libbluray 日志
`BD-J Titles: 4`）：
```
This disc uses BD-J menus and a Java VM was found, but libbluray's BD-J
support is unusable. Playing without menus.
```
libbluray 需要配套的 `libbluray-j2se-<version>.jar` 才能跑 BD-J，
随包的构建没有带。此时 `--disc-menu` 只会停在菜单 title 的背景视频
（JANUS FILMS → STUDIOCANAL 片头），按钮永远不会出来；而壳按「菜单期间
收掉控制条」的规则把控制条藏了，鼠标移动又不许唤出——用户看到的就是
「开头闪一下控制条，之后黑屏、什么都点不到」。

所以两端都先判断 BD-J：是就**跳过菜单直接播最长正片**，标题在右侧面板切。
mac 看挂载后的 `BDMV/JAR/*.jar`；Windows 看 probe 日志的
`BD-J Titles: N` / `Playing without menus`。

要真正支持 BD-J 菜单，需要在 libbluray 里编出 BD-J jar 并保证运行时有
JVM，再让 mpv 渲染 BD-J 的 ARGB overlay；这比 HDMV 的 IG 复杂得多，
暂时不做。
- **两端的自绘菜单页**（`DiscMenuWindow`，2026-11-27 上午的实现）已被
  盘内菜单取代，不再有入口。

### 边界

- **BD-J 盘**：mpv 只在 HDMV 盘上跑菜单；BD-J 盘（要 JVM +
  libbluray-j2se jar）两端都直接播正片，没有菜单（见本节末）。
- **AACS / BD+ 加密盘**：libbluray 不解密，打不开。
- **AACS2（UHD）**：没有开源方案。
- **菜单里的音轨 / 字幕选择**：走 `discnav` 时由盘自己的菜单驱动，
  和播放页的 `track-list` 是两套；正片开始后以播放页为准。

## 5.5 DVD-Video 镜像（`.iso` 的另一种）

并不是所有 `.iso` 都是蓝光：DVD 盘常见 `VIDEO_TS/`，没有 `BDMV/`。
以前壳把 `.iso` 一律当蓝光，打开就会报「这张盘里没有 BDMV 目录」——
用户看到的是「点一个剧集 / 电影，却弹无法打开原盘」。

### 怎么认盘

两端都是先挂载 / 打开，再看根目录：

| | Windows | macOS |
| --- | --- | --- |
| 蓝光 | mpv 的 `--bluray-device` 能读出 title | 挂载后找 `BDMV/` |
| DVD | 蓝光读不到时，用 mpv `--dvd-device=<iso> dvdnav://` 试开一帧 | 挂载后找 `VIDEO_TS/` |

两边都找不到才报错：「这张盘里既没有 BDMV 也没有 VIDEO_TS」。

### Windows：走 mpv 的 dvdnav

Windows 的播放器是独立进程 `mpv.exe`（官方 GPL 构建，自带 libdvdnav），
所以 DVD 和蓝光是**同一套**菜单流程：

- `--dvd-device=<iso>` + URL `dvdnav://` + `--disc-menu`；
- 菜单画面 / 按钮由 mpv 画，`discnav up|down|left|right|select|prev`
  驱动，`disc-menu-active` 判断菜单在不在；
- 菜单期间壳的控制条 / 片名 / 右侧按钮收掉，窗口按钮保留；
- 菜单收起后（`disc-menu-active=false` 稳住 700 ms）恢复控制条。

DVD 没有 mpls 标题可绑定，条目 id 固定为 `iso:<盘名>:dvd`，
进度按它回写核心。

### macOS：LGPL 构建不能开 dvdnav，按 VOB 连播

mac 是进程内 libmpv，按 **LGPL** 编（`-Dgpl=false`）；mpv 的 DVD 导航要链
GPL 的 libdvdread / libdvdnav，`-Ddvdnav=enabled` 在非 GPL 构建里直接报
「Feature dvdnav cannot be enabled: the build is not GPL!」。为了不改
分发许可证，mac 这边不走 `dvdnav://`：

1. 读 `VTS_xx_0.IFO`：`vts_pgcit`（扇区）→ PGC 表 → 选**最长**的 PGC
   （DVD 的「播放全部」）；
2. 把每个 cell 的扇区范围落到对应的 `VTS_xx_N.VOB`（非菜单分卷），
   累加它的 BCD 时长，得到每卷该播多久；
3. 拼一份 mpv EDL（`路径,0,时长`）连播，总时长 = PGC 时长。

不能用「首尾 PTS 相减」算时长：DVD 的 PTS 在每个 cell 都会重置，
实测同一卷内首尾相减会得负数或 24 小时。IFO 里的 cell 表才是准的。

用户看到的效果：播放页正常出画、进度条是整碟时长（一碟连播），
没有 DVD 菜单 / 章节；换碟用右侧「选集」（每个 ISO 是一条）。

### 自检

- Windows：`--disc-menu <dvd.iso> --disc-shot <目录>`；
  DVD 的「使用须知」常要先放几十秒，加 `--disc-menu-delay 35` 再按菜单键；
  `--disc-menu-keys=select,select` 逐个交给 `discnav`。
- macOS：`DVPLAYER_DISC=<dvd.iso>`，`DVPLAYER_PLAY_FRAME=<png>` 取一帧；
  `DVPLAYER_DISC_START=<秒>` 验证跳转。

### 实测（2026-11-27）

测试盘：真实 DVD-Video 镜像（7.7 GB，`VIDEO_TS`，最长 PGC 2:25:03，
62 个 cell / 60 章）。

- Windows：`dvdnav://` 打开后 `disc-menu-active=true`，截图是盘自己的
  「お客様へ…」使用须知；`chrome=False`；`discnav select` 后进正片，
  `disc-menu-active=false`、`chrome=True`，截图是片头；
- macOS：IFO 解析出 7 卷 VOB / 8703 s，EDL 连播；跳到 10:09 取帧
  是正片画面，播放页时长 2:25:03；
- 回归：同一台 Windows 机器上蓝光盘的 `--disc-menu` → 菜单 → PLAY →
  `disc-menu-active=false` → 绑定 `mpls1` 仍正常。

### 边界

- **CSS 加密的 DVD**：mac 挂载后读到的 VOB 是加密的，播不出画面；
  Windows 的 mpv 没有 libdvdcss，同样播不了。需要先解密 / 抽流。
- **DVD 菜单 / 分集**：只有 Windows 有（dvdnav）；mac 一碟连播。
- `.mds` 是 DVD 的索引文件（配合 `.iso` 用），本身不播；
  媒体库里只有 `.iso` 会进库。

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
