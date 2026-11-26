using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using DvPlayer.Services;

namespace DvPlayer.Player;

/// <summary>Trakt 上匹配到的一条片子 / 一部剧。</summary>
internal sealed record TraktMatch(string Kind, int TraktId, string? Slug, string Title, int? Year)
{
    public string? WebUrl => string.IsNullOrWhiteSpace(Slug)
        ? null
        : $"https://trakt.tv/{(Kind == "movie" ? "movies" : "shows")}/{Slug}";
}

/// <summary>设备码：给用户看的 8 位码 + 轮询用的 device_code。</summary>
internal sealed record TraktDeviceCode(string DeviceCode, string UserCode, string VerificationUrl,
    double ExpiresIn, double Interval);

internal sealed class TraktToken
{
    public string AccessToken { get; set; } = "";
    public string RefreshToken { get; set; } = "";
    public long ExpiresAt { get; set; }
    public string? Username { get; set; }
}

internal sealed class TraktException : Exception
{
    public int StatusCode { get; }

    public TraktException(int status, string message) : base(message) => StatusCode = status;
}

/// <summary>轮询设备码时「用户还没在网页上确认」，不是错误。</summary>
internal sealed class TraktPendingException : Exception
{
}

/// <summary>
/// Trakt v2 客户端：设备码登录、token 刷新、搜索匹配、scrobble、评分 / 收藏 / 待看。
///
/// token 存在 <see cref="AppSettings"/>（DPAPI 密封），不单独落文件。
/// refresh token 是单次的，所以刷新要串行（<see cref="_refreshLock"/>）；
/// 播放页和详情页同时发请求时不能各刷各的。
/// </summary>
internal sealed class TraktClient
{
    public static TraktClient Shared { get; } = new();

    private const string BaseUrl = "https://api.trakt.tv";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(5);

    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private readonly object _cacheLock = new();

    private Dictionary<string, int> _ratings = new();
    private DateTime _ratingsAt = DateTime.MinValue;
    private HashSet<string> _watchlist = new();
    private DateTime _watchlistAt = DateTime.MinValue;
    private HashSet<string> _collection = new();
    private DateTime _collectionAt = DateTime.MinValue;

    private readonly object _matchLock = new();
    private Dictionary<string, TraktMatch>? _matches;

    private static AppSettings Settings => AppServices.Instance.Settings;

    public string ClientId => First(Settings.TraktClientId, TraktCredential.ClientId);
    public string ClientSecret => First(Settings.TraktClientSecret, TraktCredential.ClientSecret);

    public bool IsConfigured => !string.IsNullOrWhiteSpace(ClientId);

    public bool IsLoggedIn =>
        !string.IsNullOrWhiteSpace(Settings.TraktAccessToken) &&
        !string.IsNullOrWhiteSpace(Settings.TraktRefreshToken);

    public string? Username => Settings.TraktUsername;

    // MARK: 设备码登录

    public async Task<TraktDeviceCode> StartDeviceLoginAsync(CancellationToken token = default)
    {
        if (!IsConfigured) throw new TraktException(0, "没有 Trakt 应用凭据");

        var text = await SendAsync(HttpMethod.Post, "/oauth/device/code", null,
            new Dictionary<string, object?> { ["client_id"] = ClientId },
            authorized: false, retry: false, token).ConfigureAwait(false);

        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        return new TraktDeviceCode(
            root.GetProperty("device_code").GetString() ?? "",
            root.GetProperty("user_code").GetString() ?? "",
            root.TryGetProperty("verification_url", out var url)
                ? url.GetString() ?? "https://trakt.tv/activate"
                : "https://trakt.tv/activate",
            root.TryGetProperty("expires_in", out var expires) ? expires.GetDouble() : 600,
            Math.Max(2, root.TryGetProperty("interval", out var interval) ? interval.GetDouble() : 5));
    }

