using System.IO;

namespace DvPlayer.Services;

/// <summary>视频同目录的一张外挂字幕。</summary>
public sealed record SidecarSubtitle(string Path, string? Language, string? Title);

/// <summary>
/// 找视频旁边的字幕文件，交给 mpv 一起加载。
///
/// 和 macOS 的 <c>SidecarSubtitles.swift</c> 同一套规则：
/// - 位置：视频所在目录（不递归）；
/// - 扩展名：srt / ass / ssa / vtt / sup / idx；
/// - 名字：去掉分隔符后两边互为前缀（<c>Movie.2024.srt</c> 配得上
///   <c>Movie.2024.1080p.mkv</c>），多出来的部分全是数字的不算
///   （免得 <c>E01.srt</c> 挂到 <c>E010.mkv</c> 上）；
/// - 语言：从字幕名里多出来的词认（chs / zh-Hans / 简中 / eng…）。
/// </summary>
public static class SidecarSubtitles
{
    private static readonly HashSet<string> Extensions =
        new(StringComparer.OrdinalIgnoreCase) { "srt", "ass", "ssa", "vtt", "sup", "idx" };

    public static List<SidecarSubtitle> Find(string videoUrl)
    {
        if (videoUrl.Contains("://", StringComparison.Ordinal) || !File.Exists(videoUrl))
        {
            return new List<SidecarSubtitle>();
        }

        var video = new FileInfo(videoUrl);
        var dir = video.Directory;
        if (dir is null || !dir.Exists)
        {
            return new List<SidecarSubtitle>();
        }

        var videoStem = Path.GetFileNameWithoutExtension(video.Name);
        var result = new List<SidecarSubtitle>();

        foreach (var file in dir.EnumerateFiles())
        {
            if (!Extensions.Contains(file.Extension.TrimStart('.')))
            {
                continue;
            }

            var subStem = Path.GetFileNameWithoutExtension(file.Name);
            if (!Matches(videoStem, subStem))
            {
                continue;
            }

            var extra = ExtraTokens(videoStem, subStem);
            var (language, title) = Describe(extra);
            result.Add(new SidecarSubtitle(file.FullName, language, title));
        }

        return result
            .OrderBy(item => Path.GetFileName(item.Path), StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>两边去掉分隔符后比较：相等，或互为前缀（多出来全是数字的不算）。</summary>
    public static bool Matches(string video, string subtitle)
    {
        var target = Normalize(video);
        var candidate = Normalize(subtitle);
        if (target.Length == 0 || candidate.Length == 0)
        {
            return false;
        }

        if (target == candidate)
        {
            return true;
        }

        if (candidate.StartsWith(target, StringComparison.Ordinal))
        {
            return !RemainderIsDigits(candidate, target.Length);
        }

        if (target.StartsWith(candidate, StringComparison.Ordinal))
        {
            return !RemainderIsDigits(target, candidate.Length);
        }

        return false;
    }

    /// <summary>去掉空格 / <c>.</c> <c>_</c> <c>-</c> / 括号，只留字母、数字和汉字。</summary>
    public static string Normalize(string stem)
    {
        var builder = new System.Text.StringBuilder(stem.Length);
        foreach (var ch in stem.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch))
            {
                builder.Append(ch);
            }
        }

        return builder.ToString();
    }

