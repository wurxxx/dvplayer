using System;
using System.Collections.Generic;
using System.Linq;

namespace DvPlayer.Services;

/// <summary>
/// 详情页选的音轨 / 字幕，播放时照这份应用。
///
/// 下标对应 <see cref="MediaInfoDto"/> 里的列表顺序（音频 <c>Audios</c>、
/// 字幕 <c>Subtitles</c>），和文件里的轨序一致，播放器再用 mpv 的
/// <c>aid</c> / <c>sid</c> 选对应的轨。
///
/// 只在内存里记：一次运行内切集、退出播放器再进来还认这份选择。
/// </summary>
public static class TrackPrefs
{
    /// <summary>没选过（按服务器的默认轨）。</summary>
    private const int Unset = -2;

    /// <summary>字幕「关闭」。</summary>
    public const int SubtitleOff = -1;

    private static readonly Dictionary<string, (int Audio, int Subtitle)> Map = new();
    private static readonly object Gate = new();

    /// <summary>选中的音频下标；null = 用默认轨。</summary>
    public static int? Audio(string itemId)
    {
        lock (Gate)
        {
            return Map.TryGetValue(itemId, out var value) && value.Audio != Unset
                ? value.Audio
                : null;
        }
    }

    /// <summary>选中的字幕下标；null = 默认，<see cref="SubtitleOff"/> = 关闭。</summary>
    public static int? Subtitle(string itemId)
    {
        lock (Gate)
        {
            return Map.TryGetValue(itemId, out var value) && value.Subtitle != Unset
                ? value.Subtitle
                : null;
        }
    }

    public static void SetAudio(string itemId, int? index)
    {
        lock (Gate)
        {
            (int Audio, int Subtitle) current = Map.TryGetValue(itemId, out var value)
                ? value
                : (Unset, Unset);
            Map[itemId] = (index ?? Unset, current.Subtitle);
        }
    }

    /// <summary>语言 / 标题看起来是中文轨（`zh`、`chi`、`简中`、`中英` 这些都算）。</summary>
    public static bool IsChinese(string? language, string? title)
    {
        var lang = (language ?? string.Empty).Trim().ToLowerInvariant();
        if (lang == "中文")
        {
            return true;
        }

        if (lang.Length > 0 &&
            (lang.StartsWith("zh", StringComparison.Ordinal)
             || lang.StartsWith("chi", StringComparison.Ordinal)
             || lang.StartsWith("zho", StringComparison.Ordinal)
             || lang.StartsWith("chs", StringComparison.Ordinal)
             || lang.StartsWith("cht", StringComparison.Ordinal)
             || lang.StartsWith("cmn", StringComparison.Ordinal)
             || lang.StartsWith("yue", StringComparison.Ordinal)))
        {
            return true;
        }

        var text = (title ?? string.Empty).ToLowerInvariant();
        return text.Length > 0 && ChineseHints.Any(text.Contains);
    }

    private static readonly string[] ChineseHints =
    {
        "中文", "简体", "繁体", "簡體", "繁體", "简中", "繁中", "中字", "中英", "双语",
        "chinese", "mandarin", "cantonese", "chs", "cht",
    };

    /// <summary>
    /// 详情页与播放器共用的「当前字幕」：
    /// 手动选过听手动，否则优先中文轨，再按服务器默认，最后关。
    /// </summary>
    public static int ResolveSubtitle(string itemId, IReadOnlyList<SubtitleInfoDto> subtitles)
    {
        if (Subtitle(itemId) is { } saved)
        {
            return saved;
        }

        if (subtitles.Count == 0)
        {
            return SubtitleOff;
        }

        // 简体优先，其次任意中文，再按服务器默认；一条都认不出来就当关闭。
        var simplified = -1;
        var chinese = -1;
        var byDefault = -1;

        for (var i = 0; i < subtitles.Count; i++)
        {
            var subtitle = subtitles[i];
            if (byDefault < 0 && subtitle.IsDefault)
            {
                byDefault = i;
            }

            if (chinese < 0 && IsChinese(subtitle.Language, subtitle.Title))
            {
                chinese = i;
            }

            if (simplified < 0 && IsSimplified(subtitle.Language, subtitle.Title))
            {
                simplified = i;
            }
        }

        return simplified >= 0 ? simplified
            : chinese >= 0 ? chinese
            : byDefault >= 0 ? byDefault
            : SubtitleOff;
    }

