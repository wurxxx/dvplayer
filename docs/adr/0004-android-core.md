# ADR-0004 Android：Media3 主 + libass NDK

- 状态：部分被 [ADR-0014](0014-android-dual-engine.md) 取代（2026-11-25）
- 日期：2026-11-19

## 决策

- 播放内核用 Media3（ExoPlayer），不用 libmpv。
- ASS/SSA 字幕用 NDK 编译的 libass 自绘。
- DV 能力运行时探测：支持则硬件直通，不支持则播 BL 轨并标 HDR10。
- 不给 Android TV 挂 libmpv 软解兜底：4K HEVC 在盒子上跑不动。

## 理由

- Android 的硬件解码、HDR、音频直通都绑在 MediaCodec / AudioTrack 上，
  Media3 已经把这条链路趟平。
- Media3 不支持 ASS/SSA，必须补 libass。
- 没有开源方案能在 Android 上做 P7 FEL 软件合成；承诺 FEL 是错误的产品预期。

## 后果

- Android 端与桌面端是两套内核，只共享协议、资源和设计。
- P7 FEL 片源在 Android 上统一走回退路径，UI 要明确提示。
- libass 需要额外的 NDK 构建与字体打包。

## 修订（2026-11-25）

蓝光原盘确定为硬需求后，本 ADR 的「Android 只用 Media3、不给 TV 挂 libmpv」
被 [ADR-0014](0014-android-dual-engine.md) 取代：

- 内核改为双引擎，mpv 默认、Media3 第二；
- 原盘走 mpv 原生 libbluray，不再自写 UDF / MPLS / `192→188` DataSource；
- ASS / SSA 由 mpv 的 libass 渲染（含 MKV 内嵌字体），**不再需要单独的 libass NDK**；
- DV P5 由 gpu-next 整形，不再需要定制渲染路径；
- DV P7 FEL 与 `「不给 TV 软解 4K」` 的结论不变：mpv 仍走 `hwdec=mediacodec` 硬解，
  P7 只播 BL。
