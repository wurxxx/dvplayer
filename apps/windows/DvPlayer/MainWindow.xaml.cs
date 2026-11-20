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
            // --play-shot <目录>：把播放页的控制条 / 选集 / 菜单各截一张。
            if (ArgumentAfter("--play-shot") is { Length: > 0 } playDir)
            {
                await CapturePlayerAsync(playId, playDir);
                Close();
                return;
            }

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

    /// <summary>
    /// 播放页截图：等 mpv 出画面后分别截控制条、选集面板、音频菜单和「更多」菜单。
    /// 菜单是独立窗口，得单独渲染。
    /// </summary>
    private async Task CapturePlayerAsync(string itemId, string dir)
    {
        Directory.CreateDirectory(dir);

        var shot = await BuildShotPlaylistAsync().ConfigureAwait(true);
        var playlist = shot?.Items;
        var seriesTitle = shot?.Title;

        // `--play first` 让截图落在 --play-series 的第一集上，省得另外记一个集 id。
        if (itemId is "first" or "-")
        {
            if (playlist is not { Count: > 0 })
            {
                Trace.Write("--play first 需要 --play-series");
                return;
            }

            itemId = playlist[0].Id;
        }

        var player = await PlayWindow.OpenAsync(this, itemId, null, playlist, seriesTitle);
        if (player is null)
        {
            return;
        }

        // 网络流要一会儿才出画面。
        await Task.Delay(10000);

        // 回归：把主窗口点回前台，视频层不能沉到它后面。
        Activate();
        await Task.Delay(1200);

        // --play-end：跳到片尾，验证播完自动接下一集。
        if (ArgumentAfter("--play-end") is not null)
        {
            player.SkipToEndForShot();
            await Task.Delay(22000);
            player.ShowChromeForShot();
            await Task.Delay(600);
            UiCapture.SaveScreen(player, Path.Combine(dir, "play-next.png"));
            player.Close();
            return;
        }

        player.ShowChromeForShot();
        await Task.Delay(700);
        Trace.Write("player bounds " + player.DescribeBounds());

        // 真实画面：从桌面抓，才能同时看到视频和浮层（RTB 只有浮层）。
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop.png"));
        UiCapture.SaveScreen(player, Path.Combine(dir, "play-screen.png"));
        player.SetShotBackground(true);
        UiCapture.Save(player, Path.Combine(dir, "play.png"));

        if (playlist is { Count: > 0 })
        {
            player.ShowEpisodesForShot();
            await Task.Delay(900);

            // 透明底要等分层窗口重画一帧，立刻抓会拿到上一帧（全黑）。
            player.SetShotBackground(false);
            await Task.Delay(500);
            UiCapture.SaveScreen(player, Path.Combine(dir, "play-episodes-screen.png"));

            player.SetShotBackground(true);
            await Task.Delay(300);
            UiCapture.Save(player, Path.Combine(dir, "play-episodes.png"));
            player.ShowEpisodesForShot();
            await Task.Delay(300);
        }

        if (player.OpenAudioMenuForShot() is { } audioMenu)
        {
            await Task.Delay(700);
            UiCapture.Save(audioMenu, Path.Combine(dir, "play-audio.png"));
            audioMenu.IsOpen = false;
            await Task.Delay(300);
        }

        if (player.OpenMoreMenuForShot() is { } moreMenu)
        {
            await Task.Delay(700);
            UiCapture.Save(moreMenu, Path.Combine(dir, "play-more.png"));
            moreMenu.IsOpen = false;
            await Task.Delay(300);
        }

        player.ShowMediaInfoForShot();
        await Task.Delay(600);
        UiCapture.Save(player, Path.Combine(dir, "play-info.png"));

        player.Close();
    }

    /// <summary>--play-series <剧 id>：拼一份选集列表 + 剧名，给播放页截图用。</summary>
    private static async Task<(List<PlayEpisode> Items, string? Title)?> BuildShotPlaylistAsync()
    {
        var seriesId = ArgumentAfter("--play-series");
        if (seriesId is null || AppServices.Instance.Core is not { } core)
        {
            return null;
        }

        var result = await Task.Run(() => core.Children(seriesId, 1, 200)).ConfigureAwait(true);
        var items = (result.Data?.Items ?? new List<MediaItemDto>()).ToList();

        // 剧集的直接子项是「季」，要再下一层才是集。
        if (items.Count > 0 &&
            (items[0].Kind is "season" or "Season" || items[0].SeasonNumber is not null))
        {
            var season = items.FirstOrDefault(item => item.SeasonNumber is > 0) ?? items[0];
            var episodes = await Task.Run(() => core.Children(season.Id, 1, 500)).ConfigureAwait(true);
            items = episodes.Data?.Items ?? new List<MediaItemDto>();
        }

        items = items.OrderBy(item => item.EpisodeNumber ?? 0).ToList();

        var detail = await Task.Run(() => core.ItemDetail(seriesId)).ConfigureAwait(true);
        var seriesTitle = detail.Ok ? MediaText.Clean(detail.Data?.Title) : null;

        var rows = items
            .Select((item, index) => new PlayEpisode(
                item.Id,
                item.EpisodeNumber is { } number ? $"S01E{number:00}" : $"E{index + 1:00}",
                string.Join(" · ", new[]
                    {
                        item.Resolution,
                        item.RuntimeSeconds is { } runtime ? $"{runtime / 60}:{runtime % 60:00}" : null,
                    }
                    .Where(part => !string.IsNullOrWhiteSpace(part))),
                item.PosterPath,
                MediaText.Clean(item.Title)))
            .ToList();

        return (rows, seriesTitle);
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
        // --window <宽>x<高>：换窗口尺寸再截图，用来验证自适应网格。
        if (ArgumentAfter("--window")?.Split('x') is { Length: 2 } size &&
            double.TryParse(size[0], out var windowWidth) &&
            double.TryParse(size[1], out var windowHeight))
        {
            WindowState = WindowState.Normal;
            Left = 0;
            Top = 0;
            Width = Math.Max(MinWidth, windowWidth);
            Height = Math.Max(MinHeight, windowHeight);
            UpdateLayout();
            await Task.Delay(600);
        }

        // --series <id>[,<id>...]：额外截详情页，用来验证剧集 / 未刮削目录两种布局。
        var seriesIds = ArgumentAfter("--series")?
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        // `--series first`：从库里挑一部真正有集的条目，省得手抄 guid。
        if (seriesIds is ["first"] && AppServices.Instance.Core is { } firstCore)
        {
            var libs = await Task.Run(firstCore.Libraries).ConfigureAwait(true);
            string? picked = null;

            foreach (var lib in libs.Data ?? new List<MediaLibraryDto>())
            {
                var items = await Task.Run(() => firstCore.Items(lib.Id, 1, 40, new ListQuery()))
                    .ConfigureAwait(true);

                // 目录里可能空着（只有标题没有文件），挨个点进去看一下。
                var candidates = (items.Data?.Items ?? new List<MediaItemDto>())
                    .Where(it => it.Kind is "series" or "folder")
                    .Take(8);

                foreach (var candidate in candidates)
                {
                    var kids = await Task.Run(() => firstCore.Children(candidate.Id, 1, 5))
                        .ConfigureAwait(true);
                    if (kids.Ok && kids.Data?.Items.Count > 0)
                    {
                        picked = candidate.Id;
                        break;
                    }
                }

                if (picked is not null)
                {
                    break;
                }
            }

            seriesIds = picked is null ? null : new[] { picked };
        }

        if (seriesIds is not null)
        {
            var season = int.TryParse(ArgumentAfter("--series-season"), out var n) ? n - 1 : 0;

            for (var i = 0; i < seriesIds.Length; i++)
            {
                ContentFrame.Navigate(new SeriesPage(seriesIds[i], season));
                await Task.Delay(6000);

                if (ContentFrame.Content is SeriesPage scrollShot &&
                    int.TryParse(ArgumentAfter("--series-scroll"), out var seriesOffset))
                {
                    scrollShot.ScrollByForShot(seriesOffset);
                    await Task.Delay(600);
                }

                if (Environment.GetCommandLineArgs().Contains("--arrow-click") &&
                    ContentFrame.Content is SeriesPage arrowShot)
                {
                    arrowShot.ScrollEpisodeRowForShot();
                    await Task.Delay(600);
                }

                if (ContentFrame.Content is SeriesPage arrowsPage &&
                    Environment.GetCommandLineArgs().Contains("--row-arrows"))
                {
                    arrowsPage.ShowRowArrowsForShot();
                    await Task.Delay(400);
                }

                if (Environment.GetCommandLineArgs().Contains("--season-menu") &&
                    ContentFrame.Content is SeriesPage seasonShot &&
                    seasonShot.OpenSeasonMenuForShot() is { } seasonMenu)
                {
                    await Task.Delay(700);
                    UiCapture.Save(seasonMenu, Path.Combine(dir, "series-season-menu.png"));
                    seasonMenu.IsOpen = false;
                    await Task.Delay(300);
                }

                if (ContentFrame.Content is SeriesPage seriesPage &&
                    Environment.GetCommandLineArgs().Contains("--detail-bottom"))
                {
                    seriesPage.ScrollToMediaInfoForShot();
                    await Task.Delay(1200);
                }

                var name = seriesIds.Length == 1 ? "series.png" : $"series-{i + 1}.png";
                UiCapture.Save(this, Path.Combine(dir, name));

                // --person-first：点第一个演员进作品页。
                var personIndex = int.TryParse(ArgumentAfter("--person-index"), out var pi) ? pi : 0;
                if (Environment.GetCommandLineArgs().Contains("--person-first") &&
                    ContentFrame.Content is SeriesPage castPage &&
                    castPage.FirstPersonForShot(personIndex) is { } person)
                {
                    ContentFrame.Navigate(new PersonPage(person.Id, person.Name));
                    await Task.Delay(9000);
                    UiCapture.Save(this, Path.Combine(dir, "person.png"));
                }

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
            if (Environment.GetCommandLineArgs().Contains("--favorites"))
            {
                if (ContentFrame.Content is LibrariesPage favPage)
                {
                    favPage.ShowFavoritesForShot();
                    await Task.Delay(600);
                }
                else if (ContentFrame.Content is RecordsPage recordsPage)
                {
                    recordsPage.ShowFavoritesForShot();
                    await Task.Delay(3000);
                }
            }

            // --menu-records：记录页「观看」第一张卡片的右键菜单单独渲染。
            if (Environment.GetCommandLineArgs().Contains("--menu-records") &&
                ContentFrame.Content is RecordsPage menuRecords)
            {
                menuRecords.ShowWatchForShot();
                await Task.Delay(2500);
                if (menuRecords.OpenFirstWatchMenuForShot() is { } watchMenu)
                {
                    await Task.Delay(700);
                    UiCapture.Save(watchMenu, Path.Combine(dir, "records-watch-menu.png"));
                    watchMenu.IsOpen = false;
                    await Task.Delay(300);
                }
            }

            // --menu-fav：临时收藏一条，截「收藏」页和它的卡片菜单，再撤回。
            if (Environment.GetCommandLineArgs().Contains("--menu-fav") &&
                ContentFrame.Content is RecordsPage favShot)
            {
                favShot.ShowFavoritesForShot();
                await Task.Delay(1500);
                if (await favShot.FavoriteFirstForShotAsync() is { Length: > 0 } favId)
                {
                    await Task.Delay(1500);
                    UiCapture.Save(this, Path.Combine(dir, "records-favorites.png"));
                    if (favShot.OpenFirstFavoriteMenuForShot() is { } favMenu)
                    {
                        await Task.Delay(700);
                        UiCapture.Save(favMenu, Path.Combine(dir, "records-favorite-menu.png"));
                        favMenu.IsOpen = false;
                        await Task.Delay(300);
                    }

                    await favShot.UnfavoriteForShotAsync(favId);
                }
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
                // --menu-continue：首页「继续观看」卡片的右键菜单。
                if (Environment.GetCommandLineArgs().Contains("--menu-continue") &&
                    page.OpenFirstContinueMenu() is { } continueMenu)
                {
                    await Task.Delay(700);
                    UiCapture.Save(continueMenu, Path.Combine(dir, "continue-menu.png"));
                    continueMenu.IsOpen = false;
                    await Task.Delay(300);
                }

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

                // --menu：把第一张卡片的右键菜单单独渲染成 PNG。
                if (Environment.GetCommandLineArgs().Contains("--menu"))
                {
                    if (page.OpenFirstCardMenu() is { } menu)
                    {
                        await Task.Delay(700);
                        UiCapture.Save(menu, Path.Combine(dir, "card-menu.png"));

                        // --menu-click：点第一项（添加到收藏夹），验证 Click 能拿到卡片 id，
                        // 截完整窗口让状态行的提示入镜，然后把收藏恢复。
                        if (Environment.GetCommandLineArgs().Contains("--menu-click") &&
                            menu.Items.OfType<System.Windows.Controls.MenuItem>().FirstOrDefault() is { } first)
                        {
                            var id = (menu.PlacementTarget as FrameworkElement)?.Tag as string;
                            first.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.MenuItem.ClickEvent));
                            await Task.Delay(3200);
                            UiCapture.Save(this, Path.Combine(dir, "menu-click.png"));

                            if (id is not null && AppServices.Instance.Core is { } core)
                            {
                                await Task.Run(() => core.SetFavorite(id, false));
                            }
                        }

                        menu.IsOpen = false;
                        await Task.Delay(300);
                    }
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
