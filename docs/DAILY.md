# 每日推荐（TMDB / 豆瓣 → MoviePilot）

打开应用时抓一份当天的热门：媒体源里已经有的，点开直接进媒体详情；没有的会打开
一个资料页（数据来自豆瓣 / TMDB），在资料页里看清楚简介、演职人员之后再点
「添加订阅」推到 MoviePilot。两端（macOS / Windows）功能与判定规则一致，入口都在
侧栏的「每日推荐」页。

## 1. 数据来源

| 来源 | 接口 | 说明 |
| --- | --- | --- |
| TMDB | `https://api.themoviedb.org/3/trending/all/day?api_key=<KEY>&language=zh-CN` | 需要设置里填 v3 API Key；不填就跳过，只显示豆瓣。可以单独配代理（见 1.1） |
| 豆瓣 | `https://movie.douban.com/j/search_subjects`（`type` 取 `movie` 或 `tv`，`tag=热门`） | 电影 / 剧集各 30 条；必须带桌面 UA 和 `Referer: https://movie.douban.com/`，否则返回 418 |

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
- 页头按电影 / 剧集分两个 tab，只有一类有数据时不出 tab；类型过滤：推荐是剧集时
  只看 `series / tv / folder`，电影只看 `movie / folder`。
- 先找标题完全一致且年份相差不超过 1 的；没有再退到标题完全一致；最后允许互相包含。
- 命中后卡片显示「在库」（亮绿）；已订阅显示「已订阅」，其余不显示状态。
  匹配是逐条发布的：不用等 60 条全部搜完才亮。

点卡片的行为：

| 状态 | 点击 |
| --- | --- |
| 已匹配 | 打开媒体详情页（`SeriesPage(itemId)` / `AppState.openDetail`） |
| 未匹配（含已订阅） | 打开资料页（豆瓣 / TMDB 数据），订阅在资料页里点 |

不会因为「看一眼」就订阅：卡片本身只负责打开资料页。

## 4. 条目资料页

媒体源里没有的条目，点开是一个和媒体详情页同结构的页面：大图 + 标题 / 年份 /
评分 / 类型 + 简介 + 演职人员 + 链接，底部是订阅说明。数据不经过媒体源接口：

| 条目 | 接口 | 说明 |
| --- | --- | --- |
| 豆瓣 | `https://m.douban.com/rexxar/api/v2/<movie 或 tv>/<id>?ck=&for_mobile=1` | 带桌面 UA 和 `Referer: https://m.douban.com/`；返回标题 / 原名 / 年份 / 简介 / 评分与评价人数 / 类型 / 国家 / 时长 / 导演 / 演员 / 海报 / 条目页 |
| TMDB | `https://api.themoviedb.org/3/<movie 或 tv>/<id>?api_key=<KEY>&language=zh-CN&append_to_response=credits,external_ids` | 走 TMDB 专用代理（见 1.1）；额外给出横版图、TMDB / IMDb 链接 |

- 详情接口失败时用列表里已有的字段兜底（标题、评分、海报、简介），页面顶部注明
  「资料没取全」，订阅按钮照常可用。
- 资料按条目缓存在进程内存里，来回进出详情页不重复请求；不落盘。
- 豆瓣只给竖版海报：资料页左侧放一张清楚的竖版海报卡，背景只用它放大模糊做
  氛围；TMDB 有横版图时按媒体详情页那样铺满。简介在按钮下面完整显示一份。
- 页内的「添加订阅」和原来的订阅是同一条路（见 5）；成功后按钮变成「已订阅」，
  卡片状态同步更新。

## 5. MoviePilot 订阅

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

## 6. 自检

macOS：

```bash
DVPLAYER_PAGE=daily DVPLAYER_SHOT=/tmp/daily.jpg DVPLAYER_SHOT_DELAY=20 \
  apps/macos/DvPlayer/.build/release/DvPlayer
```

`DVPLAYER_PAGE` 也接受 `daily`；`DVPLAYER_EXIT=1` 截完就退。
加 `DVPLAYER_DAILY_DETAIL=<片名>` 直接打开那条的资料页（只挑媒体源里没有的），
日志里会打一行 `[DailyTest] 详情 …` 说明取到了哪些字段。

Windows：

```bat
DvPlayer.exe --screenshot D:\shots daily
```

`--screenshot` 的页面列表里加了 `daily`，这一页会多等一会儿（抓取 + 匹配）。
加 `--daily-detail <片名>` 打开那条的资料页并另存一张 `daily-detail.png`。

## 7. 已知限制

- 豆瓣这个接口不是官方的，改版或加验证时需要跟着调；失败时页面会显示原因，
  TMDB 部分不受影响。
- 匹配是标题 + 年份的启发式，译名差异大（港台译名 / 英文原名）时可能匹配不到；
  这时点卡片会打开资料页，不会误开别的片。
- 豆瓣 / TMDB 的资料会变（评分、简介）；进程内缓存只在本次运行里有效，重启重新取。
- Windows 测试机如果装了会做 TLS 中间人的代理 / 抓包工具，HTTPS 请求会因为证书
  主机名不匹配失败；这是环境问题，正常网络下不受影响，换台机器或关掉中间人即可。
