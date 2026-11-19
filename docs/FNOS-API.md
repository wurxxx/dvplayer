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

| 端点 | 作用 |
| --- | --- |
| `POST /v/api/v1/play/info` | 取播放信息（含直链/转码选项） |
| `POST /v/api/v1/play/play` | 开始播放 |
| `POST /v/api/v1/play/quality` | 切清晰度 |
| `POST /v/api/v1/media` | 取播放链接（`getPlayLink`），也用于退出播放 |
| `POST /v/api/v1/media/p` | 重置音轨/字幕、检查链接、退出 |
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
3. **图片地址（未解决）**：`poster` 是 `/94/05/xxx.webp` 这种相对路径。
   实测 `{base}{poster}`、`/v/static{poster}`、`/v/img{poster}` 都落到 SPA 的 index.html；
   `/v/media{poster}` 返回 `{"msg":"Auth Failed"}`，说明图片服务存在但要鉴权，
   而 `<img>` 不能带 Authorization 头，前端应该用 query 参数或 cookie，尚未确认。
   当前界面上海报位留空占位。
4. **多服务器聚合**：每个源一个适配器（`FnOsSource` / `EmbySource`），统一成
   `MediaLibrary / MediaItem / PlayRecord`，再做合并与去重。实现在 `core/media`（Rust），
   三端只做界面，见 ADR-0008。
