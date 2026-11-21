using System.IO;
using System.Windows;
using System.Windows.Input;
using DvPlayer.Services;

namespace DvPlayer.Dialogs;

/// <summary>
/// 原盘标题选择。mpv 已经用 libbluray 列好 title 和时长，这里只负责挑一个。
/// </summary>
public partial class DiscTitlesDialog : Window
{
    private readonly List<BluRayTitle> _titles = new();

    private sealed record Row(string Badge, string Name, string Detail, string Duration);

    public BluRayTitle? Selected { get; private set; }

    public DiscTitlesDialog()
    {
        InitializeComponent();
    }

    /// <summary>挑一个标题；取消返回 null。</summary>
    public static BluRayTitle? Pick(Window? owner, string isoPath, BluRayProbe probe)
    {
        var dialog = new DiscTitlesDialog();
        dialog.Configure(isoPath, probe);

        if (owner is not null && !ReferenceEquals(owner, dialog))
        {
            dialog.Owner = owner;
        }

        return dialog.ShowDialog() == true ? dialog.Selected : null;
    }

    /// <summary>填充列表：正片排前面，剩下的按原盘顺序。</summary>
    public void Configure(string isoPath, BluRayProbe probe)
    {
        _titles.Clear();

        var features = probe.Titles.Where(probe.IsFeature).ToList();
        var extras = probe.Titles.Where(title => !probe.IsFeature(title)).ToList();
        _titles.AddRange(features);
        _titles.AddRange(extras);

        var rows = _titles
            .Select(title => new Row(
                probe.IsFeature(title) ? "正片" : "花絮",
                $"标题 {title.TitleNumber}",
                $"{title.Mpls:00000}.mpls",
                title.DurationLabel))
            .ToList();

        TitlesList.ItemsSource = rows;
        Title = "DV Player — 打开原盘";

        var name = string.IsNullOrWhiteSpace(probe.DiscName)
            ? Path.GetFileNameWithoutExtension(isoPath)
            : probe.DiscName!;
        SubtitleText.Text = $"{name} · {probe.Titles.Count} 个标题";

        if (rows.Count > 0)
        {
            TitlesList.SelectedIndex = 0;
        }

        PlayButton.IsEnabled = rows.Count > 0;
    }

    private void OnSelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
        => PlayButton.IsEnabled = TitlesList.SelectedIndex >= 0;

    private void OnPlayClick(object sender, RoutedEventArgs e) => Accept();

    private void OnListDoubleClick(object sender, MouseButtonEventArgs e) => Accept();

    private void Accept()
    {
        var index = TitlesList.SelectedIndex;
        if (index < 0 || index >= _titles.Count)
        {
            return;
        }

        Selected = _titles[index];
        DialogResult = true;
    }

    private void OnCancelClick(object sender, RoutedEventArgs e) => DialogResult = false;

    private void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // 快速点击时鼠标已经抬起。
        }
    }
}
