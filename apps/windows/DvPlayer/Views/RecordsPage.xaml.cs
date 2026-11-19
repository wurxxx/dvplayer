using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;

namespace DvPlayer.Views;

public partial class RecordsPage : Page
{
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
            .Select(r => new RecordRow(
                r.Title,
                $"{Format(r.PositionSeconds)} / {Format(r.DurationSeconds)}",
                r.LastPlayed is null
                    ? "—"
                    : DateTimeOffset.FromUnixTimeSeconds(r.LastPlayed.Value).LocalDateTime.ToString("MM-dd HH:mm")))
            .ToList();

        RecordList.ItemsSource = records;
        StatusText.Text = records.Count == 0 ? "还没有播放记录。" : $"{records.Count} 条";
    }

    private static string Format(long seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes:00}:{t.Seconds:00}";
    }

    private sealed record RecordRow(string Title, string Progress, string LastPlayed);
}