    /// <summary>简体字幕：`Simplified Chinese` / `简` / `chs` / `zh-CN` 都算。</summary>
    public static bool IsSimplified(string? language, string? title)
    {
        var text = (title ?? string.Empty).ToLowerInvariant();
        var lang = (language ?? string.Empty).Trim().ToLowerInvariant();
        return text.Contains("simplified") || text.Contains("简") || text.Contains("簡")
               || lang.Contains("hans")
               || lang is "chs" or "cn" or "zh-cn" or "zh-hans";
    }

    /// <summary>繁体字幕：`Traditional Chinese` / `繁` / `cht` / `zh-TW` 都算。</summary>
    public static bool IsTraditional(string? language, string? title)
    {
        var text = (title ?? string.Empty).ToLowerInvariant();
        var lang = (language ?? string.Empty).Trim().ToLowerInvariant();
        return text.Contains("traditional") || text.Contains("繁")
               || lang.Contains("hant")
               || lang is "cht" or "zh-tw" or "zh-hk" or "zh-hant";
    }

    /// <summary>
    /// 语言码 → 中文名（`chi` → 中文、`en` → 英语）。
    /// 空 / `und` / `unknown` 返回 null，调用方当作「这条轨没说语言」。
    /// </summary>
    public static string? LanguageName(string? language)
    {
        var raw = (language ?? string.Empty).Trim();
        if (raw.Length == 0)
        {
            return null;
        }

        var key = raw.ToLowerInvariant().Replace('_', '-');
        if (key is "und" or "unknown" or "undetermined" or "mul" or "zxx" or "mis")
        {
            return null;
        }

        // 服务器已经给了中文名（`中文` / `简体中文`）就直接用。
        if (HasCjk(raw))
        {
            return raw;
        }

        foreach (var (code, name) in LanguageNames)
        {
            if (key == code)
            {
                return name;
            }
        }

        // `zh-CN` / `en-US`：主标签能认出来就用主标签。
        var primary = key.Split('-')[0];
        if (primary != key)
        {
            foreach (var (code, name) in LanguageNames)
            {
                if (primary == code)
                {
                    return name;
                }
            }
        }

        // 英文写法的名字（VLC 或部分服务器会给 `Chinese` / `English`）。
        foreach (var (hint, name) in LanguageHints)
        {
            if (key.Contains(hint, StringComparison.Ordinal))
            {
                return name;
            }
        }

        return raw;
    }

