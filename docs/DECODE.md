# 解码能力验证（Windows）

> 2026-11-19。目标是回答一个问题：**这套壳 + mpv 能不能解并渲染 4K/8K、120 fps、
> HDR10 / HDR10+ / HLG**。Dolby Vision 的 P7 FEL 单独记在 `M0.md`。

## 1. 结论

| 能力 | 结论 | 依据 |
| --- | --- | --- |
| 4K HEVC 10bit | 支持 | `d3d11va` 硬解，解码器丢帧 0 |
| 8K HEVC 10bit（7680×4320） | 解码支持 | `d3d11va` 硬解；纯解码 67.7 fps |
| 120 fps | 解码支持 | 4K120 纯解码 162.6 fps |
| HDR10（PQ / BT.2020） | 支持 | `prim=bt.2020 trc=pq` |
| HDR10+（ST2094-40 动态元数据） | 支持 | 每帧解码出 `HDR10+ SEI` side data（UUID `2ca2de09…`） |
| HLG（ARIB STD-B67） | 支持 | `prim=bt.2020 trc=hlg` |
| 渲染吞吐（这台机器） | 4K 接近满帧，8K 不够 | 4K60 ≈ 57 fps，8K60 ≈ 15 fps |

**一句话**：格式和解码都过关，`decoder-frame-drop-count` 全程为 0；瓶颈在
GPU 渲染——这台 Iris Xe 上 8K 只能跑约 15 fps，4K 能到 55–60 fps。

## 2. 环境

| 项 | 值 |
| --- | --- |
| 机器 | LAPTOP-IUKJEUNQ（Windows 11 家庭版） |
| GPU | Intel Iris Xe Graphics，驱动 27.20.100.9565 |
| 屏幕 | 2160×1440 @ 60.001 Hz，**SDR** |
| 播放器 | mpv v0.42.0-38（shinchiro 2026-11-11），libplacebo v7.391，gpu-next + d3d11 |
| 壳 | `DvPlayer.Windows`（WPF + `HwndHost` + `mpv --wid`） |

屏幕是 SDR，所以 HDR 内容在这里走 tone mapping 到 SDR；
"HDR 元数据被正确识别"和"HDR 信号直通到 HDR 屏"是两件事，后者要等外接 HDR 屏。

## 3. 样片

全部用 `ffmpeg` 合成（`testsrc2`），时长 8–10 秒，目的是验证解码链路和元数据，
不代表真实影片的码率/复杂度。

| 文件 | 编码 | 备注 |
| --- | --- | --- |
| `uhd-4k120-hdr10.mp4` | HEVC 10bit，QSV，135 MB | 3840×2160@120，PQ/BT.2020 |
| `uhd-4k60-hlg.mp4` | HEVC 10bit，QSV，68 MB | 3840×2160@60，HLG/BT.2020 |
| `uhd-4k60-hdr10plus.mp4` | HEVC 10bit，libx265，20 MB | 3840×2160@60，PQ + 逐帧 ST2094-40 |
| `uhd-8k60-hdr10.mp4` | HEVC 10bit，QSV，220 MB | 7680×4320@60，PQ/BT.2020 |
| `p7-fel.mkv` | HEVC P7 双层 | 3840×2160@23.976，见 `M0.md` A1 |

生成命令（在 Windows 上跑，`D:\dvplayer\tools\ffmpeg.exe`）：

```powershell
# 4K120 HDR10
ffmpeg -f lavfi -i testsrc2=s=3840x2160:r=120 -t 10 -vf format=p010le `
  -c:v hevc_qsv -global_quality 26 -profile:v main10 tmp.mp4
