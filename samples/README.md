# 测试片源

样片不入库（见 `.gitignore`），只放本地。

## 需要什么

| 文件 | 用途 | 要求 |
| --- | --- | --- |
| `samples/p7-fel.mkv` | A1 / A2 / A4 | Profile 7 FEL，10–60 秒即可，4K 最好 |
| `samples/p7-mel.mkv` | 对照组 | Profile 7 MEL |
| `samples/p5.mp4` | 回归 | Profile 5 |

## 放置

```
samples/p7-fel.mkv
```

## 已有

| 文件 | 实际内容 | 用途 |
| --- | --- | --- |
| `samples/p7-fel.mkv` | 4K HEVC，`dv_profile=7`，单轨带内交织，EL 1920×1080，DTS-HD MA 5.1 | **A1 / A2 主样本**（已判定 P7 FEL） |
| `samples/p5.mkv` | 4K24 HEVC，`dv_profile=5`，`el_present_flag=0`，EAC3 Atmos | P5 路径冒烟（**本机颜色是紫的**，见下） |

- `p7-fel.mkv` 来源：10.0.0.100 的
  `歪心狼大电影.Coyote.vs.Acme.2026.GBR.UHD.BluRay.2160p.REMUX.DV.HDR.HEVC...mkv`，
  第 300 秒起无损 20 秒（`scripts/nas-fetch-p7.sh`）。
- `p5.mkv` 来源：10.0.0.100 的
  `I.Will.Find.You.2026.S01E01...DV.H.265-DepWeb.mkv`，第 30 秒起 20 秒
  （`scripts/nas-fetch-sample.sh`）。**不是 P7，不能用于 A1/A2。**

> ⚠️ P5 是 IPTPQc2，没有 HDR10 兼容层。macOS 的 legacy `gpu` 不做 DV 整形，
> 所以 `samples/p5.mkv` 在 m0-render 里必然偏紫——这是预期，不是样本坏了。
> 想看它的正确颜色，用产品播放器（进程内 libmpv + render API，gpu-next 整形）：
>
> ```bash
> cd apps/macos/DvPlayer && ./build.sh
> DVPLAYER_LOCAL=../../samples/p5.mkv "./build/DV Player.app/Contents/MacOS/DV Player"
> ```
>
> 颜色回归仍建议用 P8.1（NAS 上的 `F1` / `Zootopia 2`），P5 用来冒烟 P5 路径本身。

## 还缺

`p7-mel.mkv`（Profile 7 MEL 对照）还没有。FEL 已经够 A1/A2；
MEL 只用于验证徽标不会把两者判反。

已知**不可用**的来源（2026-11-19 核查）：

- NAS `/vol1/1000/影视` 全库：170 个 4K 候选里 22 个带 DV，全是 P5 或 P8.1；
  4 个 ISO + 20 个 BDMV 全是 1080p AVC，唯一 4K 盘源是单轨 HDR10。
- Jellyfin 测试库：只有 P5 / P8.1 / P8.4。

`p7-fel.mkv` 是从别处的 UHD remux 取的切片，所以本地库扫描的结论仍然成立。

## 自检

```bash
ffprobe -v error -show_entries stream=index,codec_name,width,height -of compact samples/p7-fel.mkv
mpv -v --no-config --vo=gpu-next samples/p7-fel.mkv 2>&1 | grep -iE 'dolby|enhancement'
```

日志里应出现 `Dolby Vision Profile 7 splitter` 之类的信息。

## 说明

- 只用于本地技术验证，不要提交到仓库。
- `p7-fel.mkv` 用于 A1/A2/A4；换机器时把这一份带过去即可。
