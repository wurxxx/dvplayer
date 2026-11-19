# 依赖

M0 直接使用 Homebrew 的二进制包，目的是尽快验证行为：

```bash
brew install mpv ffmpeg libplacebo dovi_tool
```

M0 用到的版本：

| 包 | 版本 |
| --- | --- |
| mpv | 0.42.0 |
| ffmpeg | 9.0.2 |
| libplacebo | 7.387.0 |
| dovi_tool | brew 当前版本 |

## 为什么 M1 要改成 vendored

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
