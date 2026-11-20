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

    public RecordsPage()
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

        StatusText.Text = _records.Count == 0
            ? "还没有播放记录。"
            : $"{_records.Count} 条记录 · 继续上次看到的位置";

        _ = Task.WhenAll(all.Select(x => x.Card).Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private const double ScrollStep = 262;

    private void OnScrollLeft(object sender, RoutedEventArgs e) => ScrollRow(sender, -ScrollStep);

    private void OnScrollRight(object sender, RoutedEventArgs e) => ScrollRow(sender, ScrollStep);

    private static void ScrollRow(object sender, double delta)
    {
        if (FindRow(sender) is { } row)
        {
            row.ScrollToHorizontalOffset(Math.Max(0, row.HorizontalOffset + delta));
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

    /// <summary>横向列表上用滚轮也能左右滚，不用去够箭头。</summary>
    private void OnRowWheel(object sender, MouseWheelEventArgs e)
    {
        if (sender is ScrollViewer row)
        {
            row.ScrollToHorizontalOffset(Math.Max(0, row.HorizontalOffset - e.Delta));
            e.Handled = true;
        }
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

        GeneralPanel.Visibility = GeneralSegment.IsChecked == true
            ? Visibility.Visible
            : Visibility.Collapsed;
        WatchPanel.Visibility = WatchSegment.IsChecked == true
            ? Visibility.Visible
            : Visibility.Collapsed;
        FavoritePanel.Visibility = FavoriteSegment.IsChecked == true
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private async void OnCardClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), id);
    }

    private static string Format(long seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1
            ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}"
            : $"{t.Minutes:00}:{t.Seconds:00}";
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