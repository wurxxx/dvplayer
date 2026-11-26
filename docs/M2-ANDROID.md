# M2 · Android / TV 客户端

> 状态：方案定稿（2026-11-25）；A0 环境与 A2 骨架已落地（2026-11-26），
> 两个 APK 可构建、native 自检库通过 16KB 校验，并在 Android 33 x86_64
> 模拟器上装起、显示 native 版本；libmpv（LGPL）+ FFmpeg + libplacebo +
> libass + libbluray 的 NDK 构建链已跑通；A1 的设备能力采集（`DeviceProfile`）
> 已落地；A4 的最小出画已在两台真机上跑通（Surface + EGL + mpv render API，
> 720p H.264 走 `mediacodec-copy`；Android 9 的 MT6765 与 Android 16 的
> 骁龙 8 Gen 1 都验过）；A5 的 HDR 通路已接通并用法生成的**真 PQ / HLG** 片源
> 验过（BT.2020_PQ / BT2020_HLG 的 EGL colorspace + buffer dataspace，
> SurfaceFlinger 侧已是 `BT2020_PQ` / `BT2020_HLG` 且 HWC 直出）；PQ 的静态
> HDR 元数据（SMPTE2086 / CTA861_3）经 EGL surface 扩展进 buffer layer；24p → 120Hz
> 的整数倍帧率匹配也已验证；HDR10+（ST2094-40）已用注入样片验到 mpv 软解能读，
> 但平台无公开写入接口，动态元数据归 Media3 内核——`:player-media3` 已用
> ExoPlayer 与 MediaCodec 探针验通（SF 层 `hdr metadata types=4`）。
> 双壳 + 双内核，手机先行。决策见 [ADR-0013](adr/0013-android-two-shells.md)（双壳）、
> [ADR-0014](adr/0014-android-dual-engine.md)（双内核）、
> [ADR-0015](adr/0015-android-vfs.md)（存储）、
> [ADR-0016](adr/0016-android-player-native.md)（播放器 native 层）。

## 1. 范围

和桌面一致的产品能力：多源接入（飞牛 / Emby / Jellyfin + 本地 / SMB / NFS /
WebDAV）、聚合搜索、续播、蓝光原盘、PGS / ASS / SRT、HDR / DV、音频直通。

Android 的差异要如实呈现，不假装支持：

| 项 | Android 的边界 |
| --- | --- |
| 解码 | 取决于设备 `MediaCodec`，不做视频软解 |
| DV P7 | 公共 API 拿不到增强层，只播 BL |
| DV P5 | 无 DV 解码器时走 mpv 整形（输出 SDR） |
| 原盘 | 只支持未加密盘；AACS / AACS2 明确拒绝 |
| 直通 | 按设备 `AudioDeviceInfo.getEncodings()`，TrueHD / DTS-HD 多数盒子没有 |
| 蓝光菜单 | 不跑 BD-J，用标题列表代替（与桌面一致） |

## 2. 模块

```
apps/android/
├── app-phone/       applicationId com.dvplayer.app         手机入口、权限、PiP
├── app-tv/          applicationId com.dvplayer.app.tv      LEANBACK_LAUNCHER、banner
├── ui-phone/        手机屏幕 + 导航（Material3）
├── ui-tv/           TV 屏幕 + 导航（androidx.tv:tv-material）
├── feature/         共享 ViewModel / UiState / 交互逻辑
├── player/          引擎契约、路由策略、音频焦点、MediaSession、字幕样式、诊断
├── player-media3/   Media3 适配
├── player-mpv/      libmpv JNI + EGL 渲染线程 + 属性桥
├── player-disc/     libbluray JNI（title / 章节），与 mpv 共用同一份 libbluray
├── data/            仓库层、hub 生命周期、源配置、图片加载
├── design/          颜色 / 字号 / 间距 / 图标 / 字符串
├── core/            JNI 声明 + camelCase 模型（kotlinx.serialization）
└── build-logic/     约定插件（Compose、JDK 17、minSdk、R8、jniLibs、16KB、ABI splits）
```

依赖方向：

```
app-phone ─┐
           ├→ ui-phone / ui-tv → feature → player ─┬→ player-media3
app-tv ────┘                          │            ├→ player-mpv
                                      │            └→ player-disc
                                      └→ data / design → core → libdvplayer_media.so
```

共享状态、不共享屏幕布局：`tv-material` 与 `material3` 的组件 API 不是一套，
ViewModel 只写一份，屏幕各写一份。

## 3. 双内核

### 3.1 契约

