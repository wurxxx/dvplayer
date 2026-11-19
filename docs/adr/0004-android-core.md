# ADR-0004 Android：Media3 主 + libass NDK

- 状态：已接受
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
