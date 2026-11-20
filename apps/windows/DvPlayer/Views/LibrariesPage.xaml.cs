using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 媒体库页。顶部一个源名、媒体 / 搜索 / 收藏
/// 分段，下面是 Hero 横幅、「我的媒体」库卡片、继续观看，以及每个库一行横向海报。
/// 点库卡片或某行的箭头进入原来的网格视图（可下钻目录、加载更多）。
/// </summary>
public partial class LibrariesPage : Page
{
    private const int PreviewPerLibrary = 12;
    private const double ScrollStep = 262;

    private static int PageSize => Math.Max(10, AppServices.Instance.Settings.PageSize);

    private List<MediaLibraryDto> _libraries = new();
    private List<LibraryCardItem> _libraryCards = new();
    private Task? _overviewTask;

    private string? _heroItemId;
    private string _heroKind = "";

    private string? _libraryId;
    private string _libraryTitle = "";

    /// <summary>当前列表的父节点（媒体库或某个目录）。</summary>
    private string? _parentId;
    private bool _childrenMode;

    /// <summary>目录路径，用于面包屑和「返回上层」。</summary>
    private readonly List<(string Id, string Title)> _stack = new();

    /// <summary>已经取到的全部卡片；顶栏搜索只过滤这一份，不再打服务器。</summary>
    private List<ItemCard> _allCards = new();
    private int _total;

    private int _page;

    public LibrariesPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
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

