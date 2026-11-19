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

- mpv 暴露 `dolby-vision-profile`，但不告诉 FEL/MEL。
- `core/dovi` 用 libdovi 解析第一个 RPU 的 `disable_residual_flag`：
  `false` → FEL，`true` → MEL。
- 在 `file-loaded` 时计算并缓存为自定义属性，UI 只读结果。
