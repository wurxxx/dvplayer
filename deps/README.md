# 依赖

M0 起就走项目内源码构建，全部装进 `prefix/`，不碰系统目录、不依赖 Homebrew：

```bash
./scripts/build-deps-macos.sh
```

| 包 | 版本 | 说明 |
| --- | --- | --- |
| FFmpeg | `n9.0.2` | `--disable-autodetect --disable-x86asm`，保留 `dovi_split` |
| libplacebo | `v7.387.0` | 只开 OpenGL；`PL_API_VER=387`，有 `enhancement_layer` |
| libass | `0.17.4` | mpv 0.42 的硬依赖 |
| mpv | `v0.42.0` | `-Dgpl=false`，关掉用不到的 X11 / Wayland / Lua 等（见 `scripts/build-deps-macos.sh`） |
| dovi_tool | `2.3.4` | 官方 universal 预编译，放在 `tools/bin/` |

## 为什么不用 Homebrew

本机是 Intel + macOS 26，Homebrew 已把该配置列为 Tier 3，不再提供 bottle；
而且本机 `/usr/local` 权限异常，`brew install` 直接失败在不可写的
`python@3.9/site-packages`。所以全部自建。

## 为什么不用 IINA 的库

IINA 1.5.0 内置 `libplacebo.360`（`PL_API_VER 360 < 370`），没有 FEL API。

## 为什么 M1 还要继续 vendored

libplacebo 7.387 换过 soname，FFmpeg 9.0 也是 ABI break。产品不能依赖用户机器上
碰巧装对的版本，否则会出现“能启动、只有 BL、不报错”的经典问题。

M1 的构建目标：

- 固定 tag + commit，记录在 `deps/pins.env`
- 全部构建到 `prefix/`，通过 `PKG_CONFIG_PATH` 优先链接
- Windows 用 MinGW-w64 出 C ABI DLL，不往 MSVC 里混 MinGW 产物
- macOS universal（arm64 + x86_64）

## 版本自检

```bash
./scripts/preflight.sh
```
