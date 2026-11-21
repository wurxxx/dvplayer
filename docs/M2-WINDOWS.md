# M2 · Windows 客户端

Windows 壳是 WPF（`apps/windows/DvPlayer`），视频交给官方 mpv 子进程，浮层是
逐像素透明的独立窗口。播放页的产品规则和 macOS 共用，写在
[UI-DESIGN.md](UI-DESIGN.md) 的「播放页」一节；这份文档只记 Windows 侧的落点和
两端的差异。

## 1. 五项功能的落点

| 功能 | 代码 | 说明 |
| --- | --- | --- |
| 画面比例 | `Player/PlayerAspect.cs`、`Views/PlayWindow.xaml.cs` | `PlayerAspect` 与 macOS 的枚举一一对应，`ToMpv()` 给 `keepaspect` / `panscan` / `video-aspect-override` 三个值；比例写 `settings.json` 的 `videoAspect`。**适应窗口**另按 mpv 的 `video-params/aspect` 改窗口形状（竖屏短剧 → 竖窗口，不留黑边），全屏 / 最大化时不抢尺寸 |
| 定时关闭 | `Views/PlayWindow.xaml.cs` | `_sleepDeadline` / `_sleepAtEof`，`OnTick` 里的 `CheckSleep()`；到点先 toast 再关窗，进度照常回写 |
| 片头片尾 | `Services/SkipMarkers.cs` | `%LOCALAPPDATA%\dvplayer\skip-markers.json`，按剧名（电影按条目 id）存 `introEnd` / `outroStart`，和 macOS 同格式 |
| 弹幕 | `Player/Danmaku.cs` | 弹弹play v2 签名（`Base64(SHA256(AppId+Timestamp+Path+AppSecret))`）→ XML 解析 → 写 ASS → `sub-add` + `secondary-sid` |
| 在线字幕 | `Player/OpenSubtitles.cs` | OpenSubtitles REST v1：搜索 → `/downloads` 取临时链接 → 存缓存 → `sub-add select` |

配置项都在 `Services/AppSettings.cs`：`videoAspect`、`danmakuEnabled` /
`danmakuAppId` / `danmakuAppSecret`、`openSubtitlesApiKey` /
`openSubtitlesUsername` / `openSubtitlesPassword`、`subtitleLanguages`。

## 2. 和 macOS 的差异

- **菜单没有子菜单**：WPF 的 `DarkMenuItem` 模板没有 `Popup` / 箭头，所以
  「更多」里的「画面比例」「定时关闭」是**连开一层菜单**（点完第一层再弹第二层），
  不是 macOS 那种悬停子菜单。
- **弹幕轨按文件名认**：`sub-add` 在 JSON IPC 里不返回轨道 id，Windows 的
  `MpvIpc` 也没有命令回复，所以靠 `track-list` 推送，按
  `external-filename` 含 `DVPlayer-danmaku` 识别并排除出字幕菜单。
- **弹幕只挂第二字幕**：没有主字幕时把 `sid` 置 `no`；关闭弹幕时按加弹幕前
  记下的 `sid` 还原。
- **字幕搜索只下主字幕**：结果直接 `sub-add select`；弹幕还开着时再把
  `secondary-sid` 绑回去，两者同屏。
- **窄窗口只留一行**：窗口宽 < 700（竖屏短剧）时，`UpdateChromeLayout` 把静音 /
  音量 / 音轨 / 字幕 / 倍速 / 全屏收起来，只留传输 + 进度 + 「更多」；这些工具
  作为菜单项补进「更多」（音量 ±10、音轨… / 字幕… / 倍速… 连开一层）。
  窄窗左右边距和两个时间标签同时收窄，进度条才留得下。
- **音频输出 / HDR 直通**：「更多 → 音频输出」列出 mpv `audio-device-list` 的
  设备（当前项打勾），加「音频直通」「HDR 直通」两个开关：直通写
  `audio-spdif=ac3,eac3,dts,dts-hd,truehd`，HDR 写 `target-colorspace-hint`。
  三项都落 `settings.json`（`audioPassthrough` / `hdrPassthrough` /
  `audioDevice`），`MpvProcess` 起 mpv 时当命令行参数带上，换集重启也保持；
  播放页「更多」的标题会带当前设备 / 直通 / HDR 状态。
- **动态范围徽标读实际输出**：`current-tracks/video` 的
  `dolby-vision-profile` + `video-params` 的 `transfer` → `DV P5/P7/P8`、
  `HDR10`、`HLG`、`SDR`，服务端刮削的 `ColorRange` 只在 mpv 还没回报时兜底。
  P7 的 FEL/MEL 仍不判（要侧路 ffmpeg + dovi_tool，M0 验证壳里有）。
- **本地文件夹源**：「服务器」页 → 添加 → 类型「本地文件夹」→ 选目录 →
  目录里的视频 / ISO 变成媒体库条目（卡片墙、详情、选集、继续观看全部统一，
  见 `LOCAL-SOURCE.md`）。核心按 `Season 01` / `S01E02` 分季分集，`playSource`
  给绝对路径；ISO 条目 `disc=true`，界面再读标题。
- **蓝光原盘**：ISO 条目的标题列表来自 `mpv.com` 打开盘时 libbluray 打的
  `title: N (时长) (xxxxx.mpls)`，不自己挂 ISO；播放用
  `--bluray-device=<iso>` + `bd://mpls/<n>`。进度回写核心（本地源）。
  自检：`--play-iso` / `--play-iso-title` / `--disc-list` / `--disc-shot`。