```kotlin
interface PlaybackEngine {
    val events: Flow<EngineEvent>              // 低频：轨道、错误、结束
    val capabilities: EngineCapabilities
    fun attach(surface: Surface, width: Int, height: Int)
    fun open(media: EngineMedia, startMs: Long)
    fun play(); fun pause()
    fun seekTo(ms: Long, exact: Boolean)
    fun setSpeed(speed: Float)
    fun setTrack(kind: TrackKind, id: String?)
    fun setSubtitleStyle(style: SubtitleStyle)
    fun snapshot(): EngineSnapshot             // 位置 / 缓冲，4Hz 轮询
    fun release()
}
```

四条不能省的约定：

- **Surface 归属**：壳持有 `SurfaceView`；Media3 用 `setVideoSurface`，
  mpv 用 `ANativeWindow_fromSurface` + EGL。
- **字幕归属**：`subtitleMode = ENGINE | CUES`。ENGINE 时壳关掉自己的字幕层，
  样式映射到 `sub-scale` / `sub-pos` / `sub-ass-override`。
- **轨道匹配**：切换按「类型 + 语言 + 编码 + 序号」回选，不按 id。
- **错误码**：带 `retryableWithOtherEngine`，自动回退只认它。

上移到 `:player`、两个引擎共用的：音频焦点、MediaSession / 通知、PiP、进度回写、
字幕样式映射、诊断采集。Media3 自带的焦点管理要关掉，避免双重处理。

### 3.2 默认与例外

默认 **mpv**。三条硬例外走 Media3：

1. 片源是 HDR10 / HDR10+ / DV 且设备支持 HDR；
2. 需要 TrueHD / DTS-HD / Atmos 直通，且 mpv 实测不支持；
3. `DeviceProfile` 判定性能不达标（4K 掉帧 / 盒子无 HDR 合成）。

运行时失败自动换另一个引擎重试一次，不循环。用户手动指定优先。

### 3.3 切换

不是无缝，是「停一个、按当前位置重开」，约 1 秒空档；seek 用精确模式，
从最近关键帧起。UI 明确显示「正在切换内核…」。

### 3.4 设备能力

`DeviceProfile` 探测一次、按系统版本缓存、可导出：

| 字段 | 来源 |
| --- | --- |
| HDR 类型（HDR10 / HDR10+ / HLG / DV） | `Display.getHdrCapabilities()` |
| DV profile | `MediaCodecList` 查 `video/dolby-vision`，按 `Format` 验证 |
| 直通编码 | `AudioDeviceInfo.getEncodings()` |
| 4K 解码能力 | `MediaCodecInfo.isFormatSupported(Format)`（Main10 / 3840×2160 / 60fps） |
| tunneling / HDR 合成器 | `MediaCodecInfo.isTunnelingSupported` + `Display` |
| 机型档 | 型号 + 系统版本白名单（spike 踩过的坑） |

能力探测页从调试工具变成发布必需项：默认引擎的路由全靠它。

## 4. 格式矩阵

逐格结果在 [DECODE.md](DECODE.md) §8（当前是规划口径，A1 spike 后回填）。摘要：

- **mpv**：原盘、ASS（含内嵌字体）、P5 整形、DTS / TrueHD 软解；HDR 输出待验。
- **Media3**：HDR 直通、HDR10+ 元数据、tunneling、平台直通；ASS 只有基础文本。
- **两套都没有**：DV P7 增强层、AACS / AACS2、3D MVC、BD-J 菜单。

## 5. 原盘

见 [BLU-RAY.md](BLU-RAY.md) §5.3。要点：

- 本地 / SAF 的 ISO、BDMV 走 mpv `--bluray-device`；
- `:player-disc` 用 libbluray 1.5 列 title / 章节（含 HDR / DV 标记与章节名）；
- NAS 原盘 v1 先下载到缓存，边读边播排 M2-B 之后；
- Media3 不参与原盘。

## 6. 存储

```
:feature → :data → Vfs（list / stat / open / seek）
                    ├── SmbVfs    smbj（SMB2/3）
                    ├── NfsVfs    libnfs（JNI，AUTH_SYS）
                    └── DavVfs    OkHttp（PROPFIND + Range）
                          │  目录树 JSON
                          ▼
        core/media vfs 源适配器（复用 SxxExx / 第 N 集 认集号）
                          ▼
        player-media3 DataSource / player-mpv 自定义 stream
```

核心需要补的三件事：

