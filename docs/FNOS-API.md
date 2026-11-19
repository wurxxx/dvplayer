# 飞牛影视 API（fnOS Media）

> 2026-11-19。目标：桌面客户端直接读飞牛影视的媒体库、条目、播放记录与播放地址，
> 不再经过 Web UI。下面全部为实测结果（`10.0.0.134:8005`，版本以实际为准）。

## 1. 基本信息

| 项 | 值 |
| --- | --- |
| 服务 | `http://10.0.0.134:8005` |
| Web UI | `/v`（Vue SPA） |
| API 前缀 | `/v/api/v1` |
| 认证 | `Authorization: <token>` + `authx` 签名头 |
| 登录 | `POST /v/api/v1/login` |

主机的 `5666` 是 fnOS 系统 Web，`8005` 才是影视应用；两者不是一回事。

## 2. 登录

```http
POST /v/api/v1/login
Content-Type: application/json

{"username":"<用户>","password":"<明文密码>"}
```

```json
{"msg":"","code":0,"data":{"token":"<32 位 token>"}}
```

注意：

- legacy `/login` 用**明文密码**；
- 新接口 `POST /user/loginByPassword` 用 **SHA-256(密码)**，body 额外带
  `app_name: "trimemedia-web"`；服务端不支持时返回 `Not Implemented`；
- 本站点 legacy 可用，优先用它。

## 3. 请求签名（authx）

每个需要认证的请求除 `Authorization` 外，还要带：

```http
authx: nonce=<6位随机数>&timestamp=<毫秒>&sign=<md5>
```

签名串：

```text
sign = md5( SALT "_" pathname "_" nonce "_" timestamp "_" bodyHash "_" APIKEY )
```

| 变量 | 值 |
| --- | --- |
| `SALT` | `NDzZTVxnRKP8Z0jXg1VAMonaG8akvh` |
| `APIKEY` | `16CCEB3D-AB42-077D-36A1-F355324E4237` |
| `pathname` | 含前缀，如 `/v/api/v1/item/list` |
| `nonce` | 6 位随机整数 |
| `timestamp` | `Date.now()`（毫秒） |
| `bodyHash` | GET：`md5(decodeURIComponent(排序后的 query string))`；其他：`md5(JSON.stringify(body))` |

关键细节，踩过才知道：

1. **签名里的 JSON 与实际发送的 JSON 必须是同一份**。Python 默认
   `json.dumps` 会加空格，签名却用紧凑串，服务端直接回 `invalid sign`。
   两边都必须用 `separators=(',',':')`。
2. GET 的 query 要**按 key 排序**，空格编码成 `%20` 而不是 `+`。
3. `bodyHash` 用的是 **apiKey**，不是用户 token；`Authorization` 才是 token。
4. 空 body（GET）时 `bodyHash = md5("")`。

参考实现（Python，可直接改成 C#）：

```python
def authx(path, params, body, method):
    if method == "GET":
        q = urlencode(sorted(params.items()), quote_via=quote).replace("+", "%20")
        body_hash = md5(unquote(q))
    else:
        body_hash = md5(json.dumps(body, separators=(",", ":")) if body else "")
    nonce = str(random.randint(100000, 999999))
    ts = str(int(time.time() * 1000))
    sign = md5("_".join([SALT, path, nonce, ts, body_hash, APIKEY]))
    return f"nonce={nonce}&timestamp={ts}&sign={sign}"
```

## 4. 媒体库与条目

### 4.1 媒体库列表

```http
GET /v/api/v1/mediadb/list
```

```json
{"code":0,"data":[{
  "guid":"aa12d2c6d7914ccc8d1fb74ac4f2ceef",
  "title":"影视","category":"Mix","view_type":0,
  "posters":["/f7/04/poster-....webp"]
}]}
```

### 4.2 条目列表

```http
POST /v/api/v1/item/list
{"guid":"<媒体库 guid>","page":1,"page_size":24}
```

```json
{"code":0,"data":{
  "total":1494,
  "list":[{
    "guid":"...","title":"...","type":"Directory|Video|Movie|TV",
    "poster":"/20/20/poster-....webp",
    "poster_list":["/f8/03/poster-....webp"],
    "watched":0,"watched_ts":0,"is_favorite":0,
    "media_stream":{"resolutions":["720p"],"audio_type":null,"color_range_type":null},
    "season_number":0,"episode_number":0,
    "number_of_seasons":0,"number_of_episodes":0,
    "ancestor_guid":"...","ancestor_name":"影视","ancestor_category":"Mix",
    "duration":127
  }]
}}
```

