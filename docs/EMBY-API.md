# Emby / Jellyfin 接口（适配器实现记录）

> 2026-11-20。适配器在 `core/media/src/sources/emby.rs`，Jellyfin 复用同一份实现。
> **状态：已在一个 Emby 4.10 的 https 实例上跑通**——登录、库列表、层级、
> 详情、图片都验证过；播放直链与进度回写还差实测（换服务器后重跑）。

## 1. 认证

两种都支持，由设置页的「用户名」是否为空区分：

| 模式 | 请求 | 结果 |
| --- | --- | --- |
| 用户名 + 密码 | `POST /Users/AuthenticateByName`，body `{Username, Pw}` | `AccessToken` + `User.Id` |
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

## 5. 还没验证 / 已知风险

| 项 | 状态 |
| --- | --- |
| 登录 | **已验证**：`POST /Users/AuthenticateByName` 返回 200 + `AccessToken`，`/Users/Me` 拿到用户 id；API Key 方式要看服务器是否签发了有效 Key（无效会返回 401 `Access token is invalid or expired.`） |
| https / 反代 | **已验证**：公网域名 + `native-tls` 正常；`/System/Info/Public` 可直接用来探活 |
| 库与层级 | **已验证**：`Views` 返回 3 个库；`ParentId` 能列 `Folder → Movie` 与 `Folder → Folder → Movie`，界面上按实际层级显示 |
| 详情与图片 | **已验证**：海报、背景图、简介、时长、`RecursiveItemCount`（「N 集」）都正常；没有剧照的条目回退成渐变占位（服务器没生成图，不是 bug） |
| 播放直链 | **待验**：`PlaybackInfo` 只传 `{UserId}`，若服务器不给 `MediaSources` 要补最小 `DeviceProfile` |
| 进度回写 | **待验**：`POST /Users/{uid}/Items/{id}/UserData` |
| 外挂字幕 | 只给了轨道信息，没给 `DeliveryUrl`；字幕选择（B12）做的时候再拼 `/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.{format}` |
| Jellyfin 差异 | 同一套 API、登录字段一致；认证头两个都发。暂未单独验证 |

## 6. 相关

- [FNOS-API.md](FNOS-API.md)：第一个源的接口记录
- [ARCHITECTURE.md](ARCHITECTURE.md) §1.2：聚合层与 `<sourceId>:<itemId>` 身份
- [M1.md](M1.md)：B10 Emby 接入的验收项