| 项 | 原因 |
| --- | --- |
| `dv_hub_replace(id, config)` | VFS 重扫；现在没有 remove / replace，只能重建 hub |
| `dv_probe_dovi_bytes(ptr, len)` | VFS / SAF 拿不到路径，判定逻辑仍只在 `core/dovi` |
| `sources/vfs.rs` + 共享扫描函数 | 复用 `local.rs` 的目录树与集号解析 |

## 7. 里程碑

单人粗估；VFS 与 UI 可与引擎工作并行。

| # | 阶段 | 内容 | 验收 |
| --- | --- | --- | --- |
| A0 | 环境与 libmpv 构建链 | JDK 17 / SDK 36 / NDK r28 / meson；libmpv（LGPL）+ FFmpeg + libplacebo + libass + libbluray；CI 缓存；16KB 校验 | `libmpv.so` 能加载，最小 demo 出画 |
| A1 | 可行性 spike（门禁） | 4K HDR10 输出与掉帧、DV P8、DV P5、DTS-HD / TrueHD 直通、24p、后台 / PiP | 六项有结论，写进 `DeviceProfile` 与例外表 |
| A2 | 骨架 | Gradle 约定、两个 app + 两份 manifest、`:design` 令牌、`:core` 加载 native | 两个 APK 能装能起，TV 出现在 leanback 桌面 |
| A3 | 数据层 | `core/media-jni` + 首包 12 个函数、模型、hub 生命周期、连接页、库 / 详情 / 记录、图片 | 飞牛全链路可浏览，记录有续播点 |
| A4 | 引擎契约 + mpv | 接口、EGL 渲染线程、属性桥、轨道 / 章节 / 字幕 / 倍速、焦点 / 会话 / 通知 / 进度 | SDR 1080p / 4K 播放、切轨、ASS、后台、续播 |
| A5 | HDR 输出 | dataspace、`colorMode`、`preferredDisplayModeId`、帧率匹配 | HDR10 真进 HDR；不达标时显示「SDR 映射」 |
| A6 | Media3 适配 | 第二引擎、FFmpeg 音频扩展、PGS / SRT、HDR 直通、tunneling | 同片源两个引擎都能播，能力表一致 |
| A7 | 切换与回退 | `DeviceProfile` 页与导出、路由、手动重播、自动重试、设置页 | HDR 自动走 Media3、P5 自动走 mpv、切换不丢位置 |
| A8 | 原盘 | libbluray 进 mpv、`player-disc` 列 title / 章节、ISO / BDMV 入口、NAS 下载缓存、加密盘提示 | 本地 ISO 选集播放；AACS 盘给出可读原因 |
| A9 | VFS | `Vfs` + WebDAV → SMB → NFS、核心虚拟源、`dv_hub_replace`、`dv_probe_dovi_bytes` | 三种协议浏览 / 起播 / seek / 续播 |
| A10 | 手机特性 | PiP、通知与后台、下载（先存应用私有目录） | PiP 可切、通知可控、离线可播 |
| A11 | TV 冒烟（门禁） | TV 壳接 `:feature` + 两个引擎 + 一个播放页 | 遥控器完成选片 → 起播 → 暂停 → 切轨 → 退出 |

**A1 与 A11 是门禁**：A1 决定例外表，A11 不通过就不开 M2-B。

A0 / A2 已落地（2026-11-26）：

- `scripts/android/{env,build-native,check-apk}.sh`：JDK 17 / SDK 36 / NDK r28 环境，
  `cargo ndk` 出 `arm64-v8a`（x86_64 只在模拟器调试时按需编），
  `zipalign -c -P 16` 校验；
- `apps/android`：AGP 8.13.2 / Gradle 8.13 / Kotlin 2.2.21，约定插件在 `build-logic`；
- Compose BOM 钉在 **2026.06.01**（ui 1.11.x，minCompileSdk 35）。2026.11.01 的
  Compose 1.13 要求 compileSdk 37 / AGP 9.1，和当前基线冲突；
- `core/media-jni` 的 JNI 自检桩 + 两个 APK 的 16KB 校验通过。

libmpv 构建链（A0 的另一半，2026-11-26）：

- `scripts/android/build-mpv.sh`：依赖全静态，只产一个 `libmpv.so`；FFmpeg
  `n9.0.2`（`--disable-gpl --disable-version3`，`-fPIC`）、libplacebo `v7.387.0`
  （`vulkan=disabled`，只留 OpenGL）、libass `0.17.4`、libbluray `1.5.0` +
  libudfread `1.2.0`、freetype / fontconfig / harfbuzz / fribidi / libunibreak；
