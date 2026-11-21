# ADR-0005 徽标：明确区分 FEL / MEL

- 状态：已接受
- 日期：2026-11-19

## 决策

| 条件 | 徽标 |
| --- | --- |
| profile 7 + EL 有残差 | `DV P7 (FEL)` |
| profile 7 + EL 无残差 | `DV P7 (MEL)` |
| profile 5 | `DV P5` |
| profile 8.x | `DV P8.x` |
| HDR10+ | `HDR10+` |
| HDR10 | `HDR10` |
| Android 设备解码 | `DV`（不标层类型） |

## 理由

桌面上“DV”和“DV FEL”是两种画质。统一写 “Dolby Vision” 会和电视端点亮 DV 的
预期混淆，也会掩盖 FEL 是否真的生效。

## 实现

- **profile 来自 mpv**：当前打包的 mpv 在 `current-tracks/video` 里报
  `dolby-vision-profile`（早期 0.42 版本没有这一项，只能看
  `video-params/colormatrix=dolbyvision`）。P5 / P7 / P8 直接用这个值。
- **EL 类型必须自己解析**：mpv 不报 FEL / MEL。`core/media/src/dovi.rs`
  读播放地址的码流前缀（本地文件直接读，网络源用 `Range` 取前 8 MB），
  扫 HEVC type 62 NAL，交给 `dolby_vision` crate 解析 RPU 的
  `disable_residual_flag`：`false` → FEL，`true` → MEL。不依赖外部
  `dovi_tool`，Windows / macOS 共用同一份。
- 解析只在 `dolby-vision-profile == 7` 时异步做一次，按条目缓存；
  失败只记日志，徽标退回 `DV P7`，不阻塞播放。
