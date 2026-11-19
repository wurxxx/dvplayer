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
| `samples/p5.mkv` | 4K24 HEVC，`dv_profile=5`，`el_present_flag=0`，EAC3 Atmos | P5 路径冒烟（**本机颜色是紫的**，见下） |

来源：10.0.0.100 的 `I.Will.Find.You.2026.S01E01...DV.H.265-DepWeb.mkv`，
第 30 秒起无损 20 秒（`scripts/nas-fetch-sample.sh`）。**不是 P7，不能用于 A1/A2。**

> ⚠️ P5 是 IPTPQc2，没有 HDR10 兼容层。macOS 的 legacy `gpu` 不做 DV 整形，
> 所以 `samples/p5.mkv` 在这台机器上必然偏紫——这是预期，不是样本坏了。
> 颜色回归请用 P8.1（NAS 上的 `F1` / `Zootopia 2`），P5 只用来冒烟解码与管线。

## 还缺

真正的 P7 双层（BL+EL+RPU）。

已知**不可用**的来源（2026-11-19 核查）：

- NAS `/vol1/1000/影视` 全库：170 个 4K 候选里 22 个带 DV，全是 P5 或 P8.1；
  4 个 ISO + 20 个 BDMV 全是 1080p AVC，唯一 4K 盘源是单轨 HDR10。
- Jellyfin 测试库：只有 P5 / P8.1 / P8.4。
- MEGA、Google Drive：本网络不可达（连接超时）。

要拿到 P7，需要 UHD 蓝光**原盘**（BDMV/ISO，且该片确实带 DV 双层），
或别人做好的 P7 remux。

## 自检

```bash
ffprobe -v error -show_entries stream=index,codec_name,width,height -of compact samples/p7-fel.mkv
mpv -v --no-config --vo=gpu-next samples/p7-fel.mkv 2>&1 | grep -iE 'dolby|enhancement'
```

日志里应出现 `Dolby Vision Profile 7 splitter` 之类的信息。

## 说明

- 只用于本地技术验证，不要提交到仓库。
- 没有样片时，A1/A2 只能停在准备阶段；脚本已经就绪。
