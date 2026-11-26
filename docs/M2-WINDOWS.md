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
| 弹幕 | `Player/Danmaku.cs` | 弹弹play v2 签名（`Base64(SHA256(AppId+Timestamp+Path+AppSecret))`）→ JSON / XML 解析 → 写 ASS → `sub-add` + `secondary-sid`；电影没有集号时按片名找 `type == "movie"` 的条目 |
| 在线字幕 | `Player/OpenSubtitles.cs` | OpenSubtitles REST v1：搜索 → `/downloads` 取临时链接 → 存缓存 → `sub-add select` |
| Trakt | `Player/TraktClient.cs`、`Views/SettingsPage.xaml` | 设备码登录；token 存 `settings.json` 的 `traktAccessToken` / `traktRefreshToken` / `traktExpiresAt`（DPAPI 密封）；scrobble 挂在 `time-pos` / `pause` / EOF / 关窗上，按顺序串行发送；匹配优先用 `MediaDetailDto.TmdbId` / `ImdbId`（Emby / Jellyfin 的 `ProviderIds`），没有才回落标题 + 年份；库页直接起播的电影用条目标题 + 详情元数据兜底；详情页「Trakt」菜单做评分 / 收藏 / 待看。打包时内置 Client ID，设置页只剩连接 / 开关 |

配置项都在 `Services/AppSettings.cs`：`videoAspect`、`danmakuEnabled`、
`openSubtitlesApiKey` / `openSubtitlesUsername` / `openSubtitlesPassword`、
`subtitleLanguages`、`traktEnabled` / `traktClientId` / `traktClientSecret`。弹幕凭据不在设置里：打包时由
`packaging/build-release.ps1` 从本地密钥文件读出来，以程序集元数据写进 exe
（详见 [SECRETS.md](SECRETS.md)）。

## 2. 播放后端：子进程（默认）/ 进程内 libmpv

默认是子进程：`mpv\mpv.exe --wid` + 命名管道 IPC。打包时用
`-Backend libmpv -MpvDir <shinchiro dev 包解压目录>` 可以换成进程内的
`libmpv-2.dll`（C API，仍然是 `wid`，不是 render API），运行时再设
`DVPLAYER_MPV_BACKEND=libmpv` 才会走这条路。

体积上**两者几乎一样**：官方 dev 包的 `libmpv-2.dll` 也是静态链接（116 MB，
和 `mpv.exe` 相同），实测 zip 只差 2.9 MB。默认保持子进程（崩溃隔离）。DV P7
FEL 在进程内后端已真机验证通过，细节和实测数据见
[ADR-0012](adr/0012-windows-libmpv-backend.md)。

日志：mpv 自己的日志两个后端都写到 `%LOCALAPPDATA%\dvplayer\mpv.log`
（进程内后端靠 `log-file`，子进程靠重定向 stderr）；进程内后端还有
`mpv-shell.log`，放壳侧的初始化 / 选项错误。

## 3. 和 macOS 的差异

- **菜单没有子菜单**：WPF 的 `DarkMenuItem` 模板没有 `Popup` / 箭头，所以
  「更多」里的「画面比例」「定时关闭」是**连开一层菜单**（点完第一层再弹第二层），
  不是 macOS 那种悬停子菜单。Trakt 的评分也是这种两层菜单（先点「评分」再选分数）。
- **Trakt 的 token 放在配置文件里**：macOS 单独存 `trakt.json`（0600），Windows
  放进 `settings.json` 的 `traktAccessToken` / `traktRefreshToken` / `traktExpiresAt`，
  和其它凭据一样在存盘时走 DPAPI 密封。设置页的「Trakt」分段用设备码登录，
  不需要在 App 里输 Trakt 密码。
- **启动检查更新 / 「关于」页**：应用启动后在后台查 GitHub Releases 的 latest
  （15 秒超时；成功结果按当前版本缓存 10 分钟，失败 / 断网不缓存）；有新版就在
  左下角版本号下面加一行「可更新 vX」，点它进「设置 → 关于」。「关于」页显示
  应用 / 共享核心版本、完整项目地址（点开系统浏览器）和更新状态，发现新版本时
  按钮变成「下载更新」。所有行共用一个 `Grid`（110 / * / Auto 三列），值列不会
  一行一个缩进；「已连接」这类能从侧栏状态点看出来的信息不重复放。