- 不产 `libavcodec.so.62` 这类版本化 soname（Android 装不进 APK）；`NEEDED` 只剩
  `libm / libc / libdl / libandroid / libmediandk / libOpenSLES / libEGL`；
- harfbuzz 是 C++ 静态库，mpv 用 C 链接器，所以把 `libc++_static.a` /
  `libc++abi.a` / `libunwind.a` 静态链进 `libmpv.so`（不额外带 `libc++_shared.so`）；
- `strip` 后 arm64 约 25MB（x86_64 28MB，平时不编），LOAD 对齐 `0x4000`；
- `scripts/android/{mpv-probe.c,check-mpv.sh}`：推到设备上 `dlopen` + 读 client API
  版本 + `mpv_create`。Android 33 x86_64 模拟器与真机（HBY 5502 / Android 9 /
  arm64）实测均为 `libmpv client API: 2.6`、`mpv_create ok`；从装好的 APK 里
  抽出的 `libmpv.so` 再测一次同样通过。
- 出画（A4 第一步，2026-11-27）：`:player-mpv` 是 C++ / CMake 模块
  （[ADR-0016](adr/0016-android-player-native.md)），渲染线程独占 EGL 与
  `mpv_render_context`。真机 HBY 5502（Android 9 / arm64）上 720p H.264 测试片
  走 `mediacodec-copy` 出画，时间码正常推进；`libdvplayer_mpv.so` 同样 16KB 对齐、
  未压缩打包。
- 引擎契约与播放控制（A4 后半段，2026-11-27）：新增 `:player` 模块，定义
  `PlayerEngine`（attach / load / play / pause / seek / speed / 轨道 / 章节 /
  外部字幕 / 状态快照 + 事件回调），mpv 与 Media3 都实现同一份契约，壳层只依赖
  接口。`:player-mpv` 的属性桥全部走 libmpv：暂停 `set pause`、seek
  `seek <秒> absolute`、倍速 `set speed`、轨道读 `track-list/N/{type,id,title,lang,
  codec,selected,external}`、切轨 `set vid/aid/sid`、外部字幕
  `sub-add <path> select`、章节读 `chapter-list/N/{title,time}`。状态用 200ms
  轮询线程推送（读属性本身线程安全），Media3 用主线程 250ms 轮询，两边行为一致。
  验证页加了控制条（播放/暂停、±10s、倍速、音轨、字幕、载入字幕），
  用一份多轨样片（2 音轨 + 1 内嵌字幕 + 3 章节）在 OnePlus 上跑通：
  mpv 侧 `pos 40.625s · 暂停` → `+10s → 50.625s` → `audio:音轨 2*` →
  `sub:test.srt*`；Media3 侧同流程，载入外部字幕后位置与音轨都保持
  （`audio:en*` 不回落默认音轨）。Media3 的章节暂时为空——ExoPlayer 1.11 的
  `MediaMetadata` 没有章节字段，`Mp4Extractor` 也不解析 `chpl`。
  会话 / 通知 / 续播还没接，属于 A4 末尾。

章节 / 续播 / ASS（A4 收尾，2026-11-27）：

- **章节**：mpv 读 `chapter-list`；Media3 的 `Mp4Extractor` 不解析 `chpl`，
  新增 `Mp4Chapters` 直接读 `moov/udta/chpl`（`version/flags + reserved + count +
  [start(100ns) len title]`）。同一份样片两边都得到「第一章 / 第二章 / 第三章」，
  验证页「下一章」把位置从 4.7s 跳到 20s、再跳到 40s。
- **续播**：`:player` 的 `PlaybackMemory` 按片源地址存位置（`SharedPreferences`），
  片尾 5 秒内清记录。实测播到 51.4s 退出，重启后日志
  `续播：51377 ms`，从原位置继续。
- **ASS**：mpv 走 libass，`sub-add <path>` 加载 `.ass` 后渲染正常
  （`{\pos}`、`\c`、`\fscx/\fscy` 都生效，截图为证）。Media3 侧 ASS 还没接，
  属于 A6 的 FFmpeg/字幕扩展。

HDR 输出（A5，2026-11-27）：在 OnePlus 10 Pro（Android 16）上，mpv 把 BT.2020 +
PQ 的 HEVC Main10 片源识别为 `prim=bt.2020`、`gamma=pq`、`max-luma=10000`，
把 BT.2020 + HLG 的片源识别为 `gamma=hlg`、`light=hlg`、`max-luma=1000`。
渲染层据此把输出切到 HDR 通路。要点是**两件事必须一起做**，只改其中一个不会
真的进 HDR：

