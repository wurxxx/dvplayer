# 每日推荐（TMDB / 豆瓣 → MoviePilot）

打开应用时抓一份当天的热门：媒体源里已经有的，点开直接进详情；没有的可以一键推到
MoviePilot 自动订阅。两端（macOS / Windows）功能与判定规则一致，入口都在侧栏的
「每日推荐」页。

## 1. 数据来源

| 来源 | 接口 | 说明 |
| --- | --- | --- |
| TMDB | `https://api.themoviedb.org/3/trending/all/day?api_key=<KEY>&language=zh-CN` | 需要设置里填 v3 API Key；不填就跳过，只显示豆瓣。可以单独配代理（见 1.1） |
| 豆瓣 | `https://movie.douban.com/j/search_subjects?type=movie\|tv&tag=热门&page_limit=30&page_start=0` | 电影 / 剧集各 30 条；必须带桌面 UA 和 `Referer: https://movie.douban.com/`，否则返回 418 |

豆瓣没有公开 API，这个 `j/search_subjects` 是网页自己的接口：字段少（标题、评分、
海报、条目页），没有年份。两边抓到的条目按「归一化标题 + 电影 / 剧集」合并去重，
TMDB 在前。

海报由客户端自己下载（豆瓣图片同样要带 Referer），两端的图片缓存都只放内存，
不进磁盘。

### 1.1 TMDB 代理

TMDB 在部分网络下无法直连（DNS 被污染 / 连接超时）。设置里的「TMDB 代理」
只给 TMDB 用，不影响别的请求：

- 写法：`http://127.0.0.1:7897`、`127.0.0.1:7897`、`socks5://host:port`；
- 留空 = 跟随系统代理；
- 生效范围：TMDB API（`api.themoviedb.org`）和海报（`image.tmdb.org`）；
- 豆瓣与 MoviePilot 不走它：MoviePilot 一般在内网，固定直连。

实现：macOS 用 `URLSessionConfiguration.connectionProxyDictionary` 建独立会话，
Windows 用 `HttpClientHandler.Proxy` 按代理地址缓存一个 `HttpClient`。

## 2. 缓存

- 文件：`daily.json`（macOS：`~/Library/Application Support/DvPlayer/`，
  Windows：`%LOCALAPPDATA%\dvplayer\`）。
- 按天存：`date` 是本地日期，打开应用时当天已有缓存就不再请求 TMDB / 豆瓣。
- 页头的「刷新」会强制重抓；重抓时保留上次的匹配 / 订阅状态，不会把已订阅的条目
  变回「可订阅」。
- 抓取的错误也存进缓存（`tmdbError` / `doubanError`），页面上给出提示；豆瓣电影和
  剧集是分开请求的，一边失败不影响另一边。

## 3. 匹配媒体源

用共享内核的聚合搜索，和搜索页同一条路：

- macOS：`Core.search(title)`；Windows：`MediaCore.Search(title)`。
- 标题归一化：去掉括号里的内容（`()（）[]【】`）、`第 N 季 / 第 N 部`、空白和标点，
  全部转小写。
- 类型过滤：推荐是剧集时只看 `series / tv / folder`，电影只看 `movie / folder`。
- 先找标题完全一致且年份相差不超过 1 的；没有再退到标题完全一致；最后允许互相包含。
- 命中后卡片左下角显示「在库」。匹配是逐条发布的：不用等 60 条全部搜完才亮。

点卡片的行为：

| 状态 | 点击 |
| --- | --- |
| 已匹配 | 打开详情页（`SeriesPage(itemId)` / `AppState.openDetail`） |
| 未匹配、未订阅 | POST 到 MoviePilot 订阅 |
| 已订阅 | 提示「已经推送到 MoviePilot 了」 |

## 4. MoviePilot 订阅

设置项：**地址** + **API Token**（MoviePilot 的「设置 → API」里可以拿到）。

```
POST <地址>/api/v1/subscribe/?apikey=<TOKEN>
Content-Type: application/json

{
  "name": "片名",
  "year": "2026",          // 有年份才带
  "type": "电影" | "电视剧",
  "tmdbid": 123456,        // TMDB 条目带
  "doubanid": "36847425",  // 豆瓣条目带
  "season": 0
}
```

- **只带 `?apikey=`**。不要同时带 `Authorization: Bearer`：MoviePilot 会把 Bearer
  当成登录令牌去校验，API Token 放进去反而 403（`token校验不通过`）。
- 401 / 403 提示检查 Token；其它非 2xx 提示 HTTP 状态码和服务端返回的
  `message` / `detail`。
- HTTP 200 也可能是业务失败（`success: false`，例如「未识别到媒体信息」），
  这种情况按失败处理，不会把卡片标成「已订阅」。
- 豆瓣条目带 `doubanid`，MoviePilot 可以按豆瓣识别；仍识别不到时按标题 + 年份，
  再失败就提示服务端原文，并建议填上 TMDB API Key 改用 TMDB 条目订阅。
- 设置页的「测试连接」发一个只读的 `GET /api/v1/subscribe/`（订阅列表），
  既确认地址可达，也验证 Token；不会真的订阅。

凭据保存：

- macOS：和 Trakt Client Secret 一样写在 `settings.json`（明文，文件权限跟随用户目录）。
- Windows：`tmdbApiKey` / `moviePilotToken` 落盘时用 DPAPI 密封（`dpapi:v1:` 前缀，
  按当前用户），`moviePilotUrl` 不加密。

## 5. 自检

macOS：

```bash
DVPLAYER_PAGE=daily DVPLAYER_SHOT=/tmp/daily.jpg DVPLAYER_SHOT_DELAY=20 \
  apps/macos/DvPlayer/.build/release/DvPlayer
```

`DVPLAYER_PAGE` 也接受 `daily`；`DVPLAYER_EXIT=1` 截完就退。

Windows：

```bat
DvPlayer.exe --screenshot D:\shots daily
```

`--screenshot` 的页面列表里加了 `daily`，这一页会多等一会儿（抓取 + 匹配）。

## 6. 已知限制

- 豆瓣这个接口不是官方的，改版或加验证时需要跟着调；失败时页面会显示原因，
  TMDB 部分不受影响。
- 匹配是标题 + 年份的启发式，译名差异大（港台译名 / 英文原名）时可能匹配不到；
  这时点卡片会走订阅，不会误开别的片。
- Windows 测试机如果装了会做 TLS 中间人的代理 / 抓包工具，HTTPS 请求会因为证书
  主机名不匹配失败；这是环境问题，正常网络下不受影响，换台机器或关掉中间人即可。
