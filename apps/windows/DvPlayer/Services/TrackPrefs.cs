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
        "中文", "简体", "繁体", "简中", "繁中", "中字", "中英", "双语",
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
        return text.Contains("simplified") || text.Contains("简")
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

    /// <summary>字幕按钮 / 菜单里显示的名字：中文轨映射成中文名，别露出 Simplified Chinese。</summary>
    public static string SubtitleName(SubtitleInfoDto subtitle)
    {
        var title = (subtitle.Title ?? string.Empty).Trim();

        if (IsSimplified(subtitle.Language, title))
        {
            return "简体中文";
        }

        if (IsTraditional(subtitle.Language, title))
        {
            return "繁体中文";
        }

        if (IsChinese(subtitle.Language, title))
        {
            return HasCjk(title) ? title : "中文";
        }

        return (subtitle.Language ?? subtitle.Codec ?? "默认").Trim();
    }

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
