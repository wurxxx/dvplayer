using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 记录页。顶栏右边是「通用 / 观看 / 收藏」分段，
/// 主体是横向的观看卡片（缩略图右下角 ▶ 时长、底部进度条、标题 + S01 · E74）。
/// </summary>
public partial class RecordsPage : Page
{
    private const double BarMax = 248;

    private List<PlayRecordDto> _records = new();
    private List<MediaItemDto> _favorites = new();
    private bool _favoritesLoaded;
    private bool _loadingFavorites;

    public RecordsPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    /// <summary>截图巡检用：停在「通用」分段。</summary>
    public void ShowGeneralForShot() => GeneralSegment.IsChecked = true;

    /// <summary>截图巡检用：停在「观看」分段。</summary>
    public void ShowWatchForShot() => WatchSegment.IsChecked = true;

    /// <summary>截图巡检用：停在「收藏」分段。</summary>
    public void ShowFavoritesForShot() => FavoriteSegment.IsChecked = true;

    /// <summary>截图巡检用：打开「观看」第一张卡片的右键菜单。</summary>
    public ContextMenu? OpenFirstWatchMenuForShot() => OpenFirstMenu(WatchList);

    /// <summary>截图巡检用：临时收藏一条记录，验证完再取消。</summary>
    public async Task<string?> FavoriteFirstForShotAsync()
    {
        if (AppServices.Instance.Core is not { } core || _records.FirstOrDefault() is not { } record)
        {
            return null;
        }

        var result = await Task.Run(() => core.SetFavorite(record.ItemId, true)).ConfigureAwait(true);
        if (!result.Ok)
        {
            Trace.Write($"records favorite shot failed id={record.ItemId} err={result.Error}");
            return null;
        }

        _favoritesLoaded = false;
        await LoadFavoritesAsync().ConfigureAwait(true);
        FillFavorites();
        Trace.Write($"records favorite shot id={record.ItemId} favorites={_favorites.Count}");
        return record.ItemId;
    }

    /// <summary>截图巡检用：截图结束把临时收藏撤掉。</summary>
    public async Task UnfavoriteForShotAsync(string id)
    {
        if (AppServices.Instance.Core is not { } core)
        {
            return;
        }

        await Task.Run(() => core.SetFavorite(id, false)).ConfigureAwait(true);
        _favorites.RemoveAll(f => f.Id == id);
        _favoritesLoaded = true;
        FillFavorites();
    }

    /// <summary>截图巡检用：打开「收藏」第一张卡片的右键菜单。</summary>
    public ContextMenu? OpenFirstFavoriteMenuForShot() => OpenFirstMenu(FavoriteList);

    private static ContextMenu? OpenFirstMenu(ItemsControl list)
    {
        if (list.ItemContainerGenerator.ContainerFromIndex(0) is not DependencyObject container ||
            FindCard(container) is not { ContextMenu: { } menu } border)
        {
            return null;
        }

        menu.PlacementTarget = border;
        menu.IsOpen = true;
        return menu;
    }

    private static Border? FindCard(DependencyObject root)
    {
        if (root is Border { ContextMenu: not null } border)
        {
            return border;
        }

        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            if (FindCard(VisualTreeHelper.GetChild(root, i)) is { } found)
            {
                return found;
            }
        }

