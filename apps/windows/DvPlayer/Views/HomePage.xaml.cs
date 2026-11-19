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
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
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

                var card = new ContinueCard
                {
                    ItemId = r.ItemId,
                    Title = r.Title,
                    Sub = $"{Format(r.PositionSeconds)} / {Format(r.DurationSeconds)}",
                    PosterPath = r.PosterPath,
                    Initial = Palette.InitialOf(r.Title),
                    BarWidth = Math.Max(0, CardWidth * progress),
                    Time = Format(r.DurationSeconds),
                };
                card.UseGradient(r.ItemId + r.Title);
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

        var library = librariesResult.Data[0];
        var itemsResult = await Task.Run(() => core.Items(library.Id, 1, 18)).ConfigureAwait(true);
        if (!itemsResult.Ok || itemsResult.Data is null)
        {
            RecentStatus.Text = "读取条目失败：" + (itemsResult.Error ?? "未知错误");
            return;
        }

        RecentStatus.Text = $"{library.Title} · 共 {itemsResult.Data.Total} 条";

        var posters = itemsResult.Data.Items.Select(item =>
        {
            var card = new PosterCard
            {
                ItemId = item.Id,
                Title = item.Title,
                Sub = ShortKind(item.Kind),
                Badge = string.IsNullOrEmpty(item.Resolution) ? "" : item.Resolution!,
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

        await PlayWindow.OpenAsync(Window.GetWindow(this), id);
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
        public string Title { get; init; } = "";
        public string Sub { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }
    }
}
