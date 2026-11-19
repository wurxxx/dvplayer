# m0-render

最小 libmpv render API 验证程序，用于 M0 的 A3：

- 证明 `MPV_RENDER_API_TYPE_OPENGL` + `NSOpenGLView` 能正确出画；
- 打印 `video-params`、`dolby-vision-profile` 与 mpv 日志；
- 为后续 macOS 壳提供可复用的最小骨架。

## 构建

```bash
./build.sh
```

依赖 `prefix/` 里的 libmpv（先跑 `scripts/build-deps-macos.sh`）。

## 运行

```bash
./m0-render /path/to/sample.mkv 10
```

- 第二个参数是运行秒数，默认 10。
- `q` 退出，空格暂停。
- 输出里的 `[file-loaded]` 段是本程序自己打印的属性，其余是 mpv 日志。

## 它不能证明什么

- 不能证明 DV：render API 只有 legacy `gpu`，没有 gpu-next。
- 不能替代 Windows 的 D3D11 路径验证。
- 没有 HDR 显示器时，只能验证渲染是否正常，不能目视验收 HDR10。
