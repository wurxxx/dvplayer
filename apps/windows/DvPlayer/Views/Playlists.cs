using System.Windows;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 拼播放页右侧「选集」用的列表。
///
/// 详情页本来就知道当前是哪一季，直接把自己那行集传进来；续播（观看记录、
/// 收藏里的单集）只有一条记录，要顺着记录把所在的容器找回来再列一遍，
/// 不然播放页就只剩一个孤零零的片子，没有上一集 / 下一集。
///
/// 各源给的线索不一样，所以按顺序试：
/// 1. <see cref="PlayRecordDto.ParentId"/>：Emby 的单集父条目就是那一季；
/// 2. 记录里的剧名：飞牛的 <c>parent_guid</c> 常常不是可浏览的目录，
///    按剧名搜回剧集再取对应那一季；
/// 3. 都不行就正常播，不硬拼。
/// </summary>
internal static class Playlists
{
    /// <summary>从剧集 / 季 / 单集的 id 读出可播放的集列表。</summary>
    /// <param name="id">剧集 id（会再下一层挑一季）、季 id 或目录 id。</param>
    /// <param name="seasonNumber">剧集有多季时挑哪一季；0 / null = 第一季。</param>
    public static async Task<(List<PlayEpisode> Items, string? Title)> LoadAsync(
        MediaCore core,
        string id,
        string? title = null,
        int? seasonNumber = null)
    {
        var result = await Task.Run(() => core.Children(id, 1, 500)).ConfigureAwait(true);
        var items = (result.Data?.Items ?? new List<MediaItemDto>()).ToList();

        // 传进来的是剧集本身：直接子项是「季」，要再下一层才是集。
        if (items.Count > 0 && IsSeason(items[0]))
        {
            var season = items.FirstOrDefault(item =>
                             seasonNumber is > 0 && item.SeasonNumber == seasonNumber)
                         ?? items.FirstOrDefault(item => item.SeasonNumber is > 0)
                         ?? items[0];

            var episodes = await Task.Run(() => core.Children(season.Id, 1, 500)).ConfigureAwait(true);
            items = (episodes.Data?.Items ?? new List<MediaItemDto>()).ToList();
        }

        items = items
            .Where(item => !string.IsNullOrEmpty(item.Id))
            .OrderBy(item => item.EpisodeNumber ?? 0)
            .ToList();

        if (string.IsNullOrWhiteSpace(title))
        {
            var detail = await Task.Run(() => core.ItemDetail(id)).ConfigureAwait(true);
            title = detail.Ok ? MediaText.Clean(detail.Data?.Title) : null;
        }

        return (ToEpisodes(items), title);
    }

    /// <summary>
    /// 从一条观看记录续播：单集记录会带上它所在那一季的选集，
    /// 电影 / 单个视频没有父条目，就照原来的方式播。
    /// </summary>
    public static async Task<PlayWindow?> PlayRecordAsync(Window? owner, PlayRecordDto record)
    {
        var core = AppServices.Instance.Core;
        if (core is null || !LooksLikeEpisode(record))
        {
            return await PlayWindow.OpenAsync(owner, record.ItemId);
        }

        // 1) 记录的父条目能直接列出集。
        if (WithSource(record, record.ParentId) is { } parentId &&
            await TryOpenAsync(owner, core, parentId, record, record.SeriesTitle) is { } byParent)
        {
            return byParent;
        }

        // 2) 飞牛的 parent_guid 不是可浏览的目录，按剧名把剧集找回来。
        if (!string.IsNullOrWhiteSpace(record.SeriesTitle) &&
            await FindSeriesAsync(core, record.SeriesTitle!) is { } seriesId &&
            await TryOpenAsync(owner, core, seriesId, record, record.SeriesTitle) is { } bySeries)
        {
            return bySeries;
        }

        Trace.Write($"record {record.ItemId} no playlist title='{record.Title}'");
        return await PlayWindow.OpenAsync(owner, record.ItemId);
    }

