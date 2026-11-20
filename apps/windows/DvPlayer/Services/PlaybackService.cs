using DvPlayer.Player;

namespace DvPlayer.Services;

/// <summary>
/// 播放协调层：取播放源 → 交给 mpv → 回写进度。
///
/// 这里**只认 <see cref="PlaySourceDto"/>**，不关心底层是飞牛还是 Emby：
/// 两个适配器都把「直链 + 请求头 + 续播点 + 轨道」填成同一个形状，
/// 播放器因此只需要一份实现。
/// </summary>
public static class Playback
{
    /// <summary>续播点小于这个秒数就从头发（片头通常几十秒）。</summary>
    private const long ResumeThresholdSeconds = 5;

    public static async Task<(PlaySourceDto? Source, string? Error)> ResolveAsync(string itemId)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return (null, "未连接媒体源。");
        }

        var result = await Task.Run(() => core.PlaySource(itemId)).ConfigureAwait(false);
        return result.Ok && result.Data is not null
            ? (result.Data, null)
            : (null, result.Error ?? "取播放地址失败");
    }

    /// <summary>把统一的播放源翻译成 mpv 的启动参数。</summary>
    public static MpvLaunch ToLaunch(PlaySourceDto source)
    {
        var resume = AppServices.Instance.Settings.ResumePlayback;
        var start = resume && source.PositionSeconds >= ResumeThresholdSeconds
            ? source.PositionSeconds
            : 0;

        var headers = (source.Headers ?? new List<HttpHeaderDto>())
            .Select(h => new MpvHeader(h.Name, h.Value))
            .ToList();

        return new MpvLaunch(
            source.Url,
            headers,
            start,
            string.IsNullOrWhiteSpace(source.Title) ? null : source.Title,
            IsNetwork: source.Url.StartsWith("http", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// 回写进度。失败不打扰用户：网络抖动、播完退出都可能失败。
    /// </summary>
    public static void Report(string itemId, double positionSeconds, double durationSeconds)
    {
        var core = AppServices.Instance.Core;
        if (core is null || string.IsNullOrEmpty(itemId))
        {
            Trace.Write("report skipped: 未连接或 itemId 为空");
            return;
        }

        var position = (long)Math.Max(0, positionSeconds);
        var duration = (long)Math.Max(0, durationSeconds);
        _ = Task.Run(() =>
        {
            var result = core.ReportProgress(itemId, position, duration);
            Trace.Write(result.Ok
                ? $"report ok  item={itemId[..Math.Min(8, itemId.Length)]} pos={position} dur={duration}"
                : $"report fail item={itemId[..Math.Min(8, itemId.Length)]} pos={position} dur={duration} err={result.Error}");
        });
    }
}

/// <summary>播放链路的轻量日志：%LOCALAPPDATA%\dvplayer\player.log。</summary>
internal static class Trace
{
    private static readonly object Gate = new();

    private static string Path => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "dvplayer", "player.log");

    public static void Write(string line)
    {
        try
        {
            lock (Gate)
            {
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
                System.IO.File.AppendAllText(Path, $"{DateTime.Now:HH:mm:ss} {line}{Environment.NewLine}");
            }
        }
        catch (Exception)
        {
            // 日志写不了不影响播放。
        }
    }
}