    /// <summary>轮询一次：没确认时抛 <see cref="TraktPendingException"/>。</summary>
    public async Task<TraktToken> PollDeviceTokenAsync(TraktDeviceCode device,
        CancellationToken token = default)
    {
        var body = new Dictionary<string, object?>
        {
            ["code"] = device.DeviceCode,
            ["client_id"] = ClientId,
        };
        if (!string.IsNullOrWhiteSpace(ClientSecret)) body["client_secret"] = ClientSecret;

        try
        {
            var text = await SendAsync(HttpMethod.Post, "/oauth/device/token", null, body,
                authorized: false, retry: false, token).ConfigureAwait(false);
            var fresh = ParseToken(text);
            SaveToken(fresh);
            return fresh;
        }
        catch (TraktException ex) when (ex.StatusCode == 400)
        {
            throw new TraktPendingException();
        }
        catch (TraktException ex) when (ex.StatusCode == 404 || ex.StatusCode == 410)
        {
            throw new TraktException(410, "设备码过期了，重新连接一次");
        }
        catch (TraktException ex) when (ex.StatusCode == 418)
        {
            throw new TraktException(418, "在网页上拒绝了授权");
        }
    }

    /// <summary>登录成功后补一次用户名（设备码响应里没有）。</summary>
    public async Task<string?> FetchUsernameAsync(CancellationToken token = default)
    {
        var text = await SendAsync(HttpMethod.Get, "/users/settings", null, null,
            token: token).ConfigureAwait(false);
        using var doc = JsonDocument.Parse(text);
        if (doc.RootElement.TryGetProperty("user", out var user) &&
            user.TryGetProperty("username", out var name))
        {
            var value = name.GetString();
            Settings.TraktUsername = value;
            Settings.Save();
            return value;
        }

        return null;
    }

