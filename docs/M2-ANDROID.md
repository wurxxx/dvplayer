# M2 · Android / TV 客户端

> 状态：A0–A10 已在真机落地（2026-11-28），手机端可直接用——媒体库 / 首页 /
> 详情 / 搜索 / 观看 / 设置 / 播放全部接通真实数据。还缺 A1 的 TV / 盒子项、
> A11（TV 冒烟）、TV 大屏 UI 与真实原盘样片。
> 决策见 [ADR-0013](adr/0013-android-two-shells.md)（双壳）、
> [ADR-0014](adr/0014-android-dual-engine.md)（双内核）、
> [ADR-0015](adr/0015-android-vfs.md)（存储）、
> [ADR-0016](adr/0016-android-player-native.md)（native 层）。
> 主验机 OnePlus NE2210（Android 16 / 骁龙 8 Gen 1），降级机 HBY 5502（Android 9 / MT6765）。

## 1. 范围与边界

产品能力与桌面一致：多源（飞牛 / Emby / 本地 / SMB / NFS / WebDAV）、聚合搜索、
续播、蓝光原盘、PGS / ASS / SRT、HDR / DV、音频直通。Android 的差异如实呈现：

| 项 | 边界 |
| --- | --- |
| 解码 | 平台 `MediaCodec`；只有 DV P5 必须软解 |
| DV P7 | 公共 API 拿不到增强层，只播 BL |
| DV P5 | libplacebo + libdovi 把 IPTPQc2 还原成 HDR10，必须软解 |
| DV P8 | BL 本身就是 HDR10，硬解即可 |
| 原盘 | 只支持未加密 ISO / BDMV；AACS / AACS2 明确拒绝 |
| 直通 | 按 `AudioDeviceInfo.getEncodings()`，手机基本没有 |
| 蓝光菜单 | 不跑 BD-J，用标题列表代替 |

## 2. 模块

```
apps/android/
├── app-phone/       applicationId com.dvplayer.app         手机入口、权限、PiP
├── app-tv/          applicationId com.dvplayer.app.tv      LEANBACK_LAUNCHER、banner
├── ui-phone/        手机屏幕 + 导航（Material3）
├── ui-tv/           TV 屏幕 + 导航（androidx.tv:tv-material）
├── feature/         共享 ViewModel / UiState / 交互逻辑
├── player/          引擎契约、路由、音频焦点、MediaSession、字幕样式、诊断
├── player-media3/   Media3 适配
├── player-mpv/      libmpv JNI + EGL 渲染线程 + 属性桥
├── player-disc/     libbluray JNI（title / 章节），与 mpv 共用同一份 libbluray
├── data/            仓库层、hub 生命周期、源配置、图片加载
├── design/          颜色 / 字号 / 间距 / 图标 / 字符串
├── core/            JNI 声明 + camelCase 模型（kotlinx.serialization）
└── build-logic/     约定插件（Compose、JDK 17、minSdk、R8、jniLibs、16KB、ABI splits）
```

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

- **Surface 归属**：壳持有 `SurfaceView`；Media3 用 `setVideoSurface`，mpv 用
  `ANativeWindow_fromSurface` + EGL。
- **字幕归属**：`subtitleMode = ENGINE | CUES`。ENGINE 时壳关掉自己的字幕层，
  样式映射到 `sub-scale` / `sub-pos` / `sub-ass-override`。
- **轨道匹配**：按「类型 + 语言 + 编码 + 序号」回选，不按 id。
- **错误码**：带 `retryableWithOtherEngine`，自动回退只认它。

两个引擎共用：音频焦点、MediaSession / 通知、PiP、进度回写、字幕样式映射、
诊断采集。Media3 自带的焦点管理要关掉，避免双重处理。

### 3.2 路由（最终版）

**默认 mpv。** `EngineRouter` 按顺序判，先命中先返回：

| # | 条件 | 内核 | 原因 |
| --- | --- | --- | --- |
| 1 | 非本地（含 `://`） | mpv | 跳过探测；桥接 / HTTP 都能喂 |
| 2 | 原盘（ISO / BDMV） | mpv | 只有它链了 libbluray，Media3 不认识盘结构 |
| 3 | DV（P5 / P7 / P8） | mpv | 平台解码器丢 DV 元数据；P5 靠 libplacebo 整形 |
| 4 | 设备不支持 HDR10+ | mpv | 不必解 SEI |
| 5 | 片源带 ST2094-40（HDR10+） | Media3 | 只有平台 MediaCodec 能把动态元数据交给显示端 |
| 6 | 其余 | mpv | 默认内核，负责 ASS / 原盘 / 软解 |

DV 必须排在 HDR10+ 之前：P7 的 SEI 会被 HDR10+ 探针误认成 ST2094-40（实测过）。
本地文件先探 DV，再用 `Hdr10PlusProbe` 解 12 帧看输出格式里有没有
`hdr10-plus-info`。

运行时失败跨内核重试一次（只 Media3 → mpv，Intent 带 `fallback=1`），不来回踢皮球；
用户手动指定优先。

### 3.3 切换

不是无缝，是「停一个、按当前位置重开」，约 1 秒空档；seek 用精确模式，从最近
关键帧起。UI 显示「正在切换内核…」。

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

逐格结果在 [DECODE.md](DECODE.md) §8。摘要：

- **mpv**：原盘、ASS（libass，含内嵌字体）、DV P5 整形、DTS / TrueHD 软解、
  HDR10 / HLG 直出（已验）。
- **Media3**：HDR10 / HDR10+ 直通（含动态元数据）、tunneling（设备支持时）、
  平台直通；ASS 只有基础文本。
- **两套都没有**：DV P7 增强层、AACS / AACS2、3D MVC、BD-J 菜单。

## 5. 原盘

见 [BLU-RAY.md](BLU-RAY.md) §5.3。要点：

- 本地 ISO / BDMV 目录**直接用普通路径**交给 mpv：`bdmv_dir_stream_open` 会识别
  `.iso` 与含 `BDMV/MovieObject.bdmv` 的目录，验证后内部转
  `bluray://<title>/<device>`。不要自己拼 `bluray://`——这条协议的路径是
  `bluray://title/device`，拼成 `bluray:///abs/path` 会被当成相对路径。
- 光盘设备（`/dev/sr0`）才需要 `--bluray-device`，移动端用不上。
- `:player-disc` 用 libbluray 1.5 列 title / 章节（含 HDR / DV 标记与章节名）。
- NAS 原盘 v1 先下载到缓存；边读边播排 M2-B 之后。
- Media3 不参与原盘。

## 6. 存储与 VFS

```
:feature → :core 的 Vfs（list / stat / open / seek）
                    ├── SmbVfs    smbj（SMB2/3）
                    ├── NfsVfs    纯 Kotlin NFSv3（AUTH_SYS）
                    └── DavVfs    OkHttp（PROPFIND + Range）
                          │  目录树 JSON
                          ▼
        core/media vfs 源适配器（复用 SxxExx / 第 N 集 认集号）
                          ▼
        player-media3 DataSource / player-mpv 自定义 stream
```

核心要补的三件事：

| 项 | 原因 |
| --- | --- |
| `dv_hub_replace(id, config)` | VFS 重扫；现在没有 remove / replace，只能重建 hub |
| `dv_probe_dovi_bytes(ptr, len)` | VFS / SAF 拿不到路径，判定逻辑仍只在 `core/dovi` |
| `sources/vfs.rs` + 共享扫描函数 | 复用 `local.rs` 的目录树与集号解析 |

## 7. 实测记录

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| A0 | 构建链（JDK 17 / SDK 36 / NDK r28、libmpv、16KB） | 完成 |
| A1 | 可行性 spike（设备能力六项） | 手机侧完成；TV / 盒子 / DV 显示项缺（门禁未关） |
| A2 | 骨架（两个 app、约定插件、`:design` / `:core`） | 完成 |
| A3 | 数据层（`core/media-jni`、hub 生命周期、库 / 详情 / 记录） | 完成（§7.1.1）：41 个 `dv_*` 全转发，`verify-core.sh` 19 步通过 |
| A4 | 引擎契约 + mpv（EGL、属性桥、会话、章节、续播、ASS） | 完成 |
| A5 | HDR 输出（dataspace、静态元数据、帧率匹配） | 完成 |
| A6 | Media3（HDR10+、音频、PGS / Sup、契约对齐） | 完成 |
| A7 | 路由 / 切换 / 回退 | 完成 |
| A8 | 原盘入口 | 入口链完成；真实原盘样片缺 |
| A9 | VFS（WebDAV / SMB / NFS / 桥接） | WebDAV + SMB + NFS 完成 |
| A10 | PiP / 前台服务 / 下载 | 完成 |
| A11 | TV 冒烟 | 未开始 |

**A1 与 A11 是门禁**：A1 决定例外表，A11 不通过就不开 M2-B。A1 的静态部分已用
`:core` 的 `Capabilities.collect()` 落地（`MediaCodecList` / `Display` /
`AudioManager` 采 `DeviceProfile`，JSON + 摘要，首页显示，日志 tag `DvCaps`）；
六项里只有「后台 / PiP」能在 HBY 5502 上验完，其余依赖 §8 的设备。

