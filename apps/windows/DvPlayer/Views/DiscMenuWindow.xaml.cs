using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 原盘菜单：打开 ISO 先停在这里，选标题 / 章节再起播。
///
/// 原盘自带的 HDMV / BD-J 菜单跑不起来（mpv / libbluray 没有菜单引擎），
/// 这一版按 mpls 的标题和 `PlayListMark` 自己画：左边标题（正片 / 花絮），
/// 右边章节。章节按标题懒加载——花絮很多张盘，一次全读要几十秒。
/// </summary>
public partial class DiscMenuWindow : Window
{
    private readonly BluRayProbe _probe;
    private readonly string _isoPath;
    private readonly double? _suggestedStart;
    private readonly Dictionary<int, List<BluRayChapter>> _chapters = new();
    private readonly HashSet<int> _loading = new();
    private readonly List<Border> _rows = new();
    private BluRayTitle? _selected;
    private (BluRayTitle Title, double Start)? _picked;

    internal DiscMenuWindow(BluRayProbe probe, string isoPath, double? suggestedStart)
    {
        InitializeComponent();
        _probe = probe;
        _isoPath = isoPath;
        _suggestedStart = suggestedStart;

        // 小屏 / 高缩放下 980×640 可能放不下；夹进工作区再居中。
        var area = SystemParameters.WorkArea;
        Width = Math.Min(Width, Math.Max(760, area.Width - 48));
        Height = Math.Min(Height, Math.Max(480, area.Height - 48));
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Top + (area.Height - Height) / 2;

        DiscNameText.Text = string.IsNullOrWhiteSpace(probe.DiscName)
            ? Path.GetFileNameWithoutExtension(isoPath)
            : probe.DiscName;

        var features = probe.Titles
            .Where(probe.IsFeature)
            .OrderByDescending(title => title.DurationSeconds)
            .ToList();
        var extras = probe.Titles
            .Where(title => !probe.IsFeature(title))
            .OrderBy(title => title.TitleNumber)
            .ToList();

        var summary = $"{probe.Titles.Count} 个标题";
        if (features.Count > 0)
        {
            summary += $" · {features.Count} 个正片";
        }

        DiscSummaryText.Text = summary;

        BuildRows(features, extras);

        PreviewKeyDown += OnPreviewKeyDown;

        var first = features.FirstOrDefault() ?? extras.FirstOrDefault();
        if (first is not null)
        {
            SelectTitle(first);
        }
        else
        {
            PlayButton.IsEnabled = false;
        }
    }

    /// <summary>弹出菜单；返回选中的标题与起播点，直接关掉返回 null。</summary>
    public static (BluRayTitle Title, double Start)? ShowMenu(
        Window? owner, BluRayProbe probe, string isoPath, double? suggestedStart)
    {
        var window = new DiscMenuWindow(probe, isoPath, suggestedStart);
        if (owner is not null && !ReferenceEquals(owner, window))
        {
            window.Owner = owner;
        }

        return window.ShowDialog() == true ? window._picked : null;
    }

    /// <summary>自检用：建好窗口但不阻塞，外面截图后再关。</summary>
    public static DiscMenuWindow ForShot(
        Window? owner, BluRayProbe probe, string isoPath, double? suggestedStart = null)
    {
        var window = new DiscMenuWindow(probe, isoPath, suggestedStart);
        if (owner is not null && !ReferenceEquals(owner, window))
        {
            window.Owner = owner;
        }

        return window;
    }

    /// <summary>
    /// 自检用：按当前选中的标题走一次「点章节」，返回挑中的标题和起点。
    /// 非模态窗口不能设 DialogResult，直接记结果再关窗。
    /// </summary>
    public (BluRayTitle Title, double Start)? SimulatePick(double start)
    {
        if (_selected is not { } title)
        {
            return null;
        }

        _picked = (title, Math.Max(0, start));
        Close();
        return _picked;
    }

    /// <summary>自检日志：选中了哪个标题、读到几章。</summary>
    public string DescribeForShot()
    {
        var title = _selected is null ? "-" : _selected.TitleNumber.ToString();
        var chapters = _selected is not null && _chapters.TryGetValue(_selected.TitleNumber, out var list)
            ? list.Count
            : -1;
        return $"selected={title} chapters={chapters} " +
               $"rows={_rows.Count} play={PlayButton.IsEnabled} " +
               $"resume={ResumeButton.Visibility}";
    }

    // MARK: - 标题列表

