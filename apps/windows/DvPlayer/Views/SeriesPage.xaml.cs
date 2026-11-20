using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 剧集 / 电影详情页。
///
/// 数据来源分两种，界面完全一样：
/// - 刮削好的剧集：TV → Season → Episode，每集自带集号和时长；
/// - 没刮削的目录（Directory → Video）：从文件名里解析 SxxExx。
/// </summary>
public partial class SeriesPage : Page
{
    private const double TileWidth = 296;

    /// <summary>集列表一页取多少集。飞牛 `/item/list` 基本随 page_size 线性变慢。</summary>
    private const int EpisodePageSize = 80;

    private readonly string _itemId;
    private readonly int _initialSeason;
    private readonly ObservableCollection<EpisodeTile> _episodeTiles = new();
    private readonly HashSet<int> _episodeNumbers = new();
    private readonly HashSet<string> _episodeIds = new();
    private MediaDetailDto? _detail;

    /// <summary>当前集列表的原始条目（缓存、补页都靠它）。</summary>
    private List<MediaItemDto> _episodeItems = new();

    /// <summary>季列表的原始条目；缓存命中时用它重建季按钮。</summary>
    private List<MediaItemDto> _seasonItems = new();

    private List<PersonDto> _people = new();

    /// <summary>集列表属于谁（季 id，未刮削目录就是条目自己）；切季时靠它停掉补页。</summary>
    private string? _episodesParentId;

    /// <summary>这一季服务器说有多少集（首屏可能只拿到一页）。</summary>
    private int _episodeTotal;

    private string? _playTargetId;
    private int _resumeEpisode;
    private string? _currentSeasonId;
    private bool _episodesAreFlat;

    /// <summary>季选择用的列表（按钮弹出菜单，不再是一排胶囊）。</summary>
    private List<SeasonChip> _seasons = new();

    /// <summary>媒体信息按条目缓存，切季回来不用重新请求。</summary>
    private readonly Dictionary<string, MediaInfoDto?> _mediaInfoCache = new();

    /// <summary>续播点（秒），按条目缓存。详情页的播放按钮上要显示它。</summary>
    private readonly Dictionary<string, long> _resumeCache = new();

    private MediaInfoDto? _tracks;
    private long _resumeSeconds;
    private bool _watched;
    private bool _favorite;

    private bool _mediaInfoLoading;

    /// <summary>本地实际有几季（服务器可能只刮到第一季）。</summary>
    private int _localSeasonCount;

    /// <summary>本地实际有几个文件；未刮削目录的标题写着「76集」，但可能只有 53 个。</summary>
    private int _localEpisodeCount;

    /// <param name="initialSeason">默认显示第几季（0 起，脚本截图用）。</param>
    public SeriesPage(string itemId, int initialSeason = 0)
    {
        _itemId = itemId;
        _initialSeason = Math.Max(0, initialSeason);
        InitializeComponent();
        Loaded += OnLoaded;
        KeyDown += OnKeyDown;
    }

    /// <summary>截图巡检用：往下滚一段，把集行露出来。</summary>
    public void ScrollByForShot(double offset) => PageScroll.ScrollToVerticalOffset(offset);

    /// <summary>截图巡检用：取第 N 个有 id 的演职人员（默认第一个）。</summary>
    public (string Id, string Name)? FirstPersonForShot(int index = 0)
    {
        if (CastList.ItemsSource is not List<CastCard> cards)
        {
            return null;
        }

        var withId = cards.Where(c => !string.IsNullOrEmpty(c.PersonId)).ToList();
        return index >= 0 && index < withId.Count ? (withId[index].PersonId, withId[index].Name) : null;
    }

    /// <summary>截图巡检用：点一下集行的右箭头（验证平滑滚动动画）。</summary>
    public void ScrollEpisodeRowForShot() => SmoothScroll.ScrollBy(EpisodeScroller, 640);

    /// <summary>截图巡检用：把横向行两侧的箭头强制显示（截不到鼠标悬停）。</summary>
    public void ShowRowArrowsForShot()
    {
        Button[] arrows =
        {
            EpisodeLeftButton, EpisodeRightButton,
            CastLeftButton, CastRightButton,
            MediaInfoLeftButton, MediaInfoRightButton,
        };

        foreach (var arrow in arrows)
        {
            arrow.Visibility = Visibility.Visible;
        }
    }