- **打开 / 切集遮罩**：`PlayWindow` 的 `OpeningCover` 一直是不透明黑，首帧判定看
  「播放位置真的推进」（`time-pos > 起播点 + 0.5`，片头跳过后从跳到的位置算），
  慢网络下 `time-pos` 停在续播点不会误收黑底；期间文案一直是「正在打开…」+ 转圈。
  **打开阶段顶栏保留**（片名 + 右上角最小化 / 最大化 / 关闭），黑底上按住任意位置
  都能拖窗口，单击只是选中窗口、不切暂停；底部控制条和截图 / 选集仍等首帧。
  打开阶段控制条是藏着的，但鼠标指针照常显示箭头（贴近四边换成改大小光标），
  不会因为 `_chromeVisible=false` 被设成 `Cursors.None`。
  打开阶段在黑底上**双击是最大化 / 还原**，不是全屏：全屏会把顶栏和右上角三个
  按钮一起收掉，窗口也没法拖，控制条又藏着，指针会跟着消失；最大化符合 Windows
  习惯，也保住了这几个操作入口。全屏里切集（`_ready=false`）同样不再把指针设成
  `Cursors.None`，`AnimateChrome` / `SetChromeOpacity` 淡出时也不会。
  **播放中**卡住（mpv `paused-for-cache`，停超过 400ms）则在画面中间浮一个
  「正在缓冲…」小胶囊，画面、控制条都不盖掉。回归：`--play <id> --play-cover-shot
  <目录>`（配合 `DVPLAYER_OPENING_HOLD=1` 假装首帧不来，截 1.5 / 12 / 31 秒三张）。
- **进来就定位到续播集**：详情页算出的续播集（进度 1%–99%）除了决定播放目标，
  还让 `EpisodeTile.IsActive` 亮起（集卡强调色描边、集号变色；进度条往里缩 4px、
  高亮集改成白色，免得和描边连成一条；≥99.5% 算看完，不画进度条、也不续播），
  「播放」按钮写成
  `播放 第 20 集 01:47`；`AutoScrollToResume()` 在布局完成后把该集滚到选集行
  最左边，只做一次（补页 / 刷新不会把用户自己滚的位置拽回去）。续播集落在后面的
  分页时，`AppendEpisodesAsync` 拿到那页后再定位。回归：`--series <剧集 id>
  --series-wait 30`，`series.png` 里第一张卡是描边的 E20、按钮带「第 20 集」。
- **集数多时的快捷选集**：一季超过 30 集，选集标题下面多一排 `1-30 / 31-60 …`
  段按钮；点一下把横向选集行滚到那一段的第 1 集（还没拉到页先补，状态栏写
  「正在加载第 31-60 集…」），被点的段高亮。段按钮**放不下就换行**（`WrapPanel`），
  不用横向滚动——这行没有箭头，滚到后面就点不回前面的段了（827 集时 28 段铺 3 行）。
  换行后每个段按钮留了 8 px 下边距，两排之间不会贴在一起。
  切季会清掉高亮；没点过时高亮跟着续播点所在的那段。回归：`--series <id>
  --series-scroll 520 --range 301`，`series-range.png` 里集行从 E301 开始、
  `301-330` 高亮。
- **播放打开失败**：取地址失败或 mpv 启动失败时窗口不关，黑底上留「播放失败 +
  原因」和「重试 / 关闭」。重试分两种：还是占位源（手上没有地址）就重新向核心
  要一次播放地址，已经有地址就按原参数重开 mpv；重试时才发现是原盘，会关掉占位窗
  换成原盘窗口。回归：`--play bogus --play-fail-shot <目录>`，日志里应有
  `play open failed` / `play retry`，截图为窗内错误面板（不关窗）。
