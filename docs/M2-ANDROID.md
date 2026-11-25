# M2 · Android / TV 客户端

> 状态：方案定稿（2026-11-25），实现未开始。双壳 + 双内核，手机先行。
> 决策见 [ADR-0013](adr/0013-android-two-shells.md)（双壳）、
> [ADR-0014](adr/0014-android-dual-engine.md)（双内核）、
> [ADR-0015](adr/0015-android-vfs.md)（存储）。

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
| x86_64 模拟器 | 逻辑与 UI 回归 | JNI / JSON、导航、ViewModel |
| Android 12+ 真机 | 手机 Alpha 主验 | 两个引擎、DV P5、ASS、PiP、VFS |
| 低端 Android 9 盒子（Amlogic） | TV 冒烟 | 起播、焦点、4K 掉帧、直通 |
| DV 电视 / 支持 DV 的盒子 | DV / HDR / 直通 | P5 / P8、HDR10、HDR10+、TrueHD 直通 |

```bash
./gradlew :app-phone:assembleDebug
cargo ndk -t arm64-v8a -t x86_64 -o core/src/main/jniLibs build -p dvplayer-media-jni --release
adb install -r app-phone-debug.apk
adb shell dumpsys media.codec | head -80
adb logcat -s DvPlayer:D MPV:D MediaCodec:D
```

## 9. 风险

风险登记在 [PLAN.md](PLAN.md) §7，前三条与 Android 直接相关：

1. **libmpv 的 Android 构建链**——头号排期风险，CI 全量编译会拖死迭代。
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
