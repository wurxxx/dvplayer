using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace DvPlayer.Player;

/// <summary>一条在线字幕搜索结果（OpenSubtitles）。</summary>
public sealed record SubtitleResult(
    int Id,
    string Language,
    string Release,
    string FileName,
    string MovieName,
    int Downloads,
    double Ratings,
    bool HearingImpaired)
{
    public string LanguageLabel => Language.ToLowerInvariant() switch
    {
        "zh-cn" or "chi" or "zho" => "简体中文",
        "zh-tw" => "繁体中文",
        "en" => "英文",
        "ja" => "日文",
        "ko" => "韩文",
        _ => Language,
    };

    public string Detail
    {
        get
        {
            var parts = new List<string> { LanguageLabel };
            if (!string.IsNullOrWhiteSpace(Release))
            {
                parts.Add(Release);
            }

            if (Downloads > 0)
            {
                parts.Add($"{Downloads} 次下载");
            }

            if (HearingImpaired)
            {
                parts.Add("听障");
            }

            return string.Join(" · ", parts);
        }
    }
}

public sealed class SubtitleException : Exception
{
    public SubtitleException(string message) : base(message)
    {
    }
}

/// <summary>
/// OpenSubtitles REST API v1：搜索 → 取下载链接 → 存成本地字幕文件。
///
/// 只需要 API Key；如果配置了用户名 / 密码，下载前会先换一个 token
/// （OpenSubtitles 对下载接口有登录要求，免费账号即可）。
/// </summary>
public sealed class OpenSubtitlesService
{
    public static OpenSubtitlesService Shared { get; } = new();

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private string? _token;
    private DateTime _tokenAt = DateTime.MinValue;
    /// <summary>同时下多份字幕时只登一次，也避免并发把 token 写乱。</summary>
    private readonly SemaphoreSlim _loginGate = new(1, 1);

    private static string BaseUrl =>
        Environment.GetEnvironmentVariable("DVPLAYER_OPENSUBTITLES_BASE")
        ?? "https://api.opensubtitles.com/api/v1";