> 2026-11-26 复测：开发机上只剩 x86_64 模拟器，A5 的直出、A6 的 Media3、
> A11 的 tunneling 都没法重跑（`h264_mediacodec` 无 JVM、10-bit HEVC
> `ERROR_CODE_DECODING_FAILED`）。这些项在 §9.1「待验」里单列，别拿模拟器结果
> 当成真机结论。

### 7.1 构建链（A0）

- `scripts/android/{env,build-native,check-apk}.sh`：JDK 17 / SDK 36 / NDK r28；
  `cargo ndk` 出 `arm64-v8a`（x86_64 只给模拟器，默认不编不打包）；
  `zipalign -c -P 16` + ELF `LOAD` 对齐校验。
- AGP 8.13.2 / Gradle 8.13 / Kotlin 2.2.21，约定插件在 `build-logic`。
- Compose BOM 钉 **2026.06.01**（ui 1.11.x，minCompileSdk 35）。2026.11.01 的
  Compose 1.13 要 compileSdk 37 / AGP 9.1，和当前基线冲突。

`scripts/android/build-mpv.sh`：依赖全静态，只产一个 `libmpv.so`。

| 依赖 | 版本 / 选项 |
| --- | --- |
| mpv | **`1eb941f`**（含 `ad9d850 libmpv: add a gpu-next render backend`），与桌面端同 commit |
| FFmpeg | n9.0.2（`--disable-gpl --disable-version3`，`-fPIC`） |
| libplacebo | v7.387.0（`vulkan=disabled`，`-Ddovi=enabled -Dlibdovi=enabled`） |
| libdovi | 3.4.0（Rust crate，cbindgen + `cargo build --features capi` 出 staticlib，手写 `dovi.pc`） |
| libass / libbluray | 0.17.4 / 1.5.0 + libudfread 1.2.0 |
| mbedTLS | 3.6.4（静态；FFmpeg 的 https / TLS 后端） |
| 字体 | freetype / fontconfig / harfbuzz / fribidi / libunibreak |

- 不产 `libavcodec.so.62` 这种版本化 soname；`NEEDED` 只剩
  `libm / libc / libdl / libandroid / libmediandk / libOpenSLES / libEGL`。
- harfbuzz 是 C++ 静态库，mpv 用 C 链接器，所以 `libc++_static.a` /
  `libc++abi.a` / `libunwind.a` 静态链进 `libmpv.so`，不额外带 `libc++_shared.so`。
- strip 后 arm64 约 **28.0 MiB**（29,310,920 字节；含 libdovi / mbedTLS；
  x86_64 只给模拟器，平时不编），`LOAD` 对齐 `0x4000`。
- **包体裁剪**：试过 `--enable-small`（28.0 → 22.8 MiB），但 4K HEVC 软解 17.5
  秒掉了 314 帧（`-O3` 时 1 帧）。P5 必须软解，已回退；继续裁只能逐组件关
  decoder / demuxer，会牺牲格式覆盖，暂不做。
- **https / 证书**：FFmpeg 之前没编 TLS，libmpv 直接报
  `recompile FFmpeg with openssl...`。现在静态链 mbedTLS 3.6.4 +
  `--enable-mbedtls`；mbedTLS 是 Apache-2.0，FFmpeg 归为 version3，所以
  **Android 这份 libmpv 按 LGPLv3 分发**（桌面端用 securetransport / schannel，
  仍是 2.1）。系统 CA 在 conscrypt 的 APEX 里，native mbedTLS 读不到，所以把
  curl 维护的 Mozilla `cacert.pem`（118 张，约 200KB）打进 APK（首次用到复制到
  `filesDir/ca/`，用 `scripts/android/update-cacert.sh` 刷新）。默认
  `tls-verify=no`（自签名 NAS 常见），`--es tls_verify 1` 才校验、没给
  `--es tls_ca` 就用内置包。实测（`verify-tls.sh`）：自签 + 校验被拦（flags: 8）、
  自签 + 默认正常起播、公网 HLS + 校验正常（`drops 2`）；`https_server.py`
  （自签 + Range）经 mpv 播到 EOF，`206`、`drops 0`。源级「允许自签名」开关还没
  进 UI（现在是全局参数），见 §9。
- `--stage` 同步 `libmpv.so` 与 mpv 头文件（`client.h` / `render.h` /
  `render_gl.h`）到 `player-mpv/.../include/mpv/`。
- **换 mpv 版本时必须删** `build/android-mpv/src/mpv`、`.../arm64/build/mpv`、
  `.../arm64/prefix/.done/mpv`：`ensure_tar` 看到源码目录已存在就跳过，只改
  版本号不会换源码。
- 自检：`scripts/android/{mpv-probe.c,check-mpv.sh}` 推到设备上 `dlopen` + 读
  client API 版本 + `mpv_create`；模拟器、HBY 5502、APK 里抽出的 `.so` 都通过
  （`client API: 2.6`）。

### 7.1.1 数据层 JNI（A3）

`core/media` 的 41 个 `dv_*` 现在全部经 `core/media-jni` 转发到 Kotlin：
`Native.kt`（external 声明）→ `Models.kt`（camelCase 模型）→ `MediaHub.kt`
（`MediaHub` / `MediaSourceHandle` / `DvCore`）。界面不直接碰 JNI。

| 约定 | 说明 |
| --- | --- |
| 句柄 | Kotlin `Long`，就是 Rust 的 `*mut SourceHandle` / `*mut HubHandle`；`close()` 调 `*_free` |
| 返回 | 统一 JSON 外壳 `{"ok":true,"data":…}` / `{"ok":false,"error":…,"code":…}`，`CoreException` 承载失败 |
| 流式回调 | `hubAddManyStream` 逐条 emit 的是**裸 `SourceConnect` 对象**，没有外壳；返回值才有 |
| 线程 | 核心是阻塞的（内部同步 HTTP），调用方必须在工作线程；hub 内部有锁，多线程安全 |
| `internal` | **external 方法不能标 `internal`**：Kotlin 会改名成 `coreVersion$core_debug`，JNI 找不到符号 |
| 布尔 | `hubSetFavorite/hubSetWatched` 的 JNI 参数是 `jint`，Kotlin 侧用 `Int`（0/1） |
| TLS | Android 没有 OpenSSL / SChannel，`reqwest` 按 target 切到 `rustls-tls-webpki-roots`；桌面仍是 `native-tls` |
| 打包 | `cargo ndk` 会把 `libdvplayer_media.so` 也复制出来（`media` 是 cdylib），脚本删掉它——`_jni.so` 已静态链入 |

`tests/android/verify-core.sh` 是这条链的回归：起 `CoreSmokeActivity`，
跑「建连 → 库 → 条目 → 详情 → 播放源 → 进度 / 记录 → 搜索 → 流式建连 →
DV 探测」，断言 19 步全过。2026-11-26 x86_64 模拟器（`p5.mkv`）：

```
✓ version 0.1.4        ✓ sourceKinds fnos,emby,jellyfin,local
✓ hub.add / libraries / items (1 条) / detail / playSource (direct=true)
✓ hubMediaInfo         ✓ reportProgress→records   ✓ setWatched / removeRecord
✓ hub.search (1 命中)  ✓ children / people / genres / favorites
✓ 错误路径 detail 不存在 → CoreException
✓ hub.addManyStream 回调 2 条，返回 2 条
✓ probeDovi P5 MEL disableResidual=true
RESULT PASS (19 步)
```

CI 的 `apk` job 现在会装 Rust + `cargo-ndk 4.1.2`、编 `arm64-v8a` 核心，
再打两个壳，`check-apk.sh` 会一并校验 `libdvplayer_media_jni.so` 的 16KB 对齐。

### 7.2 出画与播放控制（A4）

`:player-mpv` 是 C++ / CMake 模块，渲染线程独占 EGL 与 `mpv_render_context`。
HBY 5502（Android 9）与 OnePlus 上 720p H.264 走 `mediacodec-copy` 出画，
时间码正常。

属性桥全部走 libmpv：暂停 `set pause`、seek `seek <秒> absolute`、倍速
`set speed`、轨道 `track-list/N/{type,id,title,lang,codec,selected,external}`、
切轨 `set vid/aid/sid`、外部字幕 `sub-add <path> select`、章节
`chapter-list/N/{title,time}`。状态用 200ms 轮询线程推送；Media3 用主线程 250ms
轮询，行为一致。

多轨样片（2 音轨 + 1 内嵌字幕 + 3 章节）实测：mpv `pos 40.625s · 暂停` →
`+10s → 50.625s` → `audio:音轨 2*` → `sub:test.srt*`；Media3 同流程，载入外部
字幕后位置与音轨都保持。

- **章节**：mpv 读 `chapter-list`；Media3 的 `Mp4Extractor` 不解析 `chpl`，新增
  `Mp4Chapters` 直接读 `moov/udta/chpl`。两边都得到「第一章 / 第二章 / 第三章」，
  「下一章」4.7s → 20s → 40s。
