using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class LibrariesPage : Page
{
    private const int PageSize = 60;

    private string? _libraryId;
    private string _libraryTitle = "";

    /// <summary>当前列表的父节点（媒体库或某个目录）。</summary>
    private string? _parentId;
    private bool _childrenMode;

    /// <summary>目录路径，用于面包屑和「返回上层」。</summary>
    private readonly List<(string Id, string Title)> _stack = new();

    private int _page;

    public LibrariesPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            StatusText.Text = "未连接媒体源，先去「设置」添加。";
            return;
        }

        var core = services.Core!;
        var result = await Task.Run(core.Libraries).ConfigureAwait(true);

        if (!result.Ok)
        {
            StatusText.Text = "读取媒体库失败：" + (result.Error ?? "未知错误");
            return;
        }

        var libraries = result.Data ?? new List<MediaLibraryDto>();
        LibraryBar.ItemsSource = libraries
            .Select(l => new LibraryChip(l.Id, l.Title, l.Id == libraries[0].Id))
            .ToList();

        if (libraries.Count > 0)
        {
            _libraryId = libraries[0].Id;
            _libraryTitle = libraries[0].Title;
            await LoadAsync(_libraryId, _libraryTitle, children: false).ConfigureAwait(true);
        }
        else
        {
            StatusText.Text = "这个源里没有媒体库。";
        }
    }

    private async void OnChipClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
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

        _libraryId = id;
        _libraryTitle = chips.FirstOrDefault(c => c.Id == id)?.Title ?? "";
        _stack.Clear();
        await LoadAsync(_libraryId, _libraryTitle, children: false).ConfigureAwait(true);
    }

    private async void OnCardClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        var cards = ItemGrid.ItemsSource as List<ItemCard>;
        var card = cards?.FirstOrDefault(c => c.Id == id);
        if (card is null)
        {
            return;
        }

        if (card.IsPlayable)
        {
            await PlayWindow.OpenAsync(Window.GetWindow(this), id);
            return;
        }

        // 剧集 / 季 / 未刮削目录：进详情页看季和集。
        NavigationService?.Navigate(new SeriesPage(id));
    }

    private async void OnBackClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
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
        StatusText.Text = "正在加载…";
        ItemGrid.ItemsSource = null;
        MoreButton.Visibility = Visibility.Collapsed;
        UpdateBreadcrumb();

        var core = services.Core!;
        var result = await Task.Run(() => children
            ? core.Children(parentId, 1, PageSize)
            : core.Items(parentId, 1, PageSize)).ConfigureAwait(true);

        if (!result.Ok || result.Data is null)
        {
            StatusText.Text = "加载失败：" + (result.Error ?? "未知错误");
            return;
        }

        var cards = result.Data.Items.Select(ToCard).ToList();
        ItemGrid.ItemsSource = cards;
        StatusText.Text = $"{title} · 共 {result.Data.Total} 条";
        MoreButton.Visibility = result.Data.Items.Count < result.Data.Total
            ? Visibility.Visible
            : Visibility.Collapsed;

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

        var existing = (ItemGrid.ItemsSource as List<ItemCard>) ?? new List<ItemCard>();
        var added = result.Data.Items.Select(ToCard).ToList();
        existing.AddRange(added);
        ItemGrid.ItemsSource = null;
        ItemGrid.ItemsSource = existing;

        MoreButton.Visibility = existing.Count < result.Data.Total
            ? Visibility.Visible
            : Visibility.Collapsed;

        await FillMissingPostersAsync(added);
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

    private static ItemCard ToCard(MediaItemDto item)
    {
        var parts = new List<string> { ShortKind(item.Kind) };

        // 剧集优先显示集数（比分辨率有用）；没刮削的目录从标题里数。
        var episodes = item.EpisodeCount ?? item.LocalEpisodeCount ?? ParseEpisodeCount(item.Title);
        if (episodes is > 0)
        {
            parts.Add($"{episodes} 集");
        }
        else if (item.RuntimeSeconds is > 0)
        {
            var time = TimeSpan.FromSeconds(item.RuntimeSeconds.Value);
            parts.Add(time.TotalHours >= 1
                ? $"{(int)time.TotalHours}:{time.Minutes:00}"
                : $"{time.Minutes} 分钟");
        }

        if (item.SeasonCount is > 1)
        {
            parts.Add($"{item.SeasonCount} 季");
        }

        var card = new ItemCard
        {
            Id = item.Id,
            Kind = item.Kind,
            Title = MediaText.Clean(item.Title),
            Sub = string.Join(" · ", parts),
            Badge = string.IsNullOrEmpty(item.Resolution) ? "" : item.Resolution!,
            BadgeVisibility = string.IsNullOrEmpty(item.Resolution)
                ? Visibility.Collapsed
                : Visibility.Visible,
            PosterPath = item.PosterPath,
            Initial = Palette.InitialOf(item.Title),
        };
        card.UseGradient(item.Id + item.Title);
        return card;
    }

    /// <summary>能直接交给播放器的条目类型；其余（剧集/季/目录）点进去看详情。</summary>
    private static bool IsPlayableKind(string kind) => kind switch
    {
        "movie" or "episode" or "video" => true,
        _ => false,
    };

    /// <summary>
    /// 飞牛把「没刮削但对得上剧集结构」的多文件目录标成 Directory（映射成 folder），
    /// 对用户来说它就是一部剧，这里统一说成「剧集」。
    /// </summary>
    private static string ShortKind(string kind) => kind switch
    {
        "movie" => "电影",
        "series" => "剧集",
        "season" => "季",
        "episode" => "单集",
        "folder" => "剧集",
        "video" => "视频",
        _ => kind,
    };

    /// <summary>「异能寻生机（76集） - SKIT」→ 标题 + 集数。</summary>
    private static int? ParseEpisodeCount(string title)
    {
        var match = System.Text.RegularExpressions.Regex.Match(title, @"[（(]\s*(\d{1,4})\s*集\s*[)）]");
        return match.Success ? int.Parse(match.Groups[1].Value) : null;
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

        public bool IsPlayable => LibrariesPage.IsPlayableKind(Kind);
    }
}
