using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 聚合搜索页。空态：一个放大镜加「搜索所有媒体库中的内容」；
/// 输入后跨所有已连上的源找片名。
///
/// 去重、选主源、失败源都由核心的 `MediaHub::search` 做完，这里只负责显示：
/// 同一部片只出现一次，左上角标出有几个来源，点开先让用户选一个。
/// </summary>
public partial class SearchPage : Page
{

    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(280) };

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
            List<SearchCard> cards;
            List<SourceFailureDto> failed;

            if (RecordSegment.IsChecked == true)
            {
                cards = await SearchRecordsAsync(query);
                failed = new List<SourceFailureDto>();
            }
            else
            {
                // 核心已经把跨源结果去重、按主源排好；这里只负责显示。
                var outcome = await SearchMediaAsync(query);
                cards = outcome.Cards;
                failed = outcome.Failed;
            }

            if (version != _version)
            {
                return;
            }

            if (cards.Count == 0)
            {
                ShowEmpty($"没有找到「{query}」", RecordSegment.IsChecked == true
                    ? "换个关键词，或去媒体库里翻"
                    : "试试剧名或更短的关键词");
                StatusText.ToolTip = null;

                if (failed.Count == 0)
                {
                    StatusText.Text = "0 个结果";
                }
                else
                {
                    var names = string.Join("、", failed.Select(f => f.SourceName));
                    StatusText.Text = $"0 个结果 · {failed.Count} 个源没响应（{names}）";
                    StatusText.ToolTip = string.Join("\n",
                        failed.Select(f => $"{f.SourceName}：{f.Error}"));
                }
                return;
            }

            ResultGrid.ItemsSource = cards;
            EmptyState.Visibility = Visibility.Collapsed;
            ResultScroll.Visibility = Visibility.Visible;

            if (failed.Count == 0)
            {
                StatusText.Text = $"{cards.Count} 个结果";
                StatusText.ToolTip = null;
            }
            else
            {
                // 某个源挂了不影响其它源，但要让用户知道结果不全。
                var names = string.Join("、", failed.Select(f => f.SourceName));
                StatusText.Text = $"{cards.Count} 个结果 · {failed.Count} 个源没响应（{names}）";
                StatusText.ToolTip = string.Join("\n",
                    failed.Select(f => $"{f.SourceName}：{f.Error}"));
            }

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

    /// <summary>跨源搜索，交给核心（去重、选主源、失败源都已在核心里做完）。</summary>
    private async Task<(List<SearchCard> Cards, List<SourceFailureDto> Failed)> SearchMediaAsync(string query)
    {
        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return (new List<SearchCard>(), new List<SourceFailureDto>());
        }

        var result = await Task.Run(() => core.Search(query)).ConfigureAwait(true);
        if (!result.Ok || result.Data is null)
        {
            return (new List<SearchCard>(), new List<SourceFailureDto>());
        }

        var showResolution = AppServices.Instance.Settings.ShowResolution;
        var failed = result.Data.Failed ?? new List<SourceFailureDto>();

        var cards = result.Data.Items
            .Select(item =>
            {
                var title = item.Title;
                var sources = item.Sources ?? new List<ItemSourceDto>();

                var card = new SearchCard
                {
                    Id = item.Id,
                    Kind = item.Kind,
                    Title = MediaText.Clean(title),
                    Sub = MediaText.Describe(item),
                    Badge = showResolution && !string.IsNullOrEmpty(item.Resolution)
                        ? item.Resolution!
                        : "",
                    PosterPath = item.PosterPath,
                    Initial = Palette.InitialOf(title),
                    BadgeVisibility = showResolution && !string.IsNullOrEmpty(item.Resolution)
                        ? Visibility.Visible
                        : Visibility.Collapsed,
                    Sources = sources,
                };
                card.UseGradient(item.Id + title);
                return card;
            })
            .Take(120)
            .ToList();

        return (cards, failed);
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

    /// <summary>
    /// 搜索结果一律进详情：单集 / 电影也在详情页里播，
    /// 只有「继续观看」这类带进度的地方才直接续播。
    /// </summary>
    private void OnCardClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: SearchCard card } ||
            string.IsNullOrEmpty(card.Id))
        {
            return;
        }

        // 多来源不在这里选：进详情页的「资源」里切。
        NavigationService?.Navigate(new SeriesPage(card.Id));
    }

    private sealed class SearchCard : CardVisual
    {
        private List<ItemSourceDto> _sources = new();

        public string Id { get; init; } = "";
        public string Kind { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public Visibility BadgeVisibility { get; init; } = Visibility.Collapsed;

        /// <summary>同一部片的所有来源；只有聚合搜索会填。</summary>
        public List<ItemSourceDto> Sources
        {
            get => _sources;
            init => _sources = value ?? new List<ItemSourceDto>();
        }

        public string SourcesBadge => $"{Sources.Count} 源";

        public Visibility SourcesVisibility =>
            Sources.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }
}
