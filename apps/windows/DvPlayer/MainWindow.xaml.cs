using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
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
        var shotDir = ScreenshotDir();
        var start = StartTag();

        // 先定当前源，服务器首页才知道该拉哪个源。
        RefreshSourceNav();

        // 没有源时直接去「服务器」页添加，服务器首页没什么可看的。
        if (start == "libraries" && AppServices.Instance.Settings.Sources.Count == 0)
        {
            start = "sources";
        }

        // 服务器首页不是菜单项，直接开页面。
        if (start == "libraries")
        {
            Nav.SelectedItem = null;
            Navigate("libraries");
        }
        else
        {
            SelectNav(start);
        }

        // 截图巡检时不受「启动时自动连接」开关影响，否则回归会拍到空页面。
        if (AppServices.Instance.Settings.AutoConnect || shotDir is not null)
        {
            await TryAutoConnectAsync();
        }
        else
        {
            RefreshSourceStatus();
        }

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

        if (shotDir is not null)
        {
            await CaptureTourAsync(shotDir);
        }
    }

    /// <summary>启动页来自设置；只接受导航里真实存在的项。</summary>
    private static string StartTag()
    {
        var page = AppServices.Instance.Settings.StartPage;
        return page is "sources" or "records" or "search" or "settings"
            ? page
            : "libraries";
    }

    private bool _syncingSources;

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
        var known = new[] { "libraries", "sources", "records", "search", "settings" };
        if (index < 0 || index + 2 >= args.Length)
        {
            return known;
        }

        var pages = args.Skip(index + 2).Where(known.Contains).ToArray();
        return pages.Length == 0 ? new[] { "libraries" } : pages;
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

        // --delay N：每页再多等 N 秒，用来验证 Hero 自动轮播这类定时行为。
        var extraDelay = int.TryParse(ArgumentAfter("--delay"), out var extra) ? extra : 0;

        // --hover：媒体库页把 Hero 箭头亮出来，检查位置（模拟不了真实鼠标悬停）。
        var previewHover = Environment.GetCommandLineArgs().Contains("--hover");

        foreach (var tag in ScreenshotPages())
        {
            SelectNav(tag);

            // 搜索页第一次要跨库拉索引，媒体库首页要等 Hero 大图，都比别的页慢。
            await Task.Delay((tag == "search" ? 15000 : tag == "libraries" ? 9000 : 5000)
                             + extraDelay * 1000);

            // --edit-source：服务器页打开第一个源的编辑表单。
            if (Environment.GetCommandLineArgs().Contains("--edit-source") &&
                ContentFrame.Content is SourcesPage sourcesPage)
            {
                sourcesPage.EditFirstSourceForShot();
                await Task.Delay(400);
            }

            // --inline-search <关键词>：截图时停在页内搜索结果。
            var inlineQuery = ArgumentAfter("--inline-search");
            if (inlineQuery is not null && ContentFrame.Content is LibrariesPage searchShot)
            {
                searchShot.ShowInlineSearchForShot(inlineQuery);
                await Task.Delay(6000);
            }

            // --favorites：截图时停在「收藏」分段，检查空态和顶栏。
            if (Environment.GetCommandLineArgs().Contains("--favorites") &&
                ContentFrame.Content is LibrariesPage favPage)
            {
                favPage.ShowFavoritesForShot();
                await Task.Delay(600);
            }

            if (previewHover && ContentFrame.Content is LibrariesPage hoverPage)
            {
                hoverPage.PreviewHeroArrows();
                await Task.Delay(400);
            }

            // --scroll <像素>：把服务器首页往下滚，检查横幅下面的分组行。
            if (int.TryParse(ArgumentAfter("--scroll"), out var offset) && offset > 0 &&
                ContentFrame.Content is LibrariesPage scrollPage)
            {
                scrollPage.ScrollOverview(offset);
                await Task.Delay(800);
            }

            UiCapture.Save(this, Path.Combine(dir, tag + ".png"));
        }

        // --browse：再进第一个库的网格，验证库内列表 / 过滤器。
        if (Environment.GetCommandLineArgs().Contains("--browse"))
        {
            Nav.SelectedItem = null;
            ContentFrame.Navigate(new LibrariesPage());
            await Task.Delay(6000);

            if (ContentFrame.Content is LibrariesPage page)
            {
                await page.ShowFirstLibraryAsync();
                await Task.Delay(8000);

                // --browse-cat <all|tv|movie|genre|folder>：切到某个类别再截图。
                if (ArgumentAfter("--browse-cat") is { Length: > 0 } category)
                {
                    page.SelectCategoryForShot(category);
                    await Task.Delay(3000);
                }

                // --browse-sort <added|name|release|rating>：选排序字段。
                if (ArgumentAfter("--browse-sort") is { Length: > 0 } sortField)
                {
                    page.SelectSortForShot(sortField);
                    await Task.Delay(2500);
                }

                // --browse-scroll <像素>：滚到接近底部，验证「自动加载更多」。
                if (int.TryParse(ArgumentAfter("--browse-scroll"), out var browseOffset) &&
                    browseOffset > 0)
                {
                    page.ScrollBrowse(browseOffset);
                    await Task.Delay(2500);
                }

                UiCapture.Save(this, Path.Combine(dir, "library-browse.png"));
            }
        }

        Application.Current.Shutdown();
    }

    /// <summary>从页面里跳到侧栏的某一项，并同步高亮。</summary>
    public void NavigateTo(string tag) => SelectNav(tag);

    private void SelectNav(string tag)
    {
        foreach (var item in Nav.Items.OfType<ListBoxItem>())
        {
            if ((item.Tag as string) == tag)
            {
                // 选中项没变时 SelectionChanged 不触发，得手动导航。
                if (ReferenceEquals(Nav.SelectedItem, item))
                {
                    Navigate(tag);
                }
                else
                {
                    Nav.SelectedItem = item;
                }

                return;
            }
        }

        // 源首页没有菜单项，截图巡检直接开页面。
        if (tag == "libraries")
        {
            Nav.SelectedItem = null;
            Navigate("libraries");
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
        SourceHint.Text = services.IsConnected ? "媒体库已连接" : "在「媒体源」里添加";

        StatusDot.Fill = (System.Windows.Media.Brush)FindResource(
            services.IsConnected ? "AccentBrush" : services.Connections.Count > 0 ? "DangerBrush" : "FaintBrush");

        RefreshSourceNav();
    }

    /// <summary>侧栏的源列表：配置过的都列出来，连上的点亮一点。</summary>
    private void RefreshSourceNav()
    {
        if (SourceNav is null)
        {
            return;
        }

        var services = AppServices.Instance;
        var settings = services.Settings;

        var items = settings.Sources
            .Select(source => new SourceNavItem(
                source.Id,
                source.Name,
                services.Connections.Any(c => c.Id == source.Id && c.Ok)))
            .ToList();

        var selected = settings.LastSourceId;
        if (items.All(i => i.Id != selected))
        {
            // 记的源被删了或从没选过：退到第一个连上的。
            selected = (items.FirstOrDefault(i => i.Ok) ?? items.FirstOrDefault())?.Id;
            if (selected is not null)
            {
                settings.LastSourceId = selected;
                settings.Save();
            }
        }

        _syncingSources = true;
        SourceNav.ItemsSource = items;
        SourceNav.SelectedItem = items.FirstOrDefault(i => i.Id == selected);
        _syncingSources = false;
    }

    /// <summary>清掉服务器列表的选中，不触发切换源。</summary>
    private void ClearSourceSelection()
    {
        if (SourceNav is null || SourceNav.SelectedItem is null)
        {
            return;
        }

        _syncingSources = true;
        SourceNav.SelectedItem = null;
        _syncingSources = false;
    }

    private void OnSourceSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSources || SourceNav.SelectedItem is not SourceNavItem item)
        {
            return;
        }

        OpenSource(item.Id);
    }

    // 点的是已经选中的源时 SelectionChanged 不触发，所以点击也单独接一下。
    private void OnSourceItemClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string id })
        {
            OpenSource(id);
        }
    }

    private void OpenSource(string id)
    {
        var settings = AppServices.Instance.Settings;

        // 已经在看这个源了：也许停在「收藏」或库内网格，回到媒体首页就行。
        if (settings.LastSourceId == id && ContentFrame.Content is LibrariesPage page)
        {
            page.SelectMediaTab();
            return;
        }

        settings.LastSourceId = id;
        settings.Save();

        // 源首页不是导航项，清掉菜单高亮，只留源列表这一项。
        Nav.SelectedItem = null;
        ContentFrame.Navigate(new LibrariesPage());
    }

    private sealed class SourceNavItem
    {
        public SourceNavItem(string id, string name, bool ok)
        {
            Id = id;
            Name = name;
            Ok = ok;
        }

        public string Id { get; }

        public string Name { get; }

        public bool Ok { get; }
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
            // 离开源首页后，下面服务器列表不该还留着选中态。
            if (tag != "libraries")
            {
                ClearSourceSelection();
            }

            Navigate(tag);
        }
    }

    private void Navigate(string tag)
    {
        // 已经在源首页了就别重建：重建会让首页把库列表、每个库、海报全再拉一遍。
        if (tag == "libraries" && ContentFrame.Content is LibrariesPage)
        {
            return;
        }

        Page page = tag switch
        {
            "libraries" => new LibrariesPage(),
            "sources" => new SourcesPage(),
            "records" => new RecordsPage(),
            "search" => new SearchPage(),
            "settings" => new SettingsPage(),
            _ => new LibrariesPage(),
        };

        ContentFrame.Navigate(page);
    }
}