    private static readonly (string Code, string Name)[] LanguageNames =
    {
        ("zh", "中文"), ("chi", "中文"), ("zho", "中文"), ("cmn", "中文"), ("yue", "中文"),
        ("zh-cn", "中文"), ("zh-sg", "中文"), ("zh-tw", "中文"), ("zh-hk", "中文"),
        ("zh-hans", "中文"), ("zh-hant", "中文"),
        ("en", "英语"), ("eng", "英语"),
        ("ja", "日语"), ("jpn", "日语"),
        ("ko", "韩语"), ("kor", "韩语"),
        ("fr", "法语"), ("fre", "法语"), ("fra", "法语"),
        ("de", "德语"), ("ger", "德语"), ("deu", "德语"),
        ("es", "西班牙语"), ("spa", "西班牙语"),
        ("it", "意大利语"), ("ita", "意大利语"),
        ("ru", "俄语"), ("rus", "俄语"),
        ("pt", "葡萄牙语"), ("por", "葡萄牙语"),
        ("ar", "阿拉伯语"), ("ara", "阿拉伯语"),
        ("hi", "印地语"), ("hin", "印地语"),
        ("th", "泰语"), ("tha", "泰语"),
        ("vi", "越南语"), ("vie", "越南语"),
        ("id", "印尼语"), ("ind", "印尼语"),
        ("ms", "马来语"), ("msa", "马来语"), ("may", "马来语"),
        ("tr", "土耳其语"), ("tur", "土耳其语"),
        ("pl", "波兰语"), ("pol", "波兰语"),
        ("nl", "荷兰语"), ("dut", "荷兰语"), ("nld", "荷兰语"),
        ("sv", "瑞典语"), ("swe", "瑞典语"),
        ("da", "丹麦语"), ("dan", "丹麦语"),
        ("no", "挪威语"), ("nor", "挪威语"), ("nb", "挪威语"), ("nn", "挪威语"),
        ("fi", "芬兰语"), ("fin", "芬兰语"),
        ("cs", "捷克语"), ("cze", "捷克语"), ("ces", "捷克语"),
        ("el", "希腊语"), ("gre", "希腊语"), ("ell", "希腊语"),
        ("he", "希伯来语"), ("heb", "希伯来语"),
        ("hu", "匈牙利语"), ("hun", "匈牙利语"),
        ("uk", "乌克兰语"), ("ukr", "乌克兰语"),
        ("ro", "罗马尼亚语"), ("rum", "罗马尼亚语"), ("ron", "罗马尼亚语"),
        ("fa", "波斯语"), ("per", "波斯语"), ("fas", "波斯语"),
    };

    private static readonly (string Hint, string Name)[] LanguageHints =
    {
        ("chinese", "中文"), ("mandarin", "中文"), ("cantonese", "中文"),
        ("english", "英语"), ("japanese", "日语"), ("korean", "韩语"),
        ("french", "法语"), ("german", "德语"), ("spanish", "西班牙语"),
        ("italian", "意大利语"), ("russian", "俄语"), ("portuguese", "葡萄牙语"),
        ("arabic", "阿拉伯语"), ("hindi", "印地语"), ("thai", "泰语"),
        ("vietnamese", "越南语"), ("indonesian", "印尼语"), ("malay", "马来语"),
        ("turkish", "土耳其语"), ("polish", "波兰语"), ("dutch", "荷兰语"),
        ("swedish", "瑞典语"), ("danish", "丹麦语"), ("norwegian", "挪威语"),
        ("finnish", "芬兰语"), ("czech", "捷克语"), ("greek", "希腊语"),
        ("hebrew", "希伯来语"), ("hungarian", "匈牙利语"), ("ukrainian", "乌克兰语"),
        ("romanian", "罗马尼亚语"), ("persian", "波斯语"),
    };

    /// <summary>
    /// 标题只是容器 / 编码标签（`HDMV PGS_SUBTITLE`、`subrip`）时，当作没有标题。
    /// </summary>
    public static bool IsCodecLabel(string? title)
    {
        var text = (title ?? string.Empty).Trim().ToLowerInvariant();
        if (text.Length == 0)
        {
            return true;
        }

        // 把容器 / 编码词连同分隔符一起去掉，看还剩不剩有意义的字。
        foreach (var token in CodecTokens)
        {
            text = text.Replace(token, " ", StringComparison.Ordinal);
        }

        return !text.Any(char.IsLetterOrDigit);
    }

    private static readonly string[] CodecTokens =
    {
        "hdmv", "pgs", "subtitle", "subtitles", "subrip", "vobsub", "dvd_subtitle",
        "dvdsub", "mov_text", "webvtt", "ttml", "dvb", "ssa", "ass", "srt", "text",
    };

    /// <summary>去掉没意义的标题；null = 这条字幕没有标题。</summary>
    public static string? CleanTitle(string? title)
    {
        var text = (title ?? string.Empty).Trim();
        return text.Length == 0 || IsCodecLabel(text) ? null : text;
    }

