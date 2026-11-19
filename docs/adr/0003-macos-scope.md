# ADR-0003 macOS 首版范围：render API + HDR10

- 状态：已接受
- 日期：2026-11-19

## 背景

macOS 没有可靠的 `wid` 嵌入；render API 只有 legacy `gpu` 后端，
拿不到 gpu-next 的 DV 处理。IINA 等项目的 HDR/DV 问题也印证了这条路的难度。

## 决策

- v1 使用 libmpv render API + `NSOpenGLView`。
- 只保证 HDR10（或 SDR tone-map），**不承诺 Dolby Vision**。
- 不引入 Metal、不引入 MoltenVK。
- DV 支持推迟到 M3 之后，届时再评估：
  1. 上游合并 gpu-next render API（#18607 方向）；
  2. 自维护补丁；
  3. 放弃 macOS 的 DV。

## 后果

- macOS 在宣传上不能写“支持 Dolby Vision”。
- HDR10 在 SDR 显示器上需要明确的回退与提示。
- VideoToolbox 的矩形纹理路径是已知坑，M0 要压测。