- `guid` + `page` + `page_size` 列**当前层**；
- `ancestor_guid` 列**全部子孙**（实测 63094 条），适合搜索与统计；
- `type` 是树形的：`Directory` 表示文件夹，`Video` 是文件，`Movie` / `TV` 是刮削后的条目。

### 4.3 详情

```http
GET  /v/api/v1/item/<guid>
POST /v/api/v1/item/getEditDetail
```

## 5. 播放

真实链路是三步（已全部实测通过，客户端 `FnOsSource::play_source` 就是这么做的）：

### 5.1 取播放信息

```http
POST /v/api/v1/play/info   {"item_guid": "<条目 guid>"}
```

```json
{"code":0,"data":{
  "guid":"28f8ff84...","ts":149,"type":"Movie",
  "media_guid":"0d5c213f...","video_guid":"1701eed1...",
  "audio_guid":"613146ce...","subtitle_guid":"2878a0cc...",
  "direct_link_audio_index":-1,
  "item":{"title":"奥德赛","overview":"...","duration":10355,
          "posters":"/ec/16/xxx.webp","backdrops":"/94/05/xxx.webp",
          "media_stream":{"resolutions":["4k"],"color_range_type":["HDR10"],"audio_type":["DTS-HD MA"]}}
}}
```

- `ts` 是续播秒数，直接拿来当 `--start`。
- `media_guid` 是后面两步的主键，**不是**条目 guid。
- 只支持 POST，GET 返回 501 `Not Implemented, please update.`。
- `/play/play` 实测返回 `{"code":-6,"msg":"Not Found"}`，不用调。

### 5.2 取轨道

```http
POST /v/api/v1/stream   {"media_guid":"...","ip":"<任意 uuid>","header":{"User-Agent":["DVPlayer"]}}
```

返回 `file_stream`（path/size/type）、`video_stream`（`codec_name`、`resolution_type`、
`color_range_type`、`dv_profile`、`profile`、`width`/`height`）、`audio_streams[]`、
`subtitle_streams[]`、`qualities[]`（只有 `bitrate` + `resolution`，**没有 URL**）。

HDR 判断看 `video_stream.color_range_type`（`HDR10` / `DoVi` / 空 = SDR）与
`dv_profile > 0`。

### 5.3 播放直链

```http
GET /v/api/v1/media/range/<media_guid>
Authorization: <登录 token>
Range: bytes=0-1023
```

- 返回 `206 video/mp2t`，`Accept-Ranges: bytes`，`Content-Range: bytes 0-1023/94917009408`。
- 单文件 94.9 GB 蓝光原盘也能正常 Range 拖动。
- **不带 `Authorization` 就 `{"msg":"Auth Failed","code":-2}`**，不认 query 参数。
- 播放器要带上这个头：mpv 用 `--http-header-fields="Authorization: <token>"`。

其余端点：

| 端点 | 作用 |
| --- | --- |
| `POST /v/api/v1/play/quality` | 切清晰度 |
| `POST /v/api/v1/media/p` | 重置音轨/字幕、退出播放 |
| `POST /v/api/v1/play/record` | 上报播放记录 |
| `POST /v/api/v1/item/<guid>/playing` | 播放心跳 |

## 6. 播放记录

```http
GET /v/api/v1/play/list
```

```json
{"code":0,"data":[{
  "guid":"...","title":"奥德赛","type":"Movie",
  "poster":"/94/05/....webp","poster_width":3840,"poster_height":2160,
  "runtime":173,"ts":149,"duration":10355,
  "watched":0,"watched_ts":0,"is_favorite":0,
  "media_stream":{"resolutions":null,"audio_type":null,"color_range_type":null},
  "ancestor_guid":"aa12d2c6...","ancestor_name":""
}]}
```

字段含义（实测确认）：

| 字段 | 含义 |
| --- | --- |
| `duration` | 总时长，**秒** |
| `runtime` | 总时长，分钟 |
| `ts` | **看到第几秒**，续播进度就用它 |
| `watched` | 是否看完（1 = 看完） |
| `watched_ts` | 看完时间戳；没看完是 0 |

`media_stream.resolutions` 在列表接口里是 `null`，分辨率要等详情接口。

