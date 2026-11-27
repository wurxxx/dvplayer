using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DvPlayer.Services;

/// <summary>
/// 每日推荐：TMDB / 豆瓣热门 → 匹配本地媒体源 → 媒体源里没有的推到 MoviePilot。
///
/// 抓取按天缓存到 <c>daily.json</c>，打开应用时当天已有缓存就不再请求。
/// 匹配用共享核心的聚合搜索，和搜索页同一条路。
/// </summary>
public static class DailyService
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(25) };

    /// <summary>按代理地址缓存的 TMDB 客户端；没填代理就用默认的 Http。</summary>
    private static readonly Dictionary<string, HttpClient> TmdbClients = new();
    private static readonly object TmdbGate = new();

    private static HttpClient TmdbClient()
    {
        var raw = AppServices.Instance.Settings.TmdbProxy?.Trim() ?? "";
        if (raw.Length == 0)
        {
            return Http;
        }

        lock (TmdbGate)
        {
            if (TmdbClients.TryGetValue(raw, out var cached))
            {
                return cached;
            }

            try
            {
                var address = raw.Contains("://", StringComparison.Ordinal) ? raw : "http://" + raw;
                var handler = new HttpClientHandler
                {
                    Proxy = new System.Net.WebProxy(new Uri(address)),
                    UseProxy = true,
                };
                var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(25) };
                TmdbClients[raw] = client;
                return client;
            }
            catch (UriFormatException)
            {
                // 代理写得不像地址：这张请求直连，别让推荐页崩掉。
                Trace.Write("tmdb proxy invalid " + raw);
                return Http;
            }
        }
    }

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>当前这一天的数据（先读缓存，没有就是 null）。</summary>
    public static DailyFeed? Feed { get; private set; }

    public static bool Loading { get; private set; }
    public static bool Matching { get; private set; }
    public static string? Error { get; private set; }

    /// <summary>数据 / 状态变了：页面重画。可能在后台线程触发，订阅方自己切 UI 线程。</summary>
    public static event Action? Changed;

    public static string Today => DateTime.Now.ToString("yyyy-MM-dd");

    /// <summary>已经完整匹配过一轮的数据签名：切回页面不重复搜同一批条目。</summary>
    private static string _matchSignature = "";

    public static IReadOnlyList<DailyItem> Items =>
        Feed?.Items ?? (IReadOnlyList<DailyItem>)Array.Empty<DailyItem>();

    private static string CachePath
    {
        get
        {
            var directory = Path.GetDirectoryName(AppSettings.FilePath) ?? ".";
            return Path.Combine(directory, "daily.json");
        }
    }

    static DailyService()
    {
        Feed = LoadCache();
    }

    // MARK: - 刷新

    /// <summary>当天已有缓存就只补匹配；否则抓一次（打开应用时调用）。</summary>
    public static async Task RefreshIfNeededAsync()
    {
        if (Feed is { } feed && feed.Date == Today && feed.Items.Count > 0)
        {
            _ = LoadPostersAsync();
            if (AppServices.Instance.Core is not null
                && SignatureOf(feed) != _matchSignature)
            {
                await MatchAllAsync();
            }
            return;
        }

        await RefreshAsync(force: false);
    }

    public static async Task RefreshAsync(bool force)
    {
        if (Loading)
        {
            return;
        }

        if (!force && Feed is { } existing && existing.Date == Today && existing.Items.Count > 0)
        {
            return;
        }

        Loading = true;
        Error = null;
        lock (ImageGate)
        {
            FailedImages.Clear();
        }
        Changed?.Invoke();

        try
        {
            var settings = AppServices.Instance.Settings;
            var apiKey = settings.TmdbApiKey?.Trim() ?? "";

            var tmdbTask = LoadTmdbAsync(apiKey);
            var doubanTask = LoadDoubanAsync();
            var tmdb = await tmdbTask;
            var douban = await doubanTask;

            // 重新抓取保留上次的匹配 / 订阅状态：同一条片不用再匹配一遍，
            // 已订阅的也不会因为刷新变回「可订阅」。
            var previous = new Dictionary<string, DailyItem>();
            foreach (var old in Feed?.Items ?? new List<DailyItem>())
            {
                previous[old.MatchKey] = old;
            }

            var merged = new List<DailyItem>();
            var seen = new HashSet<string>();
            foreach (var item in tmdb.Items.Concat(douban.Items))
            {
                if (!seen.Add(item.MatchKey))
                {
                    continue;
                }

                if (previous.TryGetValue(item.MatchKey, out var old))
                {
                    item.MatchedItemId = old.MatchedItemId;
                    item.MatchedTitle = old.MatchedTitle;
                    item.Subscribed = old.Subscribed;
                }

                merged.Add(item);
            }

            Feed = new DailyFeed
            {
                Date = Today,
                FetchedAt = DateTime.Now,
                Items = merged,
                TmdbError = tmdb.Error,
                DoubanError = douban.Error,
            };

            Error = merged.Count == 0
                ? tmdb.Error ?? douban.Error ?? "没有取到热门资源"
                : apiKey.Length > 0 && tmdb.Error is not null && douban.Items.Count == 0
                    ? tmdb.Error
                    : null;

            _matchSignature = "";
            SaveCache();
        }
        catch (Exception ex)
        {
            Error = "获取推荐失败：" + ex.Message;
        }
        finally
        {
            Loading = false;
            Changed?.Invoke();
        }

        await MatchAllAsync();

        // 海报在后台一张张补：先让网格出来，别等全部下载完。
        _ = LoadPostersAsync();
    }

    private static async Task<(List<DailyItem> Items, string? Error)> LoadTmdbAsync(string apiKey)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            return (new List<DailyItem>(), null);
        }

        try
        {
            var url = "https://api.themoviedb.org/3/trending/all/day"
                      + "?api_key=" + Uri.EscapeDataString(apiKey) + "&language=zh-CN";
            // TMDB 走外网，超时给短一点：不通时别让豆瓣的数据跟着等 25 秒。
            using var document = await GetJsonAsync(url, timeoutSeconds: 10, client: TmdbClient());
            var root = document.RootElement;

            if (!root.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array)
            {
                return (new List<DailyItem>(), "TMDB：返回格式不对");
            }

            var items = new List<DailyItem>();
            foreach (var result in results.EnumerateArray())
            {
                var mediaType = result.TryGetProperty("media_type", out var type) ? type.GetString() : null;
                if (mediaType is not ("movie" or "tv"))
                {
                    continue;
                }

                var title = FirstString(result, "title", "name", "original_title", "original_name");
                if (string.IsNullOrWhiteSpace(title)
                    || !result.TryGetProperty("id", out var idValue)
                    || !idValue.TryGetInt32(out var tmdbId))
                {
                    continue;
                }

                var date = FirstString(result, "release_date", "first_air_date");
                int? year = date.Length >= 4 && int.TryParse(date[..4], out var parsedYear)
                    ? parsedYear
                    : null;

                var posterPath = result.TryGetProperty("poster_path", out var poster)
                                 && poster.ValueKind == JsonValueKind.String
                    ? poster.GetString()
                    : null;

                items.Add(new DailyItem
                {
                    Id = $"tmdb:{mediaType}:{tmdbId}",
                    Title = title.Trim(),
                    Year = year,
                    Kind = mediaType,
                    Rating = result.TryGetProperty("vote_average", out var vote)
                              && vote.TryGetDouble(out var score) ? score : null,
                    PosterUrl = posterPath is { Length: > 0 }
                        ? "https://image.tmdb.org/t/p/w500" + posterPath
                        : null,
                    Overview = result.TryGetProperty("overview", out var overview)
                        ? overview.GetString()
                        : null,
                    TmdbId = tmdbId,
                    Trend = "TMDB",
                });
            }

            return (items, null);
        }
        catch (Exception ex)
        {
            return (new List<DailyItem>(), "TMDB：" + ex.Message);
        }
    }

    private static async Task<(List<DailyItem> Items, string? Error)> LoadDoubanAsync()
    {
        // 电影和剧集分开抓：一页失败不应该把另一页也丢掉。
        var items = new List<DailyItem>();
        var errors = new List<string>();

        try
        {
            items.AddRange(await LoadDoubanTypeAsync("movie"));
        }
        catch (Exception ex)
        {
            errors.Add("电影 " + ex.Message);
        }

        try
        {
            items.AddRange(await LoadDoubanTypeAsync("tv"));
        }
        catch (Exception ex)
        {
            errors.Add("剧集 " + ex.Message);
        }

        return (items, errors.Count == 0 ? null : "豆瓣：" + string.Join("；", errors));
    }

    private static async Task<List<DailyItem>> LoadDoubanTypeAsync(string type)
    {
        var url = "https://movie.douban.com/j/search_subjects"
                  + "?type=" + type
                  + "&tag=" + Uri.EscapeDataString("热门")
                  + "&page_limit=30&page_start=0";

        using var document = await GetJsonAsync(url, "https://movie.douban.com/");
        if (!document.RootElement.TryGetProperty("subjects", out var subjects)
            || subjects.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("返回格式不对");
        }

        var items = new List<DailyItem>();
        foreach (var subject in subjects.EnumerateArray())
        {
            var doubanId = subject.TryGetProperty("id", out var id) ? id.GetString() : null;
            var title = subject.TryGetProperty("title", out var titleValue)
                ? titleValue.GetString()?.Trim()
                : null;
            if (string.IsNullOrEmpty(doubanId) || string.IsNullOrEmpty(title))
            {
                continue;
            }

            // 剧集接口的 episodes_info 是「更新至 16 集」，非空基本就是剧。
            var episodes = subject.TryGetProperty("episodes_info", out var episodesValue)
                ? episodesValue.GetString()
                : null;
            var isTv = type == "tv" || !string.IsNullOrWhiteSpace(episodes);

            double? rating = null;
            if (subject.TryGetProperty("rate", out var rate)
                && double.TryParse(rate.GetString(), out var parsedRate)
                && parsedRate > 0)
            {
                rating = parsedRate;
            }

            items.Add(new DailyItem
            {
                Id = $"douban:{(isTv ? "tv" : "movie")}:{doubanId}",
                Title = title,
                Kind = isTv ? "tv" : "movie",
                Rating = rating,
                PosterUrl = subject.TryGetProperty("cover", out var cover) ? cover.GetString() : null,
                Trend = "豆瓣",
                Link = subject.TryGetProperty("url", out var link) ? link.GetString() : null,
            });
        }

        return items;
    }

    // MARK: - 匹配媒体源

    public static async Task MatchAllAsync()
    {
        if (Matching || Feed is not { } feed)
        {
            return;
        }

        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var signature = SignatureOf(feed);
        if (signature == _matchSignature)
        {
            return;
        }

        Matching = true;
        Changed?.Invoke();

        try
        {
            foreach (var item in feed.Items.ToList())
            {
                if (item.MatchedItemId is not null || item.Subscribed)
                {
                    continue;
                }

                var hit = await MatchAsync(item, core);
                if (hit is not null)
                {
                    item.SetMatched(hit.Id, hit.Title);
                    // 逐条发布：海报下面一个个亮起「在库」，不用等全部匹配完。
                    Changed?.Invoke();
                }
            }
        }
        finally
        {
            Matching = false;
            _matchSignature = signature;
            SaveCache();
            Changed?.Invoke();
        }
    }

    private static string SignatureOf(DailyFeed feed) =>
        string.Join(",", feed.Items.Select(item => item.Id));

    private static async Task<MediaItemDto?> MatchAsync(DailyItem item, MediaCore core)
    {
        var key = Normalize(item.Title);
        if (key.Length == 0)
        {
            return null;
        }

        var result = await Task.Run(() => core.Search(item.Title));
        if (!result.Ok || result.Data is null)
        {
            return null;
        }

        var wantsSeries = item.IsSeries;
        var pool = result.Data.Items.Where(candidate =>
        {
            var kind = candidate.Kind.ToLowerInvariant();
            return wantsSeries
                ? kind is "series" or "tv" or "folder"
                : kind is "movie" or "folder";
        }).ToList();

        var exact = pool.Where(candidate => Normalize(candidate.Title) == key).ToList();
        if (item.Year is { } year)
        {
            var sameYear = exact.FirstOrDefault(candidate => candidate.Year is { } other
                                                             && Math.Abs(other - year) <= 1);
            if (sameYear is not null)
            {
                return sameYear;
            }
        }

        if (exact.Count > 0)
        {
            return exact[0];
        }

        return pool.FirstOrDefault(candidate =>
        {
            var other = Normalize(candidate.Title);
            return other.Length > 0 && (other.Contains(key) || key.Contains(other));
        });
    }

    // MARK: - 订阅

    public static async Task<string> SubscribeAsync(DailyItem item)
    {
        var settings = AppServices.Instance.Settings;
        var baseUrl = settings.MoviePilotUrl?.Trim() ?? "";
        var token = settings.MoviePilotToken?.Trim() ?? "";
        if (baseUrl.Length == 0 || token.Length == 0)
        {
            return "先在设置里填 MoviePilot 地址和 API Token";
        }

        if (!baseUrl.StartsWith("http", StringComparison.OrdinalIgnoreCase))
        {
            baseUrl = "https://" + baseUrl;
        }

        baseUrl = baseUrl.TrimEnd('/');

        try
        {
            var url = baseUrl + "/api/v1/subscribe/?apikey=" + Uri.EscapeDataString(token);
            // MoviePilot 的 v1 接口只认 `?apikey=`（API Token）。
            // 不要同时带 Authorization: Bearer：那会被当成登录令牌校验，反而 403。
            using var request = new HttpRequestMessage(HttpMethod.Post, url);

            var body = new Dictionary<string, object?>
            {
                ["name"] = item.Title,
                ["type"] = item.IsSeries ? "电视剧" : "电影",
                ["season"] = 0,
            };
            if (item.Year is { } year)
            {
                body["year"] = year.ToString();
            }

            if (item.TmdbId is { } tmdbId)
            {
                body["tmdbid"] = tmdbId;
            }

            // 豆瓣条目带上豆瓣 id：没填 TMDB Key 时 MoviePilot 也能按豆瓣识别。
            if (item.Id.StartsWith("douban:", StringComparison.Ordinal))
            {
                var doubanId = item.Id.Split(':').LastOrDefault();
                if (!string.IsNullOrEmpty(doubanId))
                {
                    body["doubanid"] = doubanId;
                }
            }

            request.Content = new StringContent(
                JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

            using var response = await Http.SendAsync(request);
            var text = await response.Content.ReadAsStringAsync();
            var message = ReadMessage(text);

            if (!response.IsSuccessStatusCode)
            {
                var code = (int)response.StatusCode;
                return code is 401 or 403
                    ? "订阅失败：MoviePilot 认证失败，检查 API Token"
                    : $"订阅失败：HTTP {code} {message}";
            }

            // HTTP 200 也可能是业务失败（例如识别不到媒体），不能当成订阅成功。
            if (IsExplicitFailure(text))
            {
                var hint = item.TmdbId is null && message.Contains("未识别", StringComparison.Ordinal)
                    ? "（豆瓣条目没有 TMDB id；填上 TMDB API Key 后用 TMDB 的条目订阅）"
                    : "";
                return "订阅失败：" + (message.Length > 0
                    ? message + hint
                    : "MoviePilot 拒绝了这次订阅");
            }

            item.Subscribed = true;
            item.RaiseState();
            SaveCache();
            Changed?.Invoke();

            return message.Length > 0 ? "MoviePilot：" + message : "已推送到 MoviePilot";
        }
        catch (Exception ex)
        {
            return "订阅失败：" + ex.Message;
        }
    }

    /// <summary>设置页的连通性自检：只发一个只读请求。</summary>
    public static async Task<string> CheckPilotAsync(string rawBase, string rawToken)
    {
        var baseUrl = rawBase.Trim();
        var token = rawToken.Trim();
        if (baseUrl.Length == 0 || token.Length == 0)
        {
            throw new InvalidOperationException("先填地址和 API Token");
        }

        if (!baseUrl.StartsWith("http", StringComparison.OrdinalIgnoreCase))
        {
            baseUrl = "https://" + baseUrl;
        }

        baseUrl = baseUrl.TrimEnd('/');

        // 用订阅列表做只读探活：既确认地址可达，也验证 API Token。
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            baseUrl + "/api/v1/subscribe/?apikey=" + Uri.EscapeDataString(token));

        using var response = await Http.SendAsync(request);

        if (response.IsSuccessStatusCode)
        {
            return "连接正常，API Token 有效";
        }

        return (int)response.StatusCode switch
        {
            401 or 403 => throw new InvalidOperationException("认证失败：检查 API Token"),
            404 => "地址能连上（订阅接口未找到，可能是很老的版本）",
            var code => throw new InvalidOperationException($"HTTP {code}"),
        };
    }

    private static bool IsExplicitFailure(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            return document.RootElement.TryGetProperty("success", out var success)
                   && success.ValueKind == JsonValueKind.False;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string ReadMessage(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            foreach (var key in new[] { "message", "detail" })
            {
                if (root.TryGetProperty(key, out var value)
                    && value.ValueKind == JsonValueKind.String)
                {
                    return value.GetString() ?? "";
                }
            }
        }
        catch (JsonException)
        {
            // 不是 JSON：原样截一段给用户看。
        }

        return text.Length > 120 ? text[..120] : text;
    }

    // MARK: - 缓存 / 图片

    private static void SaveCache()
    {
        if (Feed is not { } feed)
        {
            return;
        }

        try
        {
            File.WriteAllText(CachePath, JsonSerializer.Serialize(feed, Json));
        }
        catch (Exception ex)
        {
            Trace.Write("daily cache write failed: " + ex.Message);
        }
    }

    private static DailyFeed? LoadCache()
    {
        try
        {
            if (!File.Exists(CachePath))
            {
                return null;
            }

            var feed = JsonSerializer.Deserialize<DailyFeed>(File.ReadAllText(CachePath), Json);
            // 老缓存里的条目没有界面状态字段，读进来后补一遍。
            feed?.Items.ForEach(item => item.RaiseState());
            return feed;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>页面打开时把（缓存里）还没加载的海报补上。</summary>
    public static Task EnsurePostersAsync() => LoadPostersAsync();

    private static readonly HashSet<string> FailedImages = new();

    private static async Task LoadPostersAsync()
    {
        // 并发几张就够：一张张下完 60 张太慢，全放出去又会把带宽挤满。
        using var gate = new SemaphoreSlim(6);
        var tasks = Items
            .Where(item => item.PosterUrl is { Length: > 0 })
            .Select(async item =>
            {
                await gate.WaitAsync();
                try
                {
                    await item.LoadPosterAsync();
                }
                finally
                {
                    gate.Release();
                }
            })
            .ToList();

        await Task.WhenAll(tasks);
    }

    private static async Task<JsonDocument> GetJsonAsync(string url, string? referer = null,
                                                          int timeoutSeconds = 25,
                                                          HttpClient? client = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120 Safari/537.36");
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        if (referer is not null)
        {
            request.Headers.TryAddWithoutValidation("Referer", referer);
        }

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        using var response = await (client ?? Http).SendAsync(request, cts.Token);
        var text = await response.Content.ReadAsStringAsync(cts.Token);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"HTTP {(int)response.StatusCode}");
        }

        return JsonDocument.Parse(text);
    }

    private static readonly Dictionary<string, BitmapSource> ImageCache = new();
    private static readonly object ImageGate = new();

    /// <summary>推荐海报：豆瓣必须带 Referer，否则 418。</summary>
    internal static async Task<BitmapSource?> LoadImageAsync(string url)
    {
        lock (ImageGate)
        {
            if (ImageCache.TryGetValue(url, out var cached))
            {
                return cached;
            }

            if (FailedImages.Contains(url))
            {
                return null;
            }
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/120 Safari/537.36");
            if (url.Contains("douban", StringComparison.OrdinalIgnoreCase))
            {
                request.Headers.TryAddWithoutValidation("Referer", "https://movie.douban.com/");
            }

            var client = url.Contains("tmdb", StringComparison.OrdinalIgnoreCase)
                ? TmdbClient()
                : Http;
            using var response = await client.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                lock (ImageGate)
                {
                    FailedImages.Add(url);
                }
                return null;
            }

            var bytes = await response.Content.ReadAsByteArrayAsync();
            using var stream = new MemoryStream(bytes);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();

            lock (ImageGate)
            {
                // 只为页面缓存几十张，翻页不会无限涨。
                if (ImageCache.Count > 150)
                {
                    ImageCache.Clear();
                }

                ImageCache[url] = image;
            }

            return image;
        }
        catch (Exception)
        {
            lock (ImageGate)
            {
                FailedImages.Add(url);
            }
            return null;
        }
    }

    // MARK: - 标题归一化

    private static readonly Regex BracketPattern = new(@"[\(（\[【].*?[\)）\]】]", RegexOptions.Compiled);
    private static readonly Regex SeasonPattern = new(@"第[0-9一二三四五六七八九十]+[季部]", RegexOptions.Compiled);
    private static readonly Regex NoisePattern = new(@"[\s\p{P}\p{S}]+", RegexOptions.Compiled);

    /// <summary>去括号内容、季数、标点和空白：各源的标题写法不统一。</summary>
    public static string Normalize(string text)
    {
        var value = text.ToLowerInvariant();
        value = BracketPattern.Replace(value, "");
        value = SeasonPattern.Replace(value, "");
        return NoisePattern.Replace(value, "");
    }

    private static string FirstString(JsonElement element, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (element.TryGetProperty(key, out var value)
                && value.ValueKind == JsonValueKind.String)
            {
                var text = value.GetString();
                if (!string.IsNullOrWhiteSpace(text))
                {
                    return text;
                }
            }
        }

        return "";
    }
}

