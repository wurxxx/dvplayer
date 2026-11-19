using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class LibrariesPage : Page
{
    private const int PageSize = 60;

    private string? _libraryId;
    private int _page;
    private string _libraryTitle = "";

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
            await LoadLibraryAsync(libraries[0].Id, libraries[0].Title).ConfigureAwait(true);
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

        var title = chips.FirstOrDefault(c => c.Id == id)?.Title ?? "";
        await LoadLibraryAsync(id, title).ConfigureAwait(true);
    }

    private async Task LoadLibraryAsync(string libraryId, string libraryTitle)
    {
        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            return;
        }

        _libraryId = libraryId;
        _libraryTitle = libraryTitle;
        _page = 1;
        StatusText.Text = "正在加载…";
        ItemGrid.ItemsSource = null;
        MoreButton.Visibility = Visibility.Collapsed;

        var core = services.Core!;
        var result = await Task.Run(() => core.Items(libraryId, 1, PageSize)).ConfigureAwait(true);

        if (!result.Ok || result.Data is null)
        {
            StatusText.Text = "加载失败：" + (result.Error ?? "未知错误");
            return;
        }

        var cards = result.Data.Items.Select(ToCard).ToList();
        ItemGrid.ItemsSource = cards;
        StatusText.Text = $"{_libraryTitle} · 共 {result.Data.Total} 条";
        MoreButton.Visibility = result.Data.Items.Count < result.Data.Total
            ? Visibility.Visible
            : Visibility.Collapsed;

        await Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private async void OnMoreClick(object sender, RoutedEventArgs e)
    {
        if (_libraryId is null || !AppServices.Instance.IsConnected)
        {
            return;
        }

        _page++;
        var core = AppServices.Instance.Core!;
        var page = _page;
        var result = await Task.Run(() => core.Items(_libraryId, page, PageSize)).ConfigureAwait(true);

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

        await Task.WhenAll(added.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private static ItemCard ToCard(MediaItemDto item)
    {
        var parts = new List<string> { ShortKind(item.Kind) };

        if (!string.IsNullOrEmpty(item.Resolution))
        {
            parts.Add(item.Resolution!);
        }

        if (item.RuntimeSeconds is > 0)
        {
            var time = TimeSpan.FromSeconds(item.RuntimeSeconds.Value);
            parts.Add(time.TotalHours >= 1
                ? $"{(int)time.TotalHours}:{time.Minutes:00}"
                : $"{time.Minutes} 分钟");
        }

        var card = new ItemCard
        {
            Title = item.Title,
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

    private static string ShortKind(string kind) => kind switch
    {
        "movie" => "电影",
        "series" => "剧集",
        "season" => "季",
        "episode" => "单集",
        "folder" => "文件夹",
        "video" => "视频",
        _ => kind,
    };

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
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public Visibility BadgeVisibility { get; init; } = Visibility.Collapsed;
    }
}
