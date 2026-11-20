using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 聚合搜索页。空态：一个放大镜加「搜索所有媒体库中的内容」；
/// 输入后跨所有已连上的源找片名。
///
/// 现在核心还没有搜索接口，这里先把各库首页（每个库前 300 条）缓存在内存里做匹配，
/// 输入时只过滤本地索引。等核心加上索引（飞牛客户端索引 + 跨源合并）就换掉这一段。
/// </summary>
public partial class SearchPage : Page
{
    private const int IndexPerLibrary = 300;

    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(280) };

    private List<IndexEntry>? _mediaIndex;
    private List<PlayRecordDto>? _recordIndex;

    /// <summary>连点输入时只认最后一次查询的结果。</summary>
    private int _version;

    public SearchPage()
    {
        InitializeComponent();

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        _debounce.Tick += OnDebounceTick;

        // 截图回归：--search-text <关键词> 直接带一个查询进来。
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, "--search-text");
        if (index >= 0 && index + 1 < args.Length)
        {
            SearchBox.Text = args[index + 1];
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
        AppServices.Instance.ConnectionChanged += OnConnectionChanged;

        UpdatePlaceholder();
        if (!string.IsNullOrWhiteSpace(SearchBox.Text))
        {
            _ = RunSearchAsync(SearchBox.Text);
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        AppServices.Instance.ConnectionChanged -= OnConnectionChanged;
        _debounce.Stop();
    }

    /// <summary>源重连后索引整个作废，下一次搜索重新拉。</summary>
    private void OnConnectionChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(() =>
        {
            _mediaIndex = null;
            _recordIndex = null;
            if (!string.IsNullOrWhiteSpace(SearchBox.Text))
            {
                _ = RunSearchAsync(SearchBox.Text);
            }
        });

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        UpdatePlaceholder();
        _debounce.Stop();
        _debounce.Start();
    }

    private void OnScopeChanged(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded)
        {
            return;
        }

        _debounce.Stop();
        if (!string.IsNullOrWhiteSpace(SearchBox.Text))
        {
            _ = RunSearchAsync(SearchBox.Text);
        }
    }

    private void OnDebounceTick(object? sender, EventArgs e)
    {
        _debounce.Stop();
        _ = RunSearchAsync(SearchBox.Text);
    }

    private void UpdatePlaceholder() =>
        SearchPlaceholder.Visibility = string.IsNullOrEmpty(SearchBox.Text)
            ? Visibility.Visible
            : Visibility.Collapsed;

    private async Task RunSearchAsync(string raw)
    {
        var query = raw.Trim();
        var version = ++_version;

        if (query.Length == 0)
        {
            ShowEmpty("搜索「所有媒体库」中的内容", "输入片名、剧名或关键词");
            StatusText.Text = "";
            return;
        }

        var services = AppServices.Instance;
        if (!services.IsConnected)
        {
            ShowEmpty("还没有连接媒体源", "先去「媒体源」添加一个");
            StatusText.Text = "";
            return;
        }

        StatusText.Text = "正在搜索…";

        try
        {
            var cards = RecordSegment.IsChecked == true
                ? await SearchRecordsAsync(query)
                : await SearchMediaAsync(query);

            if (version != _version)
            {
                return;
            }

            if (cards.Count == 0)
            {
                ShowEmpty($"没有找到「{query}」", RecordSegment.IsChecked == true
                    ? "换个关键词，或去媒体库里翻"
                    : "试试剧名或更短的关键词");
                StatusText.Text = "0 个结果";
                return;
            }

            ResultGrid.ItemsSource = cards;
            EmptyState.Visibility = Visibility.Collapsed;
            ResultScroll.Visibility = Visibility.Visible;
            StatusText.Text = $"{cards.Count} 个结果" +
                (RecordSegment.IsChecked == true ? "" : $" · 每个库搜索前 {IndexPerLibrary} 条");

            await Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
        }
        catch (Exception ex)
        {
            if (version == _version)
            {
                StatusText.Text = "搜索失败：" + ex.Message;
            }
        }
    }

    private async Task<List<SearchCard>> SearchMediaAsync(string query)
    {
        if (_mediaIndex is null)
        {
            _mediaIndex = await BuildMediaIndexAsync().ConfigureAwait(true);
        }

        return _mediaIndex
            .Where(e => Matches(e.Item.Title, query) || Matches(e.Item.ParentTitle, query))
            .GroupBy(e => e.Item.Id)
            .Select(g => g.First())
            .Select(e =>
            {
                var item = e.Item;
                var card = new SearchCard
                {
                    Id = item.Id,
                    Kind = item.Kind,
                    Title = MediaText.Clean(item.Title),
                    Sub = e.LibraryTitle + " · " + MediaText.Describe(item),
                    Badge = AppServices.Instance.Settings.ShowResolution && !string.IsNullOrEmpty(item.Resolution)
                        ? item.Resolution!
                        : "",
                    PosterPath = item.PosterPath,
                    Initial = Palette.InitialOf(item.Title),
                    BadgeVisibility = AppServices.Instance.Settings.ShowResolution &&
                                      !string.IsNullOrEmpty(item.Resolution)
                        ? Visibility.Visible
                        : Visibility.Collapsed,
                };
                card.UseGradient(item.Id + item.Title);
                return card;
            })
            .Take(120)
            .ToList();
    }

    /// <summary>每个库抓一页条目做关键词索引。库多、条目多以后再交给核心。</summary>
    private static async Task<List<IndexEntry>> BuildMediaIndexAsync()
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return new List<IndexEntry>();
        }

        var libraries = await Task.Run(core.Libraries).ConfigureAwait(true);
        if (!libraries.Ok || libraries.Data is null)
        {
            return new List<IndexEntry>();
        }

        var entries = new List<IndexEntry>();
        foreach (var library in libraries.Data)
        {
            var id = library.Id;
            var title = library.Title;
            var page = await Task.Run(() => core.Items(id, 1, IndexPerLibrary)).ConfigureAwait(true);
            if (!page.Ok || page.Data is null)
            {
                continue;
            }

            entries.AddRange(page.Data.Items.Select(item => new IndexEntry(title, item)));
        }

        return entries;
    }

    private async Task<List<SearchCard>> SearchRecordsAsync(string query)
    {
        if (_recordIndex is null)
        {
            var core = AppServices.Instance.Core;
            if (core is null)
            {
                return new List<SearchCard>();
            }

            var result = await Task.Run(core.Records).ConfigureAwait(true);
            _recordIndex = result.Data ?? new List<PlayRecordDto>();
        }

        return _recordIndex
            .Where(r => Matches(MediaText.RecordTitle(r), query) ||
                        Matches(r.SeriesTitle, query) ||
                        Matches(r.Title, query))
            .OrderByDescending(r => r.LastPlayed ?? 0)
            .Select(r =>
            {
                var title = MediaText.RecordTitle(r);
                var progress = r.DurationSeconds <= 0
                    ? 0
                    : Math.Clamp((double)r.PositionSeconds / r.DurationSeconds, 0, 1);

                var card = new SearchCard
                {
                    Id = r.ItemId,
                    Kind = "episode",
                    Title = title,
                    Sub = progress > 0 ? $"继续观看 · {progress:P0}" : "播放记录",
                    PosterPath = r.PosterPath,
                    Initial = Palette.InitialOf(title),
                };
                card.UseGradient(r.ItemId + title);
                return card;
            })
            .Take(120)
            .ToList();
    }

    private static bool Matches(string? text, string query) =>
        !string.IsNullOrEmpty(text) &&
        text.Contains(query, StringComparison.OrdinalIgnoreCase);

    private void ShowEmpty(string title, string hint)
    {
        EmptyTitle.Text = title;
        EmptyHint.Text = hint;
        EmptyState.Visibility = Visibility.Visible;
        ResultScroll.Visibility = Visibility.Collapsed;
        ResultGrid.ItemsSource = null;
    }

    private async void OnCardClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        var cards = ResultGrid.ItemsSource as List<SearchCard>;
        var card = cards?.FirstOrDefault(c => c.Id == id);

        if (card is not null && !MediaText.IsPlayable(card.Kind))
        {
            NavigationService?.Navigate(new SeriesPage(id));
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), id);
    }

    private sealed record IndexEntry(string LibraryTitle, MediaItemDto Item);

    private sealed class SearchCard : CardVisual
    {
        public string Id { get; init; } = "";
        public string Kind { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public Visibility BadgeVisibility { get; init; } = Visibility.Collapsed;
    }
}