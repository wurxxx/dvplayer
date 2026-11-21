using System.Text.RegularExpressions;

namespace DvPlayer.Services;

/// <summary>
/// 媒体标题的显示处理。
///
/// 服务器给的是原始文件名（`异能寻生机 - S01E76.mp4`），列表里不能直接照搬；
/// 这里只做显示用的清洗，集号解析这类逻辑在核心（Rust）里，四端共用。
/// </summary>
public static class MediaText
{
    /// <summary>「异能寻生机（76集） - SKIT」→「异能寻生机」。</summary>
    public static string Clean(string? title)
    {
        if (string.IsNullOrWhiteSpace(title))
        {
            return "(未命名)";
        }

        // 去掉发布组后缀和括号里的集数：集数由副标题单独显示，标题里重复很吵。
        var cleaned = Regex.Replace(title, @"\s+-\s+[A-Za-z0-9@]+$", "");
        cleaned = Regex.Replace(cleaned, @"\s*[（(]\s*\d{1,4}\s*集\s*[)）]", "");
        return string.IsNullOrWhiteSpace(cleaned) ? title.Trim() : cleaned.Trim();
    }

    /// <summary>去掉视频扩展名。</summary>
    public static string TrimExtension(string title)
    {
        var dot = title.LastIndexOf('.');
        return dot > 0 && dot >= title.Length - 5 ? title[..dot] : title;
    }

    /// <summary>
    /// 标题是不是「剧名 + 集号」这样的文件名。是的话，列表里显示「第 N 集」比
    /// 整串文件名有用得多；刮削好的单集有自己的名字，那就原样显示。
    /// </summary>
    public static bool LooksLikeFileName(string title) =>
        Regex.IsMatch(title, @"[Ss]\d{1,2}\s*[Ee]\d{1,4}") ||
        Regex.IsMatch(title, @"^[Ee][Pp]?\s*\d{1,4}$") ||
        Regex.IsMatch(title, @"^第\s*\d{1,4}\s*集$") ||
        Regex.IsMatch(title, @"\.(mp4|mkv|avi|ts|mov|wmv|flv|rmvb|m4v)$", RegexOptions.IgnoreCase);

    /// <summary>
    /// 条目类型的中文名。飞牛把「没刮削但对得上剧集结构」的多文件目录标成
    /// Directory（映射成 folder），对用户来说它就是一部剧，这里统一说成「剧集」。
    /// </summary>
    public static string KindLabel(string kind) => kind switch
    {
        "movie" => "电影",
        "series" => "剧集",
        "season" => "季",
        "episode" => "单集",
        "folder" => "剧集",
        "video" => "视频",
        _ => kind,
    };

    /// <summary>媒体源类型的中文名（设置页与状态提示用）。</summary>
    public static string SourceKindLabel(string kind) => kind switch
    {
        "fnos" => "飞牛影视",
        "emby" => "Emby",
        "jellyfin" => "Jellyfin",
        "plex" => "Plex",
        "local" => "本地文件夹",
        "directory" => "本地目录",
        _ => kind,
    };

    /// <summary>能直接交给播放器的类型；其余（剧集 / 季 / 目录）要先看详情。</summary>
    public static bool IsPlayable(string kind) => kind switch
    {
        "movie" or "episode" or "video" => true,
        _ => false,
    };

    /// <summary>
    /// 播放记录卡片的标题。单集自己的标题常常是空的（飞牛只给剧名），
    /// 这时用「剧名 · 第 N 集」，比一张没有名字的卡片有用。
    /// </summary>
    public static string RecordTitle(PlayRecordDto record)
    {
        var episode = record.EpisodeNumber is > 0 ? $"第 {record.EpisodeNumber} 集" : null;

        if (!string.IsNullOrWhiteSpace(record.SeriesTitle) && episode is not null)
        {
            return $"{Clean(record.SeriesTitle)} · {episode}";
        }

        // 未刮削目录：记录标题是文件名（`剧名 - S01E106.mp4`），拆成「剧名 · 第 N 集」。
        var (fileSeries, fileEpisode) = SplitEpisodeFile(record.Title);
        if (fileSeries is not null && fileEpisode is not null)
        {
            return $"{fileSeries} · 第 {fileEpisode} 集";
        }

        if (!string.IsNullOrWhiteSpace(record.SeriesTitle) && string.IsNullOrWhiteSpace(record.Title))
        {
            return Clean(record.SeriesTitle);
        }

        return Clean(record.Title);
    }

    /// <summary>「剧名 - S01E106.mp4」→（「剧名」, 106）；拆不出返回 (null, null)。</summary>
    private static (string? Series, int? Episode) SplitEpisodeFile(string? title)
    {
        if (string.IsNullOrWhiteSpace(title))
        {
            return (null, null);
        }

        var name = TrimExtension(title);
        var match = Regex.Match(name, @"^(?<name>.+?)[\s._-]*[Ss]\d{1,2}\s*[Ee](?<e>\d{1,4})$");
        if (!match.Success || !int.TryParse(match.Groups["e"].Value, out var number))
        {
            return (null, null);
        }

        var series = Clean(match.Groups["name"].Value.Trim(' ', '-', '.', '_'));
        return (series, number);
    }

    /// <summary>卡片副标题：「剧集 · 81 集 · 10 季」。</summary>
    public static string Describe(MediaItemDto item)
    {
        var parts = new List<string> { KindLabel(item.Kind) };

        // 剧集优先显示集数（比分辨率有用）；未刮削目录的集数核心已从标题解析。
        var episodes = item.EpisodeCount ?? item.LocalEpisodeCount;
        if (episodes is > 0)
        {
            parts.Add($"{episodes} 集");
        }
        else if (item.RuntimeSeconds is > 0)
        {
            var time = TimeSpan.FromSeconds(item.RuntimeSeconds.Value);
            parts.Add(time.TotalHours >= 1
                ? $"{(int)time.TotalHours}:{time.Minutes:00}"
                : $"{time.Minutes} 分钟");
        }

        if (item.SeasonCount is > 1)
        {
            parts.Add($"{item.SeasonCount} 季");
        }

        return string.Join(" · ", parts);
    }
}