- **续播**：`PlaybackMemory` 按片源地址存位置（`SharedPreferences`），片尾 5 秒
  内清记录。实测 51.4s 退出，重启后 `续播：51377 ms`。
- **会话 / 通知**：`MediaSessionController` 用平台 `MediaSession`，通知用
  `Notification.MediaStyle`（id 1001）。`dumpsys media_session` 显示
  `state=PLAYING(3) position=3791`；`dispatch pause` → `PAUSED(2)`，
  `dispatch play` 恢复；ColorOS 状态栏胶囊能识别。
- **ASS**：mpv 走 libass，`{\pos}` / `\c` / `\fscx` 都生效（截图为证）。Media3 的
  `SsaParser` 能出字但忽略 `\pos`、按 PlayRes 放大字号。**ASS 参考内核是 mpv**。

### 7.3 HDR 输出（A5）

片源识别：PQ 片源 `prim=bt.2020`、`gamma=pq`、`max-luma=10000`；HLG 片源
`gamma=hlg`、`max-luma=1000`。**两件事必须一起做**，只改一个不会真进 HDR：

1. **EGLSurface 的 GL colorspace**：PQ 用 `EGL_GL_COLORSPACE_BT2020_PQ_EXT`
   （`0x3340`），HLG 用 `EGL_GL_COLORSPACE_BT2020_HLG_EXT`（`0x3540`），
   `eglCreateWindowSurface` 时传 `EGL_GL_COLORSPACE_KHR` 重建；不支持时回退
   `EGL_GL_COLORSPACE_SRGB_KHR` 并把 dataspace 退回 SRGB。
2. **Buffer dataspace**：`ANativeWindow_setBuffersDataSpace(window, ...)`，PQ
   `0x9C60000`、HLG `0xA060000`。这是 API 28 才有的符号，minSdk 26 用
   `dlsym("libandroid.so", ...)` 取，取不到就只做 EGL colorspace。

渲染线程监听 `video-params/{primaries,gamma}`，变化时重建 `EGLSurface` 再写
dataspace。`target-colorspace-hint=yes` 让 mpv 透传色彩空间、不做 tone mapping。

实测（OnePlus）：PQ `dataspace=BT2020_PQ (163971072)`、HLG
`dataspace=BT2020_HLG (168165376)`，SurfaceFlinger 层 `composition type=DEVICE`。

**静态元数据**：mastering display 的 SMPTE2086 / CTA861_3 用
`EGL_EXT_surface_SMPTE2086_metadata` / `EGL_EXT_surface_CTA861_3_metadata` 挂到
`EGLSurface`：浮点属性按 IEEE-754 位模式塞进 `EGLint`，且必须在 `eglSwapBuffers`
**之前**设置。OnePlus 上 PQ 层 `hdr metadata types=1`。不要走
`ASurfaceControl_createFromWindow` + `ASurfaceTransaction_setHdrMetadata_*`：
它只能建 child layer，元数据挂不到 SurfaceView 自己的 buffer layer（实测多出
一个无 buffer 的 `dvplayer-mpv` 层，真正显示的层 types 仍是 0）。这条路已移除。

**HDR10+**：样片用 `hdr10plus_tool inject` 注入每帧 ST2094-40 SEI（240 帧校验）。
mpv 只有软解能读到（`AV_FRAME_DATA_DYNAMIC_HDR_PLUS`），`mediacodec-copy` 不产，
软解后 `scene-max-r/g/b` 与注入的 `MaxScl` 对上（`776.8/658.9/691.2 · avg 26.3`）。
但**写不进显示端**：NDK 只有 `HDR10PLUS_SEI = 3` 枚举、没有 setter，通用
`SurfaceControl::setHdrMetadata` 是 libgui 的 C++ ABI。所以 mpv 下 HDR10+ 片源按
HDR10 静态元数据播；动态元数据归 Media3（见 7.5）。

**帧率匹配**：先钉模式再起播。mp4 用 `FrameRateProbe`（`MediaExtractor`）在
load 前读容器帧率，切完模式等 400ms 再 load；mkv 的帧率在 EBML
`DefaultDuration` 里（`MediaExtractor` 不填 `KEY_FRAME_RATE`），由 `MpvPlayer`
起播后每 50ms 轮询 `container-fps`、拿到就回调。之后按「同分辨率、刷新率是
片源帧率整数倍且倍数最小」选模式，写 `preferredDisplayModeId`（同时设
`preferredRefreshRate`）；API 30+ 再调
`Surface.setFrameRate(fps, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)`。`onStop` 把
`preferredDisplayModeId` 交还系统（设 0）。

起播丢帧实测：P5 mkv（24p 软解）从 6–7 帧降到 1；4K HDR10 mp4（24p 硬解）从
3 帧降到 1，之后都不再增长。

| 片源 | 选中模式 | 倍数 |
| --- | --- | --- |
| 30p | mode 4 @ 60Hz | ×2（最小整数倍，不盲目上 120） |
| 24p | mode 6 @ 120Hz | ×5 |
| 23.976p | mode 6 @ 120Hz | ×5.005 |
| 25p | mode 6 @ 120Hz | ×4.8（无整数倍，退回最高刷新率） |

24p 时 `dumpsys display` 的 `mActiveModeId=6`、SurfaceFlinger `vsyncRate=120.00Hz`；
切模式不重建 Surface（`EGLSurface` 日志只有 SRGB→PQ 两次）。

**已知边界**：

- OnePlus 的 `dumpsys display` 仍是 `mActiveColorMode=0`、`hdrSdrRatio NaN`——
  ColorOS 不把 HDR 当 color mode，以 SurfaceFlinger 层的
  `dataspace=BT2020_PQ/HLG` + `DEVICE` 合成为准。
- HLG 静态元数据：`apply_static_hdr` 对 PQ / HLG 都写；实测 HLG 层
  `hdr metadata types=1`，CTA861_3 要片源带 `max-cll/max-fall` 才写。
- SDR 回退：`--es force_sdr 1` 时设 `target-colorspace-hint=no`、
  `target-prim=bt.709`、`target-trc=bt.1886`、`tone-mapping=auto`、
  `hdr-compute-peak=yes`，并强制 dataspace SRGB；实测 SF 层 `V0_SRGB types=0`。
  什么时候回退由 A7 路由按 `DeviceProfile` 判，现在只是验证页开关。
- 帧率匹配目前只在验证页；正式实现要挪进播放器控制器，并处理 VFR。

### 7.4 Dolby Vision

`:player` 的 `DolbyVisionProbe` 在文件头 1MB / 尾 2MB 找 `dvcC` / `dvvC` 与紧随其后的
配置记录（`version_major=1`，profile 1..9）。MP4 在四字符码后 4 字节；MKV 的 `dvcC`
是 `BlockAddIDType`、后面还有 EBML 长度，命中后在 +4..+12 里找 `01 00` 开头。
VFS 拿不到路径，所以有随机读版本 `probe(readAt, size)`，先用 `VfsFile` 探再起播。

**P5 发紫的三层根因**（第 2 层修完还紫，是第 3 层的构建缓存没生效）：

1. **Android 的 mpv 没有 gpu-next 后端**（决定性）。v0.42.0 tarball 的
   `render_backends[]` 只有 `gpu` / `sw`，render API 落到老 `gpu`，它一上来就
   `mp_image_params_restore_dovi_mapping()` 把 DV 映射连 RPU 剥掉，IPTPQc2 被当
   BT.2020 输出 → 绿紫；桌面端早就是 gpu-next，所以同一张 `p5.mkv` 在 Mac 正常。
   修法：mpv 钉含 `gpu-next render backend` 的 `1eb941f`，并在 `create_render_context()`
   显式传 `MPV_RENDER_PARAM_RENDERER="gpu-next"`——不能靠默认探测，gpu-next 失败
   会**静默**回退到老 gpu。
2. **libplacebo 编译时把 DOVI 关了**（`-Ddovi=disabled -Dlibdovi=disabled`），
   gpu-next 也拿不到 RPU。已补 libdovi 并全开。
3. **构建缓存让修好的参数没生效**：`.done` 标记只判断「文件存在」，改成
   `-Ddovi=enabled` 后旧标记仍算完成，x86_64 那份 libplacebo 一直是 disabled，
   `PL_HAVE_DOVI` 未定义；libplacebo 用它门控 `PL_HAVE_LAV_DOLBY_VISION`，mpv 又
   用后者门控 DV 元数据映射——RPU 一句都没传给渲染器，于是又紫。
   防复发（`scripts/android/build-mpv.sh`）：`.done` 写「配方」（源码目录 +
   configure/meson 参数），对不上就重建；`ensure_tar` 记包名，换 `MPV_COMMIT`
   会重新解压；`verify()` 硬查 `PL_HAVE_DOVI`，缺了直接 `die`。

**判断 DV 链路通没通只看一行日志**：`[vd] Decoder format:` 是
`yuv420p10 dolbyvision/bt.2020/pq/...` 才对；出现 `auto/auto/auto` 就是 RPU 没
进渲染器，比看截图快。

