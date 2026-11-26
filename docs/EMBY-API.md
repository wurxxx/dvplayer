# Emby 接口（适配器实现记录）

> 2026-11-20。适配器在 `core/media/src/sources/emby.rs`。
> Jellyfin 从 2026-11-25 起是独立适配器，见 [JELLYFIN-API.md](JELLYFIN-API.md)。
> **状态：已跑通**——登录、库列表、层级、详情、图片在 Emby 4.10 的 https 实例上验证；
> 播放直链与进度回写在一个 Emby 4.9.3 实例（https + openresty 反代）上实测通过（见 §5）。

## 1. 认证

两种都支持，由设置页的「用户名」是否为空区分：

| 模式 | 请求 | 结果 |
| --- | --- | --- |
| 用户名 + 密码 | `POST /Users/{userId}`，body `{Username, Pw}` | `AccessToken` + `User.Id` |
| 仅 API Key | 不发登录请求，把 Key 当 token | 再 `GET /Users/Me` 拿 `Id` |

每个请求都带：

```
X-Emby-Authorization: MediaBrowser Client="DVPlayer", Device="Windows", DeviceId="<配置 id>", Version="0.1.0", Token="<AccessToken>"
Authorization:        <同上（Jellyfin 认这个）>
X-Emby-Token:         <AccessToken>
```

Emby 客户端习惯 `X-Emby-Authorization`，Jellyfin 习惯 `Authorization`，
两个都发；`X-Emby-Token` 是老版本 Emby 的简写，也一起带上。

`DeviceId` 用媒体源配置的 id，换源不会变成新设备——Emby 的播放记录按用户存，
不会按设备分裂。

### 登录失败怎么读

- `api error 401: Invalid username or password.`：服务端明确拒绝。这个账号在服务器上
  没有本地口令、填的是 Emby Connect 的口令、或连续失败被临时锁定，都会落到这一句。
- 错误里带「请求被重定向到 …」：地址写的是 `http`，反代 301 到 `https` 后登录 POST
  被改写成 GET；把地址改成 `https://` 再试。
- `api error 403`：认证已经过了，是设备 / 远程访问策略不允许，不是口令错。
- `api error 0` / 「登录返回无法解析」：多半是地址落到了反代的单页应用（回了 HTML），
  检查是不是少了 `/emby` 前缀或端口不对。

非 2xx 的错误保留 `api error <状态码>: <服务端原文>`；如果登录请求被重定向到别的
地址，再追加最终地址和 http→https 的提示。Windows 侧的建连日志还会带 `base` /
`user` / `pass=set(n)`，见 [M2-WINDOWS.md](M2-WINDOWS.md)。

## 2. 用到的接口

| 用途 | 请求 | 关键字段 |
| --- | --- | --- |
| 媒体库 | `GET /Users/{uid}/Views` | `Id`、`Name`、`CollectionType`、`ImageTags` |
| 条目列表 | `GET /Users/{uid}/Items?ParentId=…&StartIndex=…&Limit=…` | `Items[]`、`TotalRecordCount` |
| 搜索 | `GET /Users/{uid}/Items?SearchTerm=…&Recursive=true&IncludeItemTypes=Movie,Series,Episode` | 同条目列表，按父级归并成剧 |
| 条目详情 | `GET /Users/{uid}/Items/{id}?Fields=…` | 单条 `ItemDto` |
| 继续观看 | `GET /Users/{uid}/Items/Resume?MediaTypes=Video` | 按 `DatePlayed` 倒序 |
| 播放信息 | `POST /Items/{id}/PlaybackInfo`，body `{UserId}` | `MediaSources[0]` |
| 直连播放 | `GET /Videos/{id}/stream?Static=true&MediaSourceId=…&api_key=…` | 原文件，不转码 |
| 回写进度 | `POST /Users/{uid}/Items/{id}/UserData`，body `{PlaybackPositionTicks}` | 不依赖播放会话 |
| 图片 | `GET /Items/{id}/Images/{Primary\|Backdrop/0\|Logo}?maxWidth=…` | 带 `X-Emby-Token` |

列表接口用「精简 fields」，详情 / 播放才要 `MediaStreams` 与 `MediaSources`：
单集带上轨道信息会让一页 60 条变得很重。

## 3. 字段映射

| 统一模型 | Emby | 说明 |
| --- | --- | --- |
| `kind` | `Type` | `Movie/Series/Season/Episode/Video/Folder`；`BoxSet` 当 `Folder` |
| 季 / 集号 | `ParentIndexNumber` / `IndexNumber` | 0 视为没有 |
| 时长 | `RunTimeTicks / 10_000_000` | 1 tick = 100ns |
| 进度 | `UserData.PlaybackPositionTicks`、`PlayedPercentage` | 位置优先，没时长时用百分比 |
| 最后观看 | `UserData.LastPlayedDate` | `2026-11-19T12:00:00.0000000Z`，只取到秒（自写 `days_from_civil`，不引 chrono） |
| 剧集集数 | `RecursiveItemCount` | Series 的总集数 |
| 季数 | `ChildCount` | Series 的子项数 |
| 海报 / 背景 | `ImageTags.Primary` / `BackdropImageTags` | 有标签才给路径，避免请求 404 |
| 图片路径（模型里） | `<itemId>/Primary`、`<itemId>/Backdrop/0`、`<itemId>/Logo` | 聚合层会给它加 `<sourceId>:` 前缀 |
| HDR | `VideoRangeType` 优先 | `DOVI`→`DV`、`HDR10`/`HDR10Plus`/`HLG` 原样；没有再看 `VideoRangeType` 缺失时的 `ColorTransfer`（`smpte2084`/`arib-std-b67`）与 `DolbyVisionProfile` |
| 分辨率 | `MediaStreams[].Height` | 2000+ → 2160p，1000+ → 1080p，700+ → 720p |
| 音轨 / 字幕 | `MediaStreams[].Index` | 当作 guid；`IsDefault`、`IsExternal`、`IsTextSubtitleStream` |

