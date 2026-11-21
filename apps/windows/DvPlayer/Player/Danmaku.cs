using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;

namespace DvPlayer.Player;

/// <summary>一条弹幕（弹弹play 的 &lt;d p="…"&gt;）。</summary>
public sealed record DanmakuComment(double Time, int Mode, int Size, int Color, string Text);

public sealed class DanmakuException : Exception
{
    public DanmakuException(string message) : base(message)
    {
    }
}

/// <summary>
/// 弹弹play 客户端（v2，AppId + 签名鉴权）。
///
/// 只做两件事：按「剧名 + 集号」找 episodeId，再取这一集的 XML 弹幕。
/// 弹幕最终写成 ASS，交给 mpv 当第二字幕显示（见 <see cref="DanmakuAss"/>）。
/// </summary>
public sealed class DanmakuService
{
    public static DanmakuService Shared { get; } = new();

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(20) };

    private static string BaseUrl =>
        Environment.GetEnvironmentVariable("DVPLAYER_DANDANPLAY_BASE")
        ?? "https://api.dandanplay.net";

    /// <summary>签名 = Base64(SHA256(AppId + Timestamp + Path + AppSecret))。</summary>
    private static Dictionary<string, string> Headers(string path, string appId, string appSecret)
    {
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        var raw = appId + timestamp + path + appSecret;
        var signature = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(raw)));
        return new Dictionary<string, string>
        {
            ["X-AppId"] = appId,
            ["X-Timestamp"] = timestamp,
            ["X-Signature"] = signature,
            ["Accept"] = "application/json",
            ["User-Agent"] = "DVPlayer/1.0",
        };
    }

    private async Task<string> GetAsync(string url, string path, string appId, string appSecret,
        CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (key, value) in Headers(path, appId, appSecret))
        {
            request.Headers.TryAddWithoutValidation(key, value);
        }

        using var response = await _http.SendAsync(request, token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new DanmakuException($"弹弹play 返回 HTTP {(int)response.StatusCode}");
        }

        return await response.Content.ReadAsStringAsync(token).ConfigureAwait(false);
    }

    /// <summary>找这一集的 episodeId（先按集号匹配标题，再按顺序兜底）。</summary>
    public async Task<int> EpisodeIdAsync(string anime, int episode, string appId, string appSecret,
        CancellationToken token)
    {
        var path = "/api/v2/search/episodes";
        var url = BaseUrl + path
                  + "?anime=" + Uri.EscapeDataString(anime)
                  + "&episode=" + episode.ToString(CultureInfo.InvariantCulture);
        var body = await GetAsync(url, path, appId, appSecret, token).ConfigureAwait(false);

        using var doc = JsonDocument.Parse(body);
        if (!doc.RootElement.TryGetProperty("animes", out var animes) ||
            animes.ValueKind != JsonValueKind.Array)
        {
            throw new DanmakuException("弹弹play 没匹配到这一集");
        }

        foreach (var animeItem in animes.EnumerateArray())
        {
            if (!animeItem.TryGetProperty("episodes", out var episodes) ||
                episodes.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            var list = episodes.EnumerateArray().ToList();
            if (list.Count == 0)
            {
                continue;
            }

            // 优先标题里带「第 N 话 / 集」的。
            foreach (var item in list)
            {
                var title = item.TryGetProperty("episodeTitle", out var t) ? t.GetString() : null;
                if (title is not null &&
                    (title.Contains($"第{episode}", StringComparison.Ordinal) ||
                     title.Contains($"第 {episode}", StringComparison.Ordinal)) &&
                    item.TryGetProperty("episodeId", out var id))
                {
                    return id.GetInt32();
                }
            }

            if (episode - 1 >= 0 && episode - 1 < list.Count &&
                list[episode - 1].TryGetProperty("episodeId", out var byIndex))
            {
                return byIndex.GetInt32();
            }

            if (list[0].TryGetProperty("episodeId", out var first))
            {
                return first.GetInt32();
            }
        }

        throw new DanmakuException("弹弹play 没匹配到这一集");
    }

    /// <summary>取一集的弹幕 XML 并解析。</summary>
    public async Task<List<DanmakuComment>> CommentsAsync(int episodeId, string appId,
        string appSecret, CancellationToken token)
    {
        var path = $"/api/v2/comment/{episodeId}";
        var url = BaseUrl + path + "?withRelated=true&chConvert=1";
        var body = await GetAsync(url, path, appId, appSecret, token).ConfigureAwait(false);

        var comments = DanmakuXml.Parse(body);
        if (comments.Count == 0)
        {
            throw new DanmakuException("这一集没有弹幕");
        }

        return comments;
    }
}