    /// <summary>
    /// 列出容器里的集，认出记录对应的是哪一集再打开。
    /// 记录的 item id 有时是「播放用」的 guid，和列表里的条目 id 对不上，
    /// 所以还要按标题兜一层。
    /// </summary>
    private static async Task<PlayWindow?> TryOpenAsync(
        Window? owner,
        MediaCore core,
        string containerId,
        PlayRecordDto record,
        string? title)
    {
        var (items, seriesTitle) = await LoadAsync(core, containerId, title, record.SeasonNumber);
        if (items.Count < 2)
        {
            return null;
        }

        var target = items.FirstOrDefault(item => item.Id == record.ItemId)
                     ?? MatchByTitle(items, record);

        if (target is null)
        {
            Trace.Write($"record {record.ItemId} not in {containerId} " +
                        $"first={items[0].Id}/{items[0].Title}");
            return null;
        }

        Trace.Write($"record play {record.ItemId} -> {target.Id} " +
                    $"container={containerId} episodes={items.Count}");
        return await PlayWindow.OpenAsync(owner, target.Id, null, items, seriesTitle);
    }

    /// <summary>按标题认集：记录的标题多半就是文件名，去掉扩展名后和列表对得上。</summary>
    private static PlayEpisode? MatchByTitle(List<PlayEpisode> items, PlayRecordDto record)
    {
        var wanted = Normalize(record.Title);
        if (wanted.Length == 0)
        {
            return null;
        }

        var named = items.Where(item => !string.IsNullOrWhiteSpace(item.Title)).ToList();

        return named.FirstOrDefault(item =>
                   string.Equals(Normalize(item.Title), wanted, StringComparison.OrdinalIgnoreCase))
               ?? named.FirstOrDefault(item =>
                   Normalize(item.Title).Contains(wanted, StringComparison.OrdinalIgnoreCase))
               ?? named.FirstOrDefault(item =>
                   wanted.Contains(Normalize(item.Title), StringComparison.OrdinalIgnoreCase));
    }

    private static string Normalize(string? title) =>
        MediaText.TrimExtension(MediaText.Clean(title)).Trim();

    /// <summary>记录里的 guid 是裸的，要补 <c>&lt;sourceId&gt;:</c> 前缀核心才认。</summary>
    private static string? WithSource(PlayRecordDto record, string? id)
    {
        if (string.IsNullOrWhiteSpace(id))
        {
            return null;
        }

        return id.Contains(':') || string.IsNullOrEmpty(record.SourceId)
            ? id
            : $"{record.SourceId}:{id}";
    }

    /// <summary>电影 / 单个视频没有集的概念，不需要选集。</summary>
    private static bool LooksLikeEpisode(PlayRecordDto record) =>
        record.EpisodeNumber is > 0 ||
        record.SeasonNumber is > 0 ||
        !string.IsNullOrWhiteSpace(record.SeriesTitle);

    /// <summary>按剧名找回剧集 id：只认标题对得上的 series / tv，宁可不找也不错找。</summary>
    private static async Task<string?> FindSeriesAsync(MediaCore core, string title)
    {
        var result = await Task.Run(() => core.Search(title)).ConfigureAwait(true);
        var wanted = title.Trim();

        var series = (result.Data ?? new List<MediaItemDto>())
            .Where(item => item.Kind is "series" or "Series" or "tv" or "TV")
            .ToList();

        return series.FirstOrDefault(item =>
                   string.Equals(item.Title?.Trim(), wanted, StringComparison.OrdinalIgnoreCase))?.Id
               ?? series.FirstOrDefault()?.Id;
    }

    /// <summary>
    /// 只认 kind：未刮削的目录里每个文件的 seasonNumber 也可能是 0/1，
    /// 用「seasonNumber 有值」判断会把整排视频当成季，再下一层就空了。
    /// </summary>
    private static bool IsSeason(MediaItemDto item) =>
        string.Equals(item.Kind, "season", StringComparison.OrdinalIgnoreCase);

    private static List<PlayEpisode> ToEpisodes(List<MediaItemDto> items)
    {
        return items
            .Select((item, index) =>
            {
                var number = item.EpisodeNumber ?? index + 1;
                var badge = item.SeasonNumber is { } season
                    ? $"S{season:00}E{number:00}"
                    : $"E{number:00}";

                return new PlayEpisode(
                    item.Id,
                    badge,
                    string.Join(" · ", new[]
                        {
                            item.Resolution,
                            item.RuntimeSeconds is { } runtime
                                ? $"{runtime / 60}:{runtime % 60:00}"
                                : null,
                        }
                        .Where(part => !string.IsNullOrWhiteSpace(part))),
                    item.PosterPath,
                    MediaText.Clean(item.Title));
            })
            .ToList();
    }
}
