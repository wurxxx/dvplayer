using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 「每日推荐」页：TMDB / 豆瓣热门。媒体源里有的点开进详情，
/// 没有的推到 MoviePilot 订阅。
/// </summary>
public partial class DailyPage : Page
{
    private bool _subscribed;
    private bool _renderQueued;
    private string? _notice;
    private List<DailyItem> _movies = new();
    private List<DailyItem> _series = new();

    public DailyPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (!_subscribed)
        {
            DailyService.Changed += OnServiceChanged;
            _subscribed = true;
        }

        Render();
        _ = DailyService.EnsurePostersAsync();
        await DailyService.RefreshIfNeededAsync();
        Render();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_subscribed)
        {
            DailyService.Changed -= OnServiceChanged;
            _subscribed = false;
        }
    }

    /// <summary>服务可能在后台线程改状态：合并成一次 UI 重画。</summary>
    private void OnServiceChanged()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(QueueRender);
            return;
        }

        QueueRender();
    }

    private void QueueRender()
    {
        if (_renderQueued)
        {
            return;
        }

        _renderQueued = true;
        Dispatcher.BeginInvoke(new Action(() =>
        {
            _renderQueued = false;
            Render();
        }), DispatcherPriority.Background);
    }

    // MARK: - 渲染

    private void Render()
    {
        var items = DailyService.Items;
        var movies = items.Where(item => !item.IsSeries).ToList();
        var series = items.Where(item => item.IsSeries).ToList();

        if (!SameItems(_movies, movies))
        {
            _movies = movies;
            MovieGrid.ItemsSource = _movies;
        }

        if (!SameItems(_series, series))
        {
            _series = series;
            SeriesGrid.ItemsSource = _series;
        }

        MovieSection.Visibility = movies.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        SeriesSection.Visibility = series.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        MovieCount.Text = movies.Count > 0 ? movies.Count.ToString() : "";
        SeriesCount.Text = series.Count > 0 ? series.Count.ToString() : "";

        var hasItems = items.Count > 0;
        FeedScroll.Visibility = hasItems ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = hasItems ? Visibility.Collapsed : Visibility.Visible;

        if (!hasItems)
        {
            var loading = DailyService.Loading;
            EmptyTitle.Text = loading ? "正在获取今日热门…" : "今天还没有推荐";
            EmptyHint.Text = loading ? "稍等几秒" : "刷新一下试试，或者检查网络。";
        }

        if (DailyService.Feed is { } feed && hasItems)
        {
            CountText.Text = $"{feed.FetchedAt:M 月 d 日} · {items.Count} 条";
        }
        else
        {
            CountText.Text = "";
        }

        StatusText.Text = _notice
                          ?? (DailyService.Matching ? "正在匹配媒体源…"
                              : DailyService.Loading ? "正在获取…"
                              : "");
        RefreshButton.IsEnabled = !DailyService.Loading;

        RenderNotes();
    }

    private static bool SameItems(List<DailyItem> current, List<DailyItem> next) =>
        current.Count == next.Count && current.Zip(next).All(pair => ReferenceEquals(pair.First, pair.Second));

    private void RenderNotes()
    {
        var settings = AppServices.Instance.Settings;
        var lines = new List<string>();

        if (string.IsNullOrWhiteSpace(settings.TmdbApiKey))
        {
            lines.Add("没填 TMDB API Key，现在只显示豆瓣热门。填上之后会一起显示 TMDB 的趋势榜。");
        }

        if (DailyService.Error is { Length: > 0 } error)
        {
            lines.Add(error);
        }
        else if (!string.IsNullOrWhiteSpace(settings.TmdbApiKey)
                 && DailyService.Feed?.TmdbError is { Length: > 0 } tmdbError)
        {
            lines.Add(tmdbError);
        }

        if (string.IsNullOrWhiteSpace(settings.MoviePilotUrl))
        {
            lines.Add("没配 MoviePilot：媒体源里没有的条目暂时不能直接订阅。"
                      + "在「设置 → 通用 → 每日推荐」里填地址和 API Token。");
        }

        NotesText.Text = string.Join("\n", lines);
        NotesText.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NotesText.Foreground = DailyService.Error is { Length: > 0 }
            ? new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x6B))
            : (Brush)FindResource("FaintBrush");
    }

    // MARK: - 动作

    private async void OnRefreshClick(object sender, RoutedEventArgs e)
    {
        _notice = null;
        await DailyService.RefreshAsync(force: true);
    }

    private async void OnCardClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: DailyItem item })
        {
            return;
        }

        // 媒体源里有：直接进详情。
        if (item.InLibrary)
        {
            NavigationService?.Navigate(new SeriesPage(item.MatchedItemId!));
            return;
        }

        if (item.Subscribed)
        {
            _notice = "已经推送到 MoviePilot 了";
            Render();
            return;
        }

        _notice = "正在推送到 MoviePilot…";
        Render();
        var message = await DailyService.SubscribeAsync(item);
        _notice = message.Length > 0 ? message : null;
        Render();
    }
}