/// <summary>弹幕 XML（&lt;i&gt;&lt;d p="time,mode,size,color,…"&gt;text&lt;/d&gt;）解析。</summary>
public static class DanmakuXml
{
    public static List<DanmakuComment> Parse(string xml)
    {
        var comments = new List<DanmakuComment>();

        XDocument doc;
        try
        {
            doc = XDocument.Parse(xml);
        }
        catch (Exception)
        {
            return comments;
        }

        foreach (var element in doc.Descendants("d"))
        {
            var raw = element.Attribute("p")?.Value;
            if (raw is null)
            {
                continue;
            }

            var fields = raw.Split(',');
            if (fields.Length < 4 ||
                !double.TryParse(fields[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var time) ||
                !int.TryParse(fields[1], out var mode) ||
                !int.TryParse(fields[2], out var size) ||
                !int.TryParse(fields[3], out var color))
            {
                continue;
            }

            var text = element.Value.Trim();
            if (text.Length == 0)
            {
                continue;
            }

            comments.Add(new DanmakuComment(time, mode, size, color, text));
        }

        return comments;
    }
}

/// <summary>弹幕 → ASS。滚动 / 顶部 / 底部三种，按行错开，避免同一秒叠在一起。</summary>
public static class DanmakuAss
{
    private const double Width = 1920;
    private const double Height = 1080;
    private const double LineHeight = 62;

    public static string CacheFolder
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "dvplayer", "cache", "danmaku");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>写进缓存目录，返回文件路径。</summary>
    public static string Write(IReadOnlyList<DanmakuComment> comments, int episodeId)
    {
        var path = Path.Combine(CacheFolder, $"DVPlayer-danmaku-{episodeId}.ass");
        File.WriteAllText(path, Build(comments), new UTF8Encoding(false));
        return path;
    }

    public static string Build(IReadOnlyList<DanmakuComment> comments)
    {
        var sb = new StringBuilder();
        sb.AppendLine("[Script Info]");
        sb.AppendLine("ScriptType: v4.00+");
        sb.AppendLine($"PlayResX: {(int)Width}");
        sb.AppendLine($"PlayResY: {(int)Height}");
        sb.AppendLine("WrapStyle: 2");
        sb.AppendLine("ScaledBorderAndShadow: yes");
        sb.AppendLine();
        sb.AppendLine("[V4+ Styles]");
        sb.AppendLine("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding");
        sb.AppendLine("Style: DM,Microsoft YaHei,48,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,7,0,0,0,1");
        sb.AppendLine();
        sb.AppendLine("[Events]");
        sb.AppendLine("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text");

        var lanes = Math.Max(1, (int)((Height - 120) / LineHeight));
        var scrollFree = new double[lanes];
        var topFree = new double[Math.Max(1, lanes / 2)];
        var bottomFree = new double[Math.Max(1, lanes / 2)];

        foreach (var comment in comments.OrderBy(c => c.Time).Take(3000))
        {
            var text = Sanitize(comment.Text);
            if (text.Length == 0)
            {
                continue;
            }

            var size = comment.Size > 0 ? Math.Clamp(comment.Size * 2, 28, 64) : 48;
            var color = AssColor(comment.Color);
            var start = Math.Max(0, comment.Time);

            if (comment.Mode is 4 or 5)
            {
                var isTop = comment.Mode == 5;
                var free = isTop ? topFree : bottomFree;
                var lane = Array.FindIndex(free, value => value <= start);
                if (lane < 0)
                {
                    lane = 0;
                }

                var y = 40 + lane * LineHeight;
                free[lane] = start + 4;

                var position = isTop
                    ? "{\\an8\\pos(" + (int)(Width / 2) + "," + (int)y + ")}"
                    : "{\\an2\\pos(" + (int)(Width / 2) + "," + (int)(Height - y) + ")}";
                AppendDialogue(sb, start, start + 4, position + text, size, color);
                continue;
            }

            var textWidth = text.Length * size * 0.95;
            const double duration = 9;
            var scrollLane = Array.FindIndex(scrollFree, value => value <= start);
            if (scrollLane < 0)
            {
                scrollLane = 0;
            }

            var laneY = 30 + scrollLane * LineHeight;
            scrollFree[scrollLane] = start + duration * 0.45;

            var effect = "{\\move(" + (int)Width + "," + (int)laneY + "," + (int)-textWidth + "," + (int)laneY + ")}";
            AppendDialogue(sb, start, start + duration, effect + text, size, color);
        }

        return sb.ToString();
    }

    private static void AppendDialogue(StringBuilder sb, double start, double end, string text,
        int size, string color)
        => sb.AppendLine($"Dialogue: 0,{Timestamp(start)},{Timestamp(end)},DM,,0,0,0,,"
                         + $"{{\\fs{size}\\c{color}}}" + text);

    private static string Timestamp(double seconds)
    {
        var total = Math.Max(0, seconds);
        var hours = (int)total / 3600;
        var minutes = (int)total % 3600 / 60;
        var secs = total - Math.Floor(total) + (int)total % 60;
        return string.Create(CultureInfo.InvariantCulture, $"{hours}:{minutes:00}:{secs:00.00}");
    }

    /// <summary>ASS 颜色是 &amp;HAABBGGRR。</summary>
    private static string AssColor(int rgb)
    {
        var r = (rgb >> 16) & 0xFF;
        var g = (rgb >> 8) & 0xFF;
        var b = rgb & 0xFF;
        return $"&H00{b:X2}{g:X2}{r:X2}&";
    }

    /// <summary>ASS 的 {} 是样式指令、\ 是转义符；弹幕文本里全换成全角 / 全角斜线。</summary>
    private static string Sanitize(string text) => text
        .Replace("\r", " ")
        .Replace("\n", " ")
        .Replace("{", "｛")
        .Replace("}", "｝")
        .Replace("\\", "／")
        .Trim();
}