1. **EGLSurface 的 GL colorspace**：用
   `EGL_GL_COLORSPACE_BT2020_PQ_EXT`（`0x3340`）重建 `EGLSurface`，
   `eglCreateWindowSurface` 时传入 `EGL_GL_COLORSPACE_KHR`；HLG 用
   `EGL_GL_COLORSPACE_BT2020_HLG_EXT`（`0x3540`）；设备没有对应扩展时回退
   `EGL_GL_COLORSPACE_SRGB_KHR`，并同步把 window dataspace 退回 SRGB。
2. **Buffer dataspace**：`ANativeWindow_setBuffersDataSpace(window,
   ADATASPACE_BT2020_PQ)`（`163971072` / `0x9C60000`；HLG 是
   `168165376` / `0xA060000`）。这个 API 是 `__INTRODUCED_IN(28)`，minSdk 26
   不能直接链接，运行时用
   `dlsym("libandroid.so", "ANativeWindow_setBuffersDataSpace")` 取，取不到就只做
   EGL colorspace（HDR 效果不完整）。

渲染线程监听 mpv 的 `video-params/primaries` 与 `video-params/gamma`，变化时置
`surface_dirty`，重建 `EGLSurface` 再在新 buffer 上写 dataspace。
`target-colorspace-hint=yes` 让 mpv 把片源色彩空间透传给显示端、不做 tone mapping。

**真片源**：桌面 ffmpeg 没有 `zscale` / `x265`，所以
[`scripts/android/gen-hdr-sample.py`](../scripts/android/gen-hdr-sample.py) 直接在
numpy 里做传递函数——PQ 用 SMPTE ST 2084 的 OETF，HLG 用 ARIB STD-B67 的
OETF——把编码后的 RGB 按 BT.2020 非恒定亮度矩阵转成 10-bit 有限范围 YUV，再交给
`hevc_videotoolbox` 编成 Main10，最后用 `hevc_metadata` bsf 写入 VUI
（PQ: `colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9`；
HLG: `transfer_characteristics=18`）。这样画面本身是真正的 PQ / HLG 曲线，
不是只打标签。片源内容是灰阶斜坡 + 8 条色条 + 8 级灰阶 + 底部移动白块。

真机证据链（日志 tag `DvMpv`，OnePlus 10 Pro / Android 16）：

PQ（`dv-hdr10-real.mp4`，BT.2020 / PQ / Main10 / 24p）：
```
file loaded: ... hwdec=mediacodec-copy pixfmt=nv12 prim=bt.2020 gamma=pq
色彩空间变化：prim=bt.2020 gamma=pq -> dataspace 0x9c60000
EGLSurface 重建：colorspace 0x3340 · 1440x3216
window dataspace -> 0x9c60000
```
SurfaceFlinger：`dataspace=BT2020_PQ (163971072)`，`composition type=DEVICE`。

HLG（`dv-hlg-real.mp4`，BT.2020 / HLG / Main10 / 24p）：
```
色彩空间变化：prim=bt.2020 gamma=hlg -> dataspace 0xa060000
EGLSurface 重建：colorspace 0x3540 · 1440x3216
window dataspace -> 0xa060000
```
SurfaceFlinger：`dataspace=BT2020_HLG (168165376)`。

**静态 HDR 元数据（SMPTE2086 / CTA861_3）**：片源的 mastering display 亮度元数据
用 EGL 的 `EGL_EXT_surface_SMPTE2086_metadata` / `EGL_EXT_surface_CTA861_3_metadata`
扩展挂到 `EGLSurface` 上：`eglSurfaceAttrib` 的浮点属性按 IEEE-754 位模式塞进
`EGLint`，且必须在 `eglSwapBuffers` **之前**设置，元数据才会随这一帧的 buffer 走。
OnePlus 上验证 PQ 片源 SurfaceFlinger 层 `hdr metadata types=1`；HLG 片源仍是 0
（只对 PQ 写）。

不要走 `ASurfaceControl_createFromWindow` + `ASurfaceTransaction_setHdrMetadata_*`：
它只能给 window 建一个 child layer，元数据挂不在 SurfaceView 自己的 buffer layer 上。
实测 `dumpsys SurfaceFlinger --layers` 里多出一个 `dvplayer-mpv` 层（无 buffer、
`composition type=SOLID_COLOR`），而真正显示的 `BT2020_PQ` 层 `hdr metadata types`
仍是 0。这条路已从代码里移除。