    /// <summary>
    /// 字幕菜单 / 按钮的文案：`语言 · 标题`，缺哪个跳哪个。
    ///
    /// 两个都没有时用序号兜底（`字幕 3`）；<paramref name="ordinal"/> 为 0
    /// （按钮、媒体信息卡这类单条展示）时只写「字幕」。
    /// </summary>
    public static string SubtitleLabel(string? language, string? title, int ordinal = 0)
    {
        var lang = LanguageName(language);
        var text = CleanTitle(title);

        // 简繁信息从标题里提出来，显示成「中文 · 简体」。
        if (IsSimplified(language, title))
        {
            lang = "中文";
            text = "简体";
        }
        else if (IsTraditional(language, title))
        {
            lang = "中文";
            text = "繁体";
        }
        else if (lang is null && IsChinese(language, title))
        {
            lang = "中文";
        }

        // 标题里重复了语言名（`中文` / `English`）就别再拼一遍；
        // `English SDH` 这种带别的内容的保留。
        if (text is not null && lang is not null
            && (string.Equals(text, lang, StringComparison.OrdinalIgnoreCase)
                || (!text.Contains(' ') && LanguageName(text) == lang)))
        {
            text = null;
        }

        var parts = new List<string>(2);
        if (lang is not null)
        {
            parts.Add(lang);
        }

        if (text is not null)
        {
            parts.Add(text);
        }

        if (parts.Count > 0)
        {
            return string.Join(" · ", parts);
        }

        return ordinal > 0 ? $"字幕 {ordinal}" : "未命名";
    }

    /// <summary>详情页 / 播放器菜单里一次算一批：重名的追加序号（`中文 1`、`中文 2`）。</summary>
    public static string[] SubtitleLabels(IReadOnlyList<(string? Language, string? Title)> tracks)
    {
        var labels = new string[tracks.Count];
        for (var i = 0; i < tracks.Count; i++)
        {
            labels[i] = SubtitleLabel(tracks[i].Language, tracks[i].Title, i + 1);
        }

        var counts = new Dictionary<string, int>();
        foreach (var label in labels)
        {
            counts[label] = counts.TryGetValue(label, out var count) ? count + 1 : 1;
        }

        var seen = new Dictionary<string, int>();
        for (var i = 0; i < labels.Length; i++)
        {
            if (counts[labels[i]] <= 1)
            {
                continue;
            }

            var number = seen.TryGetValue(labels[i], out var count) ? count + 1 : 1;
            seen[labels[i]] = number;
            labels[i] = $"{labels[i]} {number}";
        }

        return labels;
    }

    /// <summary>服务器媒体信息（`MediaInfoDto.Subtitles`）的一批字幕文案。</summary>
    public static string[] SubtitleLabels(IReadOnlyList<SubtitleInfoDto> subtitles)
    {
        var tracks = new (string? Language, string? Title)[subtitles.Count];
        for (var i = 0; i < subtitles.Count; i++)
        {
            tracks[i] = (subtitles[i].Language, subtitles[i].Title);
        }

        return SubtitleLabels(tracks);
    }

    /// <summary>单条字幕的文案（按钮、媒体信息卡）。</summary>
    public static string SubtitleName(SubtitleInfoDto subtitle, int ordinal = 0) =>
        SubtitleLabel(subtitle.Language, subtitle.Title, ordinal);

    private static bool HasCjk(string text) =>
        text.Any(ch => ch >= '\u4E00' && ch <= '\u9FFF');

    public static void SetSubtitle(string itemId, int? index)
    {
        lock (Gate)
        {
            (int Audio, int Subtitle) current = Map.TryGetValue(itemId, out var value)
                ? value
                : (Unset, Unset);
            Map[itemId] = (current.Audio, index ?? Unset);
        }
    }
}