    private void BuildRows(List<BluRayTitle> features, List<BluRayTitle> extras)
    {
        TitleList.Children.Clear();
        _rows.Clear();

        if (features.Count > 0)
        {
            TitleList.Children.Add(GroupLabel("正片"));
            foreach (var title in features)
            {
                TitleList.Children.Add(BuildRow(title));
            }
        }

        if (extras.Count > 0)
        {
            var label = GroupLabel("花絮");
            label.Margin = new Thickness(4, features.Count > 0 ? 10 : 0, 0, 2);
            TitleList.Children.Add(label);
            foreach (var title in extras)
            {
                TitleList.Children.Add(BuildRow(title));
            }
        }

        UpdateRows();
    }

    private TextBlock GroupLabel(string text) => new()
    {
        Text = text,
        FontSize = 11.5,
        FontWeight = FontWeights.SemiBold,
        Foreground = Resource("FaintBrush"),
        Margin = new Thickness(4, 0, 0, 2),
    };

    private Border BuildRow(BluRayTitle title)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(new TextBlock
        {
            Text = $"标题 {title.TitleNumber}",
            FontSize = 13.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = Resource("TextBrush"),
        });

        if (_probe.IsFeature(title))
        {
            header.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xB0, 0x20)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(6, 1, 0, 0),
                Child = new TextBlock
                {
                    Text = "正片",
                    FontSize = 10,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = Resource("AccentBrush"),
                },
            });
        }

        var stack = new StackPanel();
        stack.Children.Add(header);
        stack.Children.Add(new TextBlock
        {
            Text = Meta(title),
            FontSize = 11.5,
            Foreground = Resource("FaintBrush"),
            Margin = new Thickness(0, 3, 0, 0),
        });

        var row = new Border
        {
            Child = stack,
            Tag = title,
            CornerRadius = new CornerRadius(9),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(0, 0, 0, 6),
            Cursor = Cursors.Hand,
            Background = Resource("SurfaceBrush"),
            BorderBrush = Resource("LineBrush"),
        };
        row.MouseLeftButtonUp += (_, args) =>
        {
            args.Handled = true;
            SelectTitle(title);
        };

        _rows.Add(row);
        return row;
    }

    private string Meta(BluRayTitle title)
    {
        var parts = new List<string> { title.DurationLabel };
        if (_chapters.TryGetValue(title.TitleNumber, out var chapters))
        {
            var usable = chapters.Count(chapter => chapter.Time < title.DurationSeconds - 1);
            if (usable > 0)
            {
                parts.Add($"{usable} 章");
            }
        }

        var resume = LocalProgress.Get(KeyFor(title));
        if (resume > 0)
        {
            parts.Add($"看到 {BluRayTitle.Format(resume)}");
        }

        return string.Join(" · ", parts);
    }

    private void SelectTitle(BluRayTitle title)
    {
        _selected = title;
        UpdateRows();
        ChapterMetaText.Text = $"标题 {title.TitleNumber} · {title.DurationLabel}";
        _ = LoadChaptersAsync(title);
    }

    private void UpdateRows()
    {
        foreach (var row in _rows)
        {
            var active = row.Tag is BluRayTitle title &&
                         title.TitleNumber == _selected?.TitleNumber;
            row.Background = Resource(active ? "SurfaceHoverBrush" : "SurfaceBrush");
            row.BorderBrush = active
                ? new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xB0, 0x20))
                : Resource("LineBrush");
        }

        if (_selected is not { } selected)
        {
            PlayButton.IsEnabled = false;
            ResumeButton.Visibility = Visibility.Collapsed;
            return;
        }

        PlayButton.IsEnabled = true;

        var resume = ResumeFor(selected);
        ResumeButton.Visibility = resume > 0 ? Visibility.Visible : Visibility.Collapsed;
        ResumeButton.Content = resume > 0 ? $"继续 {BluRayTitle.Format(resume)}" : "继续播放";

        // 标题行里的「N 章 / 看到 …」会随章节读完更新。
        if (_rows.FirstOrDefault(row => row.Tag is BluRayTitle title &&
                                        title.TitleNumber == selected.TitleNumber)
            is { Child: StackPanel panel } && panel.Children.Count > 1 &&
            panel.Children[1] is TextBlock meta)
        {
            meta.Text = Meta(selected);
        }
    }

    // MARK: - 章节

    private async Task LoadChaptersAsync(BluRayTitle title)
    {
        if (_chapters.TryGetValue(title.TitleNumber, out var cached))
        {
            if (_selected?.TitleNumber == title.TitleNumber)
            {
                RenderChapters(title, cached);
            }

            return;
        }

        if (!_loading.Add(title.TitleNumber))
        {
            return;
        }

        ChapterList.Children.Clear();
        ChapterCountText.Text = "";
        ChapterHint.Text = "正在读取章节…";
        ChapterHint.Visibility = Visibility.Visible;

        List<BluRayChapter> chapters;
        try
        {
            chapters = await BluRayDisc.ProbeChaptersAsync(_isoPath, title.Mpls);
        }
        catch (Exception ex)
        {
            Trace.Write($"disc chapters failed mpls={title.Mpls}: {ex.Message}");
            chapters = new List<BluRayChapter>();
        }
        finally
        {
            _loading.Remove(title.TitleNumber);
        }

        _chapters[title.TitleNumber] = chapters;

        if (_selected?.TitleNumber == title.TitleNumber)
        {
            RenderChapters(title, chapters);
        }

        UpdateRows();
    }

    private void RenderChapters(BluRayTitle title, List<BluRayChapter> chapters)
    {
        // 有些盘的 PlayListMark 在片尾还留一条（时间等于时长），点它就是直接结束，
        // 和 mac 一样滤掉。
        chapters = chapters
            .Where(chapter => chapter.Time < title.DurationSeconds - 1)
            .ToList();

        ChapterList.Children.Clear();
        ChapterCountText.Text = chapters.Count > 0 ? chapters.Count.ToString() : "";

        if (chapters.Count == 0)
        {
            ChapterHint.Text = "这张盘没有章节标记\n点下面的「从头播放」整段播放。";
            ChapterHint.Visibility = Visibility.Visible;
            return;
        }

        ChapterHint.Visibility = Visibility.Collapsed;

        foreach (var chapter in chapters)
        {
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock
            {
                Text = $"第 {chapter.Index} 章",
                FontSize = 12.5,
                FontWeight = FontWeights.Medium,
                Foreground = Resource("TextBrush"),
            });
            stack.Children.Add(new TextBlock
            {
                Text = chapter.TimeLabel,
                FontSize = 11,
                Foreground = Resource("FaintBrush"),
                Margin = new Thickness(0, 2, 0, 0),
            });

            var cell = new Border
            {
                Child = stack,
                Width = 132,
                Height = 48,
                CornerRadius = new CornerRadius(8),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(10, 6, 10, 6),
                Margin = new Thickness(0, 0, 8, 8),
                Background = Resource("SurfaceBrush"),
                BorderBrush = Resource("LineBrush"),
                Cursor = Cursors.Hand,
                ToolTip = $"从 {chapter.TimeLabel} 开始播放",
            };
            cell.MouseLeftButtonUp += (_, args) =>
            {
                args.Handled = true;
                Pick(title, chapter.Time);
            };
            ChapterList.Children.Add(cell);
        }
    }

    // MARK: - 结果

    private void Pick(BluRayTitle title, double start)
    {
        _picked = (title, Math.Max(0, start));
        CloseWith(true);
    }

    /// <summary>模态时关对话框；自检里是非模态窗口，DialogResult 不能设。</summary>
    private void CloseWith(bool result)
    {
        try
        {
            DialogResult = result;
        }
        catch (InvalidOperationException)
        {
            Close();
        }
    }

    private void OnPlayClick(object sender, RoutedEventArgs e)
    {
        if (_selected is { } title)
        {
            Pick(title, 0);
        }
    }

    private void OnResumeClick(object sender, RoutedEventArgs e)
    {
        if (_selected is { } title)
        {
            Pick(title, ResumeFor(title));
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => CloseWith(false);

    private string KeyFor(BluRayTitle title) =>
        $"iso:{Path.GetFileNameWithoutExtension(_isoPath)}:mpls{title.Mpls}";

    private double ResumeFor(BluRayTitle title)
    {
        var saved = LocalProgress.Get(KeyFor(title));
        if (saved > 0)
        {
            return saved;
        }

        // 媒体库点开时核心给的续播点只对默认标题有意义。
        var first = _probe.Titles
            .Where(_probe.IsFeature)
            .OrderByDescending(item => item.DurationSeconds)
            .FirstOrDefault();
        return first?.TitleNumber == title.TitleNumber
            ? Math.Max(0, _suggestedStart ?? 0)
            : 0;
    }

    // MARK: - 窗口

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            CloseWith(false);
        }
    }

    private void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        // 标题行 / 章节块是 Border：拖窗口会把点击吞掉，这些区域不拖。
        if (e.OriginalSource is DependencyObject source && InsideClickable(source))
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // 快速点击时鼠标已经抬起，忽略。
        }
    }

    private bool InsideClickable(DependencyObject? node)
    {
        while (node is not null)
        {
            if (node == TitleList || node == ChapterList || node is ButtonBase)
            {
                return true;
            }

            node = VisualTreeHelper.GetParent(node);
        }

        return false;
    }

    private Brush Resource(string key) => (Brush)FindResource(key);
}
