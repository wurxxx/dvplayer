using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class RecordsPage : Page
{
    private const double BarMax = 320;

    public RecordsPage()
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

                return new RecordRow
                {
                    Title = r.Title,
                    Progress = $"{Format(r.PositionSeconds)} / {Format(r.DurationSeconds)}  ·  {progress:P0}",
                    Remaining = r.DurationSeconds <= 0 ? "" : $"还剩 {Format(remaining)}",
                    LastPlayed = r.LastPlayed is null
                        ? ""
                        : DateTimeOffset.FromUnixTimeSeconds(r.LastPlayed.Value).LocalDateTime.ToString("MM-dd HH:mm"),
                    BarWidth = Math.Max(0, BarMax * progress),
                    Gradient = Palette.GradientFor(r.ItemId + r.Title),
                    Initial = Palette.InitialOf(r.Title),
                };
            })
            .ToList();

        RecordList.ItemsSource = records;
        StatusText.Text = records.Count == 0 ? "还没有播放记录。" : $"{records.Count} 条，继续上次看到的位置";
    }

    private static string Format(long seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1
            ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}"
            : $"{t.Minutes:00}:{t.Seconds:00}";
    }

    private sealed class RecordRow
    {
        public string Title { get; init; } = "";
        public string Progress { get; init; } = "";
        public string Remaining { get; init; } = "";
        public string LastPlayed { get; init; } = "";
        public string Initial { get; init; } = "";
        public double BarWidth { get; init; }
        public Brush Gradient { get; init; } = Brushes.DimGray;
    }
}
