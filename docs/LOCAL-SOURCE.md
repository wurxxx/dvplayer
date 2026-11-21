# 本地文件夹源

把「不在服务器上的东西」也放进媒体库：一个目录（或单个 ISO）就是一个源，
卡片墙、详情、选集、续播、继续观看全走媒体库那一套，不再有一个单独的
「打开原盘」入口。

实现放在共享核心 `core/media/src/sources/local.rs`，两端界面只调
`MediaSource`，所以季集推断、标题清理、进度格式只有一份。

## 1. 怎么加

- **Windows / macOS**：「服务器」页 → 添加 → 类型选「本地文件夹」→
  「浏览…」选目录（ISO 也可以直接在地址框里填完整路径）。
  侧栏不再有单独的本地文件夹入口，加源的地方只有服务器页。

源的类型是 `local`，`base` 是目录或文件的绝对路径，`dataDir` 是进度文件
所在目录（界面自动填成配置目录，不用手写）。添加后和飞牛 / Emby 并列在
侧栏「服务器」列表里，状态点同样区分连上 / 失败。

## 2. 目录怎么读

根目录下每一项单独判断：

| 情况 | 结果 |
| --- | --- |
| 视频 / ISO 文件 | 一个电影条目 |
| 目录里 ≥2 个视频，或有季子目录，或唯一视频带集号 | 一部剧（剧集） |
| 目录里只有一个视频且不像剧 | 一个电影，标题取视频文件名 |

剧的下面：

- 季目录认 `Season 01`、`S02`、`第 3 季`、`第二季`；认不出季的子目录
  里的视频并进第一季；
- 集号从文件名认 `S01E02`、`第 12 集`、`EP06`；认不出就按文件名排序编号，
  顺序不会乱；
- 只有一季时详情页直接列集（`singleChildId` 指向那一季），有第二季才先列季。

标题清理：去掉扩展名和常见发布标签（`2160p`、`BluRay`、`x265`、`DDP5.1`…），
把 `.` `_` 换成空格，`(2021)` 这种年份同时作为条目年份。

海报：视频同目录找 `<视频文件名>.jpg`、`poster.jpg`、`folder.jpg`、
`cover.jpg`（`jpg/jpeg/png/webp`）。找不到就用渐变占位，不联网刮削。

解开的蓝光目录（含 `BDMV/STREAM`）**不展开**，一个原盘应该打成 ISO 再加进库，
否则一个原盘会变成几千个「集」。

## 3. 怎么播

- 普通视频：`playSource` 直接给绝对路径，mpv 当本地文件打开；
- ISO：`playSource` 带 `disc: true`，界面走原来的原盘流程——
  Windows 用 `mpv.com` 读 title 后 `bd://mpls/<n>`（`BLU-RAY.md` §5.1），
  macOS `hdiutil` 挂载 + `mpls` → EDL（§5.2）。
  只有一条标题直接播，多标题才弹选择框；续播点仍按这一集的条目 id 回写。

## 4. 进度和记录

本地源没有服务器可回写，进度落
`<dataDir>/local-library-progress.json`（Windows `%LOCALAPPDATA%\dvplayer`，
macOS `~/Library/Application Support/DvPlayer`）。

**注意文件名**：侧栏直接打开原盘的续播点用的是 `local-progress.json`
（`LocalProgressStore` / `LocalProgress.cs`，结构是 `{ 条目 id: {...} }`），
这里的文件多一层 `items` 且带标题、季集号，两者不能混用一个文件。

有了进度文件，「记录 → 观看」里会自然出现本地条目（剧会显示
「剧名 · 第 N 集」），点进去按条目 id 续播。

## 5. 自检

核心自带一个只看扫描结果的命令行：

```bash
cd core
~/.cargo/bin/cargo run -p dvplayer-media --example local -- /path/to/dir
```

打印库、条目、季集和 `play_source` 的 URL / `disc` 标志，不启动界面。

端上自检：本地源的条目和服务器条目一样，用 `DVPLAYER_DETAIL` /
`DVPLAYER_PLAY`（macOS）、`--play`（Windows）指定
`<源 id>:f/<相对路径>` 或 `<源 id>:d/<目录>` 即可。