    public static string CacheFolder
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "dvplayer", "cache", "subtitles");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    private Dictionary<string, string> Headers(string apiKey, bool withToken)
    {
        var headers = new Dictionary<string, string>
        {
            ["Api-Key"] = apiKey,
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "DVPlayer v1.0",
        };
        if (withToken && !string.IsNullOrEmpty(_token))
        {
            headers["Authorization"] = "Bearer " + _token;
        }

        return headers;
    }

    private static void Apply(HttpRequestMessage request, Dictionary<string, string> headers)
    {
        foreach (var (key, value) in headers)
        {
            request.Headers.TryAddWithoutValidation(key, value);
        }
    }

    /// <summary>
    /// 需要 token 的接口先登录。下载（required）失败要明确报错；
    /// 搜索只是顺带登录，失败仍可只用 API Key 搜。
    /// </summary>
    private async Task LoginIfNeededAsync(string apiKey, string? username, string? password,
        CancellationToken token, bool required)
    {
        if (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(password))
        {
            if (required)
            {
                throw new SubtitleException(
                    "OpenSubtitles 下载需要登录：先填用户名和密码");
            }

            return;
        }

        if (_token is not null && DateTime.UtcNow - _tokenAt < TimeSpan.FromHours(20))
        {
            return;
        }

        await _loginGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            // 排队期间别人可能已经登好了。
            if (_token is not null && DateTime.UtcNow - _tokenAt < TimeSpan.FromHours(20))
            {
                return;
            }

            string? error = null;

            using var request = new HttpRequestMessage(HttpMethod.Post, BaseUrl + "/login");
            Apply(request, Headers(apiKey, withToken: false));
            request.Content = new StringContent(
                JsonSerializer.Serialize(new { username, password }),
                Encoding.UTF8, "application/json");

            try
            {
                using var response = await _http.SendAsync(request, token).ConfigureAwait(false);
                var body = await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    error = Message(body) ?? $"HTTP {(int)response.StatusCode}";
                }
                else
                {
                    using var doc = JsonDocument.Parse(body);
                    if (doc.RootElement.TryGetProperty("token", out var tokenElement) &&
                        tokenElement.GetString() is { Length: > 0 } value)
                    {
                        _token = value;
                        _tokenAt = DateTime.UtcNow;
                    }
                    else
                    {
                        error = "登录响应里没有 token";
                    }
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                error = ex.Message;
            }

            if (error is not null)
            {
                // 旧 token 已经超过 20 小时，留着只会让后面的请求 401。
                _token = null;
                if (required)
                {
                    throw new SubtitleException("OpenSubtitles 登录失败：" + error);
                }
            }
        }
        finally
        {
            _loginGate.Release();
        }
    }

    /// <summary>
    /// 401 时把本地 token 清掉：否则要等 20 小时的本地过期时间，
    /// 期间每次下载都拿同一个已失效的 token。
    /// </summary>
    private void InvalidateTokenIfUnauthorized(HttpResponseMessage response)
    {
        if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            _token = null;
        }
    }

    /// <summary>剧集按「标题 + 季 + 集」搜，电影只按标题。</summary>
    public async Task<List<SubtitleResult>> SearchAsync(
        string title, int? season, int? episode,
        string apiKey, string? username, string? password,
        string languages, CancellationToken token)
    {
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            throw new SubtitleException("字幕搜索需要先在「设置 → 弹幕 / 字幕」里填 OpenSubtitles API Key");
        }

        var query = "?query=" + Uri.EscapeDataString(title)
                               + "&languages=" + Uri.EscapeDataString(languages);

        // 剧集按集号搜；角标只有 E02（没有 S01）时季号是空的，不能退化成电影。
        if (episode is { } e)
        {
            query += "&type=episode"
                     + "&episode_number=" + e.ToString(CultureInfo.InvariantCulture);
            if (season is { } s)
            {
                query += "&season_number=" + s.ToString(CultureInfo.InvariantCulture);
            }
        }
        else
        {
            query += "&type=movie";
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, BaseUrl + "/subtitles" + query);
        Apply(request, Headers(apiKey, withToken: !string.IsNullOrEmpty(_token)));

        using var response = await _http.SendAsync(request, token).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            InvalidateTokenIfUnauthorized(response);
            throw new SubtitleException(Message(body) ?? $"OpenSubtitles 返回 HTTP {(int)response.StatusCode}");
        }

        var results = new List<SubtitleResult>();
        using (var doc = JsonDocument.Parse(body))
        {
            if (!doc.RootElement.TryGetProperty("data", out var data) ||
                data.ValueKind != JsonValueKind.Array)
            {
                throw new SubtitleException("OpenSubtitles 返回的数据看不懂");
            }

            foreach (var row in data.EnumerateArray())
            {
                if (!row.TryGetProperty("attributes", out var attributes) ||
                    !attributes.TryGetProperty("files", out var files) ||
                    files.ValueKind != JsonValueKind.Array ||
                    !files.EnumerateArray().Any())
                {
                    continue;
                }

                var file = files.EnumerateArray().First();
                if (!file.TryGetProperty("file_id", out var fileId))
                {
                    continue;
                }

                results.Add(new SubtitleResult(
                    fileId.GetInt32(),
                    attributes.TryGetProperty("language", out var lang) ? lang.GetString() ?? "" : "",
                    attributes.TryGetProperty("release", out var release) ? release.GetString() ?? "" : "",
                    file.TryGetProperty("file_name", out var name) ? name.GetString() ?? "" : "",
                    attributes.TryGetProperty("movie_name", out var movie) ? movie.GetString() ?? "" : "",
                    attributes.TryGetProperty("download_count", out var downloads) && downloads.ValueKind == JsonValueKind.Number
                        ? downloads.GetInt32()
                        : 0,
                    attributes.TryGetProperty("ratings", out var ratings) && ratings.ValueKind == JsonValueKind.Number
                        ? ratings.GetDouble()
                        : 0,
                    attributes.TryGetProperty("hearing_impaired", out var hi) &&
                    hi.ValueKind == JsonValueKind.True));
            }
        }

        if (results.Count == 0)
        {
            throw new SubtitleException("没搜到字幕");
        }

        // 搜索只顺带登录：没账号也能用 API Key 搜。
        await LoginIfNeededAsync(apiKey, username, password, token, required: false)
            .ConfigureAwait(false);
        return results;
    }

    /// <summary>取临时下载链接，再把字幕文件存到缓存目录。</summary>
    public async Task<string> DownloadAsync(SubtitleResult result,
        string apiKey, string? username, string? password, CancellationToken token,
        bool authRetried = false)
    {
        // 下载接口要登录 token，失败必须在下载前说清楚。
        await LoginIfNeededAsync(apiKey, username, password, token, required: true)
            .ConfigureAwait(false);

        using var request = new HttpRequestMessage(HttpMethod.Post, BaseUrl + "/downloads");
        Apply(request, Headers(apiKey, withToken: true));
        request.Content = new StringContent(
            JsonSerializer.Serialize(new { file_id = result.Id }),
            Encoding.UTF8, "application/json");

        using var response = await _http.SendAsync(request, token).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);

        if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
        {
            // token 被服务端提前作废（改密码 / 会话失效）：本地 20 小时的过期时间
            // 拦不住这种情况，重新登录再试一次。
            _token = null;
            if (!authRetried)
            {
                await LoginIfNeededAsync(apiKey, username, password, token, required: true)
                    .ConfigureAwait(false);
                return await DownloadAsync(result, apiKey, username, password, token,
                    authRetried: true).ConfigureAwait(false);
            }
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new SubtitleException(Message(body) ?? $"OpenSubtitles 返回 HTTP {(int)response.StatusCode}");
        }

        string link;
        string fileName;
        using (var doc = JsonDocument.Parse(body))
        {
            var root = doc.RootElement;
            link = root.TryGetProperty("link", out var linkElement) ? linkElement.GetString() ?? "" : "";
            fileName = root.TryGetProperty("file_name", out var nameElement)
                ? nameElement.GetString() ?? result.FileName
                : result.FileName;
        }

        if (link.Length == 0)
        {
            throw new SubtitleException("OpenSubtitles 没给下载链接");
        }

        var payload = await _http.GetByteArrayAsync(link, token).ConfigureAwait(false);
        var path = Path.Combine(CacheFolder, Sanitize(fileName));

        // 直接写目标文件：下载中断/取消会留下半份字幕，mpv 可能把它当坏文件。
        // 先写 .part 再原子替换。
        var temp = path + ".part";
        try
        {
            await File.WriteAllBytesAsync(temp, payload, token).ConfigureAwait(false);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { }
            throw;
        }

        return path;
    }

    private static string Sanitize(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var clean = new string(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray());
        return clean.Length == 0 ? "subtitle.srt" : clean;
    }

    private static string? Message(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.TryGetProperty("message", out var message)
                ? message.GetString()
                : null;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
