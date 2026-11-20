using System.Windows;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 拼播放页右侧「选集」用的列表。
///
/// 详情页本来就知道当前是哪一季，直接把自己那行集传进来；续播（观看记录、
/// 收藏里的单集）只有一条记录，所以要顺着记录的 <see cref="PlayRecordDto.ParentId"/>
/// 再查一次那一季的集，不然播放页就只剩一个孤零零的片子，没有上一集 / 下一集。
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
        if (core is null)
        {
            return await PlayWindow.OpenAsync(owner, record.ItemId);
        }

        // 1) 记录的父条目能直接列出集：Emby 的单集父条目就是「季」，一次请求搞定。
        if (!string.IsNullOrEmpty(record.ParentId))
        {
            var (items, title) = await LoadAsync(core, record.ParentId, record.SeriesTitle);
            if (items.Any(item => item.Id == record.ItemId))
            {
                Trace.Write($"record play parent={record.ParentId} episodes={items.Count}");
                return await PlayWindow.OpenAsync(owner, record.ItemId, null, items, title);
            }
        }

        // 2) 飞牛的记录里 parent_guid 不是可浏览的目录，只能按剧名把剧集找回来。
        if (!string.IsNullOrWhiteSpace(record.SeriesTitle) &&
            await FindSeriesAsync(core, record.SeriesTitle!) is { } seriesId)
        {
            var (items, title) = await LoadAsync(
                core, seriesId, record.SeriesTitle, record.SeasonNumber);
            if (items.Any(item => item.Id == record.ItemId))
            {
                Trace.Write($"record play series={seriesId} episodes={items.Count} " +
                            $"season={record.SeasonNumber}");
                return await PlayWindow.OpenAsync(owner, record.ItemId, null, items, title);
            }
        }

        Trace.Write($"record {record.ItemId} no playlist");
        return await PlayWindow.OpenAsync(owner, record.ItemId);
    }

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

    private static bool IsSeason(MediaItemDto item) =>
        item.Kind is "season" or "Season" || item.SeasonNumber is not null;

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
