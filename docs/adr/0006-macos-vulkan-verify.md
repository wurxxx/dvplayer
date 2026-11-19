# ADR-0006 macOS 增加 Vulkan 版 mpv（验证用，不进产品）

- 状态：已接受
- 日期：2026-11-19
- 相关：ADR-0001、ADR-0003

## 背景

ADR-0003 决定 macOS v1 用 libmpv render API + legacy `gpu`，只保证 HDR10。
M0 实测暴露了它的一个硬限制：

- P5 的像素是 IPTPQc2，legacy `gpu` 会把 `DOLBYVISION` 降级成 BT.2020-NCL，
  画面偏紫（见 `docs/M0.md` §5.3）；
- 正确的 DV 整形（`pl_shader_dovi_reshape`）与增强层合成只在 **gpu-next** 里；
- libmpv 的 render API **没有 gpu-next 后端**：
  `video/out/vo_libmpv.c` 的 `render_backends[]` 只有 `render_backend_gpu` 和
  `render_backend_sw`。即使给 mpv 编上 Vulkan，`MPV_RENDER_API_TYPE_OPENGL`
  仍然只会走 legacy `gpu`。

也就是说：Vulkan 不能把 DV 带进 render API，但可以让 mpv 自己的窗口
（cocoa-cb + `--gpu-context=macvk`）跑 gpu-next，从而：

1. 验证 P5 的正确颜色（对照本机的紫色）；
2. 在本机跑 A2（FEL 开/关同帧 A/B），不必等 Windows；
3. 验证 P7 的 EL 是否真的参与重建。

## 决策

新增 **`prefix-vk/`**：一套独立的 Vulkan 构建（MoltenVK + Vulkan-Loader +
glslang + libplacebo + mpv），由 `scripts/build-vk-macos.sh` 可重入地构建。

- 它是**验证工具**，不改变产品架构：产品仍用 `prefix/` 的 libmpv render API。
- 不把 MoltenVK 打进最终 App；`prefix-vk/` 不进仓库、不进发行包。
- `scripts/mpv-vk.sh` 是对它的唯一入口（设置 `VK_ICD_FILENAMES`、`DYLD_LIBRARY_PATH`，
  默认 `--vo=gpu-next --gpu-context=macvk`）。
- `scripts/fel-ab.sh ... --vk` 用这条路径跑 A2；`m0-p7-report.sh` 会自动优先用它。

## 后果

- 本机可以看 P5 的正确颜色、可以跑 A2；A4（Windows `wid`）仍需 Windows 机器，
  但 A2 不再被它阻塞。
- 构建链变长：需要 cmake（脚本用 pip 装）、swiftc、glslang 与 Vulkan-Loader；
  首次约 10–15 分钟，全部落在 `build/` 与 `prefix-vk/`。
- 两条 mpv 构建并存，容易混淆。README 与脚本必须写清：
  **`prefix/bin/mpv` = 产品路径（HDR10）；`prefix-vk/bin/mpv` = DV 验证路径**。
- 上游如果合并 gpu-next 的 render API（mpv #18607 方向），可以把这条验证路径
  收回到产品里；在那之前，产品与验证分离。

## 验证（2026-11-19）

- 环境：Intel macOS 26 / AMD Radeon RX 560 / MoltenVK 1.4.2 / Vulkan-Loader 1.4.363
- `--vo=gpu-next --gpu-context=macvk` 起播成功，`VO: [gpu-next] 3840x2160 yuv420p10`
- `samples/p5.mkv` 的紫色消失，肤色恢复自然（对照截图见 `docs/M0.md` §5.3）
- `fel-ab.sh samples/p5.mkv 8 --vk`：PSNR 52.8 dB / SSIM 0.994
  （P5 没有 EL，A/B 应几乎相同，符合预期）
- 已知告警：`VK_ERROR_FEATURE_NOT_PRESENT: Metal does not support disabling primitive restart`
  不影响出画。