## 4. 实现上的几个决定

- **不转码**：`Static=true` 直接拉原文件，解码交给 mpv。与飞牛一致，
  也避免服务端因为「客户端能力」降画质。
- **进度用 `/UserData` 而不是 `/Sessions/Playing`**：客户端只在暂停/退出时回写，
  没有长连接会话；直接写位置在任何时刻都生效，也不会留下僵尸会话。
- **API Key 放 query**：直链里带 `api_key`，同时给 `X-Emby-Token` 头。
  有些反向代理会丢掉自定义头，两个都有更稳。
- **服务器地址**：填 `http://host:8096` 即可；老版 Emby 若挂在 `/emby` 前缀下，
  把 `http://host:8096/emby` 整个填进来，适配器按原样拼路径。
- **错误信息**：HTTP 非 2xx 时优先取 `{"Error": …}`，Jellyfin 的 ProblemDetails
  也能落到 `error`/`Message`；再不行就截断原文。
- **外挂字幕下载**：`PlaybackInfo` 的 `MediaStreams` 里 `IsExternal` 的字幕，
  `playSource` 拼 `/Videos/{itemId}/{mediaSourceId}/Subtitles/{index}/Stream.{format}`
  填进 `SubtitleTrack.url`，播放器下载到缓存再 `sub-add`（带播放源的
  `X-Emby-Token`）。扩展名按编码给：文本 `srt` / `ass` / `vtt`，图形 `sup` / `sub`。
  不用服务器返回的 `DeliveryUrl`：它带 `api_key`，写进 URL 会进日志 / 缓存名。

## 5. 验证状态与已知风险

| 项 | 状态 |
| --- | --- |
| 登录 | **已验证**：`POST /Users/{userId}` 返回 200 + `AccessToken`，`/Users/Me` 拿到用户 id；API Key 方式要看服务器是否签发了有效 Key（无效会返回 401 `Access token is invalid or expired.`） |
| https / 反代 | **已验证**：公网域名 + `native-tls` 正常；`/System/Info/Public` 可直接用来探活 |
| 库与层级 | **已验证**：`Views` 返回 3 个库；`ParentId` 能列 `Folder → Movie` 与 `Folder → Folder → Movie`，界面上按实际层级显示 |
| 详情与图片 | **已验证**：海报、背景图、简介、时长、`RecursiveItemCount`（「N 集」）都正常；没有剧照的条目回退成渐变占位（服务器没生成图，不是 bug） |
| 播放直链 | **已验证**：`PlaybackInfo` 只传 `{UserId}` 就够了；`Static=true&MediaSourceId=…&api_key=…` 直连原文件，该实例上 mpv 解出 4K HEVC + eac3/aac 两轨 |
| 进度回写 | **已验证**：走 `POST /Sessions/Playing` → `/Sessions/Playing/Progress` → `/Sessions/Playing/Stopped`，`Stopped` 之后服务端才写 `UserData.PlaybackPositionTicks`。`POST /Users/{uid}/Items/{id}/UserData` 在该实例的反代上直接 404，只作兜底 |
| 外挂字幕 | **已验证**：`PlaybackInfo.MediaStreams` 里 `IsExternal` 的 ass / srt 由 `playSource` 拼下载地址，客户端落到缓存后 `sub-add`；菜单显示「中文 · 简体 / 中文 · 繁体」，自动选择也认这些轨 |
| Jellyfin | 独立适配器（`jellyfin.rs`），端点与认证头不同，见 [JELLYFIN-API.md](JELLYFIN-API.md) |

播放直链与进度回写已在 Emby 4.9.3 实例（https + openresty 反代）实测通过。
Jellyfin 另走 `jellyfin.rs`，两套实现互不影响
（[PLAN.md](PLAN.md) §5.1、[M1.md](M1.md) B10）。

**上报细节**：`Sessions/Playing` 先注册会话（`PlaySessionId` 由客户端生成），
之后每 10 秒发 `Progress`；关窗 / 播完发 `Stopped`，服务端这时才把位置写进
`UserData`。只发 `Progress` 时服务端返回 204 但不落盘。

## 6. 相关

- [FNOS-API.md](FNOS-API.md)：第一个源的接口记录
- [ARCHITECTURE.md](ARCHITECTURE.md) §1.2：聚合层与 `<sourceId>:<itemId>` 身份
- [M1.md](M1.md)：B10 Emby 接入的验收项
