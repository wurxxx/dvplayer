## 主要修复

### macOS：HDR10 片源播放偏暗

macOS 版走 mpv 的 render API，没有 swapchain，gpu-next 拿不到显示器信息，
HDR→SDR 会回落到 203 nit 的参考白，画面明显发暗。《奥德赛》01:50 同一帧
灰度均值 78.8、中位数 97，属于一眼能看出来的暗。

现在按播放窗口所在屏幕计算目标亮度（SDR 白点取 100 nit），tone mapping
用 mobius，窗口拖到另一块屏幕会重算，换屏不用重开视频。SDR 片源实测不变
（灰阶 125），DV P5 / P7 的黑位与高光也复查过，没有退化。

### 两端新增「HDR 亮度参考」

同一块屏幕在不同人眼里亮暗感受不一样，所以把 HDR→SDR 的参考白点做成了可调：

- macOS：设置 → 播放 里的滑块，或播放页「更多」菜单；自动 = 100 nit，可调 60–200
- Windows：设置 → 播放 里的下拉，或播放页「更多」菜单；自动 = 跟随系统（实测 80 nit）

播放中切换立即生效，设置会落盘；设置页改完，已经开着的播放窗也会跟着变。
只影响 HDR 片源的映射，SDR 内容不受影响。

### 打包与 CI

- macOS：bundle 里所有 dylib 的最低系统版本统一钉到 13.0；补齐 @rpath 形态的传递依赖
- macOS arm64 抢不到 GitHub runner 时自动补票，产物可以直接补进指定 Release
- Windows 打包进 CI，和 macOS 共用同一个 Release
