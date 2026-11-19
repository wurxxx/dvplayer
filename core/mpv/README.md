# core/mpv

桌面端共享的 libmpv 封装（C++），M1 开始实现。

职责：

- 封装 `mpv_handle` 生命周期、属性观察、事件分发
- 支持两种模式：
  - `WindowBinding`：Windows，`wid` + `vo=gpu-next`
  - `RenderApi`：macOS，`MPV_RENDER_API_TYPE_OPENGL`
- 对 .NET 暴露薄 C ABI；对 Swift 暴露 Objective-C++ 桥

接口草案见 [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)。

M0 阶段不写这个模块，直接用 CLI 验证行为。
