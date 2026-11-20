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
- `ancestor_guid` 列**全部子孙**（实测 63094 条），含季/集，不适合直接铺网格；
- `type` 是树形的：`Directory` 表示文件夹，`Video` 是文件，`Movie` / `TV` 是刮削后的条目。

筛选和排序也走这个接口（实测 2026-11-20）：

```json
POST /v/api/v1/item/list
{
  "guid": "<媒体库 guid>",
  "tags": { "type": ["TV"], "genres": 2 },
  "sort_column": "sort_title",
  "sort_type": "ASC",
  "page": 1,
  "page_size": 60
}
```

| 参数 | 取值 | 说明 |
| --- | --- | --- |
| `tags.type` | `Movie` / `TV` / `SEASON` / `EPISODE` / `Directory` / `Video` | **数组**；不传就是全部 |
| `tags.genres` | 数字 | **单个数字**，不是数组；传 `-1` 等于不过滤 |
| `sort_column` | `sort_title` / `create_time` / `release_date` / `vote_average` | 名称 / 入库 / 发行 / 评分 |
| `sort_type` | `ASC` / `DESC` | 不区分大小写 |

- `guid` 和 `tags` 一起用时，过滤的是这个库的条目（`type=TV` 得到的是库里的剧，
  不会把每一集都列出来）；
- `genres` 的 id 来自 `GET /tag/genres`（`[{id,value}]`，value 是 TMDB 英文名），
  某个库实际有哪些 genre 看 `GET /tag/list?guid=<库>` 的 `data.genres`；
- 排序不传就按服务器默认（入库时间倒序）返回。


### 4.2.1 搜索（全文）

```http
GET /v/api/v1/search/list?q=<关键词>
```

```json
{"code":0,"data":[
  {"guid":"...","title":"末哥超凡公路 S03 - S03E05.mp4",
   "parent_guid":"...","parent_title":"末哥超凡公路 S03（65集） - SKIT",
   "type":"Video","poster":"/6f/18/poster-....webp",
   "media_stream":{"resolutions":["1080p"],...},
   "ancestor_guid":"...","ancestor_name":"影视","ancestor_category":"Mix"}
]}
```

- 返回**平铺的文件级条目**（命中的可能是某一集），要按 `parent_guid` 归并成剧；
- 实测 `8005` 和 `15666` 两个端口都可用，走影视应用自己的接口；
- `q` 为空时不要调用，直接返回空列表；
- GET 的 `authx` 签名哈希的是 **query string**（见 §3），不是 body。

`item/list` 的 `keyword` / `search` / `name` / `title` 等参数实测都无效（返回全量），
`/item/search`、`/search` 一类路径返回 501，所以搜索只走这一个端点。

### 4.3 详情

```http
GET  /v/api/v1/item/<guid>
POST /v/api/v1/item/getEditDetail
```

`GET /item/<guid>` 返回比列表多这些字段（剧集样本实测）：

| 字段 | 说明 |
| --- | --- |
| `overview` | 简介（TMDB 中文） |
| `backdrops` / `posters` / `logos` | 横版图 / 海报 / 标题图，相对路径 |
| `poster_list` | **目录（Directory）没有 `posters`，只有这个数组** |
| `vote_average` | 评分，**字符串** `"0"` 或数字，两种都会出现 |
| `number_of_seasons` / `number_of_episodes` | TMDB 的总季数 / 总集数 |
| `local_number_of_seasons` / `local_number_of_episodes` | **本地**实际有的季数 / 集数 |
| `play_item_guid` | 「继续观看」该播的条目（目录会指向第一个视频，剧集常为空） |
| `media_stream` | `resolutions` 是数组，`audio_type` / `color_range_type` **详情里是数组、列表里是字符串或 null** |

两个坑：