- **Emby 进度上报走播放会话**：`Sessions/Playing`（注册会话）→ 每 10 秒
  `Sessions/Playing/Progress` → 关窗 / 播完 `Sessions/Playing/Stopped`。
  Monta HD 的反代对 `/Users/{uid}/Items/{id}/UserData` 返回 404，而且只发
  `Progress` 不落盘；`Stopped` 之后 `UserData.PlaybackPositionTicks` 才会更新。
  关窗时等一下这次上报（`wait: true`），否则进程退出会把后台任务带走。
  回归：播放 80 秒后关窗，`player.log` 出现 `report ok ... stopped=True`，
  服务器该条目的位置同步到 ~73 秒。
- **服务器图标**：服务器卡片和侧栏名字左边都显示源自己的图标。飞牛用官方牛头
  （品牌蓝底 + 白色剪影），Emby 用官方 app 图标（绿菱形 + 白三角），Jellyfin 用
  官方标志（紫 → 青三角），本地 / SMB / NFS / WebDAV 各是文件夹 / 共享 / 硬盘 / 云。
  Emby / Jellyfin 不再自己画三角，直接取官方素材。图标由
  `scripts/make-source-icons.py` 生成到 `Assets/sources/`（macOS 打包用仓库里同一份
  `assets/sources/`）。侧栏的状态点从名字前面挪到图标右下角：连上绿点、失败红点。
- **Emby / Jellyfin 的报错按源类型显示**：两者共用同一份适配器，以前 Jellyfin
  源出错也写「Emby：」。现在 `EmbySource` 带一个 `label`，Jellyfin 显示
  「Jellyfin：…」。回归：加一个 Jellyfin 源、用户名密码都留空，状态行是
  「连接失败：Jellyfin：用户名或 API Key 至少填一个」。
- **网络服务器代理**：服务器表单新增「HTTP 代理（可选）」，只对飞牛 / Emby /
  Jellyfin 显示，落 `settings.json` 的 `proxy`（空 = 直连，允许只写
  `127.0.0.1:7890`）。这个源的接口请求（核心 `http_client`）、海报下载
  （`PosterLoader` 按代理缓存 `HttpClient`）和播放（mpv `--http-proxy`）全走它；
  已配置过的老源会原样带过来。
- **源首页每行默认「添加时间」倒序**：首页每个库的预览显式传
  `sort=added&descending=true`（飞牛 → `create_time DESC`，Emby →
  `DateCreated` 降序），和点进库里的默认排序一致。以前不传排序，各家服务器用
  自己的默认值（飞牛的默认是入库倒序，别的版本 / 别的源不一定），
  nas 的库看起来就和飞牛不一样。
- **从详情页返回保留列表状态**：`LibrariesPage.KeepAlive = true`，GoBack 回来时沿用
  同一个页面实例，网格的类别 / 排序 / 风格 / 分页和滚动位置都还在；`OnLoaded`
  发现是同一份连接数据时只调 `RefreshBrowseAsync()` 重拉已加载的页（不重置筛选、
  不跳回顶部），别整页重建。
- **详情页链接**：链接区固定先「豆瓣」（按片名搜索），`MediaDetailDto.TmdbId` /
  `ImdbId` 有值时再加「TMDB」（`themoviedb.org/{movie|tv}/{id}`）和「IMDb」
  （`imdb.com/title/{id}/`）；飞牛这类详情没有 id 的源只显示豆瓣。
- **详情页「存储位置」**：`MediaInfo.Path` 放在媒体信息之后；电影 / 单集显示完整
  文件路径，剧集 / 季只显示目录。飞牛取 `/stream` 的 `file_stream.path`，Emby 取
  `PlaybackInfo` 的 `Path`（退回条目的 `Path`），本地源直接给文件路径。
