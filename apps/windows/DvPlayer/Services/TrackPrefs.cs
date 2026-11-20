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
