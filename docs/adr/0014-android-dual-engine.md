# ADR-0014：Android 双内核，默认 mpv，按设备能力兜底

- 状态：已接受
- 日期：2026-11-25
- 取代：ADR-0004 中「Android 只用 Media3、不给 Android TV 挂 libmpv」的部分

## 背景

蓝光原盘是硬需求（ISO / BDMV 目录，含 UHD）。Media3 没有 UDF、MPLS、AACS 这一层：
要么自己写 UDF 2.50 读取 + `192→188` 重打包 + 选集 UI，要么换一个有这层的内核。

同时，Media3 还有几处能力边界：

| 能力 | Media3 现状 |
| --- | --- |
| 蓝光原盘 | 没有 UDF / MPLS / AACS；`TsExtractor` 只认 188 字节包，M2TS 是 192 |
| ASS / SSA | 只有基础文本解码，特效与定位丢失；内嵌附件字体拿不到 |
| DV P5（无 DV 解码器） | 不映射到 HEVC，画面绿紫或找不到解码器 |
| DTS / DTS-HD / TrueHD | 平台多数不解，要自己编 FFmpeg 音频扩展 |
| DV P7 双层 | 公共 API 拿不到增强层，只能播 BL |

mpv 在这些格子上都是现成的：原生 libbluray、自带 libass（含内嵌字体）、
gpu-next 的 DV P5/P7 整形、FFmpeg 全量音频解码。桌面端已经用它跑了 M0/M1/M2。

Media3 则在另外几处更强：HDR 直通（平台原生路径）、tunneling、PiP / MediaSession、
平台音频直通，以及官方长期维护。

## 决策

1. **两个引擎都进 APK**：mpv（libmpv + gpu-next）为默认，Media3 为第二引擎；
   支持自动与手动切换。
2. **引擎契约放在 `:player`**：Surface 由壳持有（`SurfaceView`），
   切换 = 停一个、按当前位置开另一个；约 1 秒空档，不做无缝。
3. **默认 mpv；三条硬例外走 Media3**：
   - 片源是 HDR10 / HDR10+ / DV 且设备支持 HDR；
   - 需要 TrueHD / DTS-HD / Atmos 直通，且 mpv 实测不支持；
   - `DeviceProfile` 判定性能不达标（4K 掉帧 / 盒子无 HDR 合成）。
4. **用户手动指定优先**；运行时失败自动换另一个引擎重试一次，不循环。
5. **mpv 按 LGPL 构建**（`-Dgpl=false`，FFmpeg `--disable-gpl`），动态链接分发；
   不改 mpv 源码（零 fork）。不链 libsmbclient（GPLv3），SMB 走自研 VFS。
6. **单内核方案里的补丁删除**：libass NDK、DV P5 定制渲染、Media3 侧的
   `192→188` 原盘 DataSource 都不需要了。

## 引擎契约

```kotlin
interface PlaybackEngine {
    val events: Flow<EngineEvent>
    val capabilities: EngineCapabilities
    fun attach(surface: Surface, width: Int, height: Int)
    fun open(media: EngineMedia, startMs: Long)
    fun play(); fun pause()
    fun seekTo(ms: Long, exact: Boolean)
    fun setSpeed(speed: Float)
    fun setTrack(kind: TrackKind, id: String?)
    fun setSubtitleStyle(style: SubtitleStyle)
    fun snapshot(): EngineSnapshot      // 位置/缓冲，4Hz 轮询
    fun release()
}
```

四条不能省的约定：

- **Surface 归属**：Media3 用 `setVideoSurface`，mpv 用 `ANativeWindow_fromSurface` + EGL。
- **字幕归属**：`subtitleMode = ENGINE | CUES`；ENGINE 时壳必须关掉自己的字幕层。
- **轨道匹配**：切换按「类型 + 语言 + 编码 + 序号」回选，不按 id。
- **错误码**：每个错误带 `retryableWithOtherEngine`，自动回退只认它。

音频焦点、MediaSession / 通知、PiP、进度回写、字幕样式映射、诊断采集统一上移到 `:player`，
两个引擎共用；Media3 自带的焦点管理要关掉，避免双重处理。

## 路由

| 场景 | 内核 | 原因 |
| --- | --- | --- |
| 默认 | mpv | 格式覆盖、原盘、ASS 内嵌字体 |
| HDR / DV 且设备支持 | Media3 | 平台 HDR 直通；HDR10+ 动态元数据不丢 |
| 需要直通且 mpv 不支持 | Media3 | 平台 `AudioTrack` 直通链路成熟 |
| 设备能力不达标 | Media3 | 4K 掉帧 / 盒子无 HDR 合成 |
| Media3 报错 / 打不开 | 自动重试 mpv | 每片最多一次，记日志 |
| 用户手动指定 | 按用户 | 播放页「换个内核重播」+ 设置页默认值 |

路由依赖 `DeviceProfile`（HDR 类型、DV profile、直通编码、4K 解码能力、tunneling），
由能力探测页生成并缓存；这使探测页从调试工具变成发布必需项。

## 后果

- **包体积 +25–35MB/ABI**，用 ABI splits。
- **构建链显著变重**：libmpv + FFmpeg + libplacebo + libass + libbluray 的 NDK 交叉编译，
  是 M2 的头号排期风险，CI 必须缓存产物。
- **HDR 输出由壳负责**：`ANativeWindow_setBuffersDataSpace`、`window.colorMode`、
  `preferredDisplayModeId`。部分盒子只在 tunneled 模式下走 HDR，mpv 补不齐，
  这类设备直接归入能力例外。
- **音频直通待实测**：`ao_audiotrack` 的 IEC61937 支持不确定；不支持就把直通片源路由给
  Media3，不打私有补丁。
- **QA 两套**：用同一套样片在两个引擎上跑能力矩阵，把结果写进
  [DECODE.md](../DECODE.md)。
- 设置与源配置在两个壳之间不共享；播放进度仍由 `core/media` 回写服务器。