    public async Task LogoutAsync(CancellationToken token = default)
    {
        var access = Settings.TraktAccessToken;
        if (!string.IsNullOrWhiteSpace(access))
        {
            try
            {
                await SendAsync(HttpMethod.Post, "/oauth/revoke", null,
                    new Dictionary<string, object?>
                    {
                        ["token"] = access,
                        ["client_id"] = ClientId,
                        ["client_secret"] = ClientSecret,
                    }, authorized: false, retry: false, token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // 网络不通也照样清本地。
            }
        }

        Settings.TraktAccessToken = null;
        Settings.TraktRefreshToken = null;
        Settings.TraktExpiresAt = null;
        Settings.TraktUsername = null;
        Settings.Save();

        lock (_cacheLock)
        {
            _ratingsAt = DateTime.MinValue;
            _watchlistAt = DateTime.MinValue;
            _collectionAt = DateTime.MinValue;
        }
    }

    // MARK: 匹配

    /// <summary>
    /// 在 Trakt 里找条目：先用库里的 TMDB / IMDb id 精确查，都没有（或查不到）
    /// 再按片名 + 年份搜。宁可没有也不挂错：片名去掉空白标点后必须完全一致，
    /// 年份都有时最多差 1 年（首映年 vs 文件年份）。
    /// </summary>
    public async Task<TraktMatch?> MatchAsync(string title, int? year, bool series,
        string? tmdbId = null, string? imdbId = null, CancellationToken token = default)
    {
        var kind = series ? "show" : "movie";

        // id 优先：服务器刮削时记下的 id 不会和别的片子撞名。
        foreach (var (type, raw) in new[] { ("tmdb", tmdbId), ("imdb", imdbId) })
        {
            var value = raw?.Trim();
            if (string.IsNullOrEmpty(value)) continue;

            var idKey = $"{kind}|{type}|{value}";
            lock (_matchLock)
            {
                LoadMatchesIfNeeded();
                if (_matches!.TryGetValue(idKey, out var cached)) return cached;
            }

            var found = await FindByIdAsync(kind, type, value, token).ConfigureAwait(false);
            if (found is not null) return Accept(idKey, found);
        }

        var key = MatchKey(title, year, series);
        lock (_matchLock)
        {
            LoadMatchesIfNeeded();
            if (_matches!.TryGetValue(key, out var cached)) return cached;
        }

        var query = "?query=" + Uri.EscapeDataString(title) + "&limit=10";
        // 搜索是公开端点：没登录也能按标题找条目（scrobble 才需要 token）。
        var text = await SendAsync(HttpMethod.Get, series ? "/search/show" : "/search/movie",
            query, null, authorized: false, token: token).ConfigureAwait(false);

        using var doc = JsonDocument.Parse(text);
        if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;

        var wanted = Normalize(title);
        TraktMatch? yearFallback = null;

        foreach (var entry in doc.RootElement.EnumerateArray())
        {
            var item = entry.TryGetProperty(series ? "show" : "movie", out var nested) ? nested : entry;
            if (!item.TryGetProperty("ids", out var ids) ||
                !ids.TryGetProperty("trakt", out var idElement) ||
                !idElement.TryGetInt32(out var traktId)) continue;

            var name = item.TryGetProperty("title", out var titleElement)
                ? titleElement.GetString()
                : null;
            if (name is null) continue;

            int? itemYear = item.TryGetProperty("year", out var yearElement) &&
                            yearElement.TryGetInt32(out var value)
                ? value
                : null;

            var sameName = Normalize(name) == wanted;
            bool? sameYear = year is null || itemYear is null
                ? null
                : Math.Abs(year.Value - itemYear.Value) <= 1;

            var slug = ids.TryGetProperty("slug", out var slugElement) ? slugElement.GetString() : null;
            var found = new TraktMatch(series ? "show" : "movie", traktId, slug, name, itemYear);

            if (sameName)
            {
                // 标题完全一致：年份差 1 年内直接认；本地没年份也认。
                if (sameYear ?? true) return Accept(key, found);
                continue;
            }

            // 中文片名在 Trakt 里显示成原名（「千与千寻」→ Spirited Away）：
            // 标题对不上时只按年份认第一条，两边都得有年份。
            if (yearFallback is null && sameYear == true) yearFallback = found;
        }

        if (yearFallback is not null) return Accept(key, yearFallback);

        // 本地没有年份、搜索结果又只有一条：采用它（常见于刚上映的片子）。
        if (year is null && doc.RootElement.GetArrayLength() == 1)
        {
            var only = doc.RootElement[0];
            var item = only.TryGetProperty(series ? "show" : "movie", out var nested) ? nested : only;
            if (item.TryGetProperty("ids", out var ids) &&
                ids.TryGetProperty("trakt", out var idElement) &&
                idElement.TryGetInt32(out var traktId) &&
                item.TryGetProperty("title", out var titleElement) &&
                titleElement.GetString() is { } name)
            {
                int? itemYear = item.TryGetProperty("year", out var yearElement) &&
                                yearElement.TryGetInt32(out var value)
                    ? value
                    : null;
                var slug = ids.TryGetProperty("slug", out var slugElement)
                    ? slugElement.GetString()
                    : null;
                return Accept(key, new TraktMatch(series ? "show" : "movie", traktId, slug,
                    name, itemYear));
            }
        }

        return null;
    }

    /// <summary>`/search/tmdb/{id}?type=show` 这类 id 查询，取第一条。</summary>
    private async Task<TraktMatch?> FindByIdAsync(string kind, string type, string value,
        CancellationToken token)
    {
        var text = await SendAsync(HttpMethod.Get, $"/search/{type}/{Uri.EscapeDataString(value)}",
            "?type=" + kind, null, authorized: false, token: token).ConfigureAwait(false);

        using var doc = JsonDocument.Parse(text);
        if (doc.RootElement.ValueKind != JsonValueKind.Array ||
            doc.RootElement.GetArrayLength() == 0) return null;

        var entry = doc.RootElement[0];
        var item = entry.TryGetProperty(kind, out var nested) ? nested : entry;
        if (!item.TryGetProperty("ids", out var ids) ||
            !ids.TryGetProperty("trakt", out var idElement) ||
            !idElement.TryGetInt32(out var traktId) ||
            !item.TryGetProperty("title", out var titleElement) ||
            titleElement.GetString() is not { } name) return null;

        int? itemYear = item.TryGetProperty("year", out var yearElement) &&
                        yearElement.TryGetInt32(out var year)
            ? year
            : null;
        var slug = ids.TryGetProperty("slug", out var slugElement) ? slugElement.GetString() : null;
        return new TraktMatch(kind, traktId, slug, name, itemYear);
    }

    private TraktMatch Accept(string key, TraktMatch match)
    {
        lock (_matchLock)
        {
            _matches![key] = match;
            SaveMatches();
        }

        return match;
    }

    // MARK: 评分 / 收藏 / 待看

    public async Task<int?> RatingAsync(string kind, int traktId, CancellationToken token = default)
    {
        var map = await RatingMapAsync(token).ConfigureAwait(false);
        return map.TryGetValue($"{kind}:{traktId}", out var value) ? value : null;
    }

    public async Task SetRatingAsync(int? value, string kind, int traktId,
        CancellationToken token = default)
    {
        var entry = new Dictionary<string, object?> { ["ids"] = new Dictionary<string, object?> { ["trakt"] = traktId } };
        if (value is not null) entry["rating"] = value.Value;
        var path = value is null ? "/sync/ratings/remove" : "/sync/ratings";
        await SendAsync(HttpMethod.Post, path, null,
            new Dictionary<string, object?> { [kind == "movie" ? "movies" : "shows"] = new[] { entry } },
            token: token).ConfigureAwait(false);
        lock (_cacheLock) { _ratingsAt = DateTime.MinValue; }
    }

    public async Task<bool> IsInWatchlistAsync(string kind, int traktId,
        CancellationToken token = default)
    {
        var set = await WatchlistSetAsync(token).ConfigureAwait(false);
        return set.Contains($"{kind}:{traktId}");
    }

    public async Task SetWatchlistAsync(bool on, string kind, int traktId,
        CancellationToken token = default)
    {
        var noun = kind == "movie" ? "movies" : "shows";
        var path = on ? "/sync/watchlist" : "/sync/watchlist/remove";
        var body = new Dictionary<string, object?>
        {
            [noun] = new[] { new Dictionary<string, object?> { ["ids"] = new Dictionary<string, object?> { ["trakt"] = traktId } } },
        };
        await SendAsync(HttpMethod.Post, path, null, body, token: token).ConfigureAwait(false);
        lock (_cacheLock) { _watchlistAt = DateTime.MinValue; }
    }

    public async Task<bool> IsInCollectionAsync(string kind, int traktId,
        CancellationToken token = default)
    {
        var set = await CollectionSetAsync(token).ConfigureAwait(false);
        return set.Contains($"{kind}:{traktId}");
    }

    public async Task SetCollectionAsync(bool on, string kind, int traktId,
        CancellationToken token = default)
    {
        var noun = kind == "movie" ? "movies" : "shows";
        var path = on ? "/sync/collection" : "/sync/collection/remove";
        var body = new Dictionary<string, object?>
        {
            [noun] = new[] { new Dictionary<string, object?> { ["ids"] = new Dictionary<string, object?> { ["trakt"] = traktId } } },
        };
        await SendAsync(HttpMethod.Post, path, null, body, token: token).ConfigureAwait(false);
        lock (_cacheLock) { _collectionAt = DateTime.MinValue; }
    }

    // MARK: scrobble

    /// <summary>action = start / pause / stop。progress 是 0–100 的百分比。</summary>
    public async Task ScrobbleAsync(string action, TraktMatch match, int? season, int? episode,
        double progress, CancellationToken token = default)
    {
        var body = new Dictionary<string, object?>();
        if (match.Kind == "movie")
        {
            body["movie"] = new Dictionary<string, object?>
            {
                ["ids"] = new Dictionary<string, object?> { ["trakt"] = match.TraktId },
            };
        }
        else
        {
            body["show"] = new Dictionary<string, object?>
            {
                ["ids"] = new Dictionary<string, object?> { ["trakt"] = match.TraktId },
            };
            body["episode"] = new Dictionary<string, object?>
            {
                ["season"] = season ?? 1,
                ["number"] = episode ?? 1,
            };
        }

        body["progress"] = Math.Clamp(progress, 0.1, 100);
        await SendAsync(HttpMethod.Post, "/scrobble/" + action, null, body,
            token: token).ConfigureAwait(false);
    }

    // MARK: - 请求

    private async Task<string> SendAsync(HttpMethod method, string path, string? query,
        object? body, bool authorized = true, bool retry = true,
        CancellationToken token = default)
    {
        if (string.IsNullOrWhiteSpace(ClientId)) throw new TraktException(0, "没有 Trakt 应用凭据");

        using var request = new HttpRequestMessage(method, BaseUrl + path + (query ?? ""));
        request.Headers.TryAddWithoutValidation("trakt-api-version", "2");
        request.Headers.TryAddWithoutValidation("trakt-api-key", ClientId);
        request.Headers.TryAddWithoutValidation("User-Agent", "DVPlayer/1.0");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (body is not null)
        {
            request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8,
                "application/json");
        }

        if (authorized)
        {
            request.Headers.Authorization =
                new AuthenticationHeaderValue("Bearer", await ValidTokenAsync(false, token)
                    .ConfigureAwait(false));
        }

        using var response = await Http.SendAsync(request, token).ConfigureAwait(false);
        var text = await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);