    /// <summary>字幕路径比较：mpv 可能把 <c>\</c> 换成 <c>/</c>，按完整路径比。</summary>
    public static bool SamePath(string? first, string? second)
    {
        if (string.IsNullOrEmpty(first) || string.IsNullOrEmpty(second))
        {
            return false;
        }

        try
        {
            return string.Equals(
                Path.GetFullPath(first).TrimEnd(Path.DirectorySeparatorChar),
                Path.GetFullPath(second).TrimEnd(Path.DirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return string.Equals(first, second, StringComparison.OrdinalIgnoreCase);
        }
    }

    private static bool RemainderIsDigits(string text, int count)
    {
        if (count >= text.Length)
        {
            return false;
        }

        for (var i = count; i < text.Length; i++)
        {
            if (!char.IsDigit(text[i]))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>字幕名里比视频名多出来的词（<c>Movie.2024.chs.srt</c> → <c>chs</c>）。</summary>
    private static List<string> ExtraTokens(string video, string subtitle)
    {
        var videoTokens = Tokens(video).ToHashSet(StringComparer.Ordinal);
        return Tokens(subtitle).Where(token => !videoTokens.Contains(token)).ToList();
    }

    private static List<string> Tokens(string stem) =>
        stem.ToLowerInvariant()
            .Split(new[] { ' ', '.', '_', '-', '[', ']', '(', ')', '{', '}', '·', '+', '&', ',' },
                StringSplitOptions.RemoveEmptyEntries)
            .ToList();

    private static (string? Language, string? Title) Describe(List<string> extra)
    {
        var words = extra.ToHashSet(StringComparer.Ordinal);
        string? language = null;
        string? form = null;

        // 具体到简繁的先认，最后才是笼统的 `zh`；整词比较，避免
        // `french` 里的 `en` 被当成英语。
        if (words.Overlaps(new[] { "hans", "zhcn", "zhsg", "cn", "chs", "sc", "simplified",
                                   "简体", "简中", "简", "简体中文" }))
        {
            language = "zh-Hans";
            form = "简体";
        }
        else if (words.Overlaps(new[] { "hant", "zhtw", "zhhk", "cht", "tc", "traditional",
                                        "繁体", "繁中", "繁", "繁體", "繁体中文" }))
        {
            language = "zh-Hant";
            form = "繁体";
        }
        else if (words.Overlaps(new[] { "zh", "chi", "zho", "cmn", "yue", "chinese",
                                        "mandarin", "cantonese", "中文", "中字" }))
        {
            language = "zh";
        }
        else if (words.Overlaps(new[] { "eng", "en", "english", "英语", "英文" }))
        {
            language = "en";
        }
        else if (words.Overlaps(new[] { "jpn", "ja", "japanese", "日语", "日本語", "日文" }))
        {
            language = "ja";
        }
        else if (words.Overlaps(new[] { "kor", "ko", "korean", "韩语", "한국어", "韩文" }))
        {
            language = "ko";
        }
        else if (words.Overlaps(new[] { "fre", "fra", "fr", "french", "法语" }))
        {
            language = "fr";
        }
        else if (words.Overlaps(new[] { "ger", "deu", "de", "german", "德语" }))
        {
            language = "de";
        }
        else if (words.Overlaps(new[] { "spa", "es", "spanish", "西班牙语" }))
        {
            language = "es";
        }
        else if (words.Overlaps(new[] { "ita", "it", "italian", "意大利语" }))
        {
            language = "it";
        }
        else if (words.Overlaps(new[] { "rus", "ru", "russian", "俄语" }))
        {
            language = "ru";
        }
        else if (words.Overlaps(new[] { "por", "pt", "portuguese", "葡萄牙语" }))
        {
            language = "pt";
        }
        else if (words.Overlaps(new[] { "tha", "th", "thai", "泰语" }))
        {
            language = "th";
        }
        else if (words.Overlaps(new[] { "vie", "vi", "vietnamese", "越南语" }))
        {
            language = "vi";
        }

        var extras = new List<string>();
        if (form is not null)
        {
            extras.Add(form);
        }

        if (words.Overlaps(new[] { "forced", "强制" }))
        {
            extras.Add("强制");
        }

        if (words.Contains("sdh"))
        {
            extras.Add("SDH");
        }

        if (words.Contains("cc"))
        {
            extras.Add("CC");
        }

        if (words.Overlaps(new[] { "双语", "中英", "bilingual" }))
        {
            extras.Add("双语");
        }

        return (language, extras.Count == 0 ? null : string.Join(" · ", extras));
    }
}
