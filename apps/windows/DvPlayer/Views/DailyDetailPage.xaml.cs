using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 推荐详情页：媒体源里没有的条目，先用豆瓣 / TMDB 的资料看清楚，
/// 再在页面上决定要不要推到 MoviePilot 订阅。
///
/// 结构和媒体详情页（SeriesPage）一致：大图 + 信息叠加，下面是简介、
/// 演职人员、链接。区别只在数据来源和动作：这里没有播放，只有「添加订阅」。
/// </summary>
public partial class DailyDetailPage : Page
{
    private readonly DailyItem _item;
    private string? _doubanUrl;
    private string? _tmdbUrl;
    private string? _imdbUrl;

    public DailyDetailPage(DailyItem item)
    {
        InitializeComponent();
        _item = item;
        Loaded += OnLoaded;
        KeyDown += OnKeyDown;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // 列表里已有的信息先铺上，接口回来再补全。
        Fill(DailyService.BaseInfo(_item));
        SubscribeHintText.Text = BuildHint();
        UpdateSubscribeState();

        var (info, error) = await DailyService.LoadDetailAsync(_item);
        Fill(info);
        await ApplyImagesAsync(info);
        LoadingText.Visibility = Visibility.Collapsed;

        if (!string.IsNullOrWhiteSpace(error))
        {
            NoticeText.Text = "豆瓣 / TMDB 资料没取全：" + error;
            NoticeText.Visibility = Visibility.Visible;
        }

        UpdateSubscribeState();
    }

    // MARK: - 填充

