using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class RecordsPage : Page
{
    private const double BarMax = 320;

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
            StatusText.Text = "未连接媒体源，先去「设置」添加。";
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

        var records = (result.Data ?? new List<PlayRecordDto>())
            .OrderByDescending(r => r.LastPlayed ?? 0)
            .Select(r =>
            {
                var progress = r.DurationSeconds <= 0
                    ? 0
                    : Math.Clamp((double)r.PositionSeconds / r.DurationSeconds, 0, 1);

                var remaining = Math.Max(0, r.DurationSeconds - r.PositionSeconds);

                var title = MediaText.RecordTitle(r);

                var row = new RecordRow
                {
                    ItemId = r.ItemId,
                    Title = title,
                    Progress = $"{Format(r.PositionSeconds)} / {Format(r.DurationSeconds)}  ·  {progress:P0}",
                    Remaining = r.DurationSeconds <= 0 ? "" : $"还剩 {Format(remaining)}",
                    LastPlayed = r.LastPlayed is null
                        ? ""
                        : DateTimeOffset.FromUnixTimeSeconds(r.LastPlayed.Value).LocalDateTime.ToString("MM-dd HH:mm"),
                    BarWidth = Math.Max(0, BarMax * progress),
                    PosterPath = r.PosterPath,
                    Initial = Palette.InitialOf(title),
                };
                row.UseGradient(r.ItemId + title);
                return row;
            })
            .ToList();

        RecordList.ItemsSource = records;
        StatusText.Text = records.Count == 0 ? "还没有播放记录。" : $"{records.Count} 条，继续上次看到的位置";

        await Task.WhenAll(records.Select(r => r.ApplyPosterAsync(r.PosterPath)));
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

    private sealed class RecordRow : CardVisual
    {
        public string ItemId { get; init; } = "";
        public string Title { get; init; } = "";
        public string Progress { get; init; } = "";
        public string Remaining { get; init; } = "";
        public string LastPlayed { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
        public double BarWidth { get; init; }
    }
}