**HDR10+ 动态元数据（ST2094-40）**：样片把 HDR10 片源用
`ffmpeg -bsf:v hevc_mp4toannexb` 提成裸 HEVC，`hdr10plus_tool inject --json` 注入
每帧的 ST2094-40 SEI，再封回 mp4；`hdr10plus_tool extract` 校验 240 帧全部带上。
mpv 侧只有**软解**能读到动态元数据：数据来自 FFmpeg 的
`AV_FRAME_DATA_DYNAMIC_HDR_PLUS`，`mediacodec-copy` 硬解不产这个 side data，
状态行 `HDR10+ maxRGB` 不出现；存成 `--es hwdec no` 软解后
`video-params/scene-max-r/g/b`、`scene-avg` 才与注入的 `MaxScl` 对上
（`776.8/658.9/691.2 · avg 26.3`）。

但**写不进显示端**：NDK 的 `AHdrMetadataType` 只有 `HDR10PLUS_SEI = 3` 这个枚举，
没有对应的 setter；`libandroid.so` 只导出
`ASurfaceTransaction_setHdrMetadata_smpte2086/cta861_3`；通用的
`SurfaceControl::setHdrMetadata(HdrMetadata)` 是 libgui 的 C++ ABI，不是公开 C API。
结论：mpv / EGL 这条路做不了动态 HDR10+。正解是 Media3——平台 MediaCodec 会把
ST2094-40 交给显示端，`MediaFormat.KEY_HDR10_PLUS_INFO`（`"hdr10-plus-info"`）
API 29+ 就有。M2 的取舍：mpv 内核保证静态 HDR10 / HLG，HDR10+ 片源在 mpv 下按
HDR10 静态播放；动态元数据留给 Media3 内核（A6）验证。

**帧率匹配**：`PlayerTestActivity` 每秒读一次 `container-fps`（退回
`estimated-vf-fps`），在「与当前分辨率相同」的显示模式里挑**刷新率是片源帧率
整数倍、且倍数最小**的那个，写
`WindowManager.LayoutParams.preferredDisplayModeId`（同时设
`preferredRefreshRate`），API 30+ 再调
`Surface.setFrameRate(fps, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)`。

- 24p → 120Hz：`120 / 24 = 5`，每个视频帧在 120Hz 面板上重复 5 次刷新。
  日志 `帧率匹配：source=24.0fps -> mode 6 @ 120.00001Hz（×5.000）`，
  `dumpsys display` 的 `mActiveModeId=6`，SurfaceFlinger 的
  `vsyncRate=120.00 Hz`。
- 30 秒 24p 片源在稳定态两次采样都是 `fps 24.000000 · drops 0 · mode 6@120.00Hz`；
  切模式本身不重建 Surface（`EGLSurface` 日志只有 SRGB→PQ 两次）。
- 60/90/120 都支持；25p 没有整数倍模式（120/25=4.8），退回最高刷新率。
  23.976 时 120/23.976=5.005，1% 容差内仍按 5 倍处理。

测试注意：`am start` 不会自动亮屏。设备息屏 / doze 时 activity 能起来，但
Surface 不可见、mpv 不出帧，`screencap` 也是黑的。先
`adb shell input keyevent KEYCODE_WAKEUP` + `wm dismiss-keyguard`，并
`svc power stayon true`。

已知边界：

- **显示端状态**：OnePlus 的 `dumpsys display` 仍是 `mActiveColorMode=0`、
  `hdrSdrRatio NaN`——ColorOS 不把 HDR 当作一种 color mode，不能靠这两个字段
  判定；目前以 SurfaceFlinger 层的 `dataspace=BT2020_PQ/HLG` + `DEVICE` 合成为准。
  真 HDR 亮度效果最终还得靠仪器或人眼在真实片源上确认。
- **HDR10+ 动态元数据只在 Media3 内核**：mpv 侧软解能读出 ST2094-40（`scene-max-*`），
  硬解 `mediacodec-copy` 拿不到，且平台没有公开的写入接口，动态元数据进不了显示端。
  mpv 下 HDR10+ 片源按 HDR10 静态元数据播放；Media3 路径已验通（见下）。
- **HLG 静态元数据没写**：目前只对 PQ 写 SMPTE2086 / CTA861_3，HLG 只切 dataspace。
- **SDR tone mapping 回退**：显示器不支持 HDR 时的 `tone-mapping` 选项还没接。
- **帧率匹配目前只在验证页**：正式实现要挪到播放器控制器，并在暂停 / 切轨 /
  退出时恢复默认模式；可变帧率（VFR）片源还没处理。

