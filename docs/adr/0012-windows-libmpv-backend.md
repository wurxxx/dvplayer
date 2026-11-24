# ADR-0012：Windows 加一条进程内 libmpv 后端（保留子进程为默认）

- 状态：已接受（实现完成，待真机验证 DV）
- 日期：2026-11-24

## 背景

ADR-0009 定了 Windows 用 `mpv.exe` 子进程 + JSON IPC，理由是「不需要自己持有
libmpv 句柄」「可以单独升级 mpv」「进程管理是现成的」。

这条路径一直工作正常，DV P7 FEL 在真机上验过（`docs/M0.md` 的 A4/A5）。
但它带来一个副作用：**发布包必须带完整的 `mpv.exe`**，而这个官方构建是静态
链接的单文件，把 ffmpeg 全部解码器、libass、libplacebo、全部滤镜都编进去了，
116 MB。

实测 `DvPlayer-0.1.1-win-x64-portable.zip` 的构成：

| 部分 | 未压缩 |
| --- | --- |
| `mpv\mpv.exe` | 116.2 MB |
| .NET 运行时（self-contained） | ~85 MB |
| 其余（WPF、语言资源等） | ~71 MB |
| 合计 | 272.6 MB（zip 后 112.7 MB） |

`mpv.exe` 一个人就占了 43%。

## 决策

**保留子进程后端为默认，新增一条进程内 `libmpv` 后端，用环境变量切换。**

```text
DVPLAYER_MPV_BACKEND=libmpv   →  进程内 libmpv-2.dll
（不设）                       →  子进程 mpv.exe（默认，已验证）
```

实现上用 `IMpvEngine` / `IMpvControl` 两个接口把播放层和 `PlayWindow` 隔开，
两个后端各自实现，`PlayWindow` 一行都不用改。

关键点：**仍然用 `wid` 选项，不用 render API。**

`wid` 让 mpv 自己把画面画进壳的 HWND，和子进程的 `--wid` 是同一套 gpu-next
VO 代码路径。所以 DV P7 的拆层、EL 合成、DV 整形逻辑完全一致，只是"谁来装
这份 mpv"不同。用 render API 的话要自己建 D3D11 设备、管交换链、处理 resize，
代码量翻倍，而且 `target-colorspace-hint` 还得手工接——收益为零，风险很高。

## 为什么不直接替换成默认

1. **崩溃隔离消失**：mpv 和壳同进程，mpv 崩了整个 App 一起死。子进程方案里
   崩的只是 `mpv.exe`，壳还在，用户能重试。
2. **DV 链路没验证**：虽然 `wid` 路径理论上和子进程一致，但"理论上"不等于
   "验证过"。真机上必须重新确认 `[el_pair]`、`dolbyvision`、0 掉帧。
3. 现版本能用，没有必须替换的压力。

## 收益

`mpv.exe` 换成 `libmpv-2.dll` + 它依赖的几个 dll（shinchiro 构建解压后的
`lib*.dll` 集合），预计包体积从 112 MB 降到 45 MB 左右。具体数字要打包后实测。

另外顺手做了两项零风险瘦身：

- `SatelliteResourceLanguages` 限定 `zh-Hans;zh-Hant;en`：编译期就不生成其余
  156 个语言资源 dll（约 8 MB）。
- `-Backend` 参数让打包脚本按后端选择拷 `mpv\` 目录还是平铺 `lib*.dll`。

## 待验证

- [ ] 进程内后端在 Windows 真机上编译通过
- [ ] DV P7 FEL 播放：`[el_pair]` 出现、`dolbyvision` 色彩、0 掉帧
- [ ] 换集 / 关窗 / 强杀时不泄漏 mpv 实例
- [ ] 打包体积实测
- [ ] 长时间播放的内存稳定性（同进程，mpv 的内存增长会算在壳头上）
