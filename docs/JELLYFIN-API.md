# Jellyfin 接口（独立适配器）

> 2026-11-25。适配器在 `core/media/src/sources/jellyfin.rs`，**不和 Emby 共用**
> （认证头、端点集合、错误体都不一样）。
>
> **状态：10.8.12 的 http 实例上全链路跑通**——API Key 登录、库列表、条目列表、
> 详情、类型、继续观看、收藏、播放直链、图片地址都实测过（macOS 与 Windows
> 真机各跑一遍）。12.x 的实例还没碰到。

## 1. 认证

只发一个头，10.x 和 12.x 都认：

```
Authorization: MediaBrowser Client="DVPlayer", Device="Windows", DeviceId="<配置 id>", Version="0.1.0", Token="<AccessToken 或 API Key>"
```

- 用户名 + 密码：`POST /Users/AuthenticateByName`，body `{Username, Pw}` → `AccessToken` + `User.Id`。
  这个请求的 `Authorization` 只有客户端信息，不带 `Token`。
- 仅 API Key：跳过登录，把 Key 放进 `Token`（设置页：用户名留空，密码框填 Key）。
- `X-Emby-Token` / `X-Emby-Authorization` **不发**：Jellyfin 12 起已移除
  （官方 12 的升级说明里是强制关闭项），Jellyfin 10.x 也接受 `Authorization`。

### API Key 没绑定用户

服务端级 API Key 没有对应用户，`GET /Users/Me` 回 **400** `Error processing request.`
（不是 401）。适配器这时退回 `GET /Users` 取第一个用户 id —— 单用户的家庭服务器就是它。
真机上这条路径是必需的，否则登录直接失败。

## 2. 端点：12.x 与 10.8 两套

Jellyfin 12 把用户维度搬到了查询参数，路径上不再带 `/Users/{uid}`。
10.8 及更早**没有**这套新端点（实测 10.8.12 的返回见下），所以适配器登录后探测一次：

```
GET /UserViews?userId=<uid>
  200 → 新端点（12.x）
  404 → legacy（10.8），全部走 /Users/{uid}/...
```

| 用途 | 12.x | 10.8（legacy） |
| --- | --- | --- |
| 媒体库 | `GET /UserViews?userId=` | `GET /Users/{uid}/Views` |
| 列表 / 搜索 / 收藏列表 | `GET /Items?userId=&…` | 同左（`/Items?userId=` 在 10.8 也是 200） |
| 类型 | `GET /Genres?userId=&parentId=` | 同左 |
| 继续观看 | `GET /UserItems/Resume?userId=` | `GET /Users/{uid}/Items/Resume` |
| 条目详情 | `GET /Items/{id}?userId=&fields=` | `GET /Users/{uid}/Items/{id}?fields=`（10.8 的 `/Items/{id}` 回 **405**） |
| 用户数据 / 移除观看记录 | `POST /UserItems/{id}/UserData?userId=` | `POST /Users/{uid}/Items/{id}/UserData` |
| 收藏 | `POST/DELETE /UserFavoriteItems/{id}?userId=` | `POST/DELETE /Users/{uid}/FavoriteItems/{id}` |
| 已看 | `POST/DELETE /UserPlayedItems/{id}?userId=` | `POST/DELETE /Users/{uid}/PlayedItems/{id}` |
| 图片 | `GET /Items/{id}/Images/{type}?maxWidth=` | 同左 |

10.8.12 实测补充：`/UserViews` 404、`/UserItems/Resume` 404、`/Items/{id}` 405、
`/Users/{uid}/Views` 与 `/Users/{uid}/Items/{id}` 200、`/Items?userId=` 200。

## 3. 播放与进度

- 动态信息：`POST /Items/{id}/PlaybackInfo`，body `{"UserId": "<uid>"}`（GET 带
  `?userId=` 也回 200，但 POST + body 是 Emby 时代就在用的写法）。
- 直链：`/Videos/{id}/stream?Static=true&MediaSourceId=<id>`，不转码，解码交给 mpv。
- 进度：先 `POST /Sessions/Playing` 注册会话，之后 `/Sessions/Playing/Progress`，
  关窗 / 播完 `/Sessions/Playing/Stopped`（`UserData` 的位置由 `Stopped` 落盘）。
- 鉴权头里的**逗号**：`Authorization` 的值是
  `MediaBrowser Token="…", Client="…", …`，而 mpv 的 `http-header-fields` 是逗号
  分隔的列表选项。两端都要把 `\` 和 `,` 转义（macOS `MpvEngine.loadURL`、
  Windows `MpvProcess.BuildArgs` / `LibMpvProcess`），否则 mpv 会把一条头拆成好几条、
  服务端回 401，画面全黑。

## 4. 还没验证

- 12.x 实例（新端点分支只按官方 OpenAPI 写，没跑过真机）。
- 外挂字幕：`MediaStreams` 里有轨道信息，但没给 `DeliveryUrl`；
  字幕选择做的时候再拼 `/Videos/{id}/{mediaSourceId}/Subtitles/{index}/Stream.{format}`。
- 服务端级 API Key 在 12.x 上是否也回 400：`/Users` 的回退逻辑与版本无关，等实例。

## 5. 相关

- [EMBY-API.md](EMBY-API.md)：Emby 适配器（`emby.rs`），两套实现互不影响
- [FNOS-API.md](FNOS-API.md)：飞牛影视