**P5 必须软解**：`mediacodec-copy` 的帧没有 `AV_FRAME_DATA_DOVI_METADATA`
（实测 `pixfmt=nv12`、`trc bt.1886`、`sig-peak 0`）。`MpvPlayer.setDolbyVisionProfile()`
记住探到的 profile，`load()` 前把 `hwdec` 设 `no`，libplacebo 自己从码流取 RPU。
P7 / P8 不切软解：BL 本身就是 HDR10，硬解只少一层动态元数据，颜色不受影响。

实测：

| 片源 | 结果 |
| --- | --- |
| `samples/p5.mkv`（3840×2160 24p） | `hwdec no`、`prim bt2020 · trc pq · sig-peak 4.93`、fps 24；起播切 120Hz×5 有少量呈现丢弃，之后 0，`decoder-frame-drop-count` 恒 0 |
| `samples/p7-fel.mkv` | `profile=7`、`mediacodec-copy`、`trc pq`、23.976fps、0 丢帧 |
| 4K HDR10（`dv-hdr10-4k-30s.mp4`） | 无 profile、`mediacodec-copy`、`prim bt2020 · trc pq` |
| SMB `Lovesick S01E01`（9.36GB，2160p DV P5） | 探到 `profile=5` 自动软解；20s 窗口 19 帧全在起播 seek，之后 12s 不再增长；cache 14.1s，读速 ~4.8MB/s |

**判颜色只认 mpv 自己的截图**：`screencap` 拿的是 SurfaceFlinger 合成后的输出，
BT2020/PQ → SDR 由系统 tone mapping 负责，和 mpv 截的不是一张图（NFS 上的
`Lovesick` 用 `screencap` 时天空明显过饱和）。同一帧与 Mac 产品播放器比：

| 渲染路径 | 平均 RGB | 结论 |
| --- | --- | --- |
| Mac 产品播放器（gpu-next，参考） | (49,42,37) | 暖肤色 ✓ |
| Android gpu-next（修后） | (41,35,31) | 同比例暖肤色 ✓ |
| Mac `--vf=format:dolbyvision=no`（剥 DV） | (107,88,96) | 品红 ✗ |
| Android 老 gpu（修前） | 整屏洋红 / 紫 | ✗ |

修后两端的 R:G:B 比例是 1.32:1.13:1 与 1.32:1.14:1；Android 整体低约 16%，是手机
PQ 直出、截图再转 SDR 的亮度差，不是色偏。跨端只比**色相 / 串色 / 白是否中性**，
亮度要等真机 HDR 屏看。反过来验「mpv 的 HDR 输出本身没偏色」用合成 HDR10 彩条：
mpv 与 Media3 两条路径 `screencap` 的六条彩条中心色几乎相同。

两个操作坑：4K 软解 seek 后要 3–10 秒才有第一帧，`shot_at` 贴着 `seek_to` 会
「no frame」；`gpu-next + GLES` 下截图偶发 `Taking screenshot failed.`，验证页
重试 3 次。

一键回归：`tests/android/verify-dv.sh [<p5.mkv>] [-s <serial>]` —— 推片源、
`hwdec no` 起播、断言 `Decoder format` 里有 `dolbyvision`（断了退出码 1），再打
一张截图的 `R/G`、`B/G` 供人判读，十几秒就能报出根因 3 复发。

4K P5 软解在骁龙 8 Gen 1 上能跑满 24p，不需要「只降级不软解」的兜底；低端机以后
按 `dumpsys media.codec` 的 DV 解码器能力再分流。

### 7.4.1 HDR 直出的设备前提（模拟器上暴露的真 bug）

`target-colorspace-hint=yes` 是「把 PQ 原样交给显示端」，要求显示端**真的接住
PQ**。设备支持 HDR 只是第一个前提，EGLSurface 能不能用
`EGL_GL_COLORSPACE_BT2020_PQ_EXT` 建出来是另一个：模拟器（SwiftShader）扩展里
连 `EGL_KHR_gl_colorspace` 都没有，带属性建面一律 `EGL_BAD_ATTRIBUTE`，只能无属性
创建 → surface 实际是 sRGB，而 mpv 仍按直出渲染 PQ，HDR / DV 片源整片偏色，
SDR 片源正常。

修法（`mpv_gl.cpp`，命中任一处就永久关直出）：

1. `init_egl` 没有 `EGL_KHR_gl_colorspace`：在**建面之前**就设好
   `target-colorspace-hint=no / target-prim=bt.709 / target-trc=bt.1886 /
   tone-mapping=auto`，首帧就是 tone map 过的；
2. 带 PQ/HLG 属性建面失败、回退成 sRGB surface；
3. 之后 Java 再调 `setHdrPassthrough(true)` 也忽略（否则一次误调又整屏偏色）。

日志出现 `EGL 无 EGL_KHR_gl_colorspace：改由 mpv 做 HDR→SDR tone mapping`
就是走了回退。模拟器上用 mpv 截图验过：8-bit / 10-bit BT.709 彩条与 ffmpeg 解
同一帧差 1–3，HDR10 PQ 彩条白 `(221,221,221)` 完全中性、二次色两通道相等。

HDR10 彩条里 2020 纯色映射到 709 会「变淡」（绿 `(0,214,126)`、蓝 `(0,50,170)`），
这是 mpv 默认的 perceptual gamut mapping，不是矩阵错：`--es mpv_prop
"gamut-mapping-mode=clip"` 下同样三条回到 `(0,233,0)` / `(0,0,231)`。要不要换
默认值，等真机 / 电视上对参考片再定。

判「偏色」看**白色物体是否中性**，不是整帧平均色：`Lovesick` 晾衣绳那个镜头
（NFS 310s 附近）整体偏暖是逆光 + 纱帘的调色，同一帧 HDR 直出与 `force_sdr`
的高光 R−B 都是 +50 左右。

新设备（真机 / 电视 / 盒子）先跑一遍：

```bash
tests/android/verify-color.sh -s <serial>                  # 真机
tests/android/verify-color.sh -s emulator-5554 --hwdec no  # 模拟器
```

脚本自己生成片源、推设备、用 mpv 截图，按「白是否中性 / 主通道够不够亮 / 有没有
串色 / 黑位」判，退出码非 0 即失败，最后打印本次的直出降级日志。

### 7.5 Media3（A6）

`Media3Player` 是 ExoPlayer 的最小封装（SurfaceView + 播放 + 格式回调）；
`Hdr10PlusProbe` 直连 `MediaExtractor` + `MediaCodec` 看**输出格式**。三条路径
在同一台 OnePlus 上：

| 路径 | dataspace | SF 层 `hdr metadata types` |
| --- | --- | --- |
| mpv 软解 | `BT2020_PQ` | 1（SMPTE2086，EGL 扩展写入） |
| Media3 硬解，真 HDR10 | `BT2020_ITU_PQ` | 1（平台 `hdr-static-info`，25 字节） |
| Media3 硬解，HDR10+ | `BT2020_ITU_PQ` | 4（`hdr10-plus-info`，64 字节） |

`4` 是 `HDR10PLUS_SEI` 位标志（SMPTE2086=1、CTA861_3=2、HDR10PLUS=4）。同一份
PQ 片源去掉 ST2094-40 后 `types` 从 4 回落到 1，说明不是误报。**HDR10+ 只能走
Media3。**

4K HDR10（`gen-hdr-sample.py` 生成 3840×2160 / 24p / Main10 / BT.2020 PQ）：
mpv `nv12 · mediacodec-copy`、`mode 6 @ 120Hz`，启动掉 3 帧后不再增长（10 秒样片
启动 6 帧，只是预热时机差异）；Media3 `hvc1.2.6.L153.B0`、
`ColorInfo(BT2020, Limited range, ST2084 PQ, 10bit)`，30 秒全程 **0 掉帧**。

能力与字幕：

- **音频**：OnePlus 有 `audio/ffmpeg`（`OMX.ffmpeg.vtrial.decoder`），DTS 5.1 /
  TrueHD 5.1 样片直接交给 Media3 能播，mpv 侧也正常——这台机器不需要自建 FFmpeg
  音频扩展；缺 `audio/ffmpeg` 的低端盒子才需要，按 `DeviceProfile.audioCodecs` 判。
- **tunneling**：手机 `MediaCodec` 没有 `FEATURE_TunneledPlayback`，等 TV / 盒子
  （B3 / A11）验。
- **PGS**：内嵌 PGS 由 `PgsParser` 出位图 cue，`SubtitleView` 正常显示。
- **外部 `.sup`**：`PgsParser` 只认 Matroska 载荷，裸 `.sup` 每段前还有 13 字节
  `PG` 头，整文件喂进去会越界。新增 `SupSubtitleParser` 按 `.sup` 分段拆，复用
  PCS/ODS/PDS/END 解析；无 `PG` 头的数据原样交给 `PgsParser`。MIME 是
  `MimeTypes.APPLICATION_PGS`（`application/pgs`，写错会被当 SRT 静默丢掉）。
- **外挂字幕选中**：内嵌与外部 PGS 的 MIME 相同、`Format.id` 又不填，reload 后
  内嵌轨会抢回默认。给 `SubtitleConfiguration` 设 `label=文件名`，在
  `onTracksChanged` 里按 label 找回外挂轨并强制选中。