        return null;
    }

    // —— 卡片右键菜单（和媒体库页的菜单一致）——

    private static string? MenuItemId(object? sender)
    {
        if (sender is not MenuItem item)
        {
            return null;
        }

        var menu = item.Parent as ContextMenu
            ?? ItemsControl.ItemsControlFromItemContainer(item) as ContextMenu;
        return (menu?.PlacementTarget as FrameworkElement)?.Tag as string;
    }

    private async Task<bool> RunWriteAsync(Func<MediaCore, ApiResult<bool>> action)
    {
        if (AppServices.Instance.Core is not { } core)
        {
            return false;
        }

        var result = await Task.Run(() => action(core)).ConfigureAwait(true);
        if (result.Ok)
        {
            return true;
        }

        FlashStatus(result.Error ?? "操作失败");
        return false;
    }

    private async void OnMenuPlay(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        // 单集记录要带上它那一季的选集，不然播放页没有「选集 / 上一集 / 下一集」。
        if (_records.FirstOrDefault(record => record.ItemId == id) is { } record)
        {
            await Playlists.PlayRecordAsync(Window.GetWindow(this), record);
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), id);
    }

    private async void OnMenuFavorite(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (await RunWriteAsync(core => core.SetFavorite(id, true)).ConfigureAwait(true))
        {
            // 下次切到「收藏」时重新拉，刚收藏的会出现在最前面。
            _favoritesLoaded = false;
            FlashStatus("已添加到收藏夹");
        }
    }

    private async void OnMenuUnfavorite(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (!await RunWriteAsync(core => core.SetFavorite(id, false)).ConfigureAwait(true))
        {
            return;
        }

        _favorites.RemoveAll(f => f.Id == id);
        _favoritesLoaded = true;
        FillFavorites();
        FlashStatus("已取消收藏");
    }

    private async void OnMenuWatched(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (!await RunWriteAsync(core => core.SetWatched(id, true)).ConfigureAwait(true))
        {
            return;
        }

        // 本地把进度推到片尾，「继续观看」就不再显示它。
        var index = _records.FindIndex(r => r.ItemId == id);
        if (index >= 0)
        {
            _records[index] = _records[index] with
            {
                PositionSeconds = _records[index].DurationSeconds,
            };
            FillLists();
        }

        FlashStatus("已标记为已观看");
    }

    private async void OnMenuUnwatched(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (!await RunWriteAsync(core => core.SetWatched(id, false)).ConfigureAwait(true))
        {
            return;
        }

        var index = _records.FindIndex(r => r.ItemId == id);
        if (index >= 0)
        {
            _records[index] = _records[index] with { PositionSeconds = 0 };
            FillLists();
        }

        FlashStatus("已标记为未观看");
    }

    private async void OnMenuRemoveRecord(object sender, RoutedEventArgs e)
    {
        if (MenuItemId(sender) is not { Length: > 0 } id)
        {
            return;
        }

        if (!await RunWriteAsync(core => core.RemovePlayRecord(id)).ConfigureAwait(true))
        {
            return;
        }

        _records.RemoveAll(r => r.ItemId == id);
        FillLists();
        FlashStatus("已移除观看记录");
    }

    private async void FlashStatus(string message)
    {
        StatusText.Text = message;
        await Task.Delay(4000).ConfigureAwait(true);
        if (StatusText.Text == message)
        {
            UpdateStatusText();
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
    }

    private void OnConnectionChanged(object? sender, EventArgs e) =>
        // 登录在后台线程完成，重新拉数据必须回到 UI 线程。
        Dispatcher.BeginInvoke(() => OnLoaded(this, new RoutedEventArgs()));

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // 冷启动时登录还没完成，连上之后靠这个事件重新拉一次。
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
        AppServices.Instance.ConnectionChanged += OnConnectionChanged;

        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            StatusText.Text = "未连接媒体源，先去「媒体源」添加。";
            return;
        }

        StatusText.Text = "正在读取…";

        var core = services.Core!;
        var result = await Task.Run(core.Records).ConfigureAwait(true);

        if (!result.Ok)
        {
            StatusText.Text = "读取失败：" + (result.Error ?? "未知错误");
            return;
        }

        _records = (result.Data ?? new List<PlayRecordDto>())
            .OrderByDescending(r => r.LastPlayed ?? 0)
            .ToList();

        FillLists();

        // 收藏单独拉，不挡「通用 / 观看」先出来。
        _ = LoadFavoritesAsync();
    }

    /// <summary>收藏列表：飞牛 `favorite/list`，Emby `Filters=IsFavorite`。</summary>
    private async Task LoadFavoritesAsync(bool force = false)
    {
        if (_loadingFavorites || (_favoritesLoaded && !force))
        {
            return;
        }

        if (AppServices.Instance.Core is not { } core)
        {
            return;
        }

        _loadingFavorites = true;
        try
        {
            var result = await Task.Run(() => core.Favorites(1, 200)).ConfigureAwait(true);
            if (!result.Ok || result.Data is null)
            {
                StatusText.Text = "读取收藏失败：" + (result.Error ?? "未知错误");
                return;
            }

            _favorites = result.Data.Items;
            _favoritesLoaded = true;
            FillFavorites();
            UpdateStatusText();
        }
        finally
        {
            _loadingFavorites = false;
        }
    }

    private void FillFavorites()
    {
        var cards = _favorites.Select(ToFavoriteCard).ToList();
        FavoriteList.ItemsSource = cards;

        // 「通用」里也有一行收藏（和 macOS 一致），空的时候给一句提示。
        GeneralFavoriteList.ItemsSource = cards;
        GeneralFavoritesCount.Text = cards.Count > 0 ? $"{cards.Count} 个" : "";
        GeneralFavorites.Visibility = cards.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        GeneralFavoritesEmpty.Visibility = cards.Count > 0 ? Visibility.Collapsed : Visibility.Visible;

        // 收藏是异步拉的，到货时用户很可能还停在「通用」。
        // 分段面板的显隐只能交给 ApplyTabVisibility —— 直接设 Visible
        // 会让「收藏」整块盖到「继续观看」上（看起来像记录串了图）。
        ApplyTabVisibility();

        // 取消收藏后列表会变空，标题上的「共 N 个收藏」也得跟着改。
        if (FavoriteSegment.IsChecked == true)
        {
            UpdateStatusText();
        }

        _ = Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private void FillLists()
    {
        var all = _records
            .Select(r => (Record: r, Card: ToCard(r)))
            .ToList();

        WatchList.ItemsSource = all.Select(x => x.Card).ToList();

        // 继续观看按媒体源分栏。源名与顺序都来自当前连接列表：
        // 连上的排在前面，没连上的源不会出现在这里（记录可能还在，但点了打不开）。
        var connections = AppServices.Instance.Connections;
        var order = connections
            .Select((c, index) => (c.Id, index))
            .ToDictionary(x => x.Id, x => x.index);
        var names = connections.ToDictionary(c => c.Id, c => c.Name);
        var connected = connections.ToDictionary(c => c.Id, c => c.Ok);

        var groups = all
            .Where(x => x.Record.DurationSeconds <= 0 ||
                        x.Record.PositionSeconds < x.Record.DurationSeconds * 0.98)
            .GroupBy(x => x.Record.SourceId ?? "")
            .OrderBy(g => order.TryGetValue(g.Key, out var index) ? index : int.MaxValue)
            .Select(g =>
            {
                var id = g.Key;
                var title = names.TryGetValue(id, out var name)
                    ? name
                    : string.IsNullOrEmpty(id) ? "其它" : id;
                var ok = connected.TryGetValue(id, out var flag) && flag;

                return new SourceGroup
                {
                    Title = title,
                    CountText = $"{g.Count()} 条",
                    StatusBrush = (Brush)Application.Current.Resources[ok ? "SuccessBrush" : "FaintBrush"]!,
                    Items = g.Select(x => x.Card).ToList(),
                };
            })
            .ToList();

        ContinueGroups.ItemsSource = groups;
        ContinueEmpty.Visibility = groups.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        UpdateStatusText();

        _ = Task.WhenAll(all.Select(x => x.Card).Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private void UpdateStatusText()
    {
        if (FavoriteSegment.IsChecked == true)
        {
            StatusText.Text = _favorites.Count == 0
                ? "还没有收藏。"
                : $"共 {_favorites.Count} 个收藏";
            return;
        }

        StatusText.Text = _records.Count == 0
            ? "还没有播放记录。"
            : $"{_records.Count} 条记录 · 继续上次看到的位置";
    }

    private const double ScrollStep = 262;

    private void OnScrollLeft(object sender, RoutedEventArgs e) => ScrollRow(sender, -ScrollStep);

    private void OnScrollRight(object sender, RoutedEventArgs e) => ScrollRow(sender, ScrollStep);

    private static void ScrollRow(object sender, double delta)
    {
        if (FindRow(sender) is { } row)
        {
            SmoothScroll.ScrollBy(row, delta);
        }
    }

    /// <summary>按钮的父级 Grid 里就装着这一行的 ScrollViewer；不依赖 Tag 绑定。</summary>
    private static ScrollViewer? FindRow(object sender)
    {
        if (sender is Button { Tag: ScrollViewer tagged })
        {
            return tagged;
        }

        if (sender is not DependencyObject node)
        {
            return null;
        }

        for (var parent = VisualTreeHelper.GetParent(node); parent is not null;
             parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is ScrollViewer scroll)
            {
                return scroll;
            }

            if (parent is Panel panel &&
                panel.Children.OfType<ScrollViewer>().FirstOrDefault() is { } inner)
            {
                return inner;
            }
        }

        return null;
    }

    private static FavoriteCard ToFavoriteCard(MediaItemDto item)
    {
        var title = MediaText.Clean(item.Title);
        var card = new FavoriteCard
        {
            Id = item.Id,
            Title = title,
            Sub = MediaText.Describe(item),
            PosterPath = item.PosterPath,
            Initial = Palette.InitialOf(title),
        };
        card.UseGradient(item.Id + title);
        return card;
    }

    private static RecordCard ToCard(PlayRecordDto record)
    {
        var progress = record.DurationSeconds <= 0
            ? 0
            : Math.Clamp((double)record.PositionSeconds / record.DurationSeconds, 0, 1);

        var title = MediaText.RecordTitle(record);

        var card = new RecordCard
        {
            ItemId = record.ItemId,
            Title = title,
            Sub = EpisodeLabel(record, progress),
            Time = Format(record.DurationSeconds),
            BarWidth = Math.Max(0, BarMax * progress),
            PosterPath = record.PosterPath,
            Initial = Palette.InitialOf(title),
        };
        card.UseGradient(record.ItemId + title);
        return card;
    }

    /// <summary>「S01 · E74」；没有季集号时退回剩余时间。</summary>
    private static string EpisodeLabel(PlayRecordDto record, double progress)
    {
        var parts = new List<string>();
        if (record.SeasonNumber is > 0)
        {
            parts.Add($"S{record.SeasonNumber:00}");
        }

        if (record.EpisodeNumber is > 0)
        {
            parts.Add($"E{record.EpisodeNumber}");
        }

        if (parts.Count > 0)
        {
            return string.Join(" · ", parts);
        }

        var remaining = Math.Max(0, record.DurationSeconds - record.PositionSeconds);
        return progress >= 0.98 || record.DurationSeconds <= 0
            ? "已看完"
            : $"还剩 {Format(remaining)}";
    }

    private void OnTabChanged(object sender, RoutedEventArgs e)
    {
        if (GeneralPanel is null)
        {
            return;
        }

        ApplyTabVisibility();
        UpdateStatusText();

        // 每次切到收藏都重新拉一次：刚在卡片右键里收藏 / 取消的会立刻反映。
        if (FavoriteSegment.IsChecked == true)
        {
            _ = LoadFavoritesAsync(force: true);
        }
    }

    /// <summary>
    /// 三个分段面板互斥。所有改动显隐的地方都走这里：收藏数据晚到时
    /// 不能把「收藏」面板在自己的标签页之外露出来。
    /// </summary>
    private void ApplyTabVisibility()
    {
        if (GeneralPanel is null)
        {
            return;
        }

        var general = GeneralSegment.IsChecked == true;
        var watch = WatchSegment.IsChecked == true;
        var favorites = FavoriteSegment.IsChecked == true;

        GeneralPanel.Visibility = general ? Visibility.Visible : Visibility.Collapsed;
        WatchPanel.Visibility = watch ? Visibility.Visible : Visibility.Collapsed;
        FavoriteScroll.Visibility = favorites && _favorites.Count > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        FavoritePanel.Visibility = favorites && _favorites.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    /// <summary>
    /// 记录卡片点画面空白处 → 进详情页。
    /// 底部那条（进度条 + 时间）走 OnContinuePlayClick 续播。
    /// </summary>
    private void OnRecordBodyClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        // 单集记录跳它所属的剧；电影 / 单文件就是它自己。
        var target = _records.FirstOrDefault(r => r.ItemId == id)?.ParentId is { Length: > 0 } parent
            ? parent
            : id;
        NavigationService?.Navigate(new SeriesPage(target));
    }

    /// <summary>记录卡片点底部进度条 / 时间那一条 → 续播。</summary>
    private async void OnContinuePlayClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        // 别让事件继续冒泡到外层的 OnRecordBodyClick。
        e.Handled = true;

        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        if (_records.FirstOrDefault(record => record.ItemId == id) is { } record)
        {
            await Playlists.PlayRecordAsync(Window.GetWindow(this), record);
        }
    }

    /// <summary>收藏卡片点击 → 进详情（收藏的是影片 / 剧集本身）。</summary>
    private void OnCardClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        NavigationService?.Navigate(new SeriesPage(id));
    }

    private static string Format(long seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1
            ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}"
            : $"{t.Minutes:00}:{t.Seconds:00}";
    }

    private sealed class FavoriteCard : CardVisual
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
    }

    private sealed class RecordCard : CardVisual
    {
        public string ItemId { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Time { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public double BarWidth { get; init; }
    }

    /// <summary>一个源在「继续观看」里的一行。</summary>
    private sealed class SourceGroup
    {
        public string Title { get; init; } = "";
        public string CountText { get; init; } = "";
        public Brush? StatusBrush { get; init; }
        public List<RecordCard> Items { get; init; } = new();
    }
}