/// <summary>一天一份的推荐缓存。</summary>
public sealed class DailyFeed
{
    public string Date { get; set; } = "";
    public DateTime FetchedAt { get; set; }
    public List<DailyItem> Items { get; set; } = new();
    public string? TmdbError { get; set; }
    public string? DoubanError { get; set; }
}

/// <summary>推荐里的一条；匹配到的媒体源条目 id 有值就能直接进详情。</summary>
public sealed class DailyItem : CardVisual
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public int? Year { get; set; }
    /// <summary>movie / tv</summary>
    public string Kind { get; set; } = "movie";
    public double? Rating { get; set; }
    public string? PosterUrl { get; set; }
    public string? Overview { get; set; }
    /// <summary>只有 TMDB 条目有，订阅时优先用它。</summary>
    public int? TmdbId { get; set; }
    /// <summary>TMDB / 豆瓣</summary>
    public string Trend { get; set; } = "";
    /// <summary>豆瓣条目页。</summary>
    public string? Link { get; set; }

    public string? MatchedItemId { get; set; }
    public string? MatchedTitle { get; set; }
    public bool Subscribed { get; set; }

    public bool IsSeries => string.Equals(Kind, "tv", StringComparison.OrdinalIgnoreCase);
    public bool InLibrary => !string.IsNullOrEmpty(MatchedItemId);

    /// <summary>去重用：归一化标题 + 电影 / 剧集。</summary>
    public string MatchKey => DailyService.Normalize(Title) + (IsSeries ? "#tv" : "#movie");

    public string Initial => Palette.InitialOf(Title);

    public string RatingText => Rating is { } rating && rating > 0
        ? rating.ToString("0.0")
        : "";

    public System.Windows.Visibility RatingVisibility =>
        Rating is > 0 ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;

    public string StateText => InLibrary ? "在媒体源里" : Subscribed ? "已订阅" : "点按订阅";

    public Brush StateBrush => InLibrary
        ? new SolidColorBrush(Color.FromRgb(0x4A, 0xDE, 0x80))
        : Subscribed
            ? new SolidColorBrush(Color.FromRgb(0xFF, 0xB0, 0x20))
            : new SolidColorBrush(Color.FromRgb(0x96, 0x96, 0xA4));

    public System.Windows.Visibility MatchedVisibility =>
        InLibrary ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;

    public string SubText => Year is { } year ? year.ToString() : "";

    public void SetMatched(string itemId, string title)
    {
        MatchedItemId = itemId;
        MatchedTitle = title;
        RaiseState();
    }

    public void RaiseState()
    {
        Raise(nameof(InLibrary));
        Raise(nameof(StateText));
        Raise(nameof(StateBrush));
        Raise(nameof(MatchedVisibility));
        Raise(nameof(SubText));
        Raise(nameof(RatingText));
        Raise(nameof(RatingVisibility));
    }

    public async Task LoadPosterAsync()
    {
        var bitmap = await DailyService.LoadImageAsync(PosterUrl!);
        if (bitmap is null)
        {
            return;
        }

        var brush = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        brush.Freeze();
        Background = brush;
        PlaceholderVisibility = System.Windows.Visibility.Collapsed;
    }
}