- **mpv 字幕时序**：`loadfile` 后立刻 `sub-add` 会赶在文件打开前，mpv 拒绝。
  `MpvPlayer` 在拿到 duration 前挂起字幕，`pollLoop` 看到片长再补
  `sub-add ... select`；播放中调用仍立即生效。
- mpv 的 `sub-auto` 会默认加载同名外挂字幕，验证内嵌轨时要改名或去掉同名文件。

### 7.6 路由 / 切换 / 回退（A7）

- 自动路由实测：`dv-hdr10plus.mp4` → `engine media3`（「片源带 HDR10+，动态元数据
  交 Media3」），`dv-multitrack.mp4` → mpv（「无 HDR10+，用默认 mpv」）。
  `--es engine` 仍优先于自动路由。
- 切内核：mpv → media3 从 ~4s 接着播到 `pos 7.4s`，轨道 / 章节 / 会话按 Media3
  重建；再切回 mpv 接着播（`pos 27.5s`）。三个坑：
  - 启动 Intent 带 `FLAG_ACTIVITY_NEW_TASK`，直接复制再 `startActivity + finish`
    会把新 activity 也收掉；要新建只带 url / engine / sub / hwdec / force_sdr /
    seek_to / speed / paused 的干净 Intent。
  - mpv 的 `destroy` 会 join 渲染线程并等 mpv 退出，偶尔卡十几秒；放到后台线程，
    主线程只做 `detach`。
  - 帧率匹配在 `onStop` 设 `preferredDisplayModeId=0`；ColorOS 上
    `mActiveModeId` 不一定马上回默认（别的应用也请求了 120Hz），以窗口属性为准。
- 自动重试：Media3 起播失败时把 `positionMs` 放进新 Intent 换 mpv（`fallback=1`）。
  用 `rv20.rm`（Media3 不支持、mpv 能解）实测：`ExoPlaybackException: Source error`
  → 同进程 `engine=mpv` 重新加载，`切换后恢复：0ms`，正常播到 EOF。

### 7.7 原盘入口（A8）

`:player` 的 `DiscSource` 在加载前识别原盘，路由直接判给 mpv：

- **目录**：`<root>/BDMV/index.bdmv` 存在 → `root`；直接给到 `BDMV` 时自动上跳。
- **ISO**：≥ 1MB、32768 处有 UDF 卷识别序列（`BEA01` / `NSR02` / `NSR03`）、
  且前 4MB 出现 `BDMV` 目录名，两个条件都满足才算，避免误判普通 UDF 镜像。
- 验证页状态行显示「原盘 BDMV 目录 / ISO 镜像」。

用合成结构（`movie-disc/BDMV/{index.bdmv,MovieObject.bdmv}` 与合成 UDF
`fake-bd.iso`）验过入口链路：路由都正确，mpv 打开后报 `unrecognized file
format`（没有真实播放列表，符合预期）。**真实原盘播放仍未验**，缺未加密样片。

### 7.8 VFS（A9）

**WebDAV**：`DavVfs` 用 OkHttp（`HttpURLConnection` 不允许 `PROPFIND`），
`Depth: 1` + Basic 认证，解析 `207 Multi-Status`，`HttpUrl.resolve` 处理绝对 /
相对 `href`，目录名 URL 解码。播放时 mpv 设
`http-header-fields=Authorization: Basic ...`；Manifest 的
`network_security_config` 放开局域网明文，HTTPS 仍只信系统 CA。
验证环境：`tests/android/dav_server.py` + `adb reverse tcp:8099`。实测中文目录、
`seek_to 4000` 后 `position=5600 → 7600`、错误密码返回 401 不静默。https 源的
mpv 播放由 mbedTLS 提供（见 7.1），Media3 侧走 OkHttp 自己的 TLS。

**SMB**：`SmbVfs` 用 smbj 0.13.0（SMB2/3，不支持 SMB1），一个连接 + 一个会话，
按共享名复用 `DiskShare`。路径手工拆分 + 每段 `Uri.encode`（`java.net.URI` 拒绝
空格 / `[ ]` / `!`），实测 `Shippuu! Iron Leaguer Blu-ray BOX [BIXA-9069]`、
`[DVDISO]ポケットモンスター…`、`Sailor Moon` 都能进出。

播放不走 SMB：mpv 与 Media3 都不认 `smb://`。`VfsHttpBridge` 把 `VfsFile` 通过
`127.0.0.1:<随机端口>` 暴露成 HTTP，只做 GET / HEAD / `Range`，读块 256KB，
必须 keep-alive（4K 每秒几十次读）；连接线程里的异常只结束当前连接。实测：

| 项 | 结果 |
| --- | --- |
| 浏览 | `影视` 根 20 项；`Bomberman Jetters JP BDMV` 9 项；`乐高幻影忍者合集.S01` 280 项；`大风车` 579 项；BDMV 目录全部可进出，中文 / 空格正常 |
| mpv + 桥接 | `Lovesick S01E01`（9.36GB，DV）→ `seek_to 15000` 后 `pos 15140ms`；cache 1.5s → 27.9s，读速 ~4.5MB/s |
| Media3 + 桥接 | `乐高…S01E22`（3.28GB，SDR HEVC）→ `first frame rendered`，seek 发 `bytes=` → 206，`drops 0` |

`Range` 语义：mpv 先读尾部 moov（`bytes=<size-170K>-`），再按 seek 位置要
`bytes=<offset>-`；Media3 seek 同样发 `bytes=`。两者都走这条路径，没有额外
DataSource。

**NFS**：纯 Kotlin 的 NFSv3 客户端（`core/vfs/nfs/`），不用 libnfs——XDR、
ONC RPC 记录标记、AUTH_SYS、rpcbind `GETPORT`、`MOUNT`、`LOOKUP`、
`READDIRPLUS`（cookie 分页）、`READ` 全在 Kotlin 里，没有额外 native 库要编、
要过 16KB 对齐，也能在 Mac 的 JVM 上直接测。

- 地址 `nfs://host/export/sub`：导出点只有服务器知道，`MOUNT` 从最深路径往上
  逐个试，成功那层就是导出点，余下段用 `LOOKUP` 走。
- 只支持 AUTH_SYS；uid / gid 默认 `65534`（anonymous），按 IP 放行或 all_squash
  的导出直接可读，要特定身份时构造传入。
- 端口走 rpcbind（111），`GETPORT` 查不到时退回 2049；`Nfs3Client` 留了端口注入
  口，单测与「rpcbind 被墙」都能用。播放和 SMB 一样经 `VfsHttpBridge`。

`FakeNfsServer`（测试源码里的真 NFSv3 服务器）端到端覆盖：列目录、导出点在更浅
一层时逐级回退、按偏移随机读、中文目录名、AUTH_SYS 传 uid/gid、桥接 `Range`、
找不到导出点的报错、300 项目录分页。

真服务器：NAS 自己就开了 NFS，导出 `/fs/1000/nfs`（匿名可读）。先在 Mac 的
JVM 上用门控测试 `NfsLiveTest`（`NFS_LIVE=1 NFS_URL=...`）校准协议，
再上手机：

| 项 | 结果 |
| --- | --- |
| Mac JVM 列表 / 读 | `nfs://10.0.0.134/fs/1000/nfs` 自动挂到 3 段导出点，2 项；进 `影视` 20 项；读 95GB ISO 前 4KB 成功 |
| 手机浏览 | `影视` 20 项；`保种2` deep=1 递归 101 项；中文、空格、`@` 全对（URL 每段编码） |
| 手机播 1080p AVC | `seek_to 60000` → `pos=60200ms`，bw ~8.4MB/s，`drops 0`，`hwdec=mediacodec-copy` |
| 手机播 4K DV P5 | `seek_to 300000` → `pos=300884ms`，`DV profile=5` 软解，`prim bt.2020 · trc pq`，`drops` 停在 5，bw ~8.5MB/s |

`adb shell` 同 SMB：路径里的中文先 percent-encode 再传给 `--es nfs` / `--es nfs_play`，
否则设备端 shell 会改字节。脚本见 `tests/android/verify-nfs.sh`。

**未做**：共享名枚举（SMB2 无公开接口，目前用
`tests/android/smb-enum.py` 的 impacket `srvsvc.NetShareEnumAll` 在桌面问，App 里
要求用户知道共享名）；`VfsEntry` 接核心虚拟源（`dv_hub_replace`）。
**SMB / NFS 上的 BDMV 原盘还不能直接播**：桥接只服务单文件，libbluray 需要本地路径或
可列目录的流；当前要播原盘得先下载，或走能直接给出路径的本地存储 / ISO。

### 7.9 手机特性（A10）

- **PiP**：按钮与按 Home 都能进画中画，Surface 缩到 787×443 时 mpv 重建
  `EGLSurface`。重建时置 `force_render`，即使没有新帧也把上一帧重画进新 buffer，
  否则 PiP 窗口是黑的。