        // access token 过期 / 被吊销：强制刷新后重试一次。
        if ((int)response.StatusCode == 401 && authorized && retry)
        {
            await ValidTokenAsync(true, token).ConfigureAwait(false);
            return await SendAsync(method, path, query, body, authorized, false, token)
                .ConfigureAwait(false);
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new TraktException((int)response.StatusCode,
                ComposeMessage(text, (int)response.StatusCode));
        }

        return text;
    }

    private async Task<string> ValidTokenAsync(bool force, CancellationToken token)
    {
        var settings = Settings;
        if (string.IsNullOrWhiteSpace(settings.TraktAccessToken) ||
            string.IsNullOrWhiteSpace(settings.TraktRefreshToken))
        {
            throw new TraktException(0, "还没连接 Trakt 账号");
        }

        if (!force && (settings.TraktExpiresAt ?? 0) > RefreshThreshold()) return settings.TraktAccessToken!;

        await _refreshLock.WaitAsync(token).ConfigureAwait(false);
        try
        {
            // 等锁期间别的请求可能已经刷好了。
            settings = Settings;
            if (!force && (settings.TraktExpiresAt ?? 0) > RefreshThreshold() &&
                !string.IsNullOrWhiteSpace(settings.TraktAccessToken))
            {
                return settings.TraktAccessToken!;
            }

            var refresh = settings.TraktRefreshToken;
            if (string.IsNullOrWhiteSpace(refresh))
            {
                throw new TraktException(0, "Trakt 登录已失效，重新连接一次");
            }

            var fresh = await RefreshAsync(refresh, token).ConfigureAwait(false);
            fresh.Username = Settings.TraktUsername;
            SaveToken(fresh);
            return fresh.AccessToken;
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private static long RefreshThreshold() =>
        DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();

    private async Task<TraktToken> RefreshAsync(string refreshToken, CancellationToken token)
    {
        var body = new Dictionary<string, object?>
        {
            ["refresh_token"] = refreshToken,
            ["client_id"] = ClientId,
            ["grant_type"] = "refresh_token",
            // 设备码应用没有 redirect uri，Trakt 要求这个固定值。
            ["redirect_uri"] = "urn:ietf:wg:oauth:2.0:oob",
        };
        if (!string.IsNullOrWhiteSpace(ClientSecret)) body["client_secret"] = ClientSecret;

        var text = await SendAsync(HttpMethod.Post, "/oauth/token", null, body,
            authorized: false, retry: false, token).ConfigureAwait(false);
        return ParseToken(text);
    }

    private static TraktToken ParseToken(string text)
    {
        using var doc = JsonDocument.Parse(text);
        var root = doc.RootElement;
        var expires = root.TryGetProperty("expires_in", out var e) && e.TryGetInt64(out var value)
            ? value
            : 7 * 24 * 3600;
        var created = root.TryGetProperty("created_at", out var c) && c.TryGetInt64(out var at)
            ? at
            : DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        return new TraktToken
        {
            AccessToken = root.GetProperty("access_token").GetString() ?? "",
            RefreshToken = root.GetProperty("refresh_token").GetString() ?? "",
            ExpiresAt = created + expires,
        };
    }

    private static void SaveToken(TraktToken token)
    {
        var settings = Settings;
        settings.TraktAccessToken = token.AccessToken;
        settings.TraktRefreshToken = token.RefreshToken;
        settings.TraktExpiresAt = token.ExpiresAt;
        if (!string.IsNullOrWhiteSpace(token.Username)) settings.TraktUsername = token.Username;
        settings.Save();
    }

    // MARK: - 全量缓存

    private async Task<Dictionary<string, int>> RatingMapAsync(CancellationToken token)
    {
        lock (_cacheLock)
        {
            if (DateTime.UtcNow - _ratingsAt < CacheTtl) return _ratings;
        }

        var map = new Dictionary<string, int>();
        foreach (var (kind, path) in new[]
                 {
                     ("movie", "/sync/ratings/movies"),
                     ("show", "/sync/ratings/shows"),
                 })
        {
            var text = await SendAsync(HttpMethod.Get, path, null, null, token: token)
                .ConfigureAwait(false);
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) continue;
            foreach (var entry in doc.RootElement.EnumerateArray())
            {
                if (!entry.TryGetProperty("rating", out var ratingElement) ||
                    !ratingElement.TryGetInt32(out var rating)) continue;
                if (!TryReadTraktId(entry, kind, out var id)) continue;
                map[$"{kind}:{id}"] = rating;
            }
        }

        lock (_cacheLock)
        {
            _ratings = map;
            _ratingsAt = DateTime.UtcNow;
        }

        return map;
    }

    private async Task<HashSet<string>> WatchlistSetAsync(CancellationToken token)
    {
        lock (_cacheLock)
        {
            if (DateTime.UtcNow - _watchlistAt < CacheTtl) return _watchlist;
        }

        var set = await IdSetAsync(new[]
        {
            ("movie", "/sync/watchlist/movies"),
            ("show", "/sync/watchlist/shows"),
        }, token).ConfigureAwait(false);

        lock (_cacheLock)
        {
            _watchlist = set;
            _watchlistAt = DateTime.UtcNow;
        }

        return set;
    }

    private async Task<HashSet<string>> CollectionSetAsync(CancellationToken token)
    {
        lock (_cacheLock)
        {
            if (DateTime.UtcNow - _collectionAt < CacheTtl) return _collection;
        }

        var set = await IdSetAsync(new[]
        {
            ("movie", "/sync/collection/movies"),
            ("show", "/sync/collection/shows"),
        }, token).ConfigureAwait(false);

        lock (_cacheLock)
        {
            _collection = set;
            _collectionAt = DateTime.UtcNow;
        }

        return set;
    }

    private async Task<HashSet<string>> IdSetAsync((string Kind, string Path)[] paths,
        CancellationToken token)
    {
        var set = new HashSet<string>();
        foreach (var (kind, path) in paths)
        {
            var text = await SendAsync(HttpMethod.Get, path, null, null, token: token)
                .ConfigureAwait(false);
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) continue;
            foreach (var entry in doc.RootElement.EnumerateArray())
            {
                if (TryReadTraktId(entry, kind, out var id)) set.Add($"{kind}:{id}");
            }
        }

        return set;
    }

    private static bool TryReadTraktId(JsonElement entry, string kind, out int id)
    {
        id = 0;
        return entry.TryGetProperty(kind, out var item) &&
               item.TryGetProperty("ids", out var ids) &&
               ids.TryGetProperty("trakt", out var idElement) &&
               idElement.TryGetInt32(out id);
    }

    // MARK: - 匹配缓存

    private static string MatchesPath =>
        Path.Combine(Path.GetDirectoryName(AppSettings.FilePath) ?? "", "trakt-matches.json");

    private void LoadMatchesIfNeeded()
    {
        if (_matches is not null) return;
        try
        {
            if (File.Exists(MatchesPath))
            {
                var text = File.ReadAllText(MatchesPath);
                _matches = JsonSerializer.Deserialize<Dictionary<string, TraktMatch>>(text,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            }
        }
        catch (Exception)
        {
            // 缓存坏了就当没有，下次重新搜。
        }

        _matches ??= new Dictionary<string, TraktMatch>();
    }

    private void SaveMatches()
    {
        if (_matches is null) return;
        try
        {
            File.WriteAllText(MatchesPath, JsonSerializer.Serialize(_matches));
        }
        catch (Exception)
        {
            // 缓存写不进去不影响播放。
        }
    }

    private static string MatchKey(string title, int? year, bool series) =>
        $"{(series ? "show" : "movie")}|{Normalize(title)}|{year?.ToString(CultureInfo.InvariantCulture) ?? "0"}";

    /// <summary>片名比对：去掉空白和标点，全半角 / 大小写差异不影响。</summary>
    private static string Normalize(string title) =>
        new(title.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());

    private static string First(string? preferred, string fallback)
    {
        var value = preferred?.Trim();
        return string.IsNullOrWhiteSpace(value) ? fallback.Trim() : value;
    }

    private static string ComposeMessage(string body, int status)
    {
        if (string.IsNullOrWhiteSpace(body)) return $"Trakt 返回 {status}";
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            if (root.TryGetProperty("error_description", out var description) &&
                !string.IsNullOrWhiteSpace(description.GetString()))
            {
                return description.GetString()!;
            }
            if (root.TryGetProperty("error", out var error) &&
                !string.IsNullOrWhiteSpace(error.GetString()))
            {
                return error.GetString()!;
            }
        }
        catch (JsonException)
        {
            // 不是 JSON，按原文截断。
        }

        return body.Length > 180 ? body[..180] : body;
    }
}