- 字符串字段大量给 `null` 而不是省略，serde 必须写 `Option`，否则整条解析失败；
- `Episode` 类型的 `/item/<guid>` 返回空对象 `{}`，单集信息只能用列表项；
- `POST /movie/<guid>` 恒 501，别用。

### 4.4 层级：媒体库 → 剧集 → 季 → 集

```
媒体库 (aa12d2c6...)
├── TV 御兽：从退婚开始无敌          type=TV        number_of_seasons=10
│   └── Season 第一季               type=Season    season_number=1
│       └── Episode 第 1 集         type=Episode   episode_number=1
├── Directory 异能寻生机（76集）      type=Directory  ← 未刮削的多文件目录
│   └── Video 异能寻生机 - S01E76.mp4 type=Video    episode_number=0
└── Movie 枫                       type=Movie
```

- 用 `parent_guid` 往下取一层：`POST /item/list {"parent_guid":"<id>","page":1,"page_size":50}`；
- **`Directory` 不是文件夹，而是一部没刮削的剧**：子项是一堆 `Video`，没有季这一层，
  集号只能从文件名认（`S01E76` / `第 76 集` / `EP06`），客户端必须按集号排序（接口不排序）；
- `Directory` 的详情没有简介和横版图，但 `poster_list` 里有封面；
- `Video` 列表项自带**剧照**（`poster`）和时长，集列表可以直接用；
- 本地集数可能少于 TMDB 总集数（样本：10 季 81 集本地、标题写 76 集但只有 53 个文件），
  展示时以本地为准，别拿标题里的集数当真。

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

### 5.4 回写进度

```http
POST /v/api/v1/play/record   {"item_guid":"...","media_guid":"...","ts":170}
```

- **`ts` 是「看到第几秒」**，和 `play/list` 读出来的同一个字段，读写共用。
- 必须带 `media_guid`（不是条目 guid），否则记录写不进去。
- 前端还有 `resolution` / `bitrate` / `audio_guid` / `direct_link_audio_index` 几个可选字段，
  不传也能正常写。
- 注意 `/item/<guid>/playing` 不是这个用的：它返回 `code: 0` 但**不会改 `ts`**，
  容易误判成成功。

其余端点：

| 端点 | 作用 |
| --- | --- |
| `POST /v/api/v1/play/quality` | 切清晰度 |
| `POST /v/api/v1/media/p` | 重置音轨/字幕、退出播放 |
| `POST /v/api/v1/play/record` | **回写进度（就这一个有用）** |
| `POST /v/api/v1/item/<guid>/playing` | 返回 0 但不生效，别用 |

### 5.5 实测（mpv 直连）

`mpv --http-header-fields-add="Authorization: <token>" <range URL>` 直接可播：

```
Video  --vid=1  (hevc [Main 10] 3840x2160 23.976 fps)
Audio  --aid=1  (dts [DTS-HD MA] 6ch 48000 Hz)
Audio  --aid=2/3 (dts 6ch)
Subs   --sid=1..9 (hdmv_pgs_subtitle)
Using hardware decoding (d3d11va).
VO: [gpu-next] 3840x2160 d3d11[p010]
```

注意容器其实是 **MPEG-TS**（服务端实时 remux），即使源是 mkv 原盘；
所以 `Content-Type: video/mp2t` 是对的，海报那个 `image/webp` 才是写错的。
蓝光原盘的 3 条音轨、9 条 PGS 字幕都完整带过来。

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
| `POST /v/api/v1/person/list/<guid>` | 影片演员；本机库实测返回 `{"list":[],"total":0}`，刮削没存人 |
| `GET /v/api/v1/stream/list/<media_guid>` | 文件媒体信息（界面「文件媒体信息」弹窗的数据源）：`video_stream` / `audio_streams`，字段是 ffprobe 那套，码率叫 `bps`、帧率是 `"30 fps"` 字符串 |

搜索用 `GET /v/api/v1/search/list?q=`（见 §4.2.1），`item/list` 的关键词参数无效。

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
