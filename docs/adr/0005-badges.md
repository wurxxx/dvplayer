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

- **mpv 0.42 并不暴露 DV profile**（2026-11-19 实测）：
  `${dolby-vision-profile}` 展开为 `(error)`，`--list-properties` 里也没有这一项。
  mpv 只给到 `video-params/colormatrix=dolbyvision`、`primaries=bt.2020`、
  `gamma=pq`、`sig-peak`。
- 因此“是不是 DV”看 `colormatrix`；
  **profile 与 EL 类型必须自己解析**——`core/dovi` 用 libdovi 读 RPU，
  同时拿到 `dv_profile` 和 `disable_residual_flag`：
  `false` → FEL，`true` → MEL。
- 解析在 `file-loaded` 之后做一次（RPU 在第一帧就完整），结果缓存为自定义属性，
  UI 只读结果，不重复解析。