- **字幕菜单只写「语言 · 标题」**：`TrackPrefs.SubtitleLabel` 把 `chi` / `eng` 这类
  语言码翻成中文名，`HDMV PGS_SUBTITLE`、`subrip` 这类容器 / 编码标题和纯序号
  （`1`、`2`）当作没有标题；只有语言就只显示语言，两个都没有用「字幕 N」，
  重名再追加序号（`中文 1`）。mpv 只给容器标题时，按轨序从服务器的
  `MediaInfo.Subtitles` 补语言（原盘 / remux 的 `track-list` 常常 `lang` 为空）。
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
  P7 再按 RPU 判 FEL / MEL：`PlayWindow.ProbeDolbyVisionIfNeeded` 在
  `_dvProfile == 7` 时后台调核心 `dv_probe_dovi`（只读码流前缀 8 MB，
  解析 `disable_residual_flag`），按条目缓存，徽标拼成 `DV P7 (FEL)` /
  `DV P7 (MEL)`；原盘 `bd://` 与探测失败都退回 `DV P7`。
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

## 4. 远程自检

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
  `menu`（截「更多」菜单到 `play-more.png`）、`submenu`（截字幕菜单到
  `play-submenu.png`，验证「语言 · 标题」文案）、`overlay`（垫黑截浮层，
  进度条 / 控制条看 `play-overlay.png`）、`skipoutro`。
- `audioout` / `audiotoggle`：打开音频输出菜单、切一次直通 / HDR 并写日志（无桌面自检用）。
- `frame`：让 mpv 把当前解码帧写到 `<目录>\video-frame.png`，锁屏 / 无桌面也能验真实画面。
- `--screenshot <目录> settings --settings-tab play`：设置页直接停在「播放」分组，
  核对缓冲大小这类项。
- `--play-cover-shot <目录>`：抓打开遮罩。设 `DVPLAYER_OPENING_HOLD=1`（假装首帧
  不来）时，1.5 / 12 / 31 秒三张都必须是纯黑 + 片名 +「正在打开…」+ 转圈，不能透出桌面。
- `DVPLAYER_BUFFERING_HOLD=1`：出画后强制显示中间的「正在缓冲…」小胶囊（验证播放中
  卡顿时只浮状态、不盖画面）。
- 结果全部写 `%LOCALAPPDATA%\dvplayer\player.log`，状态行类似
  `features state aspect=fill intro=8 outro=16 sleep=0:03 danmaku=... outroPrompt=Visible pos=16`。

### SSH 会话里的画面

远程 SSH 会话拿不到 D3D 交换链（mpv 报 `Failed to create swapchain … 0x887a0022`），
时间轴不会走，位置类的功能就验不了。设 `DVPLAYER_MPV_HEADLESS=1` 让 mpv 用
`--vo=null --ao=null`，不输出画面但照常按实时推进 `time-pos`。
**这个开关只给自检用**，正常启动不要设。

弹幕 / 字幕的真实接口需要凭据（弹弹play AppId + AppSecret、OpenSubtitles API Key）。
弹幕凭据是内置的：打包时写进 exe 的程序集元数据，用户不用填；设置页只有默认开
弹幕的开关。在线字幕仍在「弹幕 / 字幕」分组里自己填（API Key / 密码用
`PasswordBox`）：边输入边写 `settings.json`，卡片底部一行小字显示
「已配置 / 还没填全」。没配时「搜索字幕」只给一句提示，不联网。
离线自检用 `DVPLAYER_DANDANPLAY_BASE` / `DVPLAYER_OPENSUBTITLES_BASE` 指向本地
假服务器（仓库里 `scripts/windows/fake-player-api.ps1`，拷到主机上跑），可以完整验证签名之外的每条链路：
搜索、下载、`sub-add`、`secondary-sid` 绑定、切集重挂。

## 5. 踩过的坑

- `sub-add` 的 IPC 回复是 `null`，拿不到轨道 id；只能等 `observe_property`
  推 `track-list`，再从 `external-filename` 里认。
- 弹幕 ASS 的 `{\an8\pos(...)}` 写在 C# 内插字符串里要小心：`{{` 是字面量花括号，
  再拼 `\` 会被当成表达式；用字符串拼接生成标签最稳。
- 定时关闭和「本集结束后」是两条路：前者按墙钟计时（暂停也算），后者在
  `eof-reached` 里直接关窗，不走「接下一集」。
- 片尾按钮只在 `outroStart ≤ pos < duration - 1` 区间显示，退回去会收起来；
  点了是把 `time-pos` 推到 `duration - 0.4`，让 mpv 走正常 EOF，不自己写下一集逻辑。
