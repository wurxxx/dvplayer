using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class HomePage : Page
{
    private const double CardWidth = 240;

    public HomePage()
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
            StatusText.Text = "未连接媒体源，先在「设置」里添加。";
            RecentStatus.Text = string.Empty;
            return;
        }

        var core = services.Core!;
        StatusText.Text = "正在读取…";

        var recordsResult = await Task.Run(core.Records).ConfigureAwait(true);
        if (!recordsResult.Ok)
        {
            StatusText.Text = "读取失败：" + (recordsResult.Error ?? "未知错误");
        }
        else
        {
            var records = (recordsResult.Data ?? new List<PlayRecordDto>())
                .OrderByDescending(r => r.LastPlayed ?? 0)
                .Take(12)
                .ToList();

            StatusText.Text = records.Count == 0 ? "还没有播放记录。" : $"{records.Count} 条接着看";

            var cards = records.Select(r =>
            {
                var progress = r.DurationSeconds <= 0
                    ? 0
                    : Math.Clamp((double)r.PositionSeconds / r.DurationSeconds, 0, 1);

                var title = MediaText.RecordTitle(r);

                var card = new ContinueCard
                {
                    ItemId = r.ItemId,
                    Title = title,
                    Sub = $"{Format(r.PositionSeconds)} / {Format(r.DurationSeconds)}",
                    PosterPath = r.PosterPath,
                    Initial = Palette.InitialOf(title),
                    BarWidth = Math.Max(0, CardWidth * progress),
                    Time = Format(r.DurationSeconds),
                };
                card.UseGradient(r.ItemId + title);
                return card;
            }).ToList();

            ContinueList.ItemsSource = cards;

            await Task.WhenAll(cards.Select(c => c.ApplyPosterAsync(c.PosterPath)));
        }

        var librariesResult = await Task.Run(core.Libraries).ConfigureAwait(true);
        if (!librariesResult.Ok || librariesResult.Data is not { Count: > 0 })
        {
            RecentStatus.Text = librariesResult.Ok ? "这个源里没有媒体库。" : "读取媒体库失败。";
            return;
        }

        // 每个库各取几条再合并，否则多源时「最近添加」只有第一个库的内容。
        var recent = new List<MediaItemDto>();
        foreach (var library in librariesResult.Data)
        {
            var id = library.Id;
            var page = await Task.Run(() => core.Items(id, 1, 6)).ConfigureAwait(true);
            if (page.Ok && page.Data is not null)
            {
                recent.AddRange(page.Data.Items);
            }
        }

        var items = recent
            .GroupBy(i => i.Id)
            .Select(g => g.First())
            .Take(18)
            .ToList();

        if (items.Count == 0)
        {
            RecentStatus.Text = "读取条目失败。";
            return;
        }

        RecentStatus.Text = librariesResult.Data.Count > 1
            ? $"{librariesResult.Data.Count} 个媒体库 · {items.Count} 条最近添加"
            : $"{librariesResult.Data[0].Title} · 共 {items.Count} 条";

        var showBadge = AppServices.Instance.Settings.ShowResolution;

        var posters = items.Select(item =>
        {
            var hasResolution = showBadge && !string.IsNullOrEmpty(item.Resolution);
            var card = new PosterCard
            {
                ItemId = item.Id,
                Kind = item.Kind,
                Title = MediaText.Clean(item.Title),
                Sub = MediaText.Describe(item),
                Badge = hasResolution ? item.Resolution! : "",
                BadgeVisibility = hasResolution ? Visibility.Visible : Visibility.Collapsed,
                PosterPath = item.PosterPath,
                Initial = Palette.InitialOf(item.Title),
            };
            card.UseGradient(item.Id + item.Title);
            return card;
        }).ToList();

        RecentList.ItemsSource = posters;

        await Task.WhenAll(posters.Select(c => c.ApplyPosterAsync(c.PosterPath)));
    }

    private async void OnCardClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id))
        {
            return;
        }

        // 剧集 / 目录先看详情，电影和单集直接播。
        if (sender is FrameworkElement { DataContext: PosterCard card } && !MediaText.IsPlayable(card.Kind))
        {
            NavigationService?.Navigate(new SeriesPage(id));
            return;
        }

        await PlayWindow.OpenAsync(Window.GetWindow(this), id);
    }

    private void OnAllRecordsClick(object sender, System.Windows.Input.MouseButtonEventArgs e) =>
        (Window.GetWindow(this) as MainWindow)?.NavigateTo("records");

    private static string Format(long seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return time.TotalHours >= 1
            ? $"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}"
            : $"{time.Minutes:00}:{time.Seconds:00}";
    }

    private sealed class ContinueCard : CardVisual
    {
        public string ItemId { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Time { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public double BarWidth { get; init; }
    }

    private sealed class PosterCard : CardVisual
    {
        public string ItemId { get; init; } = "";
        public string Kind { get; init; } = "";
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Badge { get; init; } = "";
        public Visibility BadgeVisibility { get; init; } = Visibility.Collapsed;
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
    }
}
