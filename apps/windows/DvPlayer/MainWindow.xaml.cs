using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
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

        // 每个源连完都会发一次：侧栏的红绿灯跟着立刻变，不等最慢的源。
        AppServices.Instance.ConnectionChanged += OnConnectionsChanged;
        Closed += (_, _) => AppServices.Instance.ConnectionChanged -= OnConnectionsChanged;
    }

    private void OnConnectionsChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(UpdateSourceNavStatus);

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            await OnLoadedCoreAsync();
        }
        catch (Exception ex)
        {
            // async void 里没人 await：异常直接结束进程，脚本只能看到「没反应」。
            // 写清楚原因再退出，至少日志里能查到。
            Trace.Write("startup failed: " + ex);
            Application.Current.Shutdown(1);
        }
    }

    private async Task OnLoadedCoreAsync()
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

        // 先定当前源，服务器首页才知道该拉哪个源；顺便把左下角版本显示出来。
        RefreshSourceStatus();

        Trace.Write($"startup page tag={start} setting={AppServices.Instance.Settings.StartPage}");

        // 启动页都是真实菜单项：选中哪一项，右边就是哪一页。
        SelectNav(start);

        // 截图巡检时不受「启动时自动连接」开关影响，否则回归会拍到空页面。
        if (AppServices.Instance.Settings.AutoConnect || shotDir is not null)
        {
            await TryAutoConnectAsync();
        }
        else
        {
            RefreshSourceStatus();
        }

        // --subtitle-test <itemId>：验证详情页/播放器共用的字幕自动选择结果。
        if (ArgumentAfter("--subtitle-test") is { Length: > 0 } subtitleItem &&
            AppServices.Instance.Core is { } subtitleCore)
        {
            var info = subtitleCore.MediaInfo(subtitleItem);
            if (info.Ok && info.Data is { } data)
            {
                var index = TrackPrefs.ResolveSubtitle(subtitleItem, data.Subtitles);
                var name = index >= 0 && index < data.Subtitles.Count
                    ? TrackPrefs.SubtitleName(data.Subtitles[index])
                    : "关闭";
                Trace.Write($"subtitle test item={subtitleItem} subs={data.Subtitles.Count} " +
                            $"index={index} name={name}");
            }
            else
            {
                Trace.Write($"subtitle test item={subtitleItem} failed={info.Error}");
            }

            Close();
            return;
        }

        // --search-test <关键词>：打印聚合搜索的条目 / 来源，以及详情页「资源」
        // 列表的行数。同一部片在同一个源里有多条（剧 + 季）时应该只算一个来源。
        if (ArgumentAfter("--search-test") is { Length: > 0 } searchQuery &&
            AppServices.Instance.Core is { } searchCore)
        {
            var result = await Task.Run(() => searchCore.Search(searchQuery));
            var found = result.Data?.Items ?? new List<MediaItemDto>();
            Trace.Write($"search test query={searchQuery} ok={result.Ok} " +
                        $"n={found.Count} err={result.Error}");
            for (var index = 0; index < found.Count; index++)
            {
                var item = found[index];
                var sources = item.Sources ?? new List<ItemSourceDto>();
                Trace.Write($"search item {item.Id} | {item.Title} | {item.Kind} | " +
                            $"sources={sources.Count} [" +
                            string.Join(" | ", sources.Select(source =>
                                $"{source.SourceName}#{source.SourceId}:{source.ItemId}")) +
                            "]");

                // 「资源」列表每次都要重新搜一遍，只查前几条，别把 80 条都跑一遍。
                if (index < 5)
                {
                    var rows = searchCore.ItemSources(item.Id);
                    var rowText = string.Join(" | ", (rows.Data ?? new List<ItemSourceDto>())
                        .Select(source => $"{source.SourceName}#{source.SourceId}:{source.ItemId}"));
                    Trace.Write($"search rows {item.Id} ok={rows.Ok} " +
                                $"n={rows.Data?.Count ?? 0} [{rowText}]");
                }
            }

            Close();
            return;
        }

        // --drag-test：模拟「指针停在同一格」两次，验证不会 A/B 来回换。
        if (Environment.GetCommandLineArgs().Contains("--drag-test"))
        {
            SourceNav.UpdateLayout();
            RunDragStabilityTest();
            (ContentFrame.Content as SourcesPage)?.RunDragStabilityTest();
            Close();
            return;
        }

        // --reorder-test：直接调用拖动排序的落位逻辑，验证设置顺序真的写回。
        if (Environment.GetCommandLineArgs().Contains("--reorder-test"))
        {
            var sources = AppServices.Instance.Settings.Sources;
            var before = string.Join(" | ", sources.Select(s => s.Name));
            if (sources.Count >= 3)
            {
                MoveSourceOrder(sources[0].Id, sources[2].Id);
                (ContentFrame.Content as SourcesPage)?.ReloadOrder();
            }
            var after = string.Join(" | ", sources.Select(s => s.Name));
            Trace.Write($"reorder test before: {before} / after: {after}");
            Close();
            return;
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

        // --disc-list <iso> --disc-shot <目录>：只截原盘标题选择框。
        if (ArgumentAfter("--disc-list") is { Length: > 0 } discListIso &&
            ArgumentAfter("--disc-shot") is { Length: > 0 } discListDir)
        {
            await CaptureDiscListAsync(discListIso, discListDir);
            return;
        }

        // --play-iso <iso>：直接播蓝光原盘；--play-iso-title N 选标题。
        if (ArgumentAfter("--play-iso") is { Length: > 0 } isoPath)
        {
            var isoTitle = int.TryParse(ArgumentAfter("--play-iso-title"), out var wanted)
                ? wanted
                : (int?)null;
            var discStart = double.TryParse(ArgumentAfter("--play-start"), out var discAt)
                ? Math.Max(0, discAt)
                : (double?)null;

            if (ArgumentAfter("--play-check") is { Length: > 0 } isoCheckDir)
            {
                var discPlayer = await OpenDiscAsync(isoPath, isoTitle, discStart, silent: true);
                if (discPlayer is not null)
                {
                    await RunPlayCheckAsync(null, isoCheckDir, discPlayer);
                }

                Close();
                return;
            }

            if (ArgumentAfter("--play-shot") is { Length: > 0 } isoShotDir)
            {
                await CaptureDiscAsync(isoPath, isoTitle, discStart, isoShotDir);
                Close();
                return;
            }

            var discWindow = await OpenDiscAsync(isoPath, isoTitle, discStart, silent: true);
            if (int.TryParse(ArgumentAfter("--play-seconds"), out var discSeconds) &&
                discSeconds > 0)
            {
                await Task.Delay(TimeSpan.FromSeconds(discSeconds));
                discWindow?.Close();
                Close();
            }

            return;
        }

        // 脚本化验证用：--play <itemId>，可再加 --play-seconds N 自动退出。
        var playId = ArgumentAfter("--play");
        if (playId is not null)
        {
            // --play-fail-shot <目录>：验证「打开失败不关窗」——窗内错误面板 + 重试。
            if (ArgumentAfter("--play-fail-shot") is { Length: > 0 } failDir)
            {
                Directory.CreateDirectory(failDir);
                var failed = await PlayWindow.OpenAsync(this, playId);
                Trace.Write($"fail shot open player={failed is not null} " +
                            $"alive={failed?.IsAlive}");
                await Task.Delay(1200);
                if (failed is { IsAlive: true })
                {
                    UiCapture.Save(failed, Path.Combine(failDir, "error.png"));
                    failed.RetryForShot();
                    await Task.Delay(3000);
                    Trace.Write($"fail shot retry alive={failed.IsAlive}");
                    UiCapture.Save(failed, Path.Combine(failDir, "error-retry.png"));
                }

                failed?.Close();
                Close();
                return;
            }

            // --play-cover-shot <目录>：抓打开遮罩（慢网络下不能透出桌面）。1.5 秒一张，
            // 12 秒再一张，31 秒第三张，验证「一直没出画面时黑底始终不透明」。
            if (ArgumentAfter("--play-cover-shot") is { Length: > 0 } coverDir)
            {
                Directory.CreateDirectory(coverDir);
                var coverPlayer = await PlayWindow.OpenAsync(this, playId);
                Trace.Write($"cover shot open player={coverPlayer is not null}");
                await Task.Delay(1500);
                Trace.Write($"cover shot 1 player={coverPlayer is not null} alive={coverPlayer?.IsAlive}");
                if (coverPlayer is { IsAlive: true })
                {
                    Trace.Write("cover shot cursor " + coverPlayer.ProbeCursorForShot());
                    UiCapture.SaveDesktop(Path.Combine(coverDir, "opening-desktop.png"));
                    UiCapture.Save(coverPlayer, Path.Combine(coverDir, "opening.png"));

                    // 打开遮罩上双击：应当最大化（不是全屏），顶栏和右上角三按钮还在，
                    // 指针仍旧是箭头；再走一次同一条路径还原成窗口态。
                    Trace.Write("cover shot dblclick max " + coverPlayer.ProbeOpeningDoubleClick());
                    await Task.Delay(700);
                    UiCapture.SaveDesktop(Path.Combine(coverDir, "opening-max-desktop.png"));
                    UiCapture.Save(coverPlayer, Path.Combine(coverDir, "opening-max.png"));
                    Trace.Write("cover shot dblclick restore " + coverPlayer.ProbeOpeningDoubleClick());
                    await Task.Delay(400);
                }

                await Task.Delay(10500);
                Trace.Write($"cover shot 12 player={coverPlayer is not null} alive={coverPlayer?.IsAlive}");
                if (coverPlayer is { IsAlive: true })
                {
                    UiCapture.SaveDesktop(Path.Combine(coverDir, "opening-12s-desktop.png"));
                    UiCapture.Save(coverPlayer, Path.Combine(coverDir, "opening-12s.png"));
                }

                await Task.Delay(19000);
                Trace.Write($"cover shot 31 player={coverPlayer is not null} alive={coverPlayer?.IsAlive}");
                if (coverPlayer is { IsAlive: true })
                {
                    UiCapture.Save(coverPlayer, Path.Combine(coverDir, "opening-31s.png"));
                }

                coverPlayer?.Close();
                Close();
                return;
            }

            // --play-shot <目录>：把播放页的控制条 / 选集 / 菜单各截一张。
            if (ArgumentAfter("--play-shot") is { Length: > 0 } playDir)
            {
                await CapturePlayerAsync(playId, playDir);
                Close();
                return;
            }

            // --play-check <目录>：五项功能自检，结果写 player.log。
            if (ArgumentAfter("--play-check") is { Length: > 0 } checkDir)
            {
                await RunPlayCheckAsync(playId, checkDir);
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

        // --play-bounds WxH：把播放窗摆成窄窗口（竖屏短剧的 400 来像素宽），
        // 验证右侧面板会跟着收窄，不会左边被切掉。
        if (ArgumentAfter("--play-bounds")?.Split('x') is { Length: 2 } bounds &&
            double.TryParse(bounds[0], out var boundsWidth) &&
            double.TryParse(bounds[1], out var boundsHeight))
        {
            player.SetBoundsForShot(boundsWidth, boundsHeight);
            await Task.Delay(400);
        }

        Trace.Write("player bounds " + player.DescribeBounds());

        // 真实画面：从桌面抓，才能同时看到视频和浮层（RTB 只有浮层）。
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop.png"));
        UiCapture.SaveScreen(player, Path.Combine(dir, "play-screen.png"));
        player.SetShotBackground(true);
        UiCapture.Save(player, Path.Combine(dir, "play.png"));

        // 播放器自己可能带着列表：剧集的选集，或原盘的标题（--play 直接点 ISO）。
        if (player.EpisodeCount > 0)
        {
            player.ShowEpisodesForShot();
            await Task.Delay(900);

            Trace.Write("episodes panel " + player.DescribeEpisodesPanel());

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

        if (player.OpenSubtitleMenuForShot() is { } subtitleMenu)
        {
            await Task.Delay(700);
            UiCapture.Save(subtitleMenu, Path.Combine(dir, "play-subtitle.png"));
            subtitleMenu.IsOpen = false;
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

    /// <summary>读原盘标题并开播放窗（媒体库里的 ISO 条目也走这条）。</summary>
    private Task<PlayWindow?> OpenDiscAsync(string isoPath, int? titleNumber = null,
        double? startOverride = null, bool silent = false)
        => PlayWindow.OpenDiscAsync(this, isoPath, titleNumber, startOverride, null, silent);

    /// <summary>自检：读标题列表，打开播放器右侧的「标题」面板截一张。</summary>
    private async Task CaptureDiscListAsync(string isoPath, string dir)
    {
        Directory.CreateDirectory(dir);

        var (probe, error) = await BluRayDisc.ProbeAsync(isoPath);
        Trace.Write($"disc list iso={Path.GetFileName(isoPath)} " +
                    $"titles={probe?.Titles.Count ?? 0} err={error ?? "-"}");
        if (probe is null)
        {
            Application.Current.Shutdown();
            return;
        }

        Trace.Write("disc list titles " + string.Join("; ", probe.Titles.Select(title =>
            $"{(probe.IsFeature(title) ? "feature" : "extra")}:{title.TitleNumber}" +
            $"/{title.Mpls}/{title.DurationLabel}")));

        var player = await OpenDiscAsync(isoPath, null, null, silent: true);
        if (player is not null)
        {
            await Task.Delay(12000);
            player.ShowChromeForShot();
            player.ShowEpisodesForShot();
            await Task.Delay(900);
            Trace.Write("disc list panel " + player.DescribeEpisodesPanel());
            UiCapture.Save(player, Path.Combine(dir, "disc-titles.png"));
            player.Close();
        }

        Application.Current.Shutdown();
    }

    /// <summary>自检：直接播原盘某个标题，截视频 + 浮层。</summary>
    private async Task CaptureDiscAsync(string isoPath, int? titleNumber, double? startOverride,
        string dir)
    {
        Directory.CreateDirectory(dir);

        var player = await OpenDiscAsync(isoPath, titleNumber, startOverride, silent: true);
        if (player is null)
        {
            return;
        }

        // 原盘要先读盘头、找 title，起画面比网络流慢一点。
        await Task.Delay(14000);
        player.ShowChromeForShot();
        await Task.Delay(800);
        Trace.Write("disc state " + player.DescribeFeatureState());

        UiCapture.SaveDesktop(Path.Combine(dir, "disc-desktop.png"));
        UiCapture.SaveScreen(player, Path.Combine(dir, "disc-screen.png"));

        player.SetShotBackground(true);
        await Task.Delay(500);
        UiCapture.Save(player, Path.Combine(dir, "disc-overlay.png"));
        player.SetShotBackground(false);

        // 右侧「标题」面板：和选集是同一套面板，正片 / 花絮都在里面。
        player.ShowEpisodesForShot();
        await Task.Delay(800);
        Trace.Write($"disc panel {player.DescribeEpisodesPanel()} title={player.CurrentTitle}");
        UiCapture.Save(player, Path.Combine(dir, "disc-titles.png"));

        // 切到第二个标题，确认原盘内部换标题不查核心、直接换 bd:// 地址。
        if (player.EpisodeCount > 1)
        {
            player.PickEpisodeForShot(1);
            await Task.Delay(12000);
            Trace.Write($"disc switched {player.DescribeFeatureState()} " +
                        $"title={player.CurrentTitle}");
            UiCapture.SaveScreen(player, Path.Combine(dir, "disc-title-2.png"));
        }

        player.Close();
    }

    /// <summary>
    /// --play-check <目录> --play-features a,b,c：五项功能的远程自检。
    ///
    /// 片头 / 片尾标记要在开窗前写好，起播跳过才走得到；其余项目在出画后逐个执行，
    /// 状态和结果都写进 player.log（远程只能看日志）。
    /// </summary>
    private async Task RunPlayCheckAsync(string? itemId, string dir, PlayWindow? opened = null)
    {
        Directory.CreateDirectory(dir);

        var shot = await BuildShotPlaylistAsync().ConfigureAwait(true);
        var playlist = shot?.Items;
        var seriesTitle = shot?.Title;
        var features = (ArgumentAfter("--play-features") ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries);

        // `--play first`：落在 --play-series 的第一集上。
        if (itemId is "first" or "-")
        {
            if (playlist is not { Count: > 0 })
            {
                Trace.Write("--play first 需要 --play-series");
                return;
            }

            itemId = playlist[0].Id;
        }

        var markerKey = opened?.ItemId ??
                        (string.IsNullOrWhiteSpace(seriesTitle) ? itemId ?? "" : seriesTitle!);
        var preset = new SkipMarker();
        foreach (var feature in features)
        {
            // 只切前两个冒号：aspect:16:9 的值本身带冒号。
            var parts = feature.Split(':', 3);
            if (parts.Length == 3 && parts[0] == "mark" && double.TryParse(parts[2], out var at))
            {
                if (parts[1] == "intro")
                {
                    preset.IntroEnd = at;
                }
                else if (parts[1] == "outro")
                {
                    preset.OutroStart = at;
                }
            }
        }

        if (!preset.IsEmpty)
        {
            SkipMarkers.Save(markerKey, preset);
            Trace.Write($"features preset key={markerKey} intro={preset.IntroEnd} outro={preset.OutroStart}");
        }

        // --play-start 0：自检时强制从头上放，别接上次看过的位置。
        double? startOverride = null;
        if (double.TryParse(ArgumentAfter("--play-start"), out var startAt))
        {
            startOverride = Math.Max(0, startAt);
        }

        var player = opened ?? await PlayWindow.OpenAsync(this, itemId ?? "", startOverride,
            playlist, seriesTitle, silentFailure: true);
        if (player is null)
        {
            Trace.Write("features: 播放窗没打开，跳过自检");
            return;
        }

        await Task.Delay(7000);
        Trace.Write("features state " + player.DescribeFeatureState());

        foreach (var feature in features)
        {
            var parts = feature.Split(':', 2);
            switch (parts[0])
            {
                case "aspect" when parts.Length > 1:
                    player.SetAspectForShot(parts[1]);
                    break;

                case "sleep" when parts.Length > 1 && double.TryParse(parts[1], out var seconds):
                    player.SetSleepSecondsForShot(seconds);
                    break;

                case "danmaku":
                    player.TestDanmakuForShot();
                    break;

                case "subsearch":
                    player.SearchSubtitlesForShot();
                    break;

                case "audiotoggle":
                    Trace.Write("audio toggle " + player.ToggleAudioOutputForShot());
                    await Task.Delay(800);
                    break;

                case "frame":
                    // 原盘 / 网络片都能用：mpv 自己解码出的一帧，锁屏也能验。
                    Trace.Write("frame requested " +
                                (player.SaveVideoFrameForShot(
                                    Path.Combine(dir, "video-frame.png")) ? "ok" : "no ipc"));
                    await Task.Delay(1500);
                    break;

                case "audioout":
                    player.ShowChromeForShot();
                    await Task.Delay(1200);
                    if (player.OpenAudioOutputForShot() is { } audioOutMenu)
                    {
                        await Task.Delay(700);
                        UiCapture.Save(audioOutMenu, Path.Combine(dir, "play-audioout.png"));
                        audioOutMenu.IsOpen = false;
                    }
                    break;

                case "submenu":
                    player.ShowChromeForShot();
                    await Task.Delay(600);
                    if (player.OpenSubtitleMenuForShot() is { } subtitleMenu)
                    {
                        await Task.Delay(700);
                        UiCapture.Save(subtitleMenu, Path.Combine(dir, "play-submenu.png"));
                        subtitleMenu.IsOpen = false;
                        await Task.Delay(300);
                    }
                    break;

                case "overlay":
                    player.ShowChromeForShot();
                    player.SetShotBackground(true);
                    await Task.Delay(600);
                    UiCapture.Save(player, Path.Combine(dir, "play-overlay.png"));
                    player.SetShotBackground(false);
                    break;

                case "subtitle":
                    await player.SubtitleRoundTripForShot();
                    break;

                case "skipoutro":
                    player.SkipOutroForShot();
                    break;

                case "menu":
                    if (player.OpenMoreMenuForShot() is { } menu)
                    {
                        await Task.Delay(500);
                        UiCapture.Save(menu, Path.Combine(dir, "play-more.png"));
                        menu.IsOpen = false;
                        await Task.Delay(300);
                    }

                    break;

                case "aspectmenu":
                    if (player.OpenAspectMenuForShot() is { } aspectMenu)
                    {
                        await Task.Delay(500);
                        UiCapture.Save(aspectMenu, Path.Combine(dir, "play-aspect.png"));
                        aspectMenu.IsOpen = false;
                        await Task.Delay(300);
                    }

                    break;

                case "sleepmenu":
                    if (player.OpenSleepMenuForShot() is { } sleepMenu)
                    {
                        await Task.Delay(500);
                        UiCapture.Save(sleepMenu, Path.Combine(dir, "play-sleep.png"));
                        sleepMenu.IsOpen = false;
                        await Task.Delay(300);
                    }

                    break;
            }

            await Task.Delay(500);
        }

        await Task.Delay(2000);
        Trace.Write("features state " + player.DescribeFeatureState());

        // 定时关闭会把窗口自己关掉：等它，别提前收摊。
        var until = DateTime.UtcNow.AddSeconds(12);
        while (player.IsAlive && DateTime.UtcNow < until)
        {
            await Task.Delay(500);
        }

        Trace.Write($"features closed={!player.IsAlive} state={player.DescribeFeatureState()}");
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

    private static async Task<(List<PlayEpisode> Items, string? Title, bool Complete)?> BuildShotPlaylistAsync()
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
        // 老配置里的 "libraries"（服务器首页）现在统一落到「服务器」页：
        // 菜单选中哪一项，右边就该是哪一页，不能选中「服务器」却显示某个源的首页。
        return page is "records" or "search" or "settings" ? page : "sources";
    }

    private bool _syncingSources;

    private static string? ScreenshotDir() => ArgumentAfter("--screenshot");

    private static string? ArgumentAfter(string flag)
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, flag);
        if (index < 0 || index + 1 >= args.Length)
        {
            return null;
        }

        // 下一个参数是另一个开关（如 `--screenshot --window 1600x900`）时，
        // 不能把它当成取值，否则截图会写到名字叫 `--window` 的目录里。
        var value = args[index + 1];
        return value.StartsWith("--", StringComparison.Ordinal) ? null : value;
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

                // --range <from>：点快捷选集段（1-30 / 31-60 …），确认滚到那一段。
                if (int.TryParse(ArgumentAfter("--range"), out var rangeFrom) &&
                    ContentFrame.Content is SeriesPage rangePage)
                {
                    await rangePage.ClickRangeForShotAsync(rangeFrom);
                    await Task.Delay(900);
                    UiCapture.Save(this, Path.Combine(dir, "series-range.png"));
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

            // --settings-tab play：设置页直接停在「播放」分组（核对缓冲大小这种项）。
            if (tag == "settings" && ArgumentAfter("--settings-tab") is { Length: > 0 } settingsTab &&
                ContentFrame.Content is SettingsPage tabbedSettings)
            {
                tabbedSettings.ShowTabForShot(settingsTab);
                await Task.Delay(600);
            }

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
                    // 等真正的收藏请求回来再截：以前只等 600ms，慢源会截到空白。
                    await favPage.ShowFavoritesForShotAsync().ConfigureAwait(true);
                    await Task.Delay(600);
                }
                else if (ContentFrame.Content is RecordsPage recordsPage)
                {
                    recordsPage.ShowFavoritesForShot();
                    await Task.Delay(3000);
                }
            }

            // --records-general-fav：停在「通用」，再让收藏数据晚到一次。
            // 回归：收藏的竖版海报不能盖到「继续观看」那一行上。
            if (Environment.GetCommandLineArgs().Contains("--records-general-fav") &&
                ContentFrame.Content is RecordsPage generalFav)
            {
                generalFav.ShowGeneralForShot();
                await Task.Delay(1200);
                if (await generalFav.FavoriteFirstForShotAsync() is { Length: > 0 } favId)
                {
                    await Task.Delay(1200);
                    UiCapture.Save(this, Path.Combine(dir, "records-general-fav.png"));
                    await generalFav.UnfavoriteForShotAsync(favId);
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

    /// <summary>
    /// 点的是已经高亮的菜单项时 SelectionChanged 不触发，单独补一次导航。
    /// 启动后「服务器」是亮的但页面在源首页，点它应该回到服务器列表。
    /// 在 MouseDown 里判断：此时选中项还没被 ListBox 改掉。
    /// </summary>
    private void OnNavPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (ItemsControl.ContainerFromElement(Nav, e.OriginalSource as DependencyObject)
                is not ListBoxItem clicked ||
            !ReferenceEquals(clicked, Nav.SelectedItem) ||
            clicked.Tag is not string tag)
        {
            return;
        }

        // 已经在这个页面就别重建（记录 / 搜索每次重建都要重新拉数据）。
        var alreadyOnPage = tag switch
        {
            "sources" => ContentFrame.Content is SourcesPage,
            "records" => ContentFrame.Content is RecordsPage,
            "search" => ContentFrame.Content is SearchPage,
            "settings" => ContentFrame.Content is SettingsPage,
            _ => false,
        };
        if (!alreadyOnPage)
        {
            Navigate(tag);
        }
    }

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

        // 左下角只放版本；连不上的原因在「服务器」页看，这里只记一条日志。
        if (!ok && error is not null)
        {
            Trace.Write("auto connect failed: " + error);
        }
    }

    /// <summary>连接状态变化后刷新左下角版本和服务器列表的状态点。</summary>
    public void RefreshSourceStatus()
    {
        var services = AppServices.Instance;
        VersionText.Text = "版本 " + AppServices.AppVersion;
        VersionText.ToolTip = services.Connections.Count > 0 && !services.IsConnected
            ? "所有服务器都没有连上"
            // 侧栏只放应用版本；核心版本放悬停提示，装错旧 dll 时能对出来。
            : "共享核心 " + (services.CoreVersion ?? "未加载");

        RefreshSourceNav();
    }

    /// <summary>
    /// 侧栏的源列表：配置过的都列出来，连上的点亮一点。
    /// <paramref name="selectId"/> 用于「用户刚点了这个源」：这时导航可能还没落地，
    /// 不能用 ContentFrame.Content 判断，否则会把刚选中的源清掉
    /// （只留下鼠标悬停色，鼠标一移开就像没选中）。
    /// </summary>
    private void RefreshSourceNav(string? selectId = null)
    {
        if (SourceNav is null)
        {
            return;
        }

        var services = AppServices.Instance;
        var settings = services.Settings;

        var items = settings.Sources
            .Select(source =>
            {
                var connection = services.Connections.FirstOrDefault(c => c.Id == source.Id);
                return new SourceNavItem(
                    source.Id,
                    source.Name,
                    connection?.Ok == true,
                    connection?.Connecting == true,
                    SourceIcons.Pack(source.Kind));
            })
            .ToList();

        var selected = selectId ?? settings.LastSourceId;
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
        // 停在源首页时点亮这个源；在服务器 / 记录 / 搜索页时这里不会有选中态
        // （清掉选中由 OnNavSelectionChanged / OpenSource 负责）。
        var onSourceHome = selectId is not null || ContentFrame?.Content is LibrariesPage;
        SourceNav.SelectedItem = onSourceHome
            ? items.FirstOrDefault(i => i.Id == selected)
            : null;
        _syncingSources = false;
    }

    /// <summary>
    /// 逐源刷状态点：只改现有项的 Ok / Pending，不重建列表，
    /// 拖动排序时也不会被打断。源增删导致结构变了才整表重建。
    /// </summary>
    private void UpdateSourceNavStatus()
    {
        if (SourceNav?.ItemsSource is not List<SourceNavItem> items)
        {
            RefreshSourceNav();
            return;
        }

        var sources = AppServices.Instance.Settings.Sources;
        if (items.Count != sources.Count ||
            items.Where((item, i) => item.Id != sources[i].Id).Any())
        {
            RefreshSourceNav();
            return;
        }

        var connections = AppServices.Instance.Connections;
        foreach (var item in items)
        {
            var connection = connections.FirstOrDefault(c => c.Id == item.Id);
            item.Ok = connection?.Ok == true;
            item.Pending = connection?.Connecting == true;
        }

        Trace.Write("nav status " + string.Join("; ", items.Select(i =>
            i.Name + "=" + (i.Pending ? "connecting" : i.Ok ? "ok" : "fail"))));
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

        // 按下鼠标时 ListBox 会立刻选中：这时候还不能进源，
        // 不然一按下去拖动就开始加载页面，拖拽和点击也会打架。
        // 记下来，等松开时确认不是拖动再打开。
        if (_navPointerDown)
        {
            _navPendingOpenId = item.Id;
            return;
        }

        OpenSource(item.Id);
    }

    /// <summary>左侧服务器列表拖动排序：拖动经过就实时让位，松手不再等待。</summary>
    private Point _sourceNavDragStart;
    private SourceNavItem? _sourceNavDragItem;
    private bool _sourceNavDragging;
    private FrameworkElement? _navDragVisual;
    /// <summary>鼠标按下但还没松开：这段时间不打开源。</summary>
    private bool _navPointerDown;
    /// <summary>按下时指针下的源，松开且没拖动就打开它。</summary>
    private string? _navPendingOpenId;
    /// <summary>
    /// 拖动开始时各槽位的纵向范围（按列表位置记录，不随动画变化）。
    /// 用槽位算落点，就不会因为列表正在滑动而命中旧位置、来回跳。
    /// </summary>
    private List<(double Top, double Bottom)>? _navSlots;

    private void OnSourceNavPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        _sourceNavDragStart = e.GetPosition(SourceNav);
        _sourceNavDragItem = (e.OriginalSource as FrameworkElement)?.DataContext as SourceNavItem;
        _sourceNavDragging = false;
        _navPointerDown = _sourceNavDragItem is not null;
        _navPendingOpenId = _sourceNavDragItem?.Id;

        if (_sourceNavDragItem is null)
        {
            return;
        }

        _navSlots = CaptureNavSlots();

        // ListBox 在按下时就会选中并触发 SelectionChanged（进而想打开源）。
        // 拖动本来就不该改选中项，这里直接吃掉按下事件，松手时再判断是点还是拖。
        SourceNav.CaptureMouse();
        e.Handled = true;
        Trace.Write("navdrag down " + _sourceNavDragItem.Id);
    }

    private List<(double Top, double Bottom)> CaptureNavSlots()
    {
        var slots = new List<(double Top, double Bottom)>();
        for (var i = 0; i < SourceNav.Items.Count; i++)
        {
            if (SourceNav.ItemContainerGenerator.ContainerFromIndex(i) is not FrameworkElement element)
            {
                continue;
            }

            var top = element.TranslatePoint(new Point(0, 0), SourceNav).Y;
            slots.Add((top, top + element.ActualHeight));
        }

        return slots;
    }

    private void OnSourceNavPreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _sourceNavDragItem is null)
        {
            return;
        }

        var position = e.GetPosition(SourceNav);
        if (!_sourceNavDragging &&
            Math.Abs(position.X - _sourceNavDragStart.X) < 8 &&
            Math.Abs(position.Y - _sourceNavDragStart.Y) < 8)
        {
            return;
        }

        // 一进入拖动就压暗原项，明确「在拖这一项」。
        if (!_sourceNavDragging)
        {
            _sourceNavDragging = true;
            Cursor = Cursors.SizeAll;
            _navDragVisual = NavContainer(_sourceNavDragItem.Id);
            if (_navDragVisual is not null)
            {
                _navDragVisual.Opacity = 0.5;
            }
        }

        // 落点按「固定槽位」算：鼠标在哪一格就换到那一格。换位后
        // 鼠标仍在同一格，命中的正好是拖着的这一项，自然不会再换回来。
        if (_navSlots is not { Count: > 0 } slots)
        {
            return;
        }

        if (NavTargetAt(position.Y) is { } targetId && targetId != _sourceNavDragItem.Id)
        {
            MoveSourceOrder(_sourceNavDragItem.Id, targetId);
        }
    }

    /// <summary>这个纵坐标落在哪一格，那一格现在是哪个源。</summary>
    private string? NavTargetAt(double y)
    {
        if (_navSlots is not { Count: > 0 } slots)
        {
            return null;
        }

        var nearest = -1;
        var best = double.MaxValue;
        for (var i = 0; i < slots.Count; i++)
        {
            var center = (slots[i].Top + slots[i].Bottom) / 2;
            var distance = Math.Abs(y - center);
            if (distance < best)
            {
                best = distance;
                nearest = i;
            }
        }

        var sources = AppServices.Instance.Settings.Sources;
        return nearest >= 0 && nearest < sources.Count ? sources[nearest].Id : null;
    }

    /// <summary>自检：指针停在第三格不动，换过去之后应该认出「就是自己」，不会来回跳。</summary>
    private void RunDragStabilityTest()
    {
        if (SourceNav.Items.Count < 3)
        {
            Trace.Write("drag test nav skipped");
            return;
        }

        var before = string.Join(" | ", AppServices.Instance.Settings.Sources.Select(s => s.Name));
        _sourceNavDragItem = SourceNav.Items[0] as SourceNavItem;
        _navSlots = CaptureNavSlots();
        if (_navSlots.Count < 3 || _sourceNavDragItem is null)
        {
            Trace.Write("drag test nav no slots");
            _navSlots = null;
            return;
        }

        var y = (_navSlots[2].Top + _navSlots[2].Bottom) / 2;
        var first = NavTargetAt(y);
        if (first is not null)
        {
            MoveSourceOrder(_sourceNavDragItem.Id, first);
        }

        SourceNav.UpdateLayout();
        var second = NavTargetAt(y);
        var after = string.Join(" | ", AppServices.Instance.Settings.Sources.Select(s => s.Name));
        Trace.Write($"drag test nav before={before} first={first} second={second} " +
                    $"drag={_sourceNavDragItem.Id} order={after} " +
                    $"stable={second == _sourceNavDragItem.Id}");
        _navSlots = null;
        _sourceNavDragItem = null;
    }

    private static void RestoreNavVisual(FrameworkElement? element)
    {
        if (element is null)
        {
            return;
        }

        element.Opacity = 1;
        element.RenderTransform = Transform.Identity;
    }

    private FrameworkElement? NavContainer(string id)
    {
        for (var i = 0; i < SourceNav.Items.Count; i++)
        {
            if (SourceNav.ItemContainerGenerator.ContainerFromIndex(i) is FrameworkElement element &&
                element.DataContext is SourceNavItem item && item.Id == id)
            {
                return element;
            }
        }

        return null;
    }

    private Dictionary<string, Point> CaptureNavPositions()
    {
        var map = new Dictionary<string, Point>();
        for (var i = 0; i < SourceNav.Items.Count; i++)
        {
            if (SourceNav.ItemContainerGenerator.ContainerFromIndex(i) is FrameworkElement element &&
                element.DataContext is SourceNavItem item)
            {
                map[item.Id] = element.TranslatePoint(new Point(0, 0), SourceNav);
            }
        }

        return map;
    }

    private void AnimateNavReorder(Dictionary<string, Point> before)
    {
        SourceNav.UpdateLayout();
        var moved = 0;
        for (var i = 0; i < SourceNav.Items.Count; i++)
        {
            if (SourceNav.ItemContainerGenerator.ContainerFromIndex(i) is not FrameworkElement element ||
                element.DataContext is not SourceNavItem item ||
                !before.TryGetValue(item.Id, out var old))
            {
                continue;
            }

            var now = element.TranslatePoint(new Point(0, 0), SourceNav);
            var dy = old.Y - now.Y;
            if (Math.Abs(dy) < 0.5)
            {
                continue;
            }

            var transform = new TranslateTransform(0, dy);
            element.RenderTransform = transform;
            transform.BeginAnimation(TranslateTransform.YProperty,
                new DoubleAnimation(0, TimeSpan.FromMilliseconds(240))
                {
                    EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                });
            moved++;
        }

        if (moved > 0)
        {
            Trace.Write($"nav flip items={moved}");
        }
    }

    private void OnSourceNavPreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        var dragging = _sourceNavDragging;
        var source = _sourceNavDragItem;
        var pendingOpen = _navPendingOpenId;
        _sourceNavDragging = false;
        _sourceNavDragItem = null;
        _navPointerDown = false;
        _navPendingOpenId = null;
        _navSlots = null;
        Cursor = Cursors.Arrow;
        RestoreNavVisual(_navDragVisual);
        _navDragVisual = null;

        if (SourceNav.IsMouseCaptured)
        {
            SourceNav.ReleaseMouseCapture();
        }

        // 点一下（没拖动）：打开这个源。
        if (!dragging)
        {
            if (pendingOpen is not null)
            {
                OpenSource(pendingOpen);
            }

            return;
        }

        e.Handled = true;

        // 拖动过程中每跨一格只改内存顺序，松手时再落盘一次：
        // 以前每跨一格都同步 Save（现在是 DPAPI 加密 + 写盘），拖一下写十几次。
        AppServices.Instance.Settings.Save();
        Trace.Write("navdrag up from=" + (source?.Id ?? "null"));
    }

    /// <summary>鼠标捕获丢了（拖出窗口松手）：收拾一下视觉状态，别一直卡在半透明。</summary>
    private void OnSourceNavLostMouseCapture(object sender, MouseEventArgs e)
    {
        // 列表换位会重建项容器，偶尔把鼠标捕获弄丢：还按着就继续抓着。
        if (_navPointerDown && Mouse.LeftButton == MouseButtonState.Pressed)
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (_navPointerDown && !SourceNav.IsMouseCaptured)
                {
                    SourceNav.CaptureMouse();
                }
            });
            return;
        }

        // 拖动中被系统抢走捕获（Alt+Tab / 弹窗）：顺序只在内存里改过，
        // 这里也落盘一次，别让这次拖动白做。
        if (_sourceNavDragging)
        {
            AppServices.Instance.Settings.Save();
            Trace.Write("navdrag lost capture, saved");
        }

        _sourceNavDragging = false;
        _sourceNavDragItem = null;
        _navPointerDown = false;
        _navPendingOpenId = null;
        _navSlots = null;
        Cursor = Cursors.Arrow;
        RestoreNavVisual(_navDragVisual);
        _navDragVisual = null;
    }

    /// <summary>把 dragId 挪到 targetId 的位置，顺序写回设置，两边列表一起刷新。</summary>
    private void MoveSourceOrder(string dragId, string targetId)
    {
        var sources = AppServices.Instance.Settings.Sources;
        var from = sources.FindIndex(s => s.Id == dragId);
        var to = sources.FindIndex(s => s.Id == targetId);
        if (from < 0 || to < 0 || from == to)
        {
            return;
        }

        var before = CaptureNavPositions();
        var item = sources[from];
        sources.RemoveAt(from);
        sources.Insert(to, item);
        Trace.Write("nav order " + string.Join(" | ", sources.Select(x => x.Name)));

        RefreshSourceStatus();
        (ContentFrame.Content as SourcesPage)?.ReloadOrder();
        Dispatcher.BeginInvoke(() =>
        {
            AnimateNavReorder(before);

            // 刷新会重建列表项，拖动中的那一项要重新压暗。
            if (_sourceNavDragging && _sourceNavDragItem is { } dragged)
            {
                _navDragVisual = NavContainer(dragged.Id);
                if (_navDragVisual is not null)
                {
                    _navDragVisual.Opacity = 0.5;
                }
            }
        }, DispatcherPriority.Loaded);
    }

    /// <summary>给设置页用：加完本地源直接跳到它的首页。</summary>
    public void OpenSourceById(string id) => OpenSource(id);

    private void OpenSource(string id)
    {
        var settings = AppServices.Instance.Settings;

        // 已经在看这个源了：也许停在「收藏」或库内网格，回到媒体首页就行。
        if (settings.LastSourceId == id && ContentFrame.Content is LibrariesPage page)
        {
            page.SelectMediaTab();
            // 点了已经打开的源：选中态也要补上，别只在鼠标悬停时好看。
            RefreshSourceNav(id);
            return;
        }

        settings.LastSourceId = id;
        settings.Save();
        Trace.Write("open source id=" + id);

        // 源首页不是导航项：清掉菜单高亮，侧栏只留这个源点亮。
        // 先换页面再刷新侧栏：RefreshSourceNav 靠当前页是不是源首页来决定高亮。
        Nav.SelectedItem = null;
        ContentFrame.Navigate(new LibrariesPage());
        // 导航是异步落地的：这里直接点名要高亮哪个源，别等 Content 更新。
        RefreshSourceNav(id);
    }

    private sealed class SourceNavItem : INotifyPropertyChanged
    {
        private bool _ok;
        private bool _pending;

        public SourceNavItem(string id, string name, bool ok, bool pending, string iconPath)
        {
            Id = id;
            Name = name;
            _ok = ok;
            _pending = pending;
            IconPath = iconPath;
        }

        public string Id { get; }

        public string Name { get; }

        /// <summary>连上了：状态点点亮。逐源回报时只改这一项，不重建列表。</summary>
        public bool Ok
        {
            get => _ok;
            set
            {
                if (_ok == value)
                {
                    return;
                }

                _ok = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Ok)));
            }
        }

        /// <summary>还在建连：状态点用灰色。</summary>
        public bool Pending
        {
            get => _pending;
            set
            {
                if (_pending == value)
                {
                    return;
                }

                _pending = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Pending)));
            }
        }

        /// <summary>侧栏名字左边的服务器图标（pack URI）。</summary>
        public string IconPath { get; }

        public event PropertyChangedEventHandler? PropertyChanged;
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

        Trace.Write("nav " + tag);
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
