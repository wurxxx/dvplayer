# core/dovi

Dolby Vision 元数据处理，M1 开始实现。

M0 的目标（A1/A2）先用现成工具完成：

- `ffmpeg -bsf:v dovi_split=mode=el_rpu` 拆增强层
- `dovi_tool info` 读 `disable_residual_flag` 判定 FEL/MEL

M1 之后在这里封装：

- 解析 RPU，输出 `profile` / `el_type` / `disable_residual_flag`
- 给 UI 提供徽标数据：`DV P7 (FEL)` / `DV P7 (MEL)` / …
- 不负责解码或合成，那是 mpv/libplacebo 的事

语言选型待定：C++ 直接调 libdovi 的 C API，或 Rust 暴露 C ABI。