- **前台服务**：`PlaybackForegroundService` 把那条 MediaStyle 通知提升为前台
  （id 1001，`foregroundServiceType="mediaPlayback"`）。实测
  `isForeground=true foregroundId=1001`，按 Home 后 position 继续增长
  （2.0s → 14.1s），进程 60 秒后仍存活，`dispatch pause/play` 正常。
- **下载**：`MediaDownloader` 落 `filesDir/downloads`（Android 11+ 的 external
  专属目录部分 ROM 上 adb / 播放器读不到），先写 `.part`，用
  `Range: bytes=<已下载>-` 续传，服务器不回 206 就从头下，完成后改名。实测 11.9MB
  全新下载、5MB 断点续传后 `md5sum` 一致、离线播放正常。
- **边界**：无音轨的片源按 Home 后 Surface 被销毁，mpv 以显示为时钟不再推进，
  position 停住（带音轨不受影响）。播放器还没搬进服务——正式页要把
  MediaSession 与引擎一起搬进去，否则 Activity 被回收时播放会停。
  `Surface.setFrameRate` 在 Surface 已释放时会抛 `IllegalStateException`，统一走
  `setSurfaceFrameRate()`（先查 `isValid` + `runCatching`）。

### 7.9.1 手机播放页（静态布局 + 真实数据映射）

播放页先在 `:ui-phone` 里做成可独立预览的静态稿，再接核心数据——这样间距、
淡出、手势这些细节不依赖 NAS 和内核就能迭代。

**布局**（`PlayerScreen`）：

| 区域 | 手机横屏 | 手机竖屏 |
| --- | --- | --- |
| 顶栏 | 40dp，半透明渐变压在画面上 | 同左，保留状态栏 |
| 视频 | 铺满全屏（接内核后换成 `SurfaceView`） | 宽度 × 16:9，在顶栏下 |
| 底部控制层 | 片名 + 规格 + 时间进度 + 44dp 按钮行合成一个 `PlayerBottomChrome`，背景全透明 | 同一个控件，竖屏只留进度 + 按钮，悬浮在画面内底部 |
| 视频下方 | — | 简介 + 选集横滑 |

`PlayerBottomChrome` 把「片名 / 规格 / 时间进度 / 按钮」放在同一个 Column、
只画一次背景。之前拆成「元信息」和「按钮」两个控件各自加渐变，交界处会露出
色差，看起来像两块内容。

- 3 秒无操作淡出；面板 / 菜单 / 拖动期间不淡出。
- 手势：点击唤出 / 收起、双击暂停、长按 2×、左右滑 seek；锁屏后只剩画面，
  长按解锁。
- 面板：音轨 / 字幕 / 选集 / 媒体信息；齿轮菜单里是内核、媒体信息、画面比例、
  选集、定时关闭。

**数据映射**（`PlayerUiModelFactory`）：核心的 `MediaDetail` / `PlaySource` /
`MediaInfo` 在 `:ui-phone` 里映射成 `PlayerUiModel`，UI 不碰核心类型。缺字段
如实写「未提供」，不编：

- 规格行：内核 / 动态范围 / 分辨率 / 帧率 / 码率，取自 `MediaInfo.video`；
- 音轨：优先 `MediaInfo.audios`，为空时退回 `PlaySource.audioStreams`；
- 字幕：第一项固定「关闭字幕」，语言码转中文（chi / eng / jpn…）；
- 媒体信息面板：视频 / 音轨 / 字幕 / 源 / 续播点；色彩范围缺失时给出显式提示，
  音轨为空时显示「源未提供音轨信息」。

**进入方式**（`PlaybackActivity`）：

```bash
# 演示数据（布局验收）
adb shell am start -n com.dvplayer.app/.PlaybackActivity --es mode landscape

# 真实条目
adb shell am start -n com.dvplayer.app/.PlaybackActivity \
    --es item 'local-smoke:f/p5.mkv' \
    --es config '{"id":"local-smoke","name":"本地冒烟","kind":"local","base":"..."}'
```

源配置落在 `:core` 的 `SourceStore`（SharedPreferences + JSON；密码仍走
`CredentialStore` 的 Keystore）。`--es config` 只用于调试，不落盘。

**实测**（Genymotion Android 12 / x86_64，`samples/p5.mkv`）：片名 `p5`、引擎
`mpv`、源「本地冒烟（local）」、直连、请求头 0；媒体信息面板 7 个视频字段全为
「未提供」，底部提示「源未提供色彩范围」；竖 / 横屏与各面板逐张截图，控制层在
两种方向下都没有「两块背景」的接缝。

#### 7.9.2 接内核（SurfaceView + mpv / Media3）

布局定稿后播放页接到 `:player` 的 `PlayerEngine`，UI 不再模拟状态。

**分层**

| 层 | 职责 |
| --- | --- |
| `PlaybackSession`（app-phone） | 建内核、把 `PlayerEvent` 翻成 `PlayerPlaybackState`、退出写回进度 |
| `PlayerScreen`（ui-phone） | 受控：`playback` 为 null 时用 `PlayerUiModel` 的静态值（截图 / 预览），传入后位置 / 时长 / 暂停 / 倍速 / 轨道全听内核 |
| `PlaybackActivity` | `Load.Ready` 带上 `PlaySource` + `EngineId` + DV profile；`SurfaceView` + `AndroidView` 出画 |

- 窗口 `ColorDrawable(BLACK)` + Compose 根节点 `Color.Transparent`，SurfaceView
  才能透出来；视频按 `videoAspect` 居中，横屏片上下留黑。
- 本地文件走 `EngineRouter`（原盘 / DV / HDR10+ 判定），`--es engine mpv|Media3` 可强制。
- Media3 必须 `attachView(SurfaceView)`（裸 `attach(surface)` 不出画），并用
  `onVideoSizeChanged` 回填真实比例。
- 续播：直接读 `PlaybackMemory.position()`。**不能走 `PlaybackController.resume`**——
  local 源首播 `durationSeconds=0` 会被它当成「时长未知」放弃续播。
- `keep-open=yes`：播完停最后一帧，duration 不归零、画面不黑。
- `eglCreateWindowSurface` 修复：设备没有 `EGL_KHR_gl_colorspace` 时直接无属性建面。
  旧逻辑先试带属性两次，MTK 驱动在连续拒绝后窗口进入坏状态，连无属性创建都
  返回 `EGL_BAD_ALLOC`（HBY 5502 实测，整条出画路径断掉）。
- `mpv_wait_event` 用 200ms 超时 + `quit` 原子标记，不再用 `-1` 无限等：
  `mpv_terminate_destroy` 在 MTK 上不会唤醒阻塞中的 wait_event，`join` 永远卡住，
  退出播放页要等 ANR 超时。

**真机实测**（HBY 5502 / MT6762 / Android 9 / 720×1280 / 无 HDR）

| 项 | 结果 |
| --- | --- |
| 出画（mpv） | ✓ 修 EGL colorspace bug 后正常 |
| 暂停 / 播放 | ✓ |
| 进度条拖动 | ✓ 01:08 → 00:39 |
| ±10 秒 | ✓ |
| 倍速 1.25× | ✓ |
| 长按 2× / 松手恢复 | ✓ |
| 双击暂停 | ✓ |
| 左右滑 seek | ✓ |
| 右侧上下滑音量 | ✓ speaker 0 → 7（系统 `STREAM_MUSIC` 同步） |
| 左侧上下滑亮度 | ✓ 窗口级 `screenBrightness` |
| 退出重进续播 | ✓ 61.6s 记录，重进从 01:08 继续 |
| 横竖屏切换 | ✓ 不重新 loadfile |
| 音轨面板 / 切换 | ✓ 英语 / 日语 eac3 |
| 字幕面板 | ✓ 真实轨道 |
| 播完停在最后一帧 | ✓ 按钮回到「播放」，再点从头播 |
| HDR10 → SDR tone mapping | ✓ 无 colorspace 扩展时自动降级，颜色不偏 |
| Media3 内核 | ✓ `--es engine Media3` 出画、暂停、seek、旋转 |
| DV P5 软解 | ✓ 出画（4K HEVC 10bit，8 线程软解，CPU 约 670%，轻微音画不同步） |

**还没接**：后台播放（把引擎搬进前台服务）、播完自动下一集、SMB / NFS 的
桥接握手（现在仍需验证页 `prepareBridge` 手动建桥）。选集已是真实数据：
播放页的横滑列表来自 `MediaHub.children`，点一集走 `onPlayEpisode` 切集。

#### 7.9.3 详情页与大屏适配（2026-11-28）

手机端界面（媒体库 / 源首页 / 分类 / 搜索 / 详情 / 观看 / 设置 / 添加源）
已接通真实源数据。布局按**窗口宽度**分档（`DvWindow`，`apps/android/design/…/DvWindow.kt`），
不看物理屏幕：分屏、折叠屏展开、桌面窗口拖动都跟着变。

| 窗口宽度 | 档位 | 差异 |
| --- | --- | --- |
| < 600dp | compact | 单列：海报在上、信息在下；海报网格 3 列（设计定稿，大屏手机也不加列） |
| 600–839dp | medium | 详情改「左海报 200dp + 右信息」双栏；网格 4 列；列表页内容收进 760dp 居中 |
| ≥ 840dp | expanded | 详情海报 250dp；网格 5 列 |
| ≥ 1200dp | wide | 网格 6 列 |