- **记录页「通用」的收藏行**：继续观看下面接一行「视频收藏」（168×252 竖卡 +
  左右箭头，空时给一句提示），和 macOS 的通用页一致。三个分段面板的显隐统一走
  `ApplyTabVisibility()`：收藏是异步拉的，晚到时之前会直接把「收藏」整块设成可见，
  结果竖版海报盖在「继续观看」那一行上（像是记录串了图）。
- **记录页的卡片墙**：「观看」也是 `Controls/PosterGrid`（`CardRatio="1.7778"`
  = 16:9 横卡、`MinCardWidth="220"`），不再用固定 248 宽的 `WrapPanel`；
  「收藏」本来就是同一组件。`PosterGrid` 新增 `CardRatio` / `MinCardWidth`
  两个依赖属性，列数与卡片高度都由它们算，窗口变宽铺满、不留右侧空白。
  外层 `ScrollViewer` 里套一层 `StackPanel`，网格才能拿到视口宽度。
- **进度条三层**：`Views/PlayWindow.xaml` 里 `SeekHost` 垫三条 `Border`
  （未观看 `#3DFFFFFF` / 已缓冲 `#A6FFFFFF` / 已观看 `AccentBrush`），上面盖
  只画滑块的 `SeekBarHit` Slider；`UpdateSeekBars()` 按 `demuxer-cache-time`
  和当前进度算像素宽度。`demuxer-cache-time` 是绝对时间戳（实测缓存满时约等于
  片长：96.7 vs 96）。
- **缓冲大小可配**：设置 → 播放 →「缓冲大小」，`AppSettings.BufferSizeMb`
  默认 512，可选 256 / 512 / 1024 / 2048 / 4096；`MpvProcess` 映射成
  `--demuxer-max-bytes`（回看缓冲取一半），起播日志带 `buffer=<MB>MiB`。
  `DVPLAYER_BUFFER_MB` 可临时覆盖，自检时压到 8 才能看到「未缓冲」那一段。
- **没有独立的字幕搜索面板**：受控环境里不方便做 380 宽的右侧面板，
  「搜索字幕…」在「更多」里就地弹出结果菜单（语言 + 发行名 + 下载数），
  点一条即下载并选中。

## 3. 远程自检

Windows 主机在 `D:\dvplayer`，没有 `.git`，改完用 zip + scp 覆盖
`apps\windows`，再 `dotnet build -c Release`。播放相关的自检走两个参数：

```
DvPlayer.exe --play <itemId> --play-series <剧容器 id> \
  --play-check D:\dvplayer\shots\feat \
  --play-features aspect:fill,mark:intro:8,mark:outro:16,danmaku,subtitle,menu,skipoutro,sleep:6 \
  --play-start 0
```

- `--play-start 0`：强制从头放，不接续播记录。
- `mark:intro:<秒>` / `mark:outro:<秒>`：**开窗前**写进 `skip-markers.json`，
  这样起播才走得到片头跳过。
- `--play-features` 的项：`aspect:<fit|fill|stretch|16:9|4:3>`、`sleep:<秒>`、
  `danmaku`（离线解析 + ASS 生成自检）、`subtitle`（搜索 + 下载整轮）、
  `menu`（截「更多」菜单到 `play-more.png`）、`overlay`（垫黑截浮层，
  进度条 / 控制条看 `play-overlay.png`）、`skipoutro`。
- `audioout` / `audiotoggle`：打开音频输出菜单、切一次直通 / HDR 并写日志（无桌面自检用）。
- `frame`：让 mpv 把当前解码帧写到 `<目录>\video-frame.png`，锁屏 / 无桌面也能验真实画面。
- `--screenshot <目录> settings --settings-tab play`：设置页直接停在「播放」分组，
  核对缓冲大小这类项。
- 结果全部写 `%LOCALAPPDATA%\dvplayer\player.log`，状态行类似
  `features state aspect=fill intro=8 outro=16 sleep=0:03 danmaku=... outroPrompt=Visible pos=16`。

### SSH 会话里的画面

远程 SSH 会话拿不到 D3D 交换链（mpv 报 `Failed to create swapchain … 0x887a0022`），
时间轴不会走，位置类的功能就验不了。设 `DVPLAYER_MPV_HEADLESS=1` 让 mpv 用
`--vo=null --ao=null`，不输出画面但照常按实时推进 `time-pos`。
**这个开关只给自检用**，正常启动不要设。

弹幕 / 字幕的真实接口需要凭据（弹弹play AppId + AppSecret、OpenSubtitles API Key）。
离线自检用 `DVPLAYER_DANDANPLAY_BASE` / `DVPLAYER_OPENSUBTITLES_BASE` 指向本地
假服务器（仓库里 `scripts/windows/fake-player-api.ps1`，拷到主机上跑），可以完整验证签名之外的每条链路：
搜索、下载、`sub-add`、`secondary-sid` 绑定、切集重挂。

## 4. 踩过的坑

- `sub-add` 的 IPC 回复是 `null`，拿不到轨道 id；只能等 `observe_property`
  推 `track-list`，再从 `external-filename` 里认。
- 弹幕 ASS 的 `{\an8\pos(...)}` 写在 C# 内插字符串里要小心：`{{` 是字面量花括号，
  再拼 `\` 会被当成表达式；用字符串拼接生成标签最稳。
- 定时关闭和「本集结束后」是两条路：前者按墙钟计时（暂停也算），后者在
  `eof-reached` 里直接关窗，不走「接下一集」。
- 片尾按钮只在 `outroStart ≤ pos < duration - 1` 区间显示，退回去会收起来；
  点了是把 `time-pos` 推到 `duration - 0.4`，让 mpv 走正常 EOF，不自己写下一集逻辑。
