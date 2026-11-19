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

## 自检

```bash
ffprobe -v error -show_entries stream=index,codec_name,width,height -of compact samples/p7-fel.mkv
mpv -v --no-config --vo=gpu-next samples/p7-fel.mkv 2>&1 | grep -iE 'dolby|enhancement'
```

日志里应出现 `Dolby Vision Profile 7 splitter` 之类的信息。

## 说明

- 只用于本地技术验证，不要提交到仓库。
- 没有样片时，A1/A2 只能停在准备阶段；脚本已经就绪。