底部 tab 在宽屏只限宽居中（`DvSpace.TabBarMaxWidth = 500dp`），不加侧栏。

**详情页背景**（`HeroBackdrop` 的 `imageOnly` 分支，以及平板的整页铺图分支）。
两个档位不一样，因为「文字压不压在图上」决定了对比度从哪里来：

| | 手机（compact） | 平板（medium 以上） |
| --- | --- | --- |
| 图 | 按宽度铺满、完整显示（两边不裁、不拉伸），顶部内容完整 | 同一张图铺满第一屏，下部继续模糊成同源氛围色 |
| 渐变 | 图内 88dp：0 透明 → 图下沿 100% 页面底色（浅色白 / 深色黑），之下全是纯色 | 310dp 起淡、500dp 收完，同样落到页面底色 |
| 文字 | 落在页面底色上：浅色主题深色字，深色主题白字 | 压在图上：恒白字 |

- 手机正文从「图高 + 30dp」开始，图高由背景量出来回调（首帧兜底 240dp），
  所以文字永远不压图。
- 渐变**必须**在图的下沿收满。让它在图外才到 100% 的话，图的下边缘还留着
  一点图像、紧接着是纯底色，会看见一道「渐变没走完就被纯色盖住」的边；
  用「图外再接一段色带」补也试过，色带要从图的底边生成，代价和收益不成比例。
- 手机图上沿不加任何白/黑蒙层，只在顶部叠 120dp、22% 的黑给返回按钮留对比。
- 详情页调色板跟随系统（`isSystemInDarkTheme()`），不强制深色。浅色主题下
  图上的 chip / 圆形操作钮换成白玻璃 + 深色图标，播放按钮改强调色；平板因为
  文字压在图上，这些控件仍走白色半透。

**其它**

- 选集 30 集一段（总数 > 30 才出现「1-30 / 31-60 …」快捷段），进详情自动滚到
  续播集，并用强调色描边高亮。
- 分节间距统一 32dp；「媒体信息」标题上留 24dp。

**真机验证**（HBY 5502 / 720×1280 / density 260）

| 项 | 结果 |
| --- | --- |
| 手机浅色 | ✓ 图完整、下沿 88dp 渐到白、正文深色、白玻璃控件可辨 |
| 手机深色 | ✓ 渐到黑、正文白字、胶囊与圆钮回到白色半透 |
| 平板 720×1280dp（`wm size 1440x2560; wm density 320`） | ✓ 双栏、海报 200dp、白字压在模糊图上 |

> 平板横屏（1280×720dp）用 `wm size` 模拟不了：单边上限 1440 px，只能等真机
> 或桌面窗口。用完必须 `wm size reset; wm density reset`。

### 7.10 工程化（单测 / CI / 凭据 / 控制器）

**单测**（纯 JVM，不依赖设备与 native）：

| 模块 | 覆盖 |
| --- | --- |
| `:player` | 路由顺序（非本地 → 原盘 → DV → HDR10+）、帧率匹配（整数倍 / 25p / 23.976）、DV 配置记录解析、续播与回退、切内核 |
| `:core` | HTTP Range 解析（后缀 / 越界 / 416）、凭据作用域与脱敏 |
| `:player-media3` | `.sup` 分段切分（90kHz→us、截断段、垃圾字节） |

```bash
./gradlew :player:testDebugUnitTest :core:testDebugUnitTest \
          :player-media3:testDebugUnitTest
```

为了让这些逻辑脱离平台跑，拆了四处：
- `FrameRateMatcher.pickMode(List<ModeInfo>, fps)`：不再直接吃 `Display.Mode`。
- `RoutingPolicy`：判定顺序与 `EngineRouter` 的平台探测分开。
- `parseByteRange(header, size)`：桥接的 Range 解析独立成 `ByteRange`。
- `SupSections.split`：`.sup` 只做字节切分，不构造 `Cue`。

**CI**（`.github/workflows/android.yml`）：

| job | 内容 |
| --- | --- |
| `unit-test` | JDK 17 + SDK 36，跑上面三个模块的单测 |
| `apk` | 装 NDK r28 + Rust + `cargo-ndk`、还原/编译 libmpv、编 `arm64-v8a` 核心、编 `:app-phone` + `:app-tv`、`check-apk.sh` 校验 APK |

libmpv 缓存在 `build/android-mpv/arm64/prefix`，key 是
`build-mpv.sh` + `env.sh` 的哈希——改脚本才重编，日常 PR 直接命中。
`build-mpv.sh` 的 NDK prebuilt 目录与 CPU 数已改为按宿主探测
（darwin / linux、`sysctl` / `nproc`），否则 Linux runner 找不到 clang。

**凭据**（`CredentialStore` / `CredentialScope`）：

- SMB / WebDAV 密码用 Android Keystore 的 AES-256-GCM 加密后进
  SharedPreferences，密钥不出 Keystore；解密失败直接删记录、让用户重输。
- 作用域是 `scheme://host:port`，同一台 NAS 换共享不用重输。
- 显式传密码时顺手加密保存，下次不传也能连；日志只打用户名，不打密码。

**播放控制**（`PlaybackController`）：

- 路由（含 4s 超时回退）、续播（显式优先；开头 3s、片尾 5s 内不续播）、
  Media3 → mpv 只回退一次、切内核，全部从验证页搬进 `:player`。
- 壳层只剩建 Surface、建 Activity、调 `load`；验证页改成调用它，
  单测覆盖了上述分支。

**16KB 页实测**（模拟器 `system-images;android-35;google_apis_ps16k;x86_64`，
`getconf PAGE_SIZE` = 16384）：`-Pdvplayer.debugAbi=x86_64` 打包 → 起
`PlayerTestActivity` → 加载 `libmpv.so` → DV 探测、章节、软解、出帧全正常，
没有 `invalid ELF alignment`；单独 `dlopen(..., RTLD_NOW)` + `dlsym("mpv_create")`
也通过。APK 由 `check-apk.sh` 校验：每个 `.so` 都 `Stored`、
`zipalign -c -P 16` 通过、ELF 每个 `PT_LOAD` ≥ `0x4000`。
`android-36.1` 是 pre-release，`system_server` 会反复重启，别用。

顺带修的一个真问题：SwiftShader 不认识 `EGL_KHR_gl_colorspace`，带
`EGL_GL_COLORSPACE_KHR` 一律 `EGL_BAD_ATTRIBUTE`。`rebuild_surface` 现在多了
第三档「不传属性创建」，这类实现（模拟器、部分老盒子）不再黑屏。

**凭据实测**（`tests/android/verify-credentials.sh`）：带密码列一次目录后，
SharedPreferences 里只有 `cred:smb://host:445 → iv:Base64(密文)`；第二次不传
密码能解出同一密码、仍列出 20 项，端到端验了「输入 → Base64 传输 → 解密 →
smbj 登录」整条链路。

早先设备侧出现过 `Authentication failed`，最后确认是测试输入的密码少一位
（同长度在 Mac 上也失败），不是 NTLM / Samba 签名问题。以后再遇到先跑门控的
`SmbLiveTest` 区分「密码错」与「smbj 兼容性」：

```bash
SMB_LIVE=1 SMB_USER=... SMB_PASS=... \
  ./gradlew :core:testDebugUnitTest --tests '*SmbLiveTest*'
```

`SmbVfs` 的认证失败日志打印 user / domain / 密码长度 / 异常类型，不打印密码。

## 8. 设备与验证

| 设备 | 用途 | 必测 |
| --- | --- | --- |
| arm64 真机 / 模拟器 | 逻辑与 UI 回归 | JNI / JSON、导航、ViewModel |
| OnePlus NE2210（Android 16 / 骁龙 8 Gen 1） | 手机主验 | HDR10 / HDR10+、120Hz 帧率匹配、DV P5、AV1 软解 |
| HBY 5502（Android 9 / MT6765） | 低端降级 | SDR、软 / 硬解回退、无直通时 PCM 下混 |
| 低端 Android 9 盒子（Amlogic） | TV 冒烟 | 起播、焦点、4K 掉帧、直通 |
| DV 电视 / 支持 DV 的盒子 | DV / HDR / 直通 | P5 / P8、HDR10、HDR10+、TrueHD 直通 |

**OnePlus NE2210**（JSON：[devices/oneplus-ne2210.json](devices/oneplus-ne2210.json)）：
1440×3216，1080p/1440p × 60/90/120Hz；HDR `hdr10`/`hlg`/`hdr10_plus`，峰值 540nit，
**没有 DV**；AVC/HEVC/VP9 有 `qcom` 硬解，AV1 只有 `c2.android.av1-dav1d` 软解；
音频只有 `pcm_16`、无 HDMI 直通；页大小 4096（16KB 兼容见 §7.10 的模拟器
`dlopen` 实测）；有 PiP。