ffmpeg -i tmp.mp4 -c copy `
  -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9 `
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc uhd-4k120-hdr10.mp4
```

`hevc_metadata` 这一步是必需的：QSV 编码器不写 VUI 色彩字段，直接播放会被当成
`bt.1886`（SDR）。HLG 用 `transfer_characteristics=18` + `-color_trc arib-std-b67`。

HDR10+ 样片用 libx265 的 `dhdr10-info` 注入，JSON 是 LEGACY 格式（顶层数组，
每帧一项，含 `NumberOfWindows` / `LuminanceParameters` / `BezierCurveData`），
生成见 `build/dl/x265/hdr10plus-legacy-600.json`。

## 4. 方法

三轮，分别隔离"能不能解""解得多快""画得动吗"：

| 轮 | 命令要点 | 回答的问题 |
| --- | --- | --- |
| A | 壳 + `mpv --wid` + IPC，读 `video-params/*`、`hwdec-current` | 元数据识别、硬解类型 |
| B | `mpv --untimed --vo=null`，计时 | 纯解码吞吐（不受屏幕刷新限制） |
| C | `mpv --untimed --vo=gpu-next`（真实窗口），计时 | GPU 渲染吞吐 |

脚本：`scripts/windows/decode-check.ps1`（B）、`decode-ipc.ps1`（A）、
`decode-render.ps1`（C）、`decode-tune.ps1`（缩放器对比）。
都通过 `schtasks /it` 在交互会话里跑（SSH 是 session 0，没有 GPU 表面）。

## 5. 结果

### 5.1 元数据与硬解（A 轮）

| 样片 | 分辨率 | 源 fps | 硬解 | 像素格式 | primaries | transfer |
| --- | --- | --- | --- | --- | --- | --- |
| 4K120 HDR10 | 3840×2160 | 120 | `d3d11va` | `d3d11` | bt.2020 | pq |
| 4K60 HLG | 3840×2160 | 60 | `d3d11va` | `d3d11` | bt.2020 | hlg |
| 4K60 HDR10+ | 3840×2160 | 60 | `d3d11va` | `d3d11` | bt.2020 | pq |
| 8K60 HDR10 | 7680×4320 | 60 | `d3d11va` | `d3d11` | bt.2020 | pq |
| P7 FEL | 3840×2160 | 23.976 | `d3d11va` | `d3d11` | bt.2020 | pq |

`decoder-frame-drop-count` 五个样本全程为 **0**。

HDR10+ 的确认方式（不是看 mpv 有没有日志，而是直接查码流和解码结果）：

```text
trace_headers: itu_t_t35_country_code = 181 (0xB5), payload_byte[5] = 4  → ST2094-40
showinfo:      side data - H.26[45] User Data Unregistered SEI message: 2ca2de09-b517-...
```

前者说明码流里带 HDR10+ 的注册 SEI，后者说明解码后每帧都带着它进入渲染链。

### 5.2 纯解码吞吐（B 轮，`--untimed --vo=null`）

| 样片 | 帧数 | 耗时 | 解码 fps | 判定 |
| --- | --- | --- | --- | --- |
| 4K120 HDR10 | 1200 | 7.38 s | 162.6 | 够 120 fps |
| 4K60 HLG | 900 | 4.58 s | 196.5 | 够 60 fps |
| 8K60 HDR10 | 360 | 5.32 s | 67.7 | 够 60 fps |
| P7 FEL | 720 | 8.83 s | 81.5 | 够 24 fps |

含进程启动和文件打开的开销，所以是偏低估计。

### 5.3 渲染吞吐（C 轮，`--untimed` + 真实 gpu-next 窗口）

窗口客户区 1920×1080 物理，8K 要缩到屏幕，HDR 要 tone map 到 SDR。

| 样片 | 帧数 | 耗时 | 渲染 fps | 源 fps | 判定 |
| --- | --- | --- | --- | --- | --- |
| 4K120 HDR10 | 600 | 15.61 s | 38.4 | 120 | 只能隔帧显示 |
| 4K60 HLG | 300 | 8.29 s | 36.2 | 60 | 接近但不满 |
| 4K60 HDR10+ | 300 | 8.22 s | 36.5 | 60 | 接近但不满 |
| 8K60 HDR10 | 240 | 19.54 s | 12.3 | 60 | 远不够 |
| P7 FEL | 240 | 8.79 s | 27.3 | 23.976 | 够 |

每轮含约 3 s 启动（解码器初始化 + 着色器编译），剔除后大致是：
4K60 ≈ 57 fps、4K120 ≈ 48 fps、8K60 ≈ 15 fps、P7 ≈ 41 fps。

缩放器对比：

| 8K60 | 耗时 | fps |
| --- | --- | --- |
| 默认（lanczos） | 19.53 s | 12.3 |
| `--scale=bilinear` | 16.56 s | 14.5 |

换成 bilinear 只快 18%，说明 8K 的瓶颈不是缩放器，而是纹理上传、色彩管理和
tone mapping 的带宽。

## 6. 边界

- **8K 实时播放这台机器做不到**：解码 67.7 fps，但渲染 ~15 fps。要么更强的 GPU，
  要么 8K 内容降到 4K 输出并接受更简单的处理。
- **4K60 在 60 Hz SDR 屏上约 57 fps**：满帧边缘，偶发丢帧。真机接 HDR 屏、关掉
  tone mapping 后应更高，未验。
- **HDR 直通未验**：屏幕是 SDR，只能证明元数据解析正确，不能证明 HDR 信号送到屏。
- **样片是合成的**：真实 UHD 蓝光的码率、参考帧数量、胶片颗粒都会改变解码/渲染开销，
  需要用真实片源复核（`samples/p7-fel.mkv` 是真实片源的第 300 秒起 20 秒，P7 表现正常）。
- **AV1 / VP9 未测**：不在本轮范围，mpv 的 d3d11va 对两者都有支持。

## 7. 复现

```bash
# 生成样片（Windows）
sh scripts/windows/wssh.sh 'powershell -File D:\dvplayer\setup\...'

# 三轮验证
sh scripts/windows/wssh.sh 'schtasks /run /tn decode-check'   # B：纯解码
sh scripts/windows/wssh.sh 'schtasks /run /tn decode-ipc'     # A：壳 + IPC
sh scripts/windows/wssh.sh 'schtasks /run /tn decode-render'  # C：渲染吞吐

scp -i ~/.ssh/dvplayer_win -r wucl@192.168.194.3:D:/dvplayer/out/decode3 out/
```