Media3 内核与 HDR10+（A6 第一步，2026-11-27）：新增 `:player-media3` 模块，
`Media3Player` 是 ExoPlayer 的最小封装（SurfaceView + 播放 + 格式回调），
`Hdr10PlusProbe` 直连 `MediaExtractor` + `MediaCodec`，专门看解码器的**输出格式**。
验证页加 `--es engine mpv|media3|codec`，三条路径在同一台 OnePlus 上的实测：

| 路径 | dataspace | SF 层 `hdr metadata types` | 说明 |
| --- | --- | --- | --- |
| mpv 软解 | `BT2020_PQ` | `1` | SMPTE2086 静态元数据（EGL 扩展写入） |
| Media3 / 硬解，真 HDR10 | `BT2020_ITU_PQ` | `1` | 平台解码器带 `hdr-static-info`（25 字节） |
| Media3 / 硬解，HDR10+ | `BT2020_ITU_PQ` | `4` | 平台解码器带 `hdr10-plus-info`（64 字节） |

`4` 就是 `HDR10PLUS_SEI`（`android::HdrMetadata` 的位标志：SMPTE2086=1、
CTA861_3=2、HDR10PLUS=4）。`codec` 探针的输出格式同时给出
`color-standard=6`（BT.2020）、`color-transfer=6`（ST 2084）、
`hdr-static-info`（25 字节）、`hdr10-plus-info`（64 字节）。对照很干净：
同一份 PQ 片源去掉 ST2094-40 后 `types` 从 `4` 回落到 `1`，说明这个字段确实反映
动态元数据有没有被解码器识别，不是误报。

结论：**HDR10+ 只能走 Media3 / MediaCodec**。A7 的路由规则据此定为「片源是
HDR10+ 且设备支持时自动切 Media3；否则默认 mpv」。mpv 内核继续负责原盘、
DV P5/P8 与 EGL 渲染路径。

契约对齐（A6 第二步）：`Media3Player` 实现同一份 `PlayerEngine`，验证页
`--es engine media3` 即可切换。暂停 / seek / 倍速 / 切音轨 / 切字幕 / 外部字幕
都跑通；外部字幕用 `MediaItem.SubtitleConfiguration`（按扩展名给 MIME），
reload 时记住位置与当前音轨，`onTracksChanged` 之后再恢复（否则会回落默认
音轨）。内嵌字幕（`mov_text`）能识别、能切。章节暂缺——ExoPlayer 1.11 的
`MediaMetadata` 没有章节字段，`Mp4Extractor` 也不解析 `chpl`。
PGS 字幕、FFmpeg 音频扩展（自定义 decoder / renderer）、tunneling 还没做，
这三块是 A6 剩下的主要工作。

A1 的静态部分已落地（2026-11-27）：`:core` 的 `Capabilities.collect()` 用
`MediaCodecList` / `Display` / `AudioManager` 采一份 `DeviceProfile`（JSON +
摘要），手机壳首页直接显示，日志 tag 是 `DvCaps`。六项结论里只有「后台 / PiP」
能在 HBY 5502 上验；HDR10 掉帧、DV P8 / P5、直通、24p 都需要一台支持
HDR + HDMI 输出的设备，仍挂在 A1 门禁上。

### M2-B TV

| # | 阶段 | 内容 |
| --- | --- | --- |
| B1 | 大屏 UI | Hero + 海报行、库、详情、搜索（屏幕键盘）、设置 |
| B2 | 播放器控制 | 遥控器键位、进度条、轨道 / 字幕面板、信息层（含当前内核） |
| B3 | 兼容矩阵 | tunneling 取舍、HDMI → AVR 直通、老盒子降级、TV 默认内核最终值 |
| B4 | 交付 | 侧载 APK（含更新检查）、Play TV 材料 |
| B5 | 原盘边读边播（可选） | libbluray 自定义 stream + 缓存 |

## 8. 验证与设备

| 设备 | 用途 | 必测 |
| --- | --- | --- |
| arm64 真机 / 模拟器 | 逻辑与 UI 回归 | JNI / JSON、导航、ViewModel |
| OnePlus 10 Pro（Android 16 / 骁龙 8 Gen 1） | 手机主验 | HDR10 / HDR10+ 输出、120Hz 帧率匹配、AV1 软解、Android 16 行为 |
| HBY 5502（Android 9 / MT6765） | 低端降级路径 | SDR 输出、软/硬解回退、无直通时的 PCM 下混 |
| Android 12+ 真机 | 手机 Alpha 主验 | 两个引擎、DV P5、ASS、PiP、VFS |
| 低端 Android 9 盒子（Amlogic） | TV 冒烟 | 起播、焦点、4K 掉帧、直通 |
| DV 电视 / 支持 DV 的盒子 | DV / HDR / 直通 | P5 / P8、HDR10、HDR10+、TrueHD 直通 |

