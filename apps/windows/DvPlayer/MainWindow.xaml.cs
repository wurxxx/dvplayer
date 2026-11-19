using System.IO;
using System.Windows;
using System.Windows.Controls;
using DvPlayer.Services;
using DvPlayer.Views;
using Wpf.Ui.Controls;

namespace DvPlayer;

public partial class MainWindow : FluentWindow
{
    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        SelectNav("home");
        await TryAutoConnectAsync();

        // 脚本化验证用：--play <itemId>，可再加 --play-seconds N 自动退出。
        var playId = ArgumentAfter("--play");
        if (playId is not null)
        {
            var player = await PlayWindow.OpenAsync(this, playId);

            if (int.TryParse(ArgumentAfter("--play-seconds"), out var seconds) && seconds > 0)
            {
                await Task.Delay(TimeSpan.FromSeconds(seconds));
                player?.Close();
                Close();
            }

            return;
        }

        var shotDir = ScreenshotDir();
        if (shotDir is not null)
        {
            await CaptureTourAsync(shotDir);
        }
    }

    private static string? ScreenshotDir() => ArgumentAfter("--screenshot");

    private static string? ArgumentAfter(string flag)
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, flag);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    /// <summary>--screenshot 之后可再跟页面名，只巡检指定的页。</summary>
    private static string[] ScreenshotPages()
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, "--screenshot");
        if (index < 0 || index + 2 >= args.Length)
        {
            return new[] { "home", "libraries", "records", "settings", "home" };
        }

        var known = new[] { "home", "libraries", "records", "settings" };
        var pages = args.Skip(index + 2).Where(known.Contains).ToArray();
        return pages.Length == 0 ? new[] { "home" } : pages;
    }

    /// <summary>依次打开每个页面并保存一张 PNG，然后退出。用于无桌面环境的回归。</summary>
    private async Task CaptureTourAsync(string dir)
    {
        // --series <id>[,<id>...]：额外截详情页，用来验证剧集 / 未刮削目录两种布局。
        var seriesIds = ArgumentAfter("--series")?
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (seriesIds is not null)
        {
            var season = int.TryParse(ArgumentAfter("--series-season"), out var n) ? n - 1 : 0;

            for (var i = 0; i < seriesIds.Length; i++)
            {
                ContentFrame.Navigate(new SeriesPage(seriesIds[i], season));
                await Task.Delay(6000);
                var name = seriesIds.Length == 1 ? "series.png" : $"series-{i + 1}.png";
                UiCapture.Save(this, Path.Combine(dir, name));
                Navigate("libraries");
                await Task.Delay(1500);
            }
        }

        foreach (var tag in ScreenshotPages())
        {
            SelectNav(tag);
            await Task.Delay(5000);
            UiCapture.Save(this, Path.Combine(dir, tag + ".png"));
        }

        Application.Current.Shutdown();
    }

    private void SelectNav(string tag)
    {
        foreach (var item in Nav.Items.OfType<ListBoxItem>())
        {
            if ((item.Tag as string) == tag)
            {
                Nav.SelectedItem = item;
                return;
            }
        }
    }

    private async Task TryAutoConnectAsync()
    {
        var (ok, error) = await AppServices.Instance.ConnectSavedAsync();
        RefreshSourceStatus();

        // 全部连不上时才把原因挂出来；部分失败在设置页看。
        if (!ok && error is not null)
        {
            SourceHint.Text = error;
            SourceHint.ToolTip = error;
        }
    }

    /// <summary>连接状态变化后刷新左下角。</summary>
    public void RefreshSourceStatus()
    {
        var services = AppServices.Instance;
        SourceStatus.Text = services.SourceSummary;
        SourceHint.Text = services.IsConnected ? "媒体库已连接" : "在设置里添加媒体源";
    }

    private void OnNavSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        // XAML 里第一个项 IsSelected="True"，会在 ContentFrame 构造之前触发一次。
        if (ContentFrame is null)
        {
            return;
        }

        if (Nav.SelectedItem is ListBoxItem { Tag: string tag })
        {
            Navigate(tag);
        }
    }

    private void Navigate(string tag)
    {
        Page page = tag switch
        {
            "libraries" => new LibrariesPage(),
            "records" => new RecordsPage(),
            "settings" => new SettingsPage(),
            _ => new HomePage(),
        };

        ContentFrame.Navigate(page);
    }
}
