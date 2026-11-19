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
| `samples/p5.mkv` | 4K24 HEVC，`dv_profile=5`，`el_present_flag=0`，EAC3 Atmos | P5 回归（颜色、徽标 `DV P5`） |

来源：10.0.0.100 的 `I.Will.Find.You.2026.S01E01...DV.H.265-DepWeb.mkv`，
第 30 秒起无损 20 秒（`scripts/nas-fetch-sample.sh`）。**不是 P7，不能用于 A1/A2。**

## 还缺

真正的 P7 双层（BL+EL+RPU）。可用来源：UHD 蓝光 remux、dovi_tool 的测试片。

## 自检

```bash
ffprobe -v error -show_entries stream=index,codec_name,width,height -of compact samples/p7-fel.mkv
mpv -v --no-config --vo=gpu-next samples/p7-fel.mkv 2>&1 | grep -iE 'dolby|enhancement'
```

日志里应出现 `Dolby Vision Profile 7 splitter` 之类的信息。

## 说明

- 只用于本地技术验证，不要提交到仓库。
- 没有样片时，A1/A2 只能停在准备阶段；脚本已经就绪。
