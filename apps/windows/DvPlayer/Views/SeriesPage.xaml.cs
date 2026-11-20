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

    private readonly string _itemId;
    private readonly int _initialSeason;
    private MediaDetailDto? _detail;

    private string? _playTargetId;
    private int _resumeEpisode;
    private string? _currentSeasonId;
    private bool _episodesAreFlat;

    /// <summary>季选择用的列表（按钮弹出菜单，不再是一排胶囊）。</summary>
    private List<SeasonChip> _seasons = new();

    /// <summary>媒体信息按条目缓存，切季回来不用重新请求。</summary>
    private readonly Dictionary<string, MediaInfoDto?> _mediaInfoCache = new();

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
        _ = LoadPeopleAsync();

        if (seasons.Count > 0)
        {
            // 剧集：先季，再集。
            var start = Math.Min(_initialSeason, seasons.Count - 1);

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
        try
        {
            await RenderEpisodesCoreAsync(items).ConfigureAwait(true);
        }
        catch (Exception ex)
        {
            Trace.Write($"render episodes err {ex}");
            StatusText.Text = "读取剧集失败：" + ex.Message;
        }
    }

    private async Task RenderEpisodesCoreAsync(List<MediaItemDto> items)
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
            ProgressVisibility = pair.item.Progress > 0.01
                ? Visibility.Visible
                : Visibility.Collapsed,
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

            EpisodeSection.Visibility = Visibility.Visible;
            EpisodeCountText.Text = $"{tiles.Count} 集";

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

        await Task.WhenAll(tiles.Select(t => t.ApplyPosterAsync(t.PosterPath)));
        _ = LoadMediaInfoAsync();
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

    private void OnEpisodeScrollLeft(object sender, RoutedEventArgs e) =>
        EpisodeScroller.ScrollToHorizontalOffset(EpisodeScroller.HorizontalOffset - 640);

    private void OnEpisodeScrollRight(object sender, RoutedEventArgs e) =>
        EpisodeScroller.ScrollToHorizontalOffset(EpisodeScroller.HorizontalOffset + 640);

    private void OnCastScrollLeft(object sender, RoutedEventArgs e) =>
        CastScroller.ScrollToHorizontalOffset(CastScroller.HorizontalOffset - 640);

    private void OnCastScrollRight(object sender, RoutedEventArgs e) =>
        CastScroller.ScrollToHorizontalOffset(CastScroller.HorizontalOffset + 640);

    private void OnMediaInfoScrollLeft(object sender, RoutedEventArgs e) =>
        MediaInfoScroller.ScrollToHorizontalOffset(MediaInfoScroller.HorizontalOffset - 720);

    private void OnMediaInfoScrollRight(object sender, RoutedEventArgs e) =>
        MediaInfoScroller.ScrollToHorizontalOffset(MediaInfoScroller.HorizontalOffset + 720);

    /// <summary>横向行不抢滚轮：转给外层纵向滚动，横向只能用箭头。</summary>
    private void OnEpisodeWheel(object sender, MouseWheelEventArgs e)
    {
        for (var parent = VisualTreeHelper.GetParent(this); parent is not null;
             parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is ScrollViewer { VerticalScrollBarVisibility: not ScrollBarVisibility.Disabled }
                scroll)
            {
                scroll.ScrollToVerticalOffset(scroll.VerticalOffset - e.Delta * 0.5);
                e.Handled = true;
                return;
            }
        }
    }

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

        if (people.Count == 0)
        {
            CastSection.Visibility = Visibility.Collapsed;
            return;
        }

        var cards = people.Select(person => new CastCard
        {
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

        await Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
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
                var result = await Task.Run(() => core.MediaInfo(id)).ConfigureAwait(true);
                info = result.Ok ? result.Data : null;
                _mediaInfoCache[id] = info;
                Trace.Write($"media info id={id} ok={result.Ok} err={result.Error} " +
                            $"video={info?.Video is not null} audios={info?.Audios.Count}");
            }
            finally
            {
                _mediaInfoLoading = false;
            }
        }

        // 读的过程中切了季，就等新的那次请求。
        if (_playTargetId == id)
        {
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
            Width = 380,
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

    private sealed class CastCard : CardVisual
    {
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
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Duration { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public double ProgressWidth { get; init; }
        public Visibility ProgressVisibility { get; init; } = Visibility.Collapsed;
    }
}