**HBY 5502**（JSON：[devices/hby-5502.json](devices/hby-5502.json)）：720×1280 单模式
57.5Hz；`supportedHdrTypes` 为空（连 HDR10 都不支持，用来验 SDR 降级）；无 AV1；
无 DV；音频只有 `pcm_16`/`pcm_float`、**没有任何直通**；GLES 3.2；有 PiP。它适合验
「按设备能力兜底」：没有 HDR / 直通 / AV1，路由应全落到 SDR + PCM + mpv / 软解。

**测试约定**（踩过的坑）：

- `am start` 不会亮屏。先 `input keyevent KEYCODE_WAKEUP`、
  `wm dismiss-keyguard`、`svc power stayon true`，否则 Surface 不可见、mpv 不出帧。
- `seek_to` / `shot_at` 是 long extra，`am` 必须用 `--el`；含空格的参数先换
  `%20`，凭据放前面、路径放最后（空格之后的 `--es` 会丢）。
- 续播会干扰测试：不传 `seek_to` 时会跳到上次位置。
- Android 16 上 `/sdcard/Android/data/<pkg>/files/` 的文件 mpv 用路径打不开
  （`loading failed`），放进内部 `filesDir` 正常；下载缓存因此落内部目录。
- Android 16 强制 edge-to-edge，状态栏会压画面，UI 按 inset 处理。
- 16KB 模拟器：`avdmanager create avd -k "system-images;android-35;google_apis_ps16k;x86_64"`
  建出来的 AVD 默认 `hw.ramSize=96M`、320×640，必须改成 4096 / 1080×1920，
  否则 boot 之后 `system_server` 一直重启。启动参数
  `-no-window -gpu swiftshader_indirect -no-audio -no-boot-anim
  -memory 3072 -cores 2`；swiftshader 偶尔 `bad color buffer handle` 崩掉。
- 装完 APK 先 `pm grant <pkg> android.permission.POST_NOTIFICATIONS`，
  否则通知权限对话框会盖住 Activity，Surface 拿不到前台。

```bash
./gradlew :app-phone:assembleDebug
scripts/android/build-mpv.sh --arch arm64 --stage   # 首次或换 mpv 版本
cargo ndk -t arm64-v8a -o core/src/main/jniLibs build -p dvplayer-media-jni --release
adb install -r apps/android/app-phone/build/outputs/apk/debug/app-phone-debug.apk
adb logcat -s DvPlayer:D DvMpv:D DvCaps:D
```

## 9. 风险与未决

### 9.1 未完成项（2026-11-28 盘点）

手机侧的 A0–A10 底层能力已闭环（§7），数据层 JNI 与手机界面也已接通
（§7.1.1、§7.9.3），剩下 TV 大屏、几处边角与需要外部条件的验证。下面按
「为什么还没完」分三类。

**缺外部条件**（代码就绪，等设备 / 素材）：

| 项 | 卡在哪 |
| --- | --- |
| 真机（OnePlus NE2210、HBY 5502） | HBY 5502 已完成播放页回归（§7.9.2）。仍缺：HDR 直出（该机 `HdrCapabilities` 为空）、120Hz 帧率匹配、AV1 软解性能、PiP / 前台服务长跑 |
| DV 电视 / 支持 DV 的盒子 | P5 / P8 在真实 HDR 屏上的观感（直出 vs tone mapping）、DV 分级与徽标；模拟器只有 SDR + SwiftShader |
| TV / 盒子 + AVR | A11 冒烟、tunneling、HDMI → AVR 直通、遥控器键位都没验 |
| 未加密的蓝光原盘（ISO / BDMV） | A8 只验了合成结构的路由；真实播放列表、章节、无缝分支、多角度未验（§7.7） |
| PGS / AV1 / VP9 样片 | 缺片源；mpv 侧 PGS、AV1 软解性能未测（PLAN §5.1） |

**代码待实现**：

| 项 | 现状 |
| --- | --- |
| 手机 UI（`ui-phone`） | 库 / 源首页 / 分类 / 搜索 / 详情 / 观看 / 设置 / 添加源都已接通真实数据，按窗口宽度分档做平板适配（§7.9.3）；播放页接内核、选集可切集（§7.9.2）。还缺后台播放（引擎搬进前台服务）、播完自动下一集 |
| TV 大屏 UI（B1 / B2） | `:ui-tv` 只有 `TvApp()` 50 行、`:app-tv` 只有 `MainActivity`，而且 `app-tv` 连 `:player` / `:core` 依赖都没有；TV 上现在跑不了播放回归 |
| TV 兼容矩阵（B3） | TV 默认内核、tunneling 取舍、HDMI 直通策略未定（§10） |
| 原盘边读边播（B5，可选） | SMB / NFS 上的 BDMV 不能直接播：桥接只服务单文件，libbluray 要本地路径或可列目录的流（§7.8） |
| SMB 共享名枚举 | App 内没有，得用户知道共享名（桌面用 `tests/android/smb-enum.py` 代查） |
| `VfsEntry` 接核心虚拟源 | `dv_hub_replace` 未接（§7.8） |
| TLS 源级「允许自签名」 | 校验已能开（`--es tls_verify 1`），开关还没进 UI |
| Android 16 本地网络访问 | 权限声明待 SDK 文档确认 |
| 播放器搬进前台服务 | 现在只有通知与 Surface 在前台服务；Activity 被回收时播放会停（§7.9 的边界） |
| NFS 非匿名导出 | uid / gid 只能构造时传，源配置里没暴露（§7.8） |
| 发布 | 两个 applicationId 的商店条目；手机侧下载是否 v1 必做 |

**待验**：

| 项 | 为什么现在验不了 |
| --- | --- |
| 网络源（fnos / Emby / Jellyfin）数据层 | JNI 链路只在 `local` 源上跑过 19 步；三家的登录、分页、搜索合并还需要可用的服务器（NAS 上没跑这些服务） |
| Media3 全链路 | 模拟器 `h264_mediacodec` 没有 JVM、10-bit HEVC 报 `ERROR_CODE_DECODING_FAILED`，只能在真机回归 |
| HDR10+ 自动切 Media3 | 路由单测过了，真机端到端（含切内核后续播）待验 |
| HDR 直出 | 模拟器没有 `EGL_KHR_gl_colorspace`，只验了回退（§7.4.1）；真机 PQ surface + 系统 HDR 待验 |
| 音频直通 | `ao_audiotrack` 的 IEC61937 未验，缺 AVR |
| 16KB 页真机 | 模拟器端到端过了（§7.10），真机待设备 |
| DV P5 观感 | 颜色已在模拟器闭环（§7.4，`verify-dv.sh` 可一键回归），arm64 那份 libplacebo 一直是对的；真实 HDR 屏上的观感仍待设备 |

### 9.2 风险登记

风险登记在 [PLAN.md](PLAN.md) §7，与 Android 直接相关的：

1. **libmpv 构建链**：已接 CI 缓存（§7.10）；16KB 页在 `android-35`
   16KB 模拟器上装 APK 起播验过，剩下真实 16KB 设备。
2. **TV / 盒子的 HDR 与 tunneling**：手机侧已验，盒子合成器只认 tunneled HDR 时
   要 Media3 补。
3. **mpv 的音频直通**：`ao_audiotrack` 的 IEC61937 支持未验证；不支持就路由 Media3。
4. **SMB 认证**：已解决，早先的 `Authentication failed` 是测试时密码输错
   （长度都对不上），不是设备侧 NTLM / Samba 签名问题；带密码与只带加密凭据
   两条路径都已实测通过（§7.10）。
5. **NFS**：已实测。协议层有回环上的真实 NFSv3 服务器测试，真机对 NAS
   的 `/fs/1000/nfs` 导出也跑通了浏览与 4K DV P5 起播（§7.8）。剩下的是
   极端情况：需要非匿名 uid 的导出、rpcbind 被墙只开 2049。

### 9.3 未决项（等产品决定）

| 未决项 | 待定 |
| --- | --- |
| TLS | 内置 Mozilla CA 包已接（`--es tls_verify 1` 即校验，实测自签被拦、公网可播）；还差源级「允许自签名」开关进 UI |
| applicationId | `com.dvplayer.app` / `com.dvplayer.app.tv` 两个商店条目 |
| 下载 | 手机 v1 是否必须；TV 明确不做 |
| NAS 原盘 | v1「先下载到缓存」是否可接受；边读边播排 B5 |
| 投屏 | Cast 明确列为非目标 |
| Android 16 | 本地网络访问限制，待 SDK 文档确认权限声明 |
| NFS 身份 | 哪些 NAS 的导出需要非匿名 uid；是否在源配置里暴露 uid/gid |

## 10. M2-B TV

| # | 阶段 | 内容 |
| --- | --- | --- |
| B1 | 大屏 UI | Hero + 海报行、库、详情、搜索（屏幕键盘）、设置 |
| B2 | 播放器控制 | 遥控器键位、进度条、轨道 / 字幕面板、信息层（含当前内核） |
| B3 | 兼容矩阵 | tunneling 取舍、HDMI → AVR 直通、老盒子降级、TV 默认内核最终值 |
| B4 | 交付 | 侧载 APK（含更新检查）、Play TV 材料 |
| B5 | 原盘边读边播（可选） | libbluray 自定义 stream + 缓存 |
