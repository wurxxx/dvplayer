# ADR-0013：Android 拆两个壳，共享一套核心

- 状态：已接受
- 日期：2026-11-25
- 取代：`docs/ARCHITECTURE.md` §6 中「一个 module，两个 launcher activity」的写法

## 背景

手机与 Android TV 的约束并不相同：

| 维度 | 手机 | TV |
| --- | --- | --- |
| 入口 | 普通 launcher | `LEANBACK_LAUNCHER` + banner + leanback feature |
| 输入 | 触摸、手势 | 遥控器 DPAD、焦点、overscan |
| 权限 | 通知、前台服务、PiP、下载 | 网络 + `WAKE_LOCK` 基本够 |
| 依赖 | MediaSession、DownloadManager | `androidx.tv:tv-material`、无下载 |
| 发布 | 商店 / 侧载 | 侧载为主，Play TV 单独 track |

如果塞进一个 module：manifest 的权限和 feature 会互相污染（TV 包带上通知与前台服务，
手机包带上 leanback 依赖），一个 AAB 把两条发布节奏绑死，崩溃归因与测试矩阵也混在一起。
技术上能凑合（`touchscreen` 设 `required=false`、两个 intent-filter 共存），
但项目刚起步，拆模块的成本只是几个 Gradle 文件。

另一头也不走：两个独立工程。41 个 C ABI、聚合去重、适配器、设备能力探测都要两份，
等于把 ADR-0008 拆了。

## 决策

1. 一个 Gradle 工程、两个 application 模块：`:app-phone` / `:app-tv`。
2. 从 `:feature` 往下一律共享：数据、状态、播放管线、设计令牌。
3. 屏幕布局不共享：`:ui-phone`（Material3）与 `:ui-tv`（tv-material）各写一份。
4. 两个 applicationId（`com.dvplayer.app` / `com.dvplayer.app.tv`）、两个发布产物；
   侧载与商店互不影响。
5. 媒体库逻辑继续只写在 `core/media`，两个壳都只做薄封装。

模块与依赖方向见 [M2-ANDROID.md](../M2-ANDROID.md) §2。

## 理由

- **共享状态、不共享屏幕**：`tv-material` 与 `material3` 的组件 API 不是一套，
  一套屏幕硬兼容触摸与焦点，最后两边都别扭。ViewModel / UiState 只写一次，屏幕各写一份。
- **发布解耦**：TV 主要靠侧载（国内盒子多、无 Play），手机走商店；版本号、审核、
  回滚互不牵连。
- **权限干净**：TV 用户不该看到通知权限，手机用户不该装 leanback 依赖。

## 后果

- 多一层模块维护（`build-logic`、版本目录），换来 TV 的安装与权限不被手机拖累。
- 每加一个屏幕要写两次布局；状态与交互只写一次。
- `ARCHITECTURE.md` §6 的「一个 module」作废，§9 目录结构同步更新。
- 两个 applicationId 意味着设置与源配置不共享；播放进度走服务器回写，不受影响。
