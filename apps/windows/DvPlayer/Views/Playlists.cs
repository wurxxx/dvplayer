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
        var clock = System.Diagnostics.Stopwatch.StartNew();

        // 详情只是为了补剧名，和列集互不依赖，一起发出去省一个来回。
        var detailTask = string.IsNullOrWhiteSpace(title)
            ? Task.Run(() => core.ItemDetail(id))
            : null;

        var items = await FetchAllChildrenAsync(core, id).ConfigureAwait(true);
        var childrenMs = clock.ElapsedMilliseconds;

        // 传进来的是剧集本身：直接子项是「季」，要再下一层才是集。
        if (items.Count > 0 && IsSeason(items[0]))
        {
            var season = items.FirstOrDefault(item =>
                             seasonNumber is > 0 && item.SeasonNumber == seasonNumber)
                         ?? items.FirstOrDefault(item => item.SeasonNumber is > 0)
                         ?? items[0];

            items = await FetchAllChildrenAsync(core, season.Id).ConfigureAwait(true);
        }

        items = items
            .Where(item => !string.IsNullOrEmpty(item.Id))
            .OrderBy(item => item.EpisodeNumber ?? 0)
            .ToList();

        if (detailTask is not null)
        {
            var detailClock = System.Diagnostics.Stopwatch.StartNew();
            var detail = await detailTask.ConfigureAwait(true);
            Trace.Write($"playlist detail id={id} ok={detail.Ok} " +
                        $"ms={detailClock.ElapsedMilliseconds} sinceStart={clock.ElapsedMilliseconds}");
            title = detail.Ok ? MediaText.Clean(detail.Data?.Title) : null;
        }

        Trace.Write($"playlist id={id} n={items.Count} childrenMs={childrenMs} " +
                    $"totalMs={clock.ElapsedMilliseconds}");

        return (ToEpisodes(items), title);
    }

    /// <summary>一页一百条地取全：一次要 500 条时服务端要扫更久，分页反而快。</summary>
    private const int ChildrenPageSize = 100;

    /// <summary>防止服务端 Total 异常时无限翻页。</summary>
    private const int ChildrenMaxPages = 30;

    private static async Task<List<MediaItemDto>> FetchAllChildrenAsync(MediaCore core, string id)
    {
        var all = new List<MediaItemDto>();

        for (var page = 1; page <= ChildrenMaxPages; page++)
        {
            var pageClock = System.Diagnostics.Stopwatch.StartNew();
            var result = await Task.Run(() => core.Children(id, page, ChildrenPageSize))
                .ConfigureAwait(true);
            Trace.Write($"playlist page={page} id={id} ok={result.Ok} " +
                        $"n={result.Data?.Items?.Count ?? 0}/{result.Data?.Total ?? 0} " +
                        $"ms={pageClock.ElapsedMilliseconds}");
            if (!result.Ok)
            {
                if (page == 1)
                {
                    Trace.Write($"playlist children failed id={id} err={result.Error}");
                }

                break;
            }

            var items = result.Data?.Items ?? new List<MediaItemDto>();
            if (items.Count == 0)
            {
                break;
            }

            all.AddRange(items);

            var total = result.Data?.Total ?? 0;
            if (items.Count < ChildrenPageSize || (total > 0 && all.Count >= total))
            {
                break;
            }
        }

        return all;
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

        // 选集只影响右侧面板，不该拖着开窗一起等：先把窗口和画面起来，
        // 集列表在后台拼好再补进去（70 集要好几秒，用户看到的却是马上有反应）。
        var window = await PlayWindow.OpenAsync(
            owner,
            record.ItemId,
            hintTitle: RecordTitle(record),
            seriesTitle: string.IsNullOrWhiteSpace(record.SeriesTitle) ? null : record.SeriesTitle);

        if (window is null)
        {
            // 连点被闸门挡下的那次，就别再去拉一遍选集了。
            return null;
        }

        _ = AttachPlaylistAsync(window, record, ResolvePlaylistAsync(core, record));
        return window;
    }

    /// <summary>认出记录所在容器里的集列表；哪条线索都不通就返回 null（照旧单集播放）。</summary>
    private static async Task<(List<PlayEpisode> Items, string? Title)?> ResolvePlaylistAsync(
        MediaCore core,
        PlayRecordDto record)
    {
        try
        {
            // 1) 记录的父条目能直接列出集。
            if (WithSource(record, record.ParentId) is { } parentId &&
                await TryLoadAsync(core, parentId, record, record.SeriesTitle) is { } byParent)
            {
                return byParent;
            }

            // 2) 飞牛的 parent_guid 不是可浏览的目录，按剧名把剧集找回来。
            if (!string.IsNullOrWhiteSpace(record.SeriesTitle) &&
                await FindSeriesAsync(core, record.SeriesTitle!) is { } seriesId &&
                await TryLoadAsync(core, seriesId, record, record.SeriesTitle) is { } bySeries)
            {
                return bySeries;
            }
        }
        catch (Exception ex)
        {
            Trace.Write($"record {record.ItemId} playlist failed: {ex.Message}");
        }

        Trace.Write($"record {record.ItemId} no playlist title='{record.Title}'");
        return null;
    }

    /// <summary>窗口已经起来了，选集到货就塞进侧栏；窗口早关了就算了。</summary>
    private static async Task AttachPlaylistAsync(
        PlayWindow window,
        PlayRecordDto record,
        Task<(List<PlayEpisode> Items, string? Title)?> playlistTask)
    {
        var playlist = await playlistTask.ConfigureAwait(true);
        if (playlist is not { } found || !window.IsAlive)
        {
            return;
        }

        window.SetPlaylist(found.Items, found.Title);
        Trace.Write($"playlist attached record={record.ItemId} n={found.Items.Count} " +
                    $"title={found.Title}");

        if (found.Items.All(item => item.Id != record.ItemId))
        {
            Trace.Write($"record {record.ItemId} playing as-is, not listed in playlist " +
                        $"({found.Items.Count} 集)");
        }
    }

    /// <summary>加载页的提示名：优先「剧名 + 集号」，没有剧名再用记录标题。</summary>
    private static string? RecordTitle(PlayRecordDto record)
    {
        var series = MediaText.Clean(record.SeriesTitle);
        if (!string.IsNullOrWhiteSpace(series))
        {
            return record.SeasonNumber is { } season && record.EpisodeNumber is { } episode
                ? $"{series}  S{season:00}E{episode:00}"
                : series;
        }

        return MediaText.Clean(record.Title);
    }

    /// <summary>
    /// 列出容器里的集，认出记录对应的是哪一集再打开。
    /// 记录的 item id 有时是「播放用」的 guid，和列表里的条目 id 对不上，
    /// 所以还要按标题兜一层。
    /// </summary>
    private static async Task<(List<PlayEpisode> Items, string? Title)?> TryLoadAsync(
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

        Trace.Write($"record playlist {record.ItemId} -> {target.Id} " +
                    $"container={containerId} episodes={items.Count}");
        return (items, seriesTitle);
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

        var series = (result.Data?.Items ?? new List<MediaItemDto>())
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