    /// <summary>截图巡检用：滚到底，看「链接 / 媒体信息」两块。</summary>
    public void ScrollToMediaInfoForShot() => PageScroll.ScrollToEnd();

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            StatusText.Text = "未连接媒体源。";
            return;
        }

        // 两分钟内回到同一部片：上次的结果直接用，不再等 /item/list。
        if (DetailCache.Get(_itemId) is { } cached)
        {
            Trace.Write($"detail cache hit id={_itemId}");
            await ApplySnapshotAsync(cached).ConfigureAwait(true);
            return;
        }

        StatusText.Text = "正在读取…";

        var clock = System.Diagnostics.Stopwatch.StartNew();
        var detail = await Task.Run(() => core.ItemDetail(_itemId)).ConfigureAwait(true);
        var detailMs = clock.ElapsedMilliseconds;
        if (detail.Ok)
        {
            _detail = detail.Data;
        }

        // 详情一到就先铺头部：背景图、标题、按钮不用等下面那两次 /item/list。
        RenderHeader();
        _ = LoadPeopleAsync();

        clock.Restart();
        var children = await Task.Run(() => core.Children(_itemId, 1, EpisodePageSize))
            .ConfigureAwait(true);
        var kids = children.Ok
            ? children.Data?.Items ?? new List<MediaItemDto>()
            : new List<MediaItemDto>();
        var childTotal = children.Ok ? children.Data?.Total ?? kids.Count : kids.Count;

        Trace.Write($"detail id={_itemId} ok={detail.Ok} title={_detail?.Title} " +
                    $"backdrop={_detail?.BackdropPath is not null} poster={_detail?.PosterPath is not null} " +
                    $"seasons={_detail?.SeasonCount} eps={_detail?.LocalEpisodeCount} " +
                    $"children={kids.Count}/{childTotal} detailMs={detailMs} childrenMs={clock.ElapsedMilliseconds}" +
                    (detail.Ok ? "" : $" err={detail.Error}"));

        var seasons = kids.Where(k => k.Kind == "season").OrderBy(k => k.SeasonNumber ?? 0).ToList();
        _localSeasonCount = seasons.Count;

        // 未刮削目录：子项就是每一集，文件数才是真实集数。
        if (seasons.Count == 0 && kids.Count > 0)
        {
            _localEpisodeCount = childTotal;
        }

        if (seasons.Count > 0)
        {
            // 剧集：先季，再集。
            var start = Math.Min(_initialSeason, seasons.Count - 1);
            _seasonItems = seasons;

            _seasons = seasons
                .Select((s, i) => new SeasonChip(
                    s.Id,
                    string.IsNullOrWhiteSpace(s.Title) ? $"第 {s.SeasonNumber ?? i + 1} 季" : s.Title,
                    i == start))
                .ToList();

            UpdateSeasonPicker();
            await LoadSeasonAsync(seasons[start].Id).ConfigureAwait(true);
            return;
        }

        // 电影 / 未刮削目录 / 单集：子项直接就是可播的条目。
        _episodesAreFlat = true;
        await RenderEpisodesAsync(kids, childTotal).ConfigureAwait(true);

        if (kids.Count < childTotal)
        {
            _ = FillEpisodesAsync(_itemId, 2);
        }
    }

    /// <summary>缓存命中：把上次的详情、演职、季、集直接铺回去。</summary>
    private async Task ApplySnapshotAsync(DetailSnapshot snapshot)
    {
        _detail = snapshot.Detail;
        _localSeasonCount = snapshot.LocalSeasonCount;
        _localEpisodeCount = snapshot.LocalEpisodeCount;
        _episodesAreFlat = snapshot.Seasons.Count == 0;
        _episodesParentId = snapshot.SeasonId ?? _itemId;

        if (snapshot.Seasons.Count > 0)
        {
            var start = Math.Max(0, snapshot.Seasons.FindIndex(s => s.Id == snapshot.SeasonId));
            _seasonItems = snapshot.Seasons;
            _seasons = snapshot.Seasons
                .Select((s, i) => new SeasonChip(
                    s.Id,
                    string.IsNullOrWhiteSpace(s.Title) ? $"第 {s.SeasonNumber ?? i + 1} 季" : s.Title,
                    i == start))
                .ToList();
            UpdateSeasonPicker();
        }

        RenderHeader();
        ApplyPeople(snapshot.People);
        await RenderEpisodesAsync(snapshot.Episodes, snapshot.EpisodesTotal).ConfigureAwait(true);

        // 上次可能只补到一半（用户提前离开），接着往下补。
        if (snapshot.Episodes.Count < snapshot.EpisodesTotal)
        {
            _ = FillEpisodesAsync(_episodesParentId ?? _itemId,
                Math.Max(2, snapshot.Episodes.Count / EpisodePageSize + 1));
        }
    }

    private async Task LoadSeasonAsync(string seasonId)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        _currentSeasonId = seasonId;
        StatusText.Text = "正在读取…";
        await LoadEpisodesAsync(seasonId).ConfigureAwait(true);
    }

    /// <summary>
    /// 集列表先取一页铺出来，剩下的后台补。
    /// 一季七十几集时整表要等 2–3 秒，首屏只等一页。
    /// </summary>
    private async Task LoadEpisodesAsync(string parentId)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        _episodesParentId = parentId;

        var clock = System.Diagnostics.Stopwatch.StartNew();
        var result = await Task.Run(() => core.Children(parentId, 1, EpisodePageSize))
            .ConfigureAwait(true);
        var items = result.Ok
            ? result.Data?.Items ?? new List<MediaItemDto>()
            : new List<MediaItemDto>();
        var total = result.Ok ? result.Data?.Total ?? items.Count : items.Count;

        Trace.Write($"episodes first parent={parentId} ok={result.Ok} n={items.Count}/{total} " +
                    $"ms={clock.ElapsedMilliseconds}");

        await RenderEpisodesAsync(items, total).ConfigureAwait(true);

        if (result.Ok && items.Count < total)
        {
            _ = FillEpisodesAsync(parentId, 2);
        }
    }

    /// <summary>后台按页把剩下的集补进来；切了季就停。</summary>
    private async Task FillEpisodesAsync(string parentId, int page)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        for (var next = page; _episodesParentId == parentId; next++)
        {
            var result = await Task.Run(() => core.Children(parentId, next, EpisodePageSize))
                .ConfigureAwait(true);
            var items = result.Ok
                ? result.Data?.Items ?? new List<MediaItemDto>()
                : new List<MediaItemDto>();

            if (_episodesParentId != parentId || items.Count == 0)
            {
                return;
            }

            if (result.Ok && result.Data is { } data && data.Total > _episodeTotal)
            {
                _episodeTotal = data.Total;
            }

            await AppendEpisodesAsync(items).ConfigureAwait(true);
            SaveCache();

            if (items.Count < EpisodePageSize || _episodeItems.Count >= _episodeTotal)
            {
                return;
            }
        }
    }

    private async Task RenderEpisodesAsync(List<MediaItemDto> items, int total)
    {
        try
        {
            await RenderEpisodesCoreAsync(items, total).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            Trace.Write($"render episodes err {ex}");
            StatusText.Text = "读取剧集失败：" + ex.Message;
        }
    }

    private async Task RenderEpisodesCoreAsync(List<MediaItemDto> items, int total)
    {
        _episodeItems = items.ToList();
        _episodeTotal = Math.Max(total, _episodeItems.Count);
        _episodeTiles.Clear();
        _episodeNumbers.Clear();
        _episodeIds.Clear();

        var fresh = AddEpisodeTiles(_episodeItems);
        EpisodeList.ItemsSource = _episodeTiles;
        EpisodeList.Visibility = _episodeTiles.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        // 有看到一半的集就接着看，否则从第 1 集开始。
        var resume = _episodeTiles.FirstOrDefault(t => t.Progress is > 0.01 and < 0.99);

        if (_episodeTiles.Count > 0)
        {
            _playTargetId = resume?.Id ?? _episodeTiles[0].Id;
            _resumeEpisode = resume?.Number ?? 0;

            EpisodeSection.Visibility = Visibility.Visible;
            EpisodeCountText.Text = $"{_episodeTotal} 集";

            // 未刮削目录没有季，按钮就退化成一行静态标题。
            if (_seasons.Count == 0)
            {
                SeasonPickerText.Text = "全部剧集";
                SeasonPicker.IsEnabled = false;
                SeasonPickerChevron.Visibility = Visibility.Collapsed;
            }
            StatusText.Text = string.Empty;
            UpdatePlayButton();
        }
        else
        {
            // 没有子项：电影或单集，直接播自己。
            SeasonPickerText.Text = "全部剧集";
            SeasonPicker.IsEnabled = false;
            _playTargetId = _itemId;
            _resumeEpisode = 0;
            EpisodeSection.Visibility = Visibility.Collapsed;
            StatusText.Text = string.Empty;
            UpdatePlayButton();
        }

        LinksSection.Visibility = Visibility.Visible;

        await Task.WhenAll(fresh.Select(t => t.ApplyPosterAsync(t.PosterPath)));
        _ = LoadMediaInfoAsync();
        SaveCache();
    }

    /// <summary>按集号插到正确位置；服务器漏集号时用没被占用的最小号码补。</summary>
    private List<EpisodeTile> AddEpisodeTiles(List<MediaItemDto> items)
    {
        var fresh = new List<EpisodeTile>();

        foreach (var item in items)
        {
            if (!_episodeIds.Add(item.Id))
            {
                continue;
            }

            var number = EpisodeNumberOf(item);
            if (number is not > 0)
            {
                var candidate = 1;
                while (_episodeNumbers.Contains(candidate))
                {
                    candidate++;
                }
                number = candidate;
            }

            var value = number.Value;
            _episodeNumbers.Add(value);

            var tile = new EpisodeTile
            {
                Number = value,
                Id = item.Id,
                Title = EpisodeTitle(item, value),
                Badge = $"E{value:00}",
                Duration = FormatDuration(item.RuntimeSeconds),
                Resolution = item.Resolution,
                PosterPath = item.PosterPath,
                Initial = Palette.InitialOf(item.Title ?? ""),
                Progress = item.Progress,
                ProgressWidth = Math.Max(0, TileWidth * Math.Clamp(item.Progress, 0, 1)),
                ProgressVisibility = item.Progress > 0.01 ? Visibility.Visible : Visibility.Collapsed,
            };
            tile.UseGradient(tile.Id + tile.Title);

            var index = _episodeTiles.Count;
            while (index > 0 && _episodeTiles[index - 1].Number > value)
            {
                index--;
            }
            _episodeTiles.Insert(index, tile);
            fresh.Add(tile);
        }

        return fresh;
    }

    /// <summary>后台补的一页：只加新卡片，不整表重建。</summary>
    private async Task AppendEpisodesAsync(List<MediaItemDto> items)
    {
        _episodeItems.AddRange(items);
        _episodeTotal = Math.Max(_episodeTotal, _episodeItems.Count);

        var fresh = AddEpisodeTiles(items);
        EpisodeCountText.Text = $"{_episodeTotal} 集";
        Trace.Write($"episodes append n={fresh.Count} rows={_episodeTiles.Count}/{_episodeTotal}");

        // 续播点可能正好落在后面这页里。
        var resume = _episodeTiles.FirstOrDefault(t => t.Progress is > 0.01 and < 0.99);
        if (resume is not null)
        {
            _playTargetId = resume.Id;
            _resumeEpisode = resume.Number;
            UpdatePlayButton();
        }

        await Task.WhenAll(fresh.Select(t => t.ApplyPosterAsync(t.PosterPath)));
    }

    /// <summary>把当前状态写回缓存；收藏 / 标记看过会主动 drop。</summary>
    private void SaveCache()
    {
        if (_detail is null)
        {
            return;
        }

        DetailCache.Put(_itemId, new DetailSnapshot(
            _detail,
            _people.ToList(),
            _seasonItems.ToList(),
            _currentSeasonId,
            _episodeItems.ToList(),
            _episodeTotal,
            _localSeasonCount,
            _localEpisodeCount,
            DateTime.UtcNow));
    }

    private void RenderHeader()
    {
        var title = MediaText.Clean(_detail?.Title);

        TitleText.Text = title;
        _watched = _detail?.IsWatched ?? false;
        _favorite = _detail?.IsFavorite ?? false;
        UpdateStateButtons();

        var original = MediaText.Clean(_detail?.OriginalTitle);
        if (original != title && original != "(未命名)")
        {
            OriginalTitleText.Text = original;
            OriginalTitleText.Visibility = Visibility.Visible;
        }
        else
        {
            OriginalTitleText.Visibility = Visibility.Collapsed;
        }

        if (_detail?.Rating is > 0)
        {
            RatingText.Text = $"★ {_detail.Rating:0.0}";
            RatingText.Visibility = Visibility.Visible;
        }
        else
        {
            RatingText.Visibility = Visibility.Collapsed;
        }

        MetaText.Text = BuildMeta();
        MetaText.Visibility = string.IsNullOrEmpty(MetaText.Text) ? Visibility.Collapsed : Visibility.Visible;

        if (!string.IsNullOrWhiteSpace(_detail?.Overview))
        {
            OverviewText.Text = _detail.Overview;
            OverviewText.Visibility = Visibility.Visible;
        }
        else
        {
            OverviewText.Visibility = Visibility.Collapsed;
        }

        BuildTags();

        // 背景图走同一套鉴权下载；没有横版图时用海报放大模糊兜底。
        if (!string.IsNullOrWhiteSpace(_detail?.BackdropPath))
        {
            _ = ApplyBackdropAsync(_detail.BackdropPath);
        }
        else if (!string.IsNullOrWhiteSpace(_detail?.PosterPath))
        {
            // 目录没有横版图：拿海报放大模糊当背景，总比一块死黑好看。
            _ = ApplyBlurAsync(_detail.PosterPath);
        }
    }

    private async Task ApplyBlurAsync(string path)
    {
        var bitmap = await PosterLoader.LoadAsync(path, 1280).ConfigureAwait(true);
        if (bitmap is null)
        {
            return;
        }

        BackdropBlur.Background = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        BackdropBlur.Visibility = Visibility.Visible;
    }

    private async Task ApplyBackdropAsync(string path)
    {
        var bitmap = await PosterLoader.LoadAsync(path, 1920).ConfigureAwait(true);
        if (bitmap is null)
        {
            return;
        }

        BackdropBrush.Background = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        BackdropBlur.Visibility = Visibility.Collapsed;
    }

    private string BuildMeta()
    {
        var parts = new List<string>();

        if (_detail?.RuntimeSeconds is { } seconds && seconds > 0)
        {
            parts.Add(FormatRuntime(seconds));
        }

        if (_detail?.ReleaseDate is { Length: >= 4 } date)
        {
            parts.Add(date);
        }

        parts.Add(_detail?.Kind == "series" ? "剧集" : "电影");

        // 只报本地有的季：显示 10 季却只能点开 1 季会让人以为数据丢了。
        var seasons = _localSeasonCount > 0 ? _localSeasonCount : _detail?.LocalSeasonCount ?? 0;
        if (seasons > 1)
        {
            parts.Add($"{seasons} 季");
        }

        var episodes = _localEpisodeCount is > 0
            ? _localEpisodeCount
            : _detail?.LocalEpisodeCount ?? _detail?.EpisodeCount;
        if (episodes is > 0)
        {
            parts.Add($"{episodes} 集");
        }

        if (_detail?.Status is { Length: > 0 } status && status != "1")
        {
            parts.Add(status == "Returning Series" ? "连载中" : "已完结");
        }

        return string.Join("  ·  ", parts);
    }

    private void BuildTags()
    {
        var tags = new List<string>();

        if (!string.IsNullOrWhiteSpace(_detail?.Resolution))
        {
            tags.Add(_detail.Resolution!);
        }

        if (!string.IsNullOrWhiteSpace(_detail?.ColorRange))
        {
            tags.Add(_detail.ColorRange!);
        }

        if (!string.IsNullOrWhiteSpace(_detail?.AudioType))
        {
            tags.Add(_detail.AudioType!);
        }

        TagBar.Children.Clear();
        foreach (var tag in tags)
        {
            var border = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)),
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(8, 3, 8, 3),
                Margin = new Thickness(0, 0, 6, 0),
                Child = new TextBlock
                {
                    Text = tag,
                    FontSize = 12,
                    Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)),
                },
            };
            TagBar.Children.Add(border);
        }

        TagBar.Visibility = tags.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdatePlayButton()
    {
        PlayButton.IsEnabled = !string.IsNullOrEmpty(_playTargetId);

        // 没看过就别摆「重头看」，跟播放键重复。
        RestartButton.IsEnabled = !string.IsNullOrEmpty(_playTargetId);
        RestartButton.Visibility = _resumeSeconds >= 5 ? Visibility.Visible : Visibility.Collapsed;

        var text = _resumeEpisode > 0
            ? $"继续观看 第 {_resumeEpisode} 集"
            : _episodesAreFlat ? "播放" : "从第 1 集开始";

        // 有进度就把时间也显示出来。
        if (_resumeSeconds >= 5)
        {
            text += $"  {Clock(_resumeSeconds)}";
        }

        PlayButtonText.Text = text;
        RestartButton.ToolTip = _resumeSeconds >= 5
            ? $"重头看（上次看到 {Clock(_resumeSeconds)}）"
            : "重头看";
    }

    /// <summary>已观看 / 收藏的图标状态：亮起 = 已标记。</summary>
    private void UpdateStateButtons()
    {
        WatchedGlyph.Foreground = new SolidColorBrush(_watched ? Accent : DarkIcon);
        WatchedButton.ToolTip = _watched ? "标记为未观看" : "标记为已观看";

        FavoriteGlyph.Foreground = new SolidColorBrush(_favorite ? Accent : DarkIcon);
        FavoriteButton.ToolTip = _favorite ? "取消收藏" : "加入收藏";
    }

    private static readonly Color Accent = Color.FromRgb(0xFF, 0xB0, 0x20);
    private static readonly Color DarkIcon = Color.FromRgb(0x14, 0x14, 0x19);

    private static string Clock(double seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return time.TotalHours >= 1
            ? $"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}"
            : $"{time.Minutes:00}:{time.Seconds:00}";
    }

    /// <summary>当前这集的播放列表，播放页右侧的「选集」用它。</summary>
    private List<PlayEpisode> BuildPlaylist()
    {
        if (EpisodeList.ItemsSource is not IList<EpisodeTile> tiles || tiles.Count == 0)
        {
            return new List<PlayEpisode>();
        }

        var season = _seasons.Count > 0 ? _seasons.FindIndex(c => c.Active) + 1 : 0;

        return tiles
            .Select(t => new PlayEpisode(
                t.Id,
                season > 0 ? $"S{season:00}{t.Badge}" : t.Badge,
                string.Join(" · ", new[] { t.Resolution, t.Duration }
                    .Where(part => !string.IsNullOrWhiteSpace(part))),
                t.PosterPath,
                MediaText.Clean(t.Title)))
            .ToList();
    }

    /// <summary>详情页的按钮组：重头看 / 已观看 / 收藏 / 音轨 / 字幕。</summary>
    private async void OnRestartClick(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_playTargetId))
        {
            return;
        }

        await PlayWindow.OpenAsync(
            Window.GetWindow(this), _playTargetId, 0, BuildPlaylist(), MediaText.Clean(_detail?.Title));
    }

    private void OnWatchedClick(object sender, RoutedEventArgs e)
    {
        _watched = !_watched;
        UpdateStateButtons();
        DetailCache.Drop(_itemId);

        if (AppServices.Instance.Core is { } core)
        {
            _ = Task.Run(() => core.SetWatched(_itemId, _watched));
        }
    }

    private void OnFavoriteClick(object sender, RoutedEventArgs e)
    {
        _favorite = !_favorite;
        UpdateStateButtons();
        DetailCache.Drop(_itemId);

        if (AppServices.Instance.Core is { } core)
        {
            _ = Task.Run(() => core.SetFavorite(_itemId, _favorite));
        }
    }

    private void OnAudioClick(object sender, RoutedEventArgs e)
    {
        var audios = _tracks?.Audios ?? new List<AudioInfoDto>();
        if (audios.Count == 0)
        {
            return;
        }

        var selected = TrackPrefs.Audio(_playTargetId ?? _itemId)
            ?? Math.Max(0, audios.FindIndex(a => a.IsDefault));

        var choices = audios
            .Select((a, i) => (
                Label: string.Join("  ", new[]
                    {
                        a.Title,
                        a.Language,
                        a.Codec,
                        a.Channels is > 0 ? $"{a.Channels}ch" : null,
                        a.SampleRate is > 0 ? $"{a.SampleRate}Hz" : null,
                        a.BitRate is > 0 ? $"{a.BitRate / 1000}kbps" : null,
                    }
                    .Where(part => !string.IsNullOrWhiteSpace(part))),
                Selected: i == selected,
                Value: i))
            .ToList();

        ShowChoiceMenu(AudioButton, choices, value =>
        {
            TrackPrefs.SetAudio(_playTargetId ?? _itemId, value);
            UpdateTrackButtons(_tracks);
        });
    }

    private void OnSubtitleClick(object sender, RoutedEventArgs e)
    {
        var subs = _tracks?.Subtitles ?? new List<SubtitleInfoDto>();
        if (subs.Count == 0)
        {
            return;
        }

        var key = _playTargetId ?? _itemId;
        var selected = TrackPrefs.Subtitle(key)
            ?? (subs.FindIndex(s => s.IsDefault) is var index && index >= 0 ? index : TrackPrefs.SubtitleOff);

        var choices = new List<(string Label, bool Selected, int Value)>
        {
            ("关闭字幕", selected == TrackPrefs.SubtitleOff, TrackPrefs.SubtitleOff),
        };

        choices.AddRange(subs.Select((s, i) => (
            Label: string.Join("  ", new[]
                {
                    s.Language,
                    s.Title,
                    s.Codec,
                    s.IsBitmap ? "图形" : null,
                    s.IsExternal ? "外挂" : null,
                }
                .Where(part => !string.IsNullOrWhiteSpace(part))),
            Selected: i == selected,
            Value: i)));

        ShowChoiceMenu(SubtitleButton, choices, value =>
        {
            TrackPrefs.SetSubtitle(key, value);
            UpdateTrackButtons(_tracks);
        });
    }

    private void ShowChoiceMenu(
        Button anchor,
        IEnumerable<(string Label, bool Selected, int Value)> choices,
        Action<int> pick)
    {
        var menu = new ContextMenu
        {
            Style = (Style)FindResource("DarkContextMenu"),
            PlacementTarget = anchor,
            Placement = PlacementMode.Top,
            IsOpen = true,
        };

        foreach (var choice in choices)
        {
            var item = new MenuItem
            {
                Header = string.IsNullOrWhiteSpace(choice.Label) ? "未命名" : choice.Label,
                Style = (Style)FindResource("DarkMenuItem"),
            };

            if (choice.Selected)
            {
                item.Icon = new TextBlock
                {
                    Text = "\uE73E",
                    FontFamily = (FontFamily)FindResource("IconFont"),
                    FontSize = 12,
                    Foreground = (Brush)FindResource("AccentBrush"),
                };
            }

            var value = choice.Value;
            item.Click += (_, _) => pick(value);
            menu.Items.Add(item);
        }
    }

    /// <summary>多音轨 / 有字幕时才显示对应按钮，并把当前选择写进提示。</summary>
    private void UpdateTrackButtons(MediaInfoDto? info)
    {
        _tracks = info;
        var audios = info?.Audios ?? new List<AudioInfoDto>();
        var subs = info?.Subtitles ?? new List<SubtitleInfoDto>();

        AudioButton.Visibility = audios.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        SubtitleButton.Visibility = subs.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AudioButton.IsEnabled = info is not null;
        SubtitleButton.IsEnabled = info is not null;

        if (audios.Count > 1)
        {
            var index = TrackPrefs.Audio(_playTargetId ?? _itemId)
                ?? Math.Max(0, audios.FindIndex(a => a.IsDefault));
            var audio = audios[Math.Min(index, audios.Count - 1)];
            AudioButton.ToolTip = "音轨：" + (audio.Language ?? audio.Title ?? audio.Codec ?? "默认");
        }

        if (subs.Count > 0)
        {
            var index = TrackPrefs.Subtitle(_playTargetId ?? _itemId);
            SubtitleButton.ToolTip = index is null or TrackPrefs.SubtitleOff
                ? "选择字幕"
                : "字幕：" + (subs.ElementAtOrDefault((int)index)?.Language ?? "已选");
        }
    }

    private async void OnPlayClick(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_playTargetId))
        {
            return;
        }

        await PlayWindow.OpenAsync(
            Window.GetWindow(this), _playTargetId, null, BuildPlaylist(), MediaText.Clean(_detail?.Title));
    }

    private async void OnEpisodeClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        await PlayWindow.OpenAsync(
            Window.GetWindow(this), id, null, BuildPlaylist(), MediaText.Clean(_detail?.Title));
    }

    // —— 季选择 ——

    private void UpdateSeasonPicker()
    {
        var chip = _seasons.FirstOrDefault(c => c.Active) ?? _seasons.FirstOrDefault();
        SeasonPickerText.Text = chip?.Title ?? "剧集";
        SeasonPicker.Visibility = _seasons.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        SeasonPicker.IsEnabled = _seasons.Count > 1;
        SeasonPickerChevron.Visibility = _seasons.Count > 1
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void OnSeasonPickerClick(object sender, RoutedEventArgs e)
    {
        if (_seasons.Count <= 1)
        {
            return;
        }

        BuildSeasonMenu().IsOpen = true;
    }

    /// <summary>截图巡检用：把季菜单打开（Popup 抓不到整窗，单独渲染）。</summary>
    public ContextMenu? OpenSeasonMenuForShot()
    {
        if (_seasons.Count == 0)
        {
            return null;
        }

        var menu = BuildSeasonMenu();
        menu.IsOpen = true;
        menu.UpdateLayout();
        return menu;
    }

    private ContextMenu BuildSeasonMenu()
    {
        var menu = new ContextMenu
        {
            Style = (Style)FindResource("DarkContextMenu"),
            PlacementTarget = SeasonPicker,
            Placement = PlacementMode.Bottom,
        };

        foreach (var chip in _seasons)
        {
            var item = new MenuItem
            {
                Header = chip.Title,
                Style = (Style)FindResource("DarkMenuItem"),
                Tag = chip.Id,
            };

            if (chip.Active)
            {
                item.Icon = new TextBlock
                {
                    Text = "\uE73E",
                    FontFamily = (FontFamily)FindResource("IconFont"),
                    FontSize = 12,
                    Foreground = (Brush)FindResource("AccentBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            }

            item.Click += OnSeasonMenuClick;
            menu.Items.Add(item);
        }

        return menu;
    }

    private async void OnSeasonMenuClick(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuItem { Tag: string id } || id == _currentSeasonId)
        {
            return;
        }

        foreach (var chip in _seasons)
        {
            chip.Active = chip.Id == id;
        }

        UpdateSeasonPicker();
        EpisodeScroller.ScrollToLeftEnd();
        await LoadSeasonAsync(id).ConfigureAwait(true);
    }

    // —— 集横向行 ——

    // 都走 SmoothScroll：和媒体库页的横向行用同一段缓出动画。
    private void OnEpisodeScrollLeft(object sender, RoutedEventArgs e) =>
        SmoothScroll.ScrollBy(EpisodeScroller, -640);

    private void OnEpisodeScrollRight(object sender, RoutedEventArgs e) =>
        SmoothScroll.ScrollBy(EpisodeScroller, 640);

    private void OnCastScrollLeft(object sender, RoutedEventArgs e) =>
        SmoothScroll.ScrollBy(CastScroller, -640);

    private void OnCastScrollRight(object sender, RoutedEventArgs e) =>
        SmoothScroll.ScrollBy(CastScroller, 640);

    private void OnMediaInfoScrollLeft(object sender, RoutedEventArgs e) =>
        SmoothScroll.ScrollBy(MediaInfoScroller, -720);

    private void OnMediaInfoScrollRight(object sender, RoutedEventArgs e) =>
        SmoothScroll.ScrollBy(MediaInfoScroller, 720);

    // —— 链接 ——

    private void OnDoubanClick(object sender, MouseButtonEventArgs e)
    {
        var title = MediaText.Clean(_detail?.Title);
        if (string.IsNullOrWhiteSpace(title) || title == "(未命名)")
        {
            return;
        }

        var url = "https://search.douban.com/movie/subject_search?search_text=" +
                  Uri.EscapeDataString(title);
        System.Diagnostics.Process.Start(
            new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
    }

    // —— 演职人员 ——

    private async Task LoadPeopleAsync()
    {
        if (AppServices.Instance.Core is not { } core)
        {
            return;
        }

        var result = await Task.Run(() => core.People(_itemId)).ConfigureAwait(true);
        var people = result.Ok ? result.Data ?? new List<PersonDto>() : new List<PersonDto>();
        Trace.Write($"people id={_itemId} ok={result.Ok} n={people.Count} err={result.Error}");

        ApplyPeople(people);
    }

    /// <summary>演职人员上屏；缓存命中时也走这里，网络请求只在上面的方法里。</summary>
    private void ApplyPeople(List<PersonDto> people)
    {
        _people = people;

        if (people.Count == 0)
        {
            CastSection.Visibility = Visibility.Collapsed;
            return;
        }

        var cards = people.Select(person => new CastCard
        {
            PersonId = person.Id,
            Name = person.Name,
            Role = person.Role ?? "",
            Job = person.Job ?? "",
            PosterPath = person.ImagePath,
            Initial = Palette.InitialOf(person.Name),
        }).ToList();

        foreach (var card in cards)
        {
            card.UseGradient(card.Name);
        }

        CastList.ItemsSource = cards;
        CastSection.Visibility = Visibility.Visible;

        _ = Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    // —— 媒体信息 ——

    private async Task LoadMediaInfoAsync()
    {
        var id = _playTargetId;
        if (string.IsNullOrEmpty(id) || AppServices.Instance.Core is not { } core ||
            _mediaInfoLoading)
        {
            return;
        }

        if (!_mediaInfoCache.TryGetValue(id, out var info))
        {
            _mediaInfoLoading = true;
            try
            {
                // 媒体信息（轨道清单）和播放源（续播点）一起取：详情页的按钮
                // 既要列出音轨 / 字幕，也要在播放键上显示「上次看到哪」。
                // 两个请求互不依赖，并发发出去，不用等前一个回来再发后一个。
                var infoTask = Task.Run(() => core.MediaInfo(id));
                var playTask = Task.Run(() => core.PlaySource(id));
                await Task.WhenAll(infoTask, playTask).ConfigureAwait(true);

                var infoResult = infoTask.Result;
                var playResult = playTask.Result;

                info = infoResult.Ok ? infoResult.Data : null;
                _mediaInfoCache[id] = info;
                _resumeCache[id] = playResult.Ok ? playResult.Data?.PositionSeconds ?? 0 : 0;

                Trace.Write($"media info id={id} ok={infoResult.Ok} err={infoResult.Error} " +
                            $"video={info?.Video is not null} audios={info?.Audios.Count} " +
                            $"subs={info?.Subtitles.Count} resume={_resumeCache[id]}");
            }
            finally
            {
                _mediaInfoLoading = false;
            }
        }

        // 读的过程中切了季，就等新的那次请求。
        if (_playTargetId == id)
        {
            _resumeSeconds = _resumeCache.TryGetValue(id, out var resume) ? resume : 0;
            UpdatePlayButton();
            UpdateTrackButtons(info);
            RenderMediaInfo(info);
        }
    }

    private void RenderMediaInfo(MediaInfoDto? info)
    {
        MediaInfoPanel.Children.Clear();

        if (info?.Video is { } video)
        {
            var rows = new List<(string Key, string Value)>
            {
                ("标题", video.Title ?? ""),
                ("编码", video.Codec ?? ""),
                ("分辨率", video.Width is > 0 && video.Height is > 0
                    ? $"{video.Width} x {video.Height}"
                    : ""),
                ("帧率", video.FrameRate is > 0 ? $"{video.FrameRate:0.##} fps" : ""),
                ("比特率", FormatBitRate(video.BitRate)),
                ("动态范围", video.ColorRange ?? (video.DolbyVision ? "DV" : "")),
                ("配置", video.Profile ?? ""),
                ("等级", video.Level is { } level ? level.ToString("0.###") : ""),
                ("长宽比", video.AspectRatio ?? ""),
                ("交错", video.Interlaced is { } interlaced ? (interlaced ? "是" : "否") : ""),
                ("位深", video.BitDepth is > 0 ? $"{video.BitDepth} bit" : ""),
                ("像素格式", video.PixelFormat ?? ""),
            };

            MediaInfoPanel.Children.Add(BuildInfoCard("\uE714", "视频", rows));
        }

        // 每条音轨一张卡，当前音轨（默认轨）打勾。
        foreach (var audio in info?.Audios ?? new List<AudioInfoDto>())
        {
            var rows = new List<(string Key, string Value)>
            {
                ("标题", audio.Title ?? ""),
                ("语言", audio.Language ?? "--"),
                ("编码", audio.Codec ?? ""),
                ("配置", audio.Profile ?? ""),
                ("布局", audio.Layout ?? ""),
                ("声道", audio.Channels is > 0 ? $"{audio.Channels} ch" : ""),
                ("采样率", audio.SampleRate is > 0 ? $"{audio.SampleRate} Hz" : ""),
                ("比特率", FormatBitRate(audio.BitRate)),
                ("默认", audio.IsDefault ? "是" : "否"),
                ("外部", audio.IsExternal ? "是" : "否"),
            };

            MediaInfoPanel.Children.Add(BuildInfoCard("\uE8D6", "音频", rows, audio.IsDefault));
        }

        MediaInfoSection.Visibility = MediaInfoPanel.Children.Count > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    /// <summary>一张「视频 / 音频」卡：标题 + 键值行，空值整行跳过。</summary>
    private Border BuildInfoCard(
        string icon,
        string title,
        IEnumerable<(string Key, string Value)> rows,
        bool active = false)
    {
        var body = new StackPanel();

        var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        header.Children.Add(new TextBlock
        {
            Text = icon,
            FontFamily = (FontFamily)FindResource("IconFont"),
            FontSize = 14,
            Foreground = (Brush)FindResource("MutedBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0),
        });
        header.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 14.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("TextBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        });

        if (active)
        {
            header.Children.Add(new TextBlock
            {
                Text = "\uE73E",
                FontFamily = (FontFamily)FindResource("IconFont"),
                FontSize = 12,
                Foreground = (Brush)FindResource("TextBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(10, 0, 0, 0),
            });
        }

        body.Children.Add(header);

        foreach (var (key, value) in rows)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            var line = new Grid { Margin = new Thickness(0, 7, 0, 0) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });

            var keyText = new TextBlock
            {
                Text = key,
                FontSize = 12.5,
                Foreground = (Brush)FindResource("MutedBrush"),
                MinWidth = 84,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(keyText, 0);
            line.Children.Add(keyText);

            var valueText = new TextBlock
            {
                Text = value,
                FontSize = 13,
                Foreground = (Brush)FindResource("TextBrush"),
                HorizontalAlignment = HorizontalAlignment.Right,
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(valueText, 1);
            line.Children.Add(valueText);

            body.Children.Add(line);
        }

        return new Border
        {
            Background = (Brush)FindResource("SurfaceBrush"),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(18, 16, 18, 16),
            Margin = new Thickness(0, 0, 18, 18),
            Width = 320,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = body,
        };
    }

    private static string FormatBitRate(long? bits) => bits is > 0
        ? bits >= 1_000_000
            ? $"{bits.Value / 1_000_000.0:0.##} Mbps"
            : $"{bits.Value / 1000.0:0.##} Kbps"
        : "";

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (NavigationService?.CanGoBack == true)
        {
            NavigationService.GoBack();
        }
    }

    private void OnKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Escape)
        {
            OnBackClick(sender, e);
            e.Handled = true;
        }
    }

    /// <summary>
    /// 集号：核心已经解析好（服务器的 episode_number 优先，没有就从文件名认），
    /// 这里只在最后兜底按顺序编号。
    /// </summary>
    private static int? EpisodeNumberOf(MediaItemDto item) => item.EpisodeNumber;

    /// <summary>文件名当标题没用，显示「第 N 集」；刮削好的单集保留自己的名字。</summary>
    private static string EpisodeTitle(MediaItemDto item, int number)
    {
        var raw = (item.Title ?? string.Empty).Trim();
        if (raw.Length == 0)
        {
            return $"第 {number} 集";
        }

        return MediaText.LooksLikeFileName(raw) ? $"第 {number} 集" : MediaText.TrimExtension(raw);
    }

    /// <summary>「1小时38分钟」这种长时长，详情页顶部用。</summary>
    private static string FormatRuntime(long seconds)
    {
        var span = TimeSpan.FromSeconds(seconds);
        if (span.TotalHours >= 1)
        {
            return $"{(int)span.TotalHours} 小时 {span.Minutes} 分钟";
        }

        return $"{Math.Max(1, span.Minutes)} 分钟";
    }

    private static string FormatDuration(long? seconds) => seconds is > 0
        ? TimeSpan.FromSeconds(seconds.Value).ToString(seconds >= 3600 ? @"h\:mm\:ss" : @"m\:ss")
        : "";

    private sealed class SeasonChip
    {
        public SeasonChip(string id, string title, bool active)
        {
            Id = id;
            Title = title;
            Active = active;
        }

        public string Id { get; }
        public string Title { get; }
        public bool Active { get; set; }
    }

    /// <summary>点头像进这个人的作品页。</summary>
    private void OnCastClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        var name = (sender as FrameworkElement)?.DataContext is CastCard card
            ? card.Name
            : "演职人员";

        NavigationService?.Navigate(new PersonPage(id, name));
    }

    private sealed class CastCard : CardVisual
    {
        public string PersonId { get; init; } = "";
        public string Name { get; init; } = "";
        public string Role { get; init; } = "";
        public string Job { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }

        public Visibility RoleVisibility => string.IsNullOrWhiteSpace(Role)
            ? Visibility.Collapsed
            : Visibility.Visible;

        public Visibility JobVisibility => string.IsNullOrWhiteSpace(Job)
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private sealed class EpisodeTile : CardVisual
    {
        public int Number { get; init; }
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Duration { get; init; } = "";
        public string? Resolution { get; init; }
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public double Progress { get; init; }
        public double ProgressWidth { get; init; }
        public Visibility ProgressVisibility { get; init; } = Visibility.Collapsed;
    }
}
