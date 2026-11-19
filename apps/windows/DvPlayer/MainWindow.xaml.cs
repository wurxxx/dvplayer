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

        var shotDir = ScreenshotDir();
        if (shotDir is not null)
        {
            await CaptureTourAsync(shotDir);
        }
    }

    private static string? ScreenshotDir()
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, "--screenshot");
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

        var pages = args.Skip(index + 2).Where(a => !a.StartsWith("--", StringComparison.Ordinal)).ToArray();
        return pages.Length == 0 ? new[] { "home" } : pages;
    }

    /// <summary>依次打开每个页面并保存一张 PNG，然后退出。用于无桌面环境的回归。</summary>
    private async Task CaptureTourAsync(string dir)
    {
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
        var (ok, error) = await AppServices.Instance.ConnectLastAsync();
        SourceStatus.Text = ok
            ? AppServices.Instance.CurrentSource?.Name ?? "已连接"
            : error ?? "未连接";
        SourceHint.Text = ok ? "媒体库已连接" : "在设置里添加媒体源";
    }

    /// <summary>设置页连接成功后刷新左下角状态。</summary>
    public void RefreshSourceStatus()
    {
        var connected = AppServices.Instance.IsConnected;
        SourceStatus.Text = connected
            ? AppServices.Instance.CurrentSource?.Name ?? "已连接"
            : "未连接";
        SourceHint.Text = connected ? "媒体库已连接" : "在设置里添加媒体源";
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