HBY 5502 的实测能力（2026-11-27，完整 JSON 见
[devices/hby-5502.json](devices/hby-5502.json)，由 `:core` 的
`Capabilities.collect()` 采集）：

| 项 | 结果 |
| --- | --- |
| 屏幕 | 720×1280，只有一个模式 57.5Hz，`wideColorGamut=false` |
| HDR | `supportedHdrTypes` 为空——这台机器连 HDR10 都不支持，A5 的降级路径在这里验 |
| 解码 | AVC / HEVC / VP8 / VP9 / MPEG2 / MPEG4 / H263 / VC1(WMV) / DivX；**无 AV1** |
| DV | 没有 DV 解码器，P5 / P8 在这台上只能走 mpv 整形到 SDR |
| 音频输出 | 只有 earpiece / speaker / telephony，编码只有 `pcm_16` / `pcm_float`——**没有任何直通** |
| PiP | 有 |
| GLES | 3.2 |

它适合验「按设备能力兜底」这条主线：没有 HDR、没有直通、没有 AV1，路由应该全部
落到 SDR + PCM + mpv/软解。

OnePlus 10 Pro 的实测能力（2026-11-27，JSON 见
[devices/oneplus-ne2210.json](devices/oneplus-ne2210.json)）：

| 项 | 结果 |
| --- | --- |
| 屏幕 | 1440×3216，支持 1080p/1440p × 60/90/120Hz 六种模式；`wideColorGamut=true` |
| HDR | `hdr10` / `hlg` / `hdr10_plus`，最大亮度 540 nit；**没有 Dolby Vision** |
| 解码 | AVC / HEVC / VP9 有 `qcom` 硬解（含 secure、low_latency）；AV1 只有 `c2.android.av1-dav1d` 软解 |
| 音频输出 | speaker / earpiece / telephony，只有 `pcm_16`，无 HDMI 直通 |
| 页大小 | 4096——不是 16KB 设备，16KB 兼容仍靠静态校验（`zipalign -P 16` + ELF LOAD） |
| PiP | 有 |

这台补上了 HDR 与多刷新率两块：A5 的 HDR10 / HDR10+ 输出和 24p 帧率匹配可以在
它上面验。DV 仍然缺设备（P5 / P8 没有解码器，也没有 DV 显示）。

Android 16 上还踩到一个存储问题：`/sdcard/Android/data/<pkg>/files/` 里的文件，
mpv 用路径直接打开会 `loading failed`；同一个文件放进 app 内部 `filesDir`
（`/data/user/0/<pkg>/files/`）就正常。A9 的下载缓存因此应该落在内部目录，
不要落 external 的 app 专属目录。Android 16 强制 edge-to-edge 也让状态栏压在
画面上，UI 侧要按 inset 处理。

```bash
./gradlew :app-phone:assembleDebug
cargo ndk -t arm64-v8a -o core/src/main/jniLibs build -p dvplayer-media-jni --release
adb install -r app-phone-debug.apk
adb shell dumpsys media.codec | head -80
adb logcat -s DvPlayer:D MPV:D MediaCodec:D
```

## 9. 风险

风险登记在 [PLAN.md](PLAN.md) §7，前三条与 Android 直接相关：

1. **libmpv 的 Android 构建链**——头号排期风险，CI 全量编译会拖死迭代。
   本地链路已通（2026-11-26），剩下的是把产物接进 CI 缓存，避免每次全量重编。
2. **mpv 的 HDR 输出**——默认内核可能是 SDR；盒子合成器只认 tunneled HDR 时补不齐。
3. **mpv 的音频直通**——`ao_audiotrack` 的 IEC61937 支持未验证；不支持就路由 Media3。

## 10. 未决

| 项 | 待定 |
| --- | --- |
| TLS | vendored OpenSSL vs rustls + 平台校验 + 源级「允许自签名」开关 |
| applicationId | `com.dvplayer.app` / `com.dvplayer.app.tv` 两个商店条目 |
| 下载 | 手机 v1 是否必须；TV 明确不做 |
| NAS 原盘 | v1「先下载到缓存」是否可接受；边读边播排 B5 |
| 投屏 | Cast 明确列为非目标 |
| Android 16 | 本地网络访问限制，待 SDK 文档确认权限声明 |
