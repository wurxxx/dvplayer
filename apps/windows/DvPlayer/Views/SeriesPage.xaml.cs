using System.Windows;
using System.Windows.Controls;
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
    private const double TileWidth = 226;

    private readonly string _itemId;
    private readonly int _initialSeason;
    private MediaDetailDto? _detail;

    private string? _playTargetId;
    private int _resumeEpisode;
    private string? _currentSeasonId;
    private bool _episodesAreFlat;

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

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            StatusText.Text = "未连接媒体源。";
            return;
        }

        StatusText.Text = "正在读取…";

        var detail = await Task.Run(() => core.ItemDetail(_itemId)).ConfigureAwait(true);
        if (detail.Ok)
        {
            _detail = detail.Data;
        }

        var children = await Task.Run(() => core.Children(_itemId, 1, 500)).ConfigureAwait(true);
        var kids = children.Ok ? children.Data?.Items ?? new List<MediaItemDto>() : new List<MediaItemDto>();

        Trace.Write($"detail id={_itemId} ok={detail.Ok} title={_detail?.Title} " +
                    $"backdrop={_detail?.BackdropPath is not null} poster={_detail?.PosterPath is not null} " +
                    $"seasons={_detail?.SeasonCount} eps={_detail?.LocalEpisodeCount} children={kids.Count}" +
                    (detail.Ok ? "" : $" err={detail.Error}"));

        var seasons = kids.Where(k => k.Kind == "season").OrderBy(k => k.SeasonNumber ?? 0).ToList();
        _localSeasonCount = seasons.Count;

        // 未刮削目录：子项就是每一集，文件数才是真实集数。
        if (seasons.Count == 0 && kids.Count > 0)
        {
            _localEpisodeCount = kids.Count;
        }

        RenderHeader();

        if (seasons.Count > 0)
        {
            // 剧集：先季，再集。
            var start = Math.Min(_initialSeason, seasons.Count - 1);

            SeasonBar.ItemsSource = seasons
                .Select((s, i) => new SeasonChip(
                    s.Id,
                    string.IsNullOrWhiteSpace(s.Title) ? $"第 {s.SeasonNumber ?? i + 1} 季" : s.Title,
                    i == start))
                .ToList();
            SeasonBarHost.Visibility = seasons.Count > 1 ? Visibility.Visible : Visibility.Collapsed;

            await LoadSeasonAsync(seasons[start].Id).ConfigureAwait(true);
            return;
        }

        // 电影 / 未刮削目录 / 单集：子项直接就是可播的条目。
        _episodesAreFlat = true;
        await RenderEpisodesAsync(kids).ConfigureAwait(true);
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

        var result = await Task.Run(() => core.Children(seasonId, 1, 1000)).ConfigureAwait(true);
        var items = result.Ok ? result.Data?.Items ?? new List<MediaItemDto>() : new List<MediaItemDto>();

        await RenderEpisodesAsync(items).ConfigureAwait(true);
    }

    private async Task RenderEpisodesAsync(List<MediaItemDto> items)
    {
        var ordered = items
            .Select((item, index) => (item, number: EpisodeNumberOf(item) ?? index + 1))
            .OrderBy(pair => pair.number)
            .ToList();

        // 有看到一半的集就接着看，否则从第 1 集开始。
        var resume = ordered.FirstOrDefault(pair => pair.item.Progress is > 0.01 and < 0.99);

        var tiles = ordered.Select(pair => new EpisodeTile
        {
            Id = pair.item.Id,
            Title = EpisodeTitle(pair.item, pair.number),
            Badge = $"E{pair.number:00}",
            Duration = FormatDuration(pair.item.RuntimeSeconds),
            PosterPath = pair.item.PosterPath,
            Initial = Palette.InitialOf(pair.item.Title ?? ""),
            ProgressWidth = Math.Max(0, TileWidth * Math.Clamp(pair.item.Progress, 0, 1)),
        }).ToList();

        foreach (var tile in tiles)
        {
            tile.UseGradient(tile.Id + tile.Title);
        }

        EpisodeList.ItemsSource = tiles;
        EpisodeList.Visibility = tiles.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        if (tiles.Count > 0)
        {
            _playTargetId = resume.item?.Id ?? tiles[0].Id;
            _resumeEpisode = resume.item is null ? 0 : EpisodeNumberOf(resume.item) ?? 1;

            EpisodeHeader.Text = _episodesAreFlat ? $"全部 {tiles.Count} 集" : "剧集";
            EpisodeHeader.Visibility = Visibility.Visible;
            StatusText.Text = string.Empty;
            UpdatePlayButton();
        }
        else
        {
            // 没有子项：电影或单集，直接播自己。
            _playTargetId = _itemId;
            _resumeEpisode = 0;
            EpisodeHeader.Visibility = Visibility.Collapsed;
            StatusText.Text = string.Empty;
            UpdatePlayButton();
        }

        await Task.WhenAll(tiles.Select(t => t.ApplyPosterAsync(t.PosterPath)));
    }

    private void RenderHeader()
    {
        var title = MediaText.Clean(_detail?.Title);

        TitleText.Text = title;
        PosterInitial.Text = Palette.InitialOf(title);

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

        // 海报 / 背景图走同一套鉴权下载。
        if (!string.IsNullOrWhiteSpace(_detail?.PosterPath))
        {
            _ = ApplyPosterAsync(_detail.PosterPath);
        }

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

    private async Task ApplyPosterAsync(string path)
    {
        var bitmap = await PosterLoader.LoadAsync(path).ConfigureAwait(true);
        if (bitmap is null)
        {
            return;
        }

        PosterBorder.Background = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        PosterInitial.Visibility = Visibility.Collapsed;
    }

    private async Task ApplyBlurAsync(string path)
    {
        var bitmap = await PosterLoader.LoadAsync(path, 1280).ConfigureAwait(true);
        if (bitmap is null)
        {
            return;
        }

        BackdropBlur.Source = bitmap;
    }

    private async Task ApplyBackdropAsync(string path)
    {
        var bitmap = await PosterLoader.LoadAsync(path, 1280).ConfigureAwait(true);
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

        if (_detail?.ReleaseDate is { Length: >= 4 } date)
        {
            parts.Add(date[..4]);
        }

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
        PlayButtonText.Text = _resumeEpisode > 0
            ? $"继续观看 第 {_resumeEpisode} 集"
            : _episodesAreFlat ? "播放" : "从第 1 集开始";
    }

    private async void OnPlayClick(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(_playTargetId))
        {
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), _playTargetId);
    }

    private async void OnEpisodeClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), id);
    }

    private async void OnSeasonClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string id })
        {
            return;
        }

        var chips = SeasonBar.ItemsSource as List<SeasonChip>;
        if (chips is null)
        {
            return;
        }

        foreach (var chip in chips)
        {
            chip.Active = chip.Id == id;
        }

        SeasonBar.ItemsSource = null;
        SeasonBar.ItemsSource = chips;

        if (id != _currentSeasonId)
        {
            await LoadSeasonAsync(id).ConfigureAwait(true);
        }
    }

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

    private sealed class EpisodeTile : CardVisual
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Duration { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public double ProgressWidth { get; init; }
    }
}
