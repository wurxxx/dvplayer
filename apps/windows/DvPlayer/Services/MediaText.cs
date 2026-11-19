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
}
