# core/dovi

Dolby Vision 元数据处理。

M0 用现成工具做过验证：

- `ffmpeg -bsf:v dovi_split=mode=el_rpu` 拆增强层
- `dovi_tool info` 读 `disable_residual_flag` 判定 FEL/MEL

现在的实现（M1）在 `core/media/src/dovi.rs`：

- Rust crate `dolby_vision` 解析 RPU，输出 `profile` / `el_type` /
  `disable_residual_flag`
- 读播放地址的码流前缀（本地文件直接读，网络源 `Range` 取前 8 MB），
  Annex-B / 4 字节长度前缀 / MKV 宽松扫描三种 NAL 布局都支持
- C ABI `dv_probe_dovi(url, headers_json, proxy)` 给两端共用
- 给 UI 提供徽标数据：`DV P7 (FEL)` / `DV P7 (MEL)` / …
- 不负责解码或合成，那是 mpv/libplacebo 的事

不再依赖外部 `dovi_tool`（M0 的脚本仍保留，用来做手工排查）。
