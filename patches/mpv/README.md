# mpv 补丁

目前**没有**需要打的补丁。目录留着，方便以后再需要时放。

## 曾经有过的补丁：0001-view-cametal-layer

早期 mpv 的 `video/out/mac/view.swift` 在 `isOpaque` 里写的是 `layer as? MetalLayer`，
而 `MetalLayer` 定义在 `metal_layer.swift`，那个文件只在 `-Dmetal=enabled` 时进编译。
我们编的是 render API（`-Dvulkan=disabled`、不带 metal），`MetalLayer` 类型不存在，
编译会报找不到类型。补丁做了两件事：

1. `import QuartzCore`（为了 `CAMetalLayer`）
2. `layer as? MetalLayer` → `layer as? CAMetalLayer`

## 为什么删掉了

mpv commit `1eb941f`（2026-11 用的版本）上游已经自己改成了 `CAMetalLayer`，
补丁的第 2 处改成「改一个不存在的东西」，`git apply` 直接失败：

```
error: patch failed: video/out/mac/view.swift:29
error: video/out/mac/view.swift: patch does not apply
```

第 1 处（`import QuartzCore`）也不需要了：`view.swift` 只 `import Cocoa`，
而 Cocoa 会转发 QuartzCore，`CAMetalLayer` 直接可用。

这个失败只在干净 checkout 上出现。开发机的 `build/src/mpv` 是历史遗留的
「补丁已应用」状态，所以本机一直没暴露——CI 上第一次跑就撞上了。

以后再给 mpv 打补丁时，注意两点：

- **在干净 checkout 上验证**：`git clone` 一份到临时目录，`git apply --check` 过一遍。
  本机 `build/src/mpv` 可能已经带着上次的改动，不能作为验证依据。
- **补丁要跟着 mpv commit 走**：`MPV_COMMIT` 在 `scripts/build-deps-macos.sh` 里，
  换 commit 时补丁的上下文行很可能对不上，要么更新补丁要么删掉。