        _overviewTask = LoadOverviewAsync();
        await _overviewTask.ConfigureAwait(true);
    }

    /// <summary>截图巡检用：等首页数据就绪后直接进第一个库的网格。</summary>
    public async Task ShowFirstLibraryAsync()
    {
        if (_overviewTask is not null)
        {
            await _overviewTask.ConfigureAwait(true);
        }

        if (_libraries.Count > 0)
        {
            await ShowLibraryAsync(_libraries[0].Id).ConfigureAwait(true);
        }
    }

    // —— 源首页 ——

    private async Task LoadOverviewAsync()
    {
        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            SourceTitle.Text = "媒体库";
            StatusText.Text = "未连接媒体源，先去「媒体源」添加。";
            return;
        }

        var core = services.Core!;
        SourceTitle.Text = services.Connections.FirstOrDefault(c => c.Ok)?.Name ?? "媒体库";
        StatusText.Text = "正在读取…";

        var librariesResult = await Task.Run(core.Libraries).ConfigureAwait(true);
        if (!librariesResult.Ok || librariesResult.Data is null)
        {
            StatusText.Text = "读取媒体库失败：" + (librariesResult.Error ?? "未知错误");
            return;
        }

        _libraries = librariesResult.Data;
        LibrariesCount.Text = $"{_libraries.Count} 个";

        _libraryCards = _libraries
            .Select(library =>
            {
                var card = new LibraryCardItem
                {
                    Id = library.Id,
                    Title = library.Title,
                    PosterPath = library.PosterPath,
                    Initial = Palette.InitialOf(library.Title),
                };
                card.UseGradient(library.Id + library.Title);
                return card;
            })
            .ToList();
        LibraryCards.ItemsSource = _libraryCards;

        // 每个库取一页做预览。库多的时候这是 N 次请求，但都是一页，不影响体感。
        var sections = new List<LibrarySection>();
        foreach (var library in _libraries)
        {
            var id = library.Id;
            var title = library.Title;
            var page = await Task.Run(() => core.Items(id, 1, PreviewPerLibrary)).ConfigureAwait(true);
            if (!page.Ok || page.Data is null)
            {
                continue;
            }

            sections.Add(new LibrarySection
            {
                Id = id,
                Title = title,
                CountText = $"{page.Data.Total} ›",
                Items = page.Data.Items.Select(ToCard).ToList(),
            });

            // 库自己没有封面时，借这个库第一张有图的海报当封面。
            var card = _libraryCards.FirstOrDefault(c => c.Id == id);
            if (card is not null && string.IsNullOrWhiteSpace(card.PosterPath))
            {
                card.PosterPath = page.Data.Items
                    .FirstOrDefault(i => !string.IsNullOrWhiteSpace(i.PosterPath))?.PosterPath;
            }
        }

        Sections.ItemsSource = sections;
        StatusText.Text = "";

        // 继续观看（当前源的全部记录，取前 12 条未看完的）
        var recordsResult = await Task.Run(core.Records).ConfigureAwait(true);
        if (recordsResult.Ok && recordsResult.Data is not null)
        {
            var continuing = recordsResult.Data
                .Where(r => r.DurationSeconds <= 0 || r.PositionSeconds < r.DurationSeconds * 0.98)
                .OrderByDescending(r => r.LastPlayed ?? 0)
                .Take(12)
                .ToList();

            var cards = continuing.Select(ToRecordCard).ToList();
            ContinueRow.ItemsSource = cards;
            ContinueEmpty.Visibility = cards.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            ContinueCount.Text = cards.Count == 0 ? "" : $"{cards.Count} ›";

            _ = Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
        }

        // Hero：第一个库的第一条；没有库时退回「我的媒体」第一张卡。
        var featured = sections.FirstOrDefault()?.Items.FirstOrDefault();
        if (featured is not null)
        {
            await LoadHeroAsync(featured.Id).ConfigureAwait(true);
        }
        else
        {
            HeroTitle.Text = _libraries.Count > 0 ? _libraries[0].Title : "这个源里没有媒体库";
            HeroMeta.Text = "";
            HeroOverview.Text = "";
        }

        // 库卡片与分组里的海报最后补，先把结构画出来。
        var all = sections.SelectMany(s => s.Items).ToList();
        await Task.WhenAll(all.Select(c => c.ApplyPosterAsync(c.PosterPath)));
        await Task.WhenAll(_libraryCards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private async Task LoadHeroAsync(string itemId)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var detail = await Task.Run(() => core.ItemDetail(itemId)).ConfigureAwait(true);
        if (!detail.Ok || detail.Data is null)
        {
            return;
        }

        var item = detail.Data;
        _heroItemId = item.Id;
        _heroKind = item.Kind;

        HeroTitle.Text = MediaText.Clean(item.Title);

        var parts = new List<string>();
        if (item.Rating is > 0)
        {
            parts.Add($"★ {item.Rating:0.0}");
        }

        if (!string.IsNullOrWhiteSpace(item.ReleaseDate) && item.ReleaseDate.Length >= 4)
        {
            parts.Add(item.ReleaseDate[..4]);
        }

        parts.Add(MediaText.KindLabel(item.Kind));
        HeroMeta.Text = string.Join(" · ", parts);
        HeroOverview.Text = item.Overview ?? "";

        await ApplyBackgroundAsync(HeroBackdrop, item.BackdropPath ?? item.PosterPath).ConfigureAwait(true);
    }

    private static async Task ApplyBackgroundAsync(Border border, string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        var bitmap = await PosterLoader.LoadAsync(path, 1280).ConfigureAwait(true);
        if (bitmap is null)
        {
            return;
        }

        var brush = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        brush.Freeze();
        border.Background = brush;
    }

    private async void OnHeroClick(object sender, MouseButtonEventArgs e)
    {
        if (_heroItemId is null)
        {
            return;
        }

        if (!MediaText.IsPlayable(_heroKind))
        {
            NavigationService?.Navigate(new SeriesPage(_heroItemId));
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), _heroItemId);
    }

    private void OnTabChanged(object sender, RoutedEventArgs e)
    {
        if (OverviewRoot is null)
        {
            return;
        }

        // 搜索直接交给搜索页，那边有完整的输入框和空态。
        if (SearchSegment.IsChecked == true)
        {
            (Window.GetWindow(this) as MainWindow)?.NavigateTo("search");
            MediaSegment.IsChecked = true;
            return;
        }

        var favorites = FavoriteSegment.IsChecked == true;
        OverviewRoot.Visibility = favorites ? Visibility.Collapsed : Visibility.Visible;
        FavoriteEmpty.Visibility = favorites ? Visibility.Visible : Visibility.Collapsed;
        BrowseRoot.Visibility = Visibility.Collapsed;
    }

    private async void OnRefreshClick(object sender, RoutedEventArgs e)
    {
        BrowseRoot.Visibility = Visibility.Collapsed;
        OverviewRoot.Visibility = Visibility.Visible;
        MediaSegment.IsChecked = true;
        await LoadOverviewAsync().ConfigureAwait(true);
    }

    private async void OnLibraryClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            await ShowLibraryAsync(id).ConfigureAwait(true);
        }
    }

    private async void OnSectionMoreClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string id })
        {
            await ShowLibraryAsync(id).ConfigureAwait(true);
        }
    }

    private void OnBackToOverview(object sender, RoutedEventArgs e)
    {
        BrowseRoot.Visibility = Visibility.Collapsed;
        OverviewRoot.Visibility = Visibility.Visible;
    }

    // —— 库内网格（原视图） ——

    private async Task ShowLibraryAsync(string libraryId)
    {
        var library = _libraries.FirstOrDefault(l => l.Id == libraryId);
        if (library is null)
        {
            return;
        }

        LibraryBar.ItemsSource = _libraries
            .Select(l => new LibraryChip(l.Id, l.Title, l.Id == libraryId))
            .ToList();

        OverviewRoot.Visibility = Visibility.Collapsed;
        FavoriteEmpty.Visibility = Visibility.Collapsed;
        BrowseRoot.Visibility = Visibility.Visible;

        _libraryId = library.Id;
        _libraryTitle = library.Title;
        BrowseTitle.Text = library.Title;
        _stack.Clear();
        FilterBox.Text = string.Empty;

        await LoadAsync(library.Id, library.Title, children: false).ConfigureAwait(true);
    }

    private async void OnChipClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: string id })
        {
            return;
        }

        var chips = LibraryBar.ItemsSource as List<LibraryChip>;
        if (chips is null)
        {
            return;
        }

        foreach (var chip in chips)
        {
            chip.Active = chip.Id == id;
        }

        // LibraryChip 不是 INotifyPropertyChanged，重新赋值刷新选中态。
        LibraryBar.ItemsSource = null;
        LibraryBar.ItemsSource = chips;

        var active = chips.FirstOrDefault(c => c.Id == id);
        _libraryId = id;
        _libraryTitle = active?.Title ?? "";
        BrowseTitle.Text = _libraryTitle;
        _stack.Clear();
        FilterBox.Text = string.Empty;
        await LoadAsync(_libraryId, _libraryTitle, children: false).ConfigureAwait(true);
    }

    private async void OnCardClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        // 网格里的卡片、横向海报行、继续观看卡片共用这个处理器；
        // 只有网格卡片带 Kind，其它卡片都按可播放处理是不对的，
        // 所以这里先查网格数据，找不到再看行卡片。
        var cards = ItemGrid.ItemsSource as List<ItemCard>;
        var card = cards?.FirstOrDefault(c => c.Id == id);
        if (card is not null)
        {
            if (card.IsPlayable)
            {
                await PlayWindow.OpenAsync(Window.GetWindow(this), id);
                return;
            }

            NavigationService?.Navigate(new SeriesPage(id));
            return;
        }

        var record = (ContinueRow.ItemsSource as List<RecordCard>)?.FirstOrDefault(c => c.ItemId == id);
        if (record is not null)
        {
            await PlayWindow.OpenAsync(Window.GetWindow(this), id);
            return;
        }

        // 库分组里的海报：先看详情，能播就直接播。
        var core = AppServices.Instance.Core;
        if (core is not null)
        {
            var detail = await Task.Run(() => core.ItemDetail(id)).ConfigureAwait(true);
            if (detail is { Ok: true, Data: not null } && MediaText.IsPlayable(detail.Data.Kind))
            {
                await PlayWindow.OpenAsync(Window.GetWindow(this), id);
                return;
            }
        }

        NavigationService?.Navigate(new SeriesPage(id));
    }

    private async void OnBackClick(object sender, MouseButtonEventArgs e)
    {
        if (_stack.Count == 0)
        {
            return;
        }

        _stack.RemoveAt(_stack.Count - 1);

        if (_stack.Count == 0)
        {
            await LoadAsync(_libraryId!, _libraryTitle, children: false).ConfigureAwait(true);
            return;
        }

        var parent = _stack[^1];
        await LoadAsync(parent.Id, parent.Title, children: true).ConfigureAwait(true);
    }

    private async Task LoadAsync(string parentId, string title, bool children)
    {
        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            return;
        }

        _parentId = parentId;
        _childrenMode = children;
        _page = 1;
        BrowseStatus.Text = "正在加载…";
        ItemGrid.ItemsSource = null;
        _allCards = new List<ItemCard>();
        _total = 0;
        MoreButton.Visibility = Visibility.Collapsed;
        UpdateBreadcrumb();

        var core = services.Core!;
        var result = await Task.Run(() => children
            ? core.Children(parentId, 1, PageSize)
            : core.Items(parentId, 1, PageSize)).ConfigureAwait(true);

        if (!result.Ok || result.Data is null)
        {
            BrowseStatus.Text = "加载失败：" + (result.Error ?? "未知错误");
            return;
        }

        var cards = result.Data.Items.Select(ToCard).ToList();
        _allCards = cards;
        _total = result.Data.Total;
        ApplyFilter();

        await FillMissingPostersAsync(cards);
    }

    /// <summary>
    /// 未刮削的目录（Directory）列表项不带封面，需要单独取一次详情拿第一张图。
    /// 并发限制在 8 个，避免一页 60 个请求把服务端打满。
    /// </summary>
    private static async Task FillMissingPostersAsync(List<ItemCard> cards)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var pending = cards.Where(c => c.PosterPath is null && !c.IsPlayable).ToList();

        using var gate = new SemaphoreSlim(8);

        await Task.WhenAll(pending.Select(async card =>
        {
            await gate.WaitAsync().ConfigureAwait(true);
            try
            {
                var detail = await Task.Run(() => core.ItemDetail(card.Id)).ConfigureAwait(true);
                if (detail.Ok && !string.IsNullOrWhiteSpace(detail.Data?.PosterPath))
                {
                    await card.ApplyPosterAsync(detail.Data.PosterPath).ConfigureAwait(true);
                }
            }
            catch (Exception)
            {
                // 一张封面失败不影响列表。
            }
            finally
            {
                gate.Release();
            }
        }));

        await Task.WhenAll(cards.Where(c => c.PosterPath is not null)
            .Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private async void OnMoreClick(object sender, RoutedEventArgs e)
    {
        if (_parentId is null || !AppServices.Instance.IsConnected)
        {
            return;
        }

        _page++;
        var core = AppServices.Instance.Core!;
        var page = _page;
        var children = _childrenMode;
        var parentId = _parentId;

        var result = await Task.Run(() => children
            ? core.Children(parentId, page, PageSize)
            : core.Items(parentId, page, PageSize)).ConfigureAwait(true);

        if (!result.Ok || result.Data is null)
        {
            _page--;
            return;
        }

        var added = result.Data.Items.Select(ToCard).ToList();
        _allCards.AddRange(added);
        _total = result.Data.Total;
        ApplyFilter();

        await FillMissingPostersAsync(added);
    }

    /// <summary>顶栏搜索：只在已取到的条目里过滤，不打断分页。</summary>
    private void ApplyFilter()
    {
        var query = FilterBox?.Text?.Trim() ?? "";
        var cards = string.IsNullOrEmpty(query)
            ? _allCards
            : _allCards
                .Where(c => c.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                            c.Sub.Contains(query, StringComparison.OrdinalIgnoreCase))
                .ToList();

        ItemGrid.ItemsSource = null;
        ItemGrid.ItemsSource = cards;

        BrowseStatus.Text = string.IsNullOrEmpty(query)
            ? $"{_libraryTitle} · 共 {_total} 条"
            : $"{_libraryTitle} · 筛出 {cards.Count} 条（已加载 {_allCards.Count} 条）";

        // 过滤状态下不再提供「加载更多」：那一页还没拉下来，命中率没法保证。
        MoreButton.Visibility = string.IsNullOrEmpty(query) && _allCards.Count < _total
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void OnFilterChanged(object sender, TextChangedEventArgs e)
    {
        if (FilterPlaceholder is not null)
        {
            FilterPlaceholder.Visibility = string.IsNullOrEmpty(FilterBox.Text)
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        if (BrowseRoot.Visibility == Visibility.Visible)
        {
            ApplyFilter();
        }
    }

    private void UpdateBreadcrumb()
    {
        var inFolder = _childrenMode && _stack.Count > 0;
        Breadcrumb.Visibility = inFolder ? Visibility.Visible : Visibility.Collapsed;

        if (inFolder)
        {
            var trail = string.Join("  ›  ", _stack.Select(s => s.Title));
            BreadcrumbText.Text = $"{_libraryTitle}  ›  {trail}";
        }
    }

    // —— 横向滚动 ——

    private void OnScrollLeft(object sender, RoutedEventArgs e) => ScrollRow(sender, -ScrollStep);

    private void OnScrollRight(object sender, RoutedEventArgs e) => ScrollRow(sender, ScrollStep);

    private static void ScrollRow(object sender, double delta)
    {
        if (FindRow(sender) is { } row)
        {
            Animate(row, row.HorizontalOffset + delta);
        }
    }

    private static void Animate(ScrollViewer row, double target)
    {
        var clamped = Math.Clamp(target, 0, row.ScrollableWidth);

        row.BeginAnimation(SmoothScroll.OffsetProperty, null);
        SmoothScroll.SetOffset(row, row.HorizontalOffset);

        var animation = new DoubleAnimation(row.HorizontalOffset, clamped,
            TimeSpan.FromMilliseconds(260))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };

        row.BeginAnimation(SmoothScroll.OffsetProperty, animation);
    }

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

    private void OnRowWheel(object sender, MouseWheelEventArgs e)
    {
        if (sender is ScrollViewer row)
        {
            Animate(row, row.HorizontalOffset - e.Delta * 1.2);
            e.Handled = true;
        }
    }

    // —— 数据装配 ——

    private static ItemCard ToCard(MediaItemDto item)
    {
        var showBadge = AppServices.Instance.Settings.ShowResolution &&
                        !string.IsNullOrEmpty(item.Resolution);

        var card = new ItemCard
        {
            Id = item.Id,
            Kind = item.Kind,
            Title = MediaText.Clean(item.Title),
            Sub = MediaText.Describe(item),
            Badge = showBadge ? item.Resolution! : "",
            BadgeVisibility = showBadge ? Visibility.Visible : Visibility.Collapsed,
            PosterPath = item.PosterPath,
            Initial = Palette.InitialOf(item.Title),
        };
        card.UseGradient(item.Id + item.Title);
        return card;
    }

    private static RecordCard ToRecordCard(PlayRecordDto record)
    {
        var progress = record.DurationSeconds <= 0
            ? 0
            : Math.Clamp((double)record.PositionSeconds / record.DurationSeconds, 0, 1);

        var title = MediaText.RecordTitle(record);
        var card = new RecordCard
        {
            ItemId = record.ItemId,
            Title = title,
            Sub = $"{(int)(progress * 100)}%",
            Time = Format(record.DurationSeconds),
            BarWidth = Math.Max(0, 248 * progress),
            PosterPath = record.PosterPath,
            Initial = Palette.InitialOf(title),
        };
        card.UseGradient(record.ItemId + title);
        return card;
    }

    private static string Format(long seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1
            ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}"
            : $"{t.Minutes:00}:{t.Seconds:00}";
    }

    private sealed class LibraryChip
    {
        public LibraryChip(string id, string title, bool active)
        {
            Id = id;
            Title = title;
            Active = active;
        }

        public string Id { get; }

        public string Title { get; }

        public bool Active { get; set; }
    }

    private sealed class ItemCard : CardVisual
    {
        public string Id { get; init; } = "";
        public string Kind { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public Visibility BadgeVisibility { get; init; } = Visibility.Collapsed;

        public bool IsPlayable => MediaText.IsPlayable(Kind);
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

    private sealed class LibraryCardItem : CardVisual
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; set; }
    }

    private sealed class LibrarySection
    {
        public string Id { get; init; } = "";
        public string Title { get; init; } = "";
        public string CountText { get; init; } = "";
        public List<ItemCard> Items { get; init; } = new();
    }
}