注意：列表里的 `poster` 虽然是 2:1 横图（`poster_width: 3840, poster_height: 2160`），
不是竖版海报。首页 16:9 的「继续观看」卡片正好能用；竖版网格里会被裁切，需要时可换成
`/play/info` 返回的 `item.posters`。

## 7. 其它有用端点

搜索、收藏、字幕、人物：

| 端点 | 作用 |
| --- | --- |
| `POST /v/api/v1/person/search` | 搜索人物 |
| `POST /v/api/v1/search/rebuild` | 重建索引 |
| `POST /v/api/v1/favorite/list` | 收藏列表 |
| `PUT /v/api/v1/item/favorite` | 加收藏 |
| `POST /v/api/v1/subtitle/search` | 搜字幕 |
| `POST /v/api/v1/subtitle/download` | 下字幕 |
| `GET /v/api/v1/movie/<guid>` | 影片详情 |
| `POST /v/api/v1/person/list/<guid>` | 影片演员 |

搜索本身没有单独的全文接口，`item/list` 带 `ancestor_guid` + 关键词参数（未完全验证）。

## 8. 客户端实现要点

1. **签名要逐字节对齐**：先序列化成紧凑 JSON 字符串，同一份字符串既做 body 又做哈希输入。
2. **token 有效期未测**：先按 `code == -2 (Auth Failed)` 触发重新登录。
3. **图片地址（已解决）**：`poster` 是 `/94/05/xxx.webp` 这种相对路径，拼成
   `GET /v/api/v1/sys/img{poster}` 再带 `Authorization: <token>` 即可，返回真实 JPEG
   （服务端 `Content-Type` 写成 `image/webp`，实际字节是 `FF D8 FF E0`，按 JPEG 解码）。
   **不能**把 URL 直接交给 `<img>` / `Image`，因为只认请求头，不认 `?token=` / `?authx=`。
   当前实现是 C# 自己下字节 + 落盘缓存 + `ImageBrush`（`Services/PosterLoader.cs`）。
4. **多服务器聚合**：每个源一个适配器（`FnOsSource` / `EmbySource`），统一成
   `MediaLibrary / MediaItem / PlayRecord / PlaySource`，再做合并与去重。实现在 `core/media`（Rust），
   三端只做界面，见 ADR-0008。

## 9. Jellyfin / Emby 兼容层（Infuse / VidHub 走的那条）

`GET /emby/System/Info` 返回 `ProductName: "Jellyfin Server"`, `Version: 10.10.0`,
`OperatingSystem: "fnOS"`，所以飞牛确实内置了一个 Jellyfin 兼容层。但它**只实现了一部分**：

| 能力 | 实测结果 |
| --- | --- |
| `POST /emby/Users/AuthenticateByName` | ✅ 200，返回 `AccessToken` + `User.Id` |
| `GET /emby/Users/{uid}/Views` | ✅ 200，能列出「影视」媒体库 |
| `GET /emby/Users/{uid}/Items?...` | ⚠️ 只在同时带 `ParentId` + `Recursive` + `Fields` + `Limit` 时才 200；少一个就 400（空 body） |
| `GET /emby/Users/{uid}/Items/Resume` | ❌ 400 |
| `GET /emby/Users/{uid}/Items/{id}` | ✅ 200，3.2 万字节，字段接近 Jellyfin |
| `GET /emby/Items/{id}`（不带 user） | ❌ 回落到 SPA `index.html`（4303 B） |
| `GET /emby/Items/{id}/Images/Primary?tag=...` | ✅ 200 真图（约 1.3 MB） |
| `POST /emby/Items/{id}/PlaybackInfo` | ❌ **恒 403**（空 body），换客户端名、加 `MediaSourceId` 都不行 |
| `GET /emby/Videos/{id}/stream` | ❌ 回落到 SPA `index.html`（4303 B） |
| `POST /emby/Sessions/Playing/Progress` | ✅ 204（能写进度） |

结论：**兼容层拿不到播放直链**（`PlaybackInfo` 全 403、`Videos/stream` 没实现），
照抄 Infuse 的调用方式行不通；但原生 API 的 `/media/range` 就是它实际在播的那条流，
所以**不需要抓包**，直接用原生链路即可。

鉴权头：`X-Emby-Token: <token>` 有效；`Authorization: MediaBrowser ..., Token=` 形式**不认**
（返回 `{"error":"Token is missing"}`）。
