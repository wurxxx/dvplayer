using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;
using DvPlayer.Controls;
using DvPlayer.Dialogs;
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
        // --window-test：没人能手动点按钮，自检一遍最小化 / 最大化 / 关闭，
        // 结果写到 %TEMP%\dvplayer\window-test.log，供远程核对。
        if (Environment.GetCommandLineArgs().Contains("--window-test"))
        {
            await RunWindowTestAsync();
            return;
        }

        // --dialog-test：自动点一次确认、一次取消，验证深色确认框的返回值。
        if (Environment.GetCommandLineArgs().Contains("--dialog-test"))
        {
            var logPath = Path.Combine(Path.GetTempPath(), "dvplayer", "dialog-test.log");
            Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
            File.WriteAllText(logPath, "");
            void Log(string line) => File.AppendAllText(logPath, line + Environment.NewLine);

            // 确认框是模态的，用 DispatcherTimer 在它的消息循环里点按钮。
            void ClickLater(string name, int delay)
            {
                var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(delay) };
                timer.Tick += (_, _) =>
                {
                    timer.Stop();
                    var dialog = Application.Current.Windows.OfType<ConfirmDialog>().FirstOrDefault();
                    if (dialog?.FindName(name) is System.Windows.Controls.Button button)
                    {
                        button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
                    }
                    else
                    {
                        Log($"找不到 {name}");
                    }
                };
                timer.Start();
            }

            ClickLater("ConfirmButton", 700);
            Log($"点确认 → Ask={ConfirmDialog.Ask(this, "删除服务器", "测试一下", "删除")}");

            ClickLater("CancelButton", 700);
            Log($"点取消 → Ask={ConfirmDialog.Ask(this, "删除服务器", "测试一下", "删除")}");

            Application.Current.Shutdown();
            return;
        }

        // --dialog-shot <目录>：把深色确认框单独渲染一张，检查它和页面是不是一套。
        if (ArgumentAfter("--dialog-shot") is { Length: > 0 } dialogDir)
        {
            var dialog = new ConfirmDialog();
            dialog.Configure("删除服务器",
                "删除服务器「飞牛影视」？\n播放记录与已收藏的进度都还在，\n重新添加这个源就能接上。",
                "删除", danger: true, showCancel: true);
            dialog.Owner = this;
            dialog.Show();
            await Task.Delay(700);

            var origin = dialog.PointToScreen(new Point(0, 0));
            var dpi = VisualTreeHelper.GetDpi(dialog);
            Trace.Write($"dialog bounds {dialog.ActualWidth:0}x{dialog.ActualHeight:0} " +
                        $"at {origin.X / dpi.DpiScaleX:0},{origin.Y / dpi.DpiScaleY:0}");

            UiCapture.Save(dialog, Path.Combine(dialogDir, "confirm.png"));
            dialog.Close();
            Application.Current.Shutdown();
            return;
        }

        // --ui-test <目录>：单独渲染「搜索框 + 深色滚动条」，验证点整块能聚焦、
        // 滚动条不再是系统浅色条。没人能远程点界面，只能靠这个核对。
        if (ArgumentAfter("--ui-test") is { Length: > 0 } uiDir)
        {
            await RunUiTestAsync(uiDir);
            return;
        }

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

        // --playlist <容器 id>：只量选集加载耗时（不起播放器、不占带宽），
        // 用来对比「边播边拼选集」时服务端响应慢多少。
        if (ArgumentAfter("--playlist") is { Length: > 0 } playlistOnly &&
            AppServices.Instance.Core is { } playlistCore)
        {
            var loaded = await Playlists.LoadAsync(playlistCore, playlistOnly);
            Trace.Write($"--playlist items={loaded.Items.Count} title={loaded.Title}");
            Close();
            return;
        }

        // --play-record [序号]：从观看记录续播，验证选集列表真的拼出来了。
        if (ArgumentAfter("--play-record") is { Length: > 0 } recordArg &&
            ArgumentAfter("--play-shot") is { Length: > 0 } recordDir)
        {
            await CaptureRecordAsync(recordArg, recordDir);
            Close();
            return;
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

        // --play-input：真实鼠标事件验证点画面暂停 / 拖窗口 / 改大小。
        if (ArgumentAfter("--play-input") is not null)
        {
            await Task.Delay(9000);
            await player.RunInputTestAsync();
            await Task.Delay(600);
            UiCapture.SaveDesktop(Path.Combine(dir, "desktop-input.png"));
            player.Close();
            return;
        }

        // --play-min：最小化 / 还原，验证浮层不会飘在桌面上。
        if (ArgumentAfter("--play-min") is not null)
        {
            await Task.Delay(9000);
            await player.RunMinimizeTestAsync(dir);
            player.Close();
            return;
        }

        // 打开后先看一眼：控制条应该立即出现（3 秒无操作才会自动隐藏）。
        await Task.Delay(1500);
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop-open.png"));

        // 网络流要一会儿才出画面。
        await Task.Delay(8500);

        // 刚打开、还没碰过任何窗口时，控制条就该在。
        Trace.Write("player bounds (fresh) " + player.DescribeBounds());
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop-early.png"));

        // 回归：最小化主窗口，播放窗是独立窗口，应该继续放着（视频 + 控制条都在）。
        WindowState = WindowState.Minimized;
        await Task.Delay(1500);
        Trace.Write("main minimized, player bounds " + player.DescribeBounds());
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop-main-min.png"));
        WindowState = WindowState.Normal;
        await Task.Delay(1200);

        // 播放窗现在是独立窗口，库拿回前台会把它盖住；巡检要看播放窗，再点回它。
        Activate();
        await Task.Delay(600);
        player.Activate();
        await Task.Delay(800);

        // --play-end：跳到片尾，验证剧集接下一集、电影回到开头（窗口都不关）。
        if (ArgumentAfter("--play-end") is not null)
        {
            player.SkipToEndForShot();
            await Task.Delay(22000);
            Trace.Write("eof state " + player.DescribePlaybackState());
            player.ShowChromeForShot();
            await Task.Delay(600);
            UiCapture.SaveScreen(player, Path.Combine(dir, "play-next.png"));
            UiCapture.SaveDesktop(Path.Combine(dir, "desktop-end.png"));
            player.Close();
            return;
        }

        // --play-pick N：像点右侧选集那样切到第 N 集，验证是从头开始，
        // 而不是接着上一回看到的位置（看完的集会立刻 EOF 跳到下一集）。
        if (int.TryParse(ArgumentAfter("--play-pick"), out var pick) && playlist is { Count: > 0 })
        {
            player.PickEpisodeForShot(pick);
            await Task.Delay(9000);
            Trace.Write("pick state " + player.DescribePlaybackState());
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
    /// <summary>
    /// 续播巡检：拿观看记录里的第 N 条（默认第一条），走和「继续观看」一样的
    /// <see cref="Playlists.PlayRecordAsync"/>，再截整屏。
    /// </summary>
    private async Task CaptureRecordAsync(string arg, string dir)
    {
        Directory.CreateDirectory(dir);

        if (AppServices.Instance.Core is not { } core)
        {
            Trace.Write("--play-record 没有可用的源");
            return;
        }

        var result = await Task.Run(() => core.Records()).ConfigureAwait(true);
        var records = result.Data ?? new List<PlayRecordDto>();
        var index = int.TryParse(arg, out var picked) && picked > 0 ? picked - 1 : 0;
        if (index >= records.Count)
        {
            Trace.Write($"--play-record 记录不足 index={index} count={records.Count}");
            return;
        }

        var record = records[index];
        Trace.Write($"--play-record item={record.ItemId} parent={record.ParentId} " +
                    $"series={record.SeriesTitle} s={record.SeasonNumber} e={record.EpisodeNumber}");

        PlayWindow? player;

        if (Environment.GetCommandLineArgs().Contains("--play-spam"))
        {
            // 连点自检：同时点两次，第二次应该被闸门挡掉，只留一个窗口。
            var first = Playlists.PlayRecordAsync(this, record);
            var second = Playlists.PlayRecordAsync(this, record);
            var opened = await Task.WhenAll(first, second);
            Trace.Write("play spam opened=" +
                        $"{(opened[0] is not null ? 1 : 0) + (opened[1] is not null ? 1 : 0)}");
            player = opened[0] ?? opened[1];
        }
        else
        {
            player = await Playlists.PlayRecordAsync(this, record);
        }

        if (player is null)
        {
            return;
        }

        // 选集是后台补的：--play-wait 秒之后才截，等它到货再验侧栏。
        var waitMs = int.TryParse(ArgumentAfter("--play-wait"), out var waitSeconds) && waitSeconds > 0
            ? waitSeconds * 1000
            : 9000;
        await Task.Delay(waitMs);

        // --play-end：从续播放到片尾，验证真的接上了下一集。
        if (ArgumentAfter("--play-end") is not null)
        {
            player.SkipToEndForShot();
            await Task.Delay(22000);
            Trace.Write("eof state " + player.DescribePlaybackState());
            player.Close();
            return;
        }

        player.ShowChromeForShot();
        await Task.Delay(600);
        Trace.Write($"record player bounds {player.DescribeBounds()}");
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop-record.png"));
        UiCapture.SaveScreen(player, Path.Combine(dir, "play-record.png"));

        // 选集是后台补的，这里渲染一张浮层截图验证侧栏真的补进来了。
        player.ShowEpisodesForShot();
        await Task.Delay(800);
        Trace.Write($"record episodes panel {player.DescribeEpisodesPanel()}");
        player.SetShotBackground(true);
        await Task.Delay(300);
        UiCapture.Save(player, Path.Combine(dir, "play-record-episodes.png"));
        player.Close();
    }

    private static async Task<(List<PlayEpisode> Items, string? Title)?> BuildShotPlaylistAsync()
    {
        var seriesId = ArgumentAfter("--play-series");
        if (seriesId is null || AppServices.Instance.Core is not { } core)
        {
            return null;
        }

        var loaded = await Playlists.LoadAsync(core, seriesId).ConfigureAwait(true);
        return loaded.Items.Count == 0 ? null : loaded;
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

                // --pick-track subtitle:1[,audio:0]：像点媒体信息卡那样切轨，
                // 验证卡片可点、单选、以及和顶部按钮的联动。
                if (ArgumentAfter("--pick-track") is { Length: > 0 } pickTrack &&
                    ContentFrame.Content is SeriesPage pickPage)
                {
                    foreach (var part in pickTrack.Split(',', StringSplitOptions.RemoveEmptyEntries))
                    {
                        var pair = part.Split(':');
                        if (pair.Length == 2 && int.TryParse(pair[1], out var trackIndex))
                        {
                            pickPage.PickTrackForShot(pair[0].Trim().ToLowerInvariant(), trackIndex);
                        }
                    }
                    await Task.Delay(500);
                }

                // --media-scroll <像素>：把媒体信息横向行滚一段，让右边的卡片进画面。
                if (ArgumentAfter("--media-scroll") is { Length: > 0 } mediaScroll &&
                    double.TryParse(mediaScroll, out var mediaOffset) &&
                    ContentFrame.Content is SeriesPage mediaPage)
                {
                    mediaPage.ScrollMediaInfoForShot(mediaOffset);
                    await Task.Delay(700);
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

    // ── 无标题栏窗口 ────────────────────────────────────────────────────────
    // 没有标题栏：内容从窗口最顶上开始，右上角只浮三个
    // 自绘按钮（最小化 / 最大化 / 关闭）。拖动和双击缩放落在最上面一条上，
    // 和系统标题栏的手感一致。

    private const double CaptionDragHeight = 36;

    /// <summary>
    /// 无标题栏靠 WindowChrome：把整块客户区铺满窗口，系统只留 4px 的缩放边。
    /// 这里自己设一遍、不调用 base —— WPF-UI 的实现带 DWM 合成检查，在没有
    /// 桌面合成的会话里会跳过，窗口就退回系统标题栏。
    /// </summary>
    protected override void SetWindowChrome()
    {
        try
        {
            WindowChrome.SetWindowChrome(this, new WindowChrome
            {
                CaptionHeight = 0,
                CornerRadius = default,
                GlassFrameThickness = new Thickness(0.00001),
                ResizeBorderThickness = ResizeMode == ResizeMode.NoResize
                    ? default
                    : new Thickness(4),
                UseAeroCaptionButtons = false,
            });
        }
        catch (COMException)
        {
            // 和 WPF-UI 一致：设不上就算了，至少页面还能用。
        }
    }

    private void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        // 只有窗口最上面一条当标题栏；页面里的点击照常往下走。
        if (e.GetPosition(this).Y > CaptionDragHeight)
        {
            return;
        }

        // 按钮、输入框这些自己处理点击，别被拖动吃掉。
        if (IsInteractive(e.OriginalSource as DependencyObject))
        {
            return;
        }

        if (e.ClickCount == 2)
        {
            ToggleMaximize();
            return;
        }

        if (WindowState == WindowState.Maximized)
        {
            RestoreFromDrag(e);
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // 鼠标已经抬起（快速点击）时 DragMove 会抛，忽略即可。
        }
    }

    /// <summary>最大化状态下拖标题栏：先还原，并让光标留在标题栏上的相对位置。</summary>
    private void RestoreFromDrag(MouseButtonEventArgs e)
    {
        var ratio = e.GetPosition(this).X / Math.Max(1, ActualWidth);
        var restoreWidth = RestoreBounds.Width;
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var screen = PointToScreen(e.GetPosition(this));

        WindowState = WindowState.Normal;
        Left = screen.X / dpi - restoreWidth * ratio;
        Top = Math.Max(0, screen.Y / dpi - CaptionDragHeight / 2);
    }

    private static bool IsInteractive(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is ButtonBase or TextBoxBase or ComboBox or ScrollBar
                or Slider or ListBoxItem or TabItem)
            {
                return true;
            }

            source = VisualTreeHelper.GetParent(source);
        }

        return false;
    }

    private void OnMinimizeClick(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState.Minimized;
    }

    private void OnMaximizeClick(object sender, RoutedEventArgs e) => ToggleMaximize();

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void ToggleMaximize() =>
        WindowState = WindowState == WindowState.Maximized
            ? WindowState.Normal
            : WindowState.Maximized;

    private void OnWindowStateChanged(object sender, EventArgs e)
    {
        if (MaximizeGlyph is null)
        {
            return;
        }

        var maximized = WindowState == WindowState.Maximized;
        MaximizeGlyph.Text = maximized ? "\uE923" : "\uE922";
        MaximizeButton.ToolTip = maximized ? "还原" : "最大化";
    }

    /// <summary>
    /// UI 自检：搜索框整块聚焦 + 深色滚动条，截图和日志写到指定目录。
    private async Task RunUiTestAsync(string dir)
    {
        Directory.CreateDirectory(dir);
        var logPath = Path.Combine(dir, "ui-test.log");
        File.WriteAllText(logPath, "");
        void Log(string line) => File.AppendAllText(logPath, line + Environment.NewLine);

        var window = new Window
        {
            Width = 760,
            Height = 560,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ShowInTaskbar = false,
            Background = new SolidColorBrush(Color.FromRgb(0x14, 0x14, 0x19)),
        };

        var searchBorder = new Border
        {
            Style = (Style)FindResource("SearchBoxBorder"),
            Width = 300,
            Height = 36,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        SearchBoxFocus.SetEnabled(searchBorder, true);

        var grid = new Grid();
        grid.Children.Add(new System.Windows.Controls.TextBlock
        {
            Text = "\uE721",
            Style = (Style)FindResource("SearchBoxIcon"),
        });
        var input = new System.Windows.Controls.TextBox
        {
            Style = (Style)FindResource("SearchBoxInput"),
        };
        grid.Children.Add(input);
        var placeholder = new System.Windows.Controls.TextBlock
        {
            Text = "搜索",
            Style = (Style)FindResource("SearchBoxPlaceholder"),
        };
        grid.Children.Add(placeholder);
        searchBorder.Child = grid;

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Height = 300,
            Margin = new Thickness(0, 18, 0, 0),
        };
        scroll.Content = new Border
        {
            Height = 1200,
            Background = new SolidColorBrush(Color.FromRgb(0x1F, 0x1F, 0x27)),
        };

        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(searchBorder);
        panel.Children.Add(scroll);
        window.Content = panel;

        input.Text = "搜索测试 abc";
        placeholder.Visibility = Visibility.Collapsed;
        window.Show();
        await Task.Delay(600);

        // 点在搜索框的图标 / 内边距位置（事件直接发给 Border，等价于点空白处）。
        searchBorder.RaiseEvent(new MouseButtonEventArgs(
            Mouse.PrimaryDevice, 0, MouseButton.Left)
        {
            RoutedEvent = UIElement.MouseLeftButtonDownEvent,
        });
        await Task.Delay(200);

        Log($"search focus={input.IsFocused}");
        Log($"input text={input.Text}");
        Log($"scroll visible={scroll.ComputedVerticalScrollBarVisibility}");
        UiCapture.Save(window, Path.Combine(dir, "ui-test.png"));

        window.Close();
        Application.Current.Shutdown();
    }

    /// 依次点三个窗口按钮，把状态写进 `%TEMP%\dvplayer\window-test.log`。
    /// 走的是真实的 Click 事件，验证 XAML 里的接线和 WindowState 行为；
    /// 最后点关闭，进程应该直接退出（日志停在「点关闭」）。
    /// </summary>
    private async Task RunWindowTestAsync()
    {
        var path = Path.Combine(Path.GetTempPath(), "dvplayer", "window-test.log");

        void Log(string line)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.AppendAllText(path, line + Environment.NewLine);
            }
            catch
            {
                // 自检写日志失败不影响结论。
            }
        }

        try
        {
            File.Delete(path);
        }
        catch
        {
            // 没有旧日志就算了。
        }

        await Task.Delay(800);
        var chrome = WindowChrome.GetWindowChrome(this);
        Log($"起始 state={WindowState} size={ActualWidth:0}x{ActualHeight:0} 工作区={SystemParameters.WorkArea}");
        Log($"chrome 标题区={chrome?.CaptionHeight} 缩放边={chrome?.ResizeBorderThickness} " +
            $"系统按钮={chrome?.UseAeroCaptionButtons}");

        // 客户区应该约等于整个窗口（只差 4px 缩放边），否则说明还有系统标题栏。
        var normalHwnd = new WindowInteropHelper(this).Handle;
        GetWindowRect(normalHwnd, out var normalWindow);
        GetClientRect(normalHwnd, out var normalClient);
        Log($"普通矩形={normalWindow.Left},{normalWindow.Top} " +
            $"{normalWindow.Right - normalWindow.Left}x{normalWindow.Bottom - normalWindow.Top} " +
            $"客户区={normalClient.Right}x{normalClient.Bottom}");

        MinimizeButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        await Task.Delay(900);
        Log($"点最小化 → state={WindowState}");
        WindowState = WindowState.Normal;
        await Task.Delay(700);

        MaximizeButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        await Task.Delay(900);
        Log($"点最大化 → state={WindowState} size={ActualWidth:0}x{ActualHeight:0} " +
            $"图标={(MaximizeGlyph.Text == "\uE923" ? "还原" : "最大化")} 提示={MaximizeButton.ToolTip}");

        // 最大化时窗口会比工作区大出系统边框的厚度；FluentWindow 的模板里
        // ClientAreaBorder 会用内边距把内容收回工作区。这里把两边都量出来，
        // 确认内容原点落在边距内、右上角的按钮没有被裁到屏幕外。
        var hwnd = new WindowInteropHelper(this).Handle;
        GetWindowRect(hwnd, out var windowRect);
        GetClientRect(hwnd, out var clientRect);
        var area = SystemParameters.WorkArea;
        Log($"最大化矩形={windowRect.Left},{windowRect.Top} " +
            $"{windowRect.Right - windowRect.Left}x{windowRect.Bottom - windowRect.Top} " +
            $"客户区={clientRect.Right}x{clientRect.Bottom} " +
            $"工作区={area.Left:0},{area.Top:0} {area.Width:0}x{area.Height:0}");

        if (Content is FrameworkElement contentRoot)
        {
            var origin = contentRoot.TransformToAncestor(this).Transform(new Point(0, 0));
            Log($"内容原点={origin.X:0},{origin.Y:0} 尺寸={contentRoot.ActualWidth:0}x{contentRoot.ActualHeight:0}");
        }

        // 顺便把最大化时的界面存一张，看看按钮有没有被裁掉。
        UiCapture.Save(this, Path.Combine(Path.GetDirectoryName(path)!, "window-test.png"));

        MaximizeButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        await Task.Delay(700);
        Log($"再点一次 → state={WindowState} " +
            $"图标={(MaximizeGlyph.Text == "\uE923" ? "还原" : "最大化")}");

        Log("点关闭 → 这行之后进程应该直接退出");
        CloseButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        await Task.Delay(1500);
        Log("关闭没生效：进程还在");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Win32Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out Win32Rect rect);

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hwnd, out Win32Rect rect);
}
