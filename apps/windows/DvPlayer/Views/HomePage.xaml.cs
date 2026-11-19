using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class HomePage : Page
{
    public HomePage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var services = AppServices.Instance;

        if (!services.IsConnected)
        {
            StatusText.Text = "未连接媒体源，先在「设置」里添加。";
            return;
        }

        StatusText.Text = "正在读取播放记录…";

        var core = services.Core!;
        var result = await Task.Run(core.Records).ConfigureAwait(true);

        if (!result.Ok)
        {
            StatusText.Text = "读取失败：" + (result.Error ?? "未知错误");
            return;
        }

        var records = result.Data ?? new List<PlayRecordDto>();
        StatusText.Text = records.Count == 0
            ? "还没有播放记录。"
            : $"{records.Count} 条记录";

        RecordList.ItemsSource = records
            .OrderByDescending(r => r.LastPlayed ?? 0)
            .Take(24)
            .Select(r => new RecordCard(
                r.Title,
                services.CurrentSource?.Name ?? r.SourceId,
                r.DurationSeconds == 0 ? 0 : r.PositionSeconds * 100.0 / r.DurationSeconds,
                $"{Format(r.PositionSeconds)} / {Format(r.DurationSeconds)}"))
            .ToList();
    }

    private static string Format(long seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes:00}:{t.Seconds:00}";
    }

    private sealed record RecordCard(string Title, string Source, double ProgressPercent, string Detail);
}