    private void Fill(DailyDetailInfo info)
    {
        SourceText.Text = _item.Trend;
        TitleText.Text = info.Title;

        var original = info.OriginalTitle ?? "";
        OriginalTitleText.Text = original;
        OriginalTitleText.Visibility = original.Length > 0
                                       && !string.Equals(original, info.Title, StringComparison.Ordinal)
            ? Visibility.Visible
            : Visibility.Collapsed;

        MetaText.Text = BuildMeta(info);

        var rating = BuildRating(info);
        RatingText.Text = rating;
        RatingText.Visibility = rating.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        BuildTags(info);

        // 简介只在下面完整显示一份，顶部不重复截断。
        var overview = info.Overview ?? "";
        IntroText.Text = overview;
        IntroSection.Visibility = overview.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        PeopleList.Children.Clear();
        AddPeopleRow("导演", info.Directors, first: true);
        AddPeopleRow("主演", info.Cast, first: info.Directors.Count == 0);
        PeopleSection.Visibility = info.Directors.Count > 0 || info.Cast.Count > 0
            ? Visibility.Visible
            : Visibility.Collapsed;

        // 没有横版图（豆瓣）才摆竖版海报；有横版图时背景已经够清楚。
        PosterCard.Visibility = string.IsNullOrWhiteSpace(info.BackdropUrl)
                                && !string.IsNullOrWhiteSpace(info.PosterUrl)
            ? Visibility.Visible
            : Visibility.Collapsed;

        _doubanUrl = info.DoubanUrl;
        _tmdbUrl = info.TmdbUrl;
        _imdbUrl = info.ImdbUrl;
        DoubanButton.Visibility = string.IsNullOrWhiteSpace(_doubanUrl)
            ? Visibility.Collapsed
            : Visibility.Visible;
        TmdbButton.Visibility = string.IsNullOrWhiteSpace(_tmdbUrl)
            ? Visibility.Collapsed
            : Visibility.Visible;
        ImdbButton.Visibility = string.IsNullOrWhiteSpace(_imdbUrl)
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private static string BuildMeta(DailyDetailInfo info)
    {
        var parts = new List<string>();
        if (info.Year is { } year)
        {
            parts.Add(year.ToString());
        }

        if (info.Countries.Count > 0)
        {
            parts.Add(string.Join(" / ", info.Countries.Take(2)));
        }

        if (!string.IsNullOrWhiteSpace(info.Runtime))
        {
            parts.Add(info.Runtime);
        }

        if (info.Episodes is > 0)
        {
            parts.Add($"共 {info.Episodes} 集");
        }

        return string.Join(" · ", parts);
    }

    private static string BuildRating(DailyDetailInfo info)
    {
        if (info.Rating is not > 0)
        {
            return "";
        }

        var text = $"{info.Rating.Value:0.0} 分";
        if (info.RatingCount is { } count && count >= 100)
        {
            text += count >= 10000
                ? $" · {count / 10000.0:0.0} 万人评价"
                : $" · {count}人评价";
        }

        return text;
    }

    private void BuildTags(DailyDetailInfo info)
    {
        var tags = new List<string> { info.IsSeries ? "剧集" : "电影" };
        tags.AddRange(info.Genres.Take(3));

        TagBar.Children.Clear();
        foreach (var tag in tags)
        {
            TagBar.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x1F, 0xFF, 0xFF, 0xFF)),
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(8, 3, 8, 3),
                Margin = new Thickness(0, 0, 6, 0),
                Child = new TextBlock
                {
                    Text = tag,
                    FontSize = 12,
                    Foreground = new SolidColorBrush(Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)),
                },
            });
        }
    }

    private void AddPeopleRow(string label, List<string> names, bool first)
    {
        if (names.Count == 0)
        {
            return;
        }

        var row = new Grid { Margin = new Thickness(0, first ? 0 : 8, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var labelBlock = new TextBlock
        {
            Text = label,
            FontSize = 12,
            Foreground = (Brush)FindResource("FaintBrush"),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 3, 0, 0),
        };

        var namesBlock = new TextBlock
        {
            Text = string.Join(" / ", names),
            FontSize = 13,
            Foreground = (Brush)FindResource("MutedBrush"),
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20,
        };
        Grid.SetColumn(namesBlock, 1);

        row.Children.Add(labelBlock);
        row.Children.Add(namesBlock);
        PeopleList.Children.Add(row);
    }

    // MARK: - 图片

    private async Task ApplyImagesAsync(DailyDetailInfo info)
    {
        // 有横版图就用横版图；豆瓣只给海报，拿海报放大模糊当背景。
        if (!string.IsNullOrWhiteSpace(info.BackdropUrl))
        {
            var bitmap = await DailyService.LoadImageAsync(info.BackdropUrl);
            if (bitmap is not null)
            {
                BackdropBrush.Background = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
                BackdropBlur.Visibility = Visibility.Collapsed;
                return;
            }
        }

        if (!string.IsNullOrWhiteSpace(info.PosterUrl))
        {
            var bitmap = await DailyService.LoadImageAsync(info.PosterUrl);
            if (bitmap is not null)
            {
                var brush = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
                brush.Freeze();
                BackdropBlur.Background = brush;
                // 竖版海报放大当背景：背景只做氛围，主体交给左边那张清楚的海报。
                if (BackdropBlur.Effect is BlurEffect blur)
                {
                    blur.Radius = 46;
                }

                BackdropBlur.Opacity = 0.72;
                BackdropBlur.Visibility = Visibility.Visible;
                PosterCard.Background = brush;
            }
        }
    }

    // MARK: - 动作

    private void OnBackClick(object sender, RoutedEventArgs e)
    {
        if (NavigationService?.CanGoBack == true)
        {
            NavigationService.GoBack();
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            OnBackClick(sender, e);
            e.Handled = true;
        }
    }

    private async void OnSubscribeClick(object sender, RoutedEventArgs e)
    {
        if (_item.Subscribed)
        {
            return;
        }

        SubscribeButton.IsEnabled = false;
        SubscribeButtonText.Text = "正在订阅…";

        var message = await DailyService.SubscribeAsync(_item);
        NoticeText.Text = message;
        NoticeText.Visibility = message.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateSubscribeState();
    }

    private void UpdateSubscribeState()
    {
        var subscribed = _item.Subscribed;
        SubscribeButton.IsEnabled = !subscribed;
        SubscribeButtonText.Text = subscribed ? "已订阅" : "添加订阅";
        SubscribeGlyph.Text = subscribed ? "\uE73E" : "\uE710";
        SubscribeButton.ToolTip = subscribed
            ? "已经推送到 MoviePilot"
            : "把这个条目推到 MoviePilot 自动搜索下载";
    }

    private string BuildHint()
    {
        var settings = AppServices.Instance.Settings;
        var text = "订阅会把这个条目推到 MoviePilot，由它自动搜索资源并下载。"
                   + "只想先了解的话不用订阅，直接返回列表就行。";

        if (string.IsNullOrWhiteSpace(settings.MoviePilotUrl)
            || string.IsNullOrWhiteSpace(settings.MoviePilotToken))
        {
            text += "\n还没配 MoviePilot：到「设置 → 通用 → 每日推荐」填地址和 API Token "
                    + "后，这里的「添加订阅」才能用。";
        }

        return text;
    }

    private void OnDoubanClick(object sender, RoutedEventArgs e) => OpenUrl(_doubanUrl);

    private void OnTmdbClick(object sender, RoutedEventArgs e) => OpenUrl(_tmdbUrl);

    private void OnImdbClick(object sender, RoutedEventArgs e) => OpenUrl(_imdbUrl);

    private static void OpenUrl(string? url)
    {
        if (string.IsNullOrWhiteSpace(url))
        {
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            System.Diagnostics.Trace.Write("open link failed: " + ex.Message);
        }
    }
}
