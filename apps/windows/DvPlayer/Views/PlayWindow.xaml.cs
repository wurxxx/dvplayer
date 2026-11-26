using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using DvPlayer.Dialogs;
using DvPlayer.Player;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>播放页右侧「选集」里的一集。由详情页拼好传进来，播放器不查库。</summary>
public sealed record PlayEpisode(
    string Id,
    string Badge,
    string Meta,
    string? PosterPath,
    string? Title = null);

/// <summary>
/// 播放窗口：逐像素透明的浮层控制条，视频在下层的
/// <see cref="PlayerSurfaceWindow"/> 里。
///
/// 为什么要分两个窗口：WPF 的 <see cref="MpvHost"/> 是 HwndHost，原生子窗口
/// 永远压在同一个窗口的 WPF 内容上面，控制条画在自己窗口里根本看不见
/// （airspace）。所以视频沉底，这个窗口只画浮层，两者保持同一矩形。
///
/// 点画面暂停、双击全屏、滚轮调音量都在这一层处理，键盘焦点也在这里。
/// </summary>
public partial class PlayWindow : Window
{
    /// <summary>每隔几秒回写一次进度。</summary>
    private const int ReportEverySeconds = 10;

    private double? _startSeconds;
    private readonly IMpvEngine _mpv = MpvBackend.Create();

    private readonly DispatcherTimer _ticker = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    /// <summary>
    /// 拖窗口时别指望鼠标事件：窗口会跟着鼠标跑，跨窗口的移动/抬起容易丢。
    /// 改成每 15ms 直接读光标和左键状态，拖动和改大小都稳。
    /// </summary>
    private readonly DispatcherTimer _dragTimer = new() { Interval = TimeSpan.FromMilliseconds(15) };

    private readonly List<PlayEpisode> _playlist;
    private string? _seriesTitle;

    private IntPtr _hwnd;
    private bool _started;
    private bool _closed;
    /// <summary>关窗信号：详情页等它完成再刷新，否则刷新发生在起播那一刻。</summary>
    private readonly TaskCompletionSource _closedSignal =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    /// <summary>切集的代次：后点的那一次赢，先发出的慢请求回来时直接丢弃。</summary>
    private int _switchSeq;
    /// <summary>错误面板点「重试」正在跑：别连点重复解析 / 重复起 mpv。</summary>
    private bool _retrying;
    private IMpvControl? _ipc;
    private int _session;

    private string _itemId;
    private PlaySourceDto _current;

    /// <summary>蓝光原盘：进度存本地、不查媒体信息、不拼选集，mpv 要带 --bluray-device。</summary>
    private readonly bool _isLocalDisc;
    private readonly string? _discIsoPath;
    /// <summary>原盘的标题表：右侧「选集」面板里逐个标题切换。</summary>
    private readonly IReadOnlyList<BluRayTitle> _discTitles;
    private readonly string? _discDisplayName;

    /// <summary>从媒体库点开的本地原盘：条目在核心里，进度要回写核心。</summary>
    private readonly string? _coreItemId;

    private MediaInfoDto? _mediaInfo;
    /// <summary>媒体信息请求已经结束（成功与否），字幕自动选择不用再等它。</summary>
    private bool _mediaInfoLoaded;
    /// <summary>已经记录过的选中字幕，避免每次 track-list 都刷一行日志。</summary>
    private int _loggedSubtitle = -1;
    private readonly List<MpvTrack> _audioTracks = new();
    private readonly List<MpvTrack> _subtitleTracks = new();
    /// <summary>音轨 / 字幕各自套用一次。字幕轨常常比音轨晚到，不能合并成一个标志。</summary>
    private bool _audioPrefsApplied;
    private bool _subtitlePrefsApplied;

    private double _position;
    private double _duration;
    /// <summary>demuxer 缓存到的位置（秒）；没有缓存信息时等于当前位置。</summary>
    private double _bufferedPosition;

    /// <summary>mpv 报的 DV profile（0 = 不是 DV）与输出传递函数（pq / hlg / bt.1886）。</summary>
    private int _dvProfile;
    /// <summary>P7 的增强层类型："fel" / "mel"；还没探到就只标 DV P7。</summary>
    private string? _dvElType;
    private bool _doviProbeStarted;
    /// <summary>按条目缓存 FEL / MEL：切回来不再重复读码流。</summary>
    private static readonly Dictionary<string, string> DoviCache = new();
    private string _transfer = "";
    /// <summary>mpv 报的视频编码；原盘没有服务端媒体信息，chips 靠它。</summary>
    private string _videoCodec = "";
    private double _videoFps;
    private double _videoBitrate;

    // —— 音频输出 / HDR 直通 ——
    private List<(string Name, string Description)> _audioDevices = new();
    private string _audioDevice = "";
    private bool _audioPassthrough;
    private bool _hdrPassthrough;
    /// <summary>HDR → SDR 的亮度参考（nits）；0 = 自动（跟随系统）。</summary>
    private int _hdrPeakNits;

    /// <summary>本次起播的续播点与起播时刻：用来认出「一开就播完」的假片尾。</summary>
    private double _launchStart;
    /// <summary>首帧判定基准：起播点；片头跳过后改到跳到的位置。</summary>
    private double _openingBase;
    private DateTime _launchAt = DateTime.UtcNow;
    private bool _seeking;
    private bool _volumeDragging;
    private bool _paused;
    /// <summary>当前是否已阻止关屏 / 睡眠。只在状态变化时操作系统 API。</summary>
    private bool _sleepBlocked;
    private bool _eof;
    private int _sinceReport;
    private bool _chromeVisible = true;

    /// <summary>首帧已经到了：控制条这时才允许出现。打开 / 切集期间黑底盖着。</summary>
    private bool _ready;

    /// <summary>
    /// 起播时 mpv 是暂停的（`--pause=yes`），等首帧到了再放开：
    /// 音频比首帧早约 0.5 秒，直接播就成了「声音先出、画面晚一秒」。
    /// </summary>
    private static readonly bool PauseUntilFirstFrame =
        Environment.GetEnvironmentVariable("DVPLAYER_MPV_HEADLESS") != "1";

    /// <summary>这一轮起播的暂停还没放开（首帧 / 超时 / 用户操作三选一）。</summary>
    private bool _openingPaused;
    private DispatcherTimer? _openingGate;

    /// <summary>
    /// 巡检用：假装首帧一直没来（`DVPLAYER_OPENING_HOLD=1`）。
    /// 慢网络挡不了，靠这个验证遮罩会一直不透明。
    /// </summary>
    private static readonly bool OpeningHold =
        Environment.GetEnvironmentVariable("DVPLAYER_OPENING_HOLD") == "1";

    /// <summary>巡检用：出画后强制显示「正在缓冲…」状态（`DVPLAYER_BUFFERING_HOLD=1`）。</summary>
    private static readonly bool BufferingHold =
        Environment.GetEnvironmentVariable("DVPLAYER_BUFFERING_HOLD") == "1";

    /// <summary>mpv 在等缓存（`paused-for-cache`）。出画后在播放窗中间显示一个小状态。</summary>
    private bool _buffering;
    private CancellationTokenSource? _bufferingCts;
    private bool _hardwareDecode = true;
    private bool _muted;
    private double _speed = 1;

    // —— 画面比例 / 定时关闭 / 片头片尾 / 弹幕 / 在线字幕 ——
    private PlayerAspect _aspect = PlayerAspect.Fit;
    private bool _compactChrome;
    private double _videoAspect;
    private int _videoWidth;
    private int _videoHeight;
    private bool _fitApplied;
    private double _fittedAspect;
    private SkipMarker _markers = new();
    private string _markerKey = "";
    private DateTime? _sleepDeadline;
    private bool _sleepAtEof;
    private double? _pendingIntroSkip;
    private string? _danmakuFile;
    private int _danmakuCount;
    private bool _danmakuEnabled;
    private int _danmakuBoundTrack = -1;
    private int _danmakuTrackId = -1;
    private int _sidBeforeDanmaku;
    private CancellationTokenSource? _danmakuCts;
    private bool _danmakuNoticeShown;
    private readonly List<SubtitleResult> _subtitleResults = new();
    private bool _subtitleSearching;
    private CancellationTokenSource? _subtitleCts;

    /// <summary>视频层，跟这个窗口保持同一矩形。</summary>
    private PlayerSurfaceWindow? _surface;

    private bool _fullscreen;
    private bool _maximized;
    private Rect _windowedBounds;
    private Rect _maximizedFrom;
    private Window? _mainWindow;
    private bool _windowPlaced;

    private Point _pressPoint;
    private bool _pressInTopBar;
    private bool _dragMoved;

    /// <summary>手动拖动 / 改大小的状态（分层窗口用不了系统的非客户区行为）。</summary>
    private DragKind _drag = DragKind.None;
    private Point _dragOrigin;
    private Rect _dragBounds;
    private const double TopBarHeight = 48;

    private enum DragKind
    {
        None,
        Move,
        Left,
        Right,
        Top,
        Bottom,
        TopLeft,
        TopRight,
        BottomLeft,
        BottomRight,
    }

    /// <summary>双击里的第一次点击已经切过暂停，双击时要还原。</summary>
    private bool _clickToggledPause;

    public PlayWindow(
        PlaySourceDto source,
        double? startSeconds = null,
        List<PlayEpisode>? playlist = null,
        string? seriesTitle = null,
        bool localDisc = false,
        string? discIsoPath = null,
        string? coreItemId = null,
        IReadOnlyList<BluRayTitle>? discTitles = null,
        string? discDisplayName = null)
    {
        _current = source;
        _startSeconds = startSeconds;
        _playlist = playlist ?? new List<PlayEpisode>();
        _seriesTitle = seriesTitle;
        _itemId = source.ItemId;
        _isLocalDisc = localDisc;
        _discIsoPath = discIsoPath;
        _coreItemId = coreItemId;
        _discTitles = discTitles ?? Array.Empty<BluRayTitle>();
        _discDisplayName = discDisplayName;

        var settings = AppServices.Instance.Settings;
        _aspect = PlayerAspectExtensions.Parse(settings.VideoAspect);
        _danmakuEnabled = settings.DanmakuEnabled ?? false;
        _audioPassthrough = settings.AudioPassthrough;
        _hdrPassthrough = settings.HdrPassthrough;
        _hdrPeakNits = settings.HdrPeakNits;
        _audioDevice = settings.AudioDevice ?? "";
        ResetMarkerKey();

        InitializeComponent();

        ApplySourceToUi(source);
        SyncDanmakuButton();
        DurationText.Text = Format(source.DurationSeconds);

        _surface = new PlayerSurfaceWindow();
        _surface.Host.HostReady += OnHostReady;
        Loaded += OnLoaded;
        Closing += OnClosing;
        // 详情页要等播放窗口真的关掉再刷新（见 SeriesPage.RefreshAfterPlaybackAsync）。
        Closed += (_, _) => _closedSignal.TrySetResult();

        // 进度条 / 音量条的点按只能挂在根节点上：点在滑块的模板 Border 上时，
        // 挂在 Slider 自己身上的预览事件收不到（MouseLeftButtonDown 是按元素重抛的）。
        Root.PreviewMouseDown += OnSliderPreviewMouseDown;
        Root.PreviewMouseMove += OnSliderPreviewMouseMove;
        Root.PreviewMouseUp += OnSliderPreviewMouseUp;
        // 鼠标捕获被系统抢走（Alt+Tab / 弹窗）时收不到 MouseUp：
        // 按「松手」收尾，否则 _seeking / _volumeDragging 一直为 true，
        // 控制条永远不自动隐藏、进度条也不再跟播放走。
        Root.AddHandler(
            Mouse.LostMouseCaptureEvent,
            new MouseEventHandler(OnSliderLostCapture),
            handledEventsToo: true);

        _ticker.Tick += OnTick;
        _hideTimer.Tick += OnHideTick;
        _dragTimer.Tick += OnDragTick;
        _ticker.Start();
        ResetHideTimer();

        RenderPlaylist();
        ShowOpeningCover();
    }

    /// <summary>命令行参数：`--flag value`。</summary>
    private static string? ArgAfter(string flag)
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, flag);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    /// <summary>开窗闸门：同一时刻只允许一次。</summary>
    private static int _openGate;

    /// <summary>上一次开窗成功的时刻，用来吞掉连点里的后几下。</summary>
    private static DateTime _lastOpenAt = DateTime.MinValue;

    /// <summary>
    /// 打开播放窗口。窗口先出来（带「正在打开…」），再去解析播放源：
    /// 取地址慢的时候用户也能马上看到反馈，不会以为没点上而连点开出一堆播放器。
    /// 失败时关掉窗口，在主窗口提示，不抛异常。
    /// </summary>
    /// <param name="startSeconds">0 = 重头看；null = 按服务器给的续播点。</param>
    /// <param name="playlist">剧集的选集列表；电影传 null（可以之后再补）。</param>
    /// <param name="hintTitle">播放源还没解析出来时，加载页先显示的名字。</param>
    public static async Task<PlayWindow?> OpenAsync(
        Window? owner,
        string itemId,
        double? startSeconds = null,
        List<PlayEpisode>? playlist = null,
        string? seriesTitle = null,
        string? hintTitle = null,
        bool silentFailure = false)
    {
        // 连点保护：正在开的时候只接一次；刚开完的 800ms 也当连点。
        if (Interlocked.CompareExchange(ref _openGate, 1, 0) != 0 ||
            DateTime.UtcNow - _lastOpenAt < TimeSpan.FromMilliseconds(800))
        {
            Trace.Write($"play open ignored item={itemId}");
            return null;
        }

        var clock = System.Diagnostics.Stopwatch.StartNew();
        Trace.Write($"play open start item={itemId}");

        PlayWindow? window = null;
        var shown = false;
        try
        {
            window = new PlayWindow(Placeholder(itemId), startSeconds, playlist, seriesTitle);
            window._started = true; // 还是占位源，OnLoaded 先别启 mpv

            var hint = hintTitle ?? window.DisplayTitle(window._current);
            if (IsRealTitle(hint))
            {
                window.LoadingTitle.Text = hint;
            }

            // 淡入：浮层是透明窗口，硬出现会像一块悬空的控制条。
            // 要在 AttachSurface 之前置 0：那里会先把浮层 Show 出来摆位置。
            window.Opacity = 0;
            window.AttachSurface(owner);
            window.Show();
            shown = true;
            window.BeginAnimation(OpacityProperty, new DoubleAnimation(
                1, TimeSpan.FromMilliseconds(180))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
            });
            Trace.Write($"play open shown item={itemId} ms={clock.ElapsedMilliseconds}");

            // 截图巡检：`--play-opening-shot <png>` 在窗口刚出现、还没出画时从桌面抓一张，
            // 确认打开阶段是不透明黑底，而不是透出桌面。
            if (ArgAfter("--play-opening-shot") is { Length: > 0 } openingShot)
            {
                _ = window.Dispatcher.BeginInvoke(async () =>
                {
                    await Task.Delay(150);
                    // 渲染浮层自己：无头会话里桌面截图是白的，看不出黑底。
                    Services.UiCapture.Save(window, openingShot, flattenOnBlack: true);
                });
            }

            var (source, error) = await Playback.ResolveAsync(itemId).ConfigureAwait(true);
            Trace.Write($"play open resolved item={itemId} ok={source is not null} " +
                        $"ms={clock.ElapsedMilliseconds}");
            if (source is null)
            {
                // 不关窗：黑底上直接写原因，用户可以点「重试」再取一次地址。
                // 真的不想留（后台补选集之类）才走 silentFailure。
                if (silentFailure)
                {
                    var failed = window;
                    window = null;
                    failed.Close();
                    return null;
                }

                Trace.Write($"play open failed item={itemId} err={error ?? "-"}");
                window.ShowError(error ?? "取播放地址失败");
                return window;
            }

            // 等地址的这几秒里用户可能已经把窗口关了，别对着死 hwnd 起 mpv。
            if (window._closed)
            {
                return null;
            }

            // 本地文件夹源里的 ISO：条目在媒体库里，播放要先读原盘标题。
            if (source.Disc)
            {
                Trace.Write($"play open disc item={itemId} iso={source.Url}");
                var placeholder = window;
                window = null;
                placeholder.Close();
                return await OpenDiscAsync(owner, source.Url,
                    startOverride: source.PositionSeconds > 0 ? source.PositionSeconds : null,
                    coreItemId: source.ItemId);
            }

            window.BeginPlayback(source, startSeconds);
            return window;
        }
        catch (Exception ex)
        {
            Trace.Write("play open failed: " + ex.Message);
            if (shown && window is not null && !silentFailure)
            {
                // 窗口已经出来了：不关，把原因留在黑底上，重试按钮还能用。
                window.ShowError(ex.Message);
                return window;
            }

            window?.Close();
            if (!silentFailure)
            {
                ConfirmDialog.Alert(owner, "无法播放", ex.Message);
            }
            return null;
        }
        finally
        {
            _lastOpenAt = DateTime.UtcNow;
            Interlocked.Exchange(ref _openGate, 0);
        }
    }

    /// <summary>
    /// 读原盘标题并开播放窗。`titleNumber` 非空时直接播那一个（自检用）；
    /// 否则单标题直接播、多标题才弹标题选择框。
    /// </summary>
    public static async Task<PlayWindow?> OpenDiscAsync(
        Window? owner,
        string isoPath,
        int? titleNumber = null,
        double? startOverride = null,
        string? coreItemId = null,
        bool silent = false)
    {
        if (!File.Exists(isoPath))
        {
            if (!silent)
            {
                ConfirmDialog.Alert(owner, "无法打开原盘", "找不到 ISO 文件：" + isoPath);
            }

            return null;
        }

        var (probe, error) = await BluRayDisc.ProbeAsync(isoPath);
        Trace.Write($"disc probe iso={Path.GetFileName(isoPath)} " +
                    $"titles={probe?.Titles.Count ?? 0} err={error ?? "-"}");

        if (probe is null)
        {
            if (!silent)
            {
                ConfirmDialog.Alert(owner, "无法打开原盘", error ?? "读不到原盘标题。");
            }

            return null;
        }

        var title = titleNumber is { } wanted
            ? probe.Titles.FirstOrDefault(item => item.TitleNumber == wanted)
            : null;

        // 直接播默认标题（最长的正片），不再弹选择框；
        // 其它标题在播放器右侧的「标题」面板里切，和选集是同一套交互。
        title ??= DefaultDiscTitle(probe);
        if (title is null)
        {
            if (!silent)
            {
                ConfirmDialog.Alert(owner, "无法打开原盘", "这张盘没有可播放的标题。");
            }

            return null;
        }

        Trace.Write($"disc default title={title.TitleNumber} mpls={title.Mpls} " +
                    $"dur={title.DurationSeconds:0} of {probe.Titles.Count}");
        return OpenIso(owner, isoPath, title, probe, startOverride, coreItemId);
    }

    /// <summary>没指定标题时播哪个：最长的正片；没有正片就最长的标题。</summary>
    private static BluRayTitle? DefaultDiscTitle(BluRayProbe probe)
    {
        var features = probe.Titles.Where(probe.IsFeature).ToList();
        return (features.Count > 0 ? features : probe.Titles.ToList())
            .OrderByDescending(item => item.DurationSeconds)
            .ThenBy(item => item.TitleNumber)
            .FirstOrDefault();
    }

    /// <summary>原盘标题的条目 id：每个标题各存一份本地进度。</summary>
    public static string DiscItemId(string isoPath, BluRayTitle title) =>
        $"iso:{Path.GetFileNameWithoutExtension(isoPath)}:mpls{title.Mpls}";

    /// <summary>拼一个原盘标题的播放源（URL 是 `bd://mpls/&lt;n&gt;`）。</summary>
    public static PlaySourceDto DiscSource(string isoPath, BluRayTitle title, string display,
        double start = 0) => new(
        DiscItemId(isoPath, title),
        $"{display} · 标题 {title.TitleNumber}",
        $"bd://mpls/{title.Mpls}",
        new List<HttpHeaderDto>(),
        true,
        false,
        string.Empty,
        null,
        null,
        null,
        (long)Math.Max(0, start),
        (long)Math.Max(0, title.DurationSeconds),
        null,
        null,
        null,
        null,
        false,
        null,
        null,
        new List<AudioTrackDto>(),
        new List<SubtitleTrackDto>());

    /// <summary>右侧「选集」面板里的原盘标题：正片在前（长的先），花絮按标题号。</summary>
    public static List<PlayEpisode> DiscPlaylist(string isoPath, BluRayProbe probe)
    {
        var features = probe.Titles
            .Where(probe.IsFeature)
            .OrderByDescending(item => item.DurationSeconds)
            .ToList();
        var extras = probe.Titles
            .Where(item => !probe.IsFeature(item))
            .OrderBy(item => item.TitleNumber)
            .ToList();
        var display = string.IsNullOrWhiteSpace(probe.DiscName)
            ? Path.GetFileNameWithoutExtension(isoPath)
            : probe.DiscName!;

        return features.Concat(extras)
            .Select(item => new PlayEpisode(
                DiscItemId(isoPath, item),
                $"标题 {item.TitleNumber}",
                $"{(probe.IsFeature(item) ? "正片" : "花絮")} · {item.DurationLabel}",
                null,
                $"{display} · 标题 {item.TitleNumber}"))
            .ToList();
    }

    /// <summary>
    /// 播一个蓝光原盘标题。原盘不经过媒体库核心：直接拼一个本地播放源，
    /// URL 是 `bd://mpls/<n>`，mpv 靠 `--bluray-device=<iso>` 读盘。
    /// </summary>
    public static PlayWindow OpenIso(
        Window? owner,
        string isoPath,
        BluRayTitle title,
        BluRayProbe? probe = null,
        double? startOverride = null,
        string? coreItemId = null)
    {
        var name = Path.GetFileNameWithoutExtension(isoPath);
        var display = string.IsNullOrWhiteSpace(probe?.DiscName) ? name : probe!.DiscName!;
        var start = startOverride ??
            (coreItemId is null ? LocalProgress.Get(DiscItemId(isoPath, title)) : 0);
        var source = DiscSource(isoPath, title, display, start);
        var playlist = probe is { Titles.Count: > 1 } ? DiscPlaylist(isoPath, probe) : null;

        Trace.Write($"disc open iso={Path.GetFileName(isoPath)} title={title.TitleNumber} " +
                    $"mpls={title.Mpls} dur={title.DurationSeconds:0} resume={start:0} " +
                    $"titles={playlist?.Count ?? 1}");

        var window = new PlayWindow(source, start > 0 ? start : 0, playlist, null,
            localDisc: true, discIsoPath: isoPath, coreItemId: coreItemId,
            discTitles: probe?.Titles, discDisplayName: display);
        // 先用占位状态挡住 Show() 触发的 OnLoaded，BeginPlayback 再正式起 mpv。
        window._started = true;
        window.AttachSurface(owner);
        window.Show();
        window.BeginPlayback(source, start > 0 ? start : 0);
        return window;
    }

    /// <summary>占位播放源：窗口先出来，真实地址解析出来后由 <see cref="BeginPlayback"/> 换掉。</summary>
    private static PlaySourceDto Placeholder(string itemId) => new(
        itemId,
        string.Empty,
        string.Empty,
        new List<HttpHeaderDto>(),
        false,
        false,
        string.Empty,
        null,
        null,
        null,
        0,
        0,
        null,
        null,
        null,
        null,
        false,
        null,
        null,
        new List<AudioTrackDto>(),
        new List<SubtitleTrackDto>());

    /// <summary>真实播放源到了：换掉占位数据并真正起播。</summary>
    public void BeginPlayback(PlaySourceDto source, double? startSeconds)
    {
        if (_closed)
        {
            return;
        }

        _current = source;
        _itemId = source.ItemId;
        _startSeconds = startSeconds;
        _eof = false;
        _started = false;

        ApplySourceToUi(source);
        DurationText.Text = Format(source.DurationSeconds);
        Seek.Maximum = Math.Max(1, source.DurationSeconds);
        UpdatePlaylistSelection();

        LoadingStatus.Text = "正在打开…";
        LoadingPanel.Visibility = Visibility.Visible;
        StartMpv();
    }

    /// <summary>窗口还开着吗：后台补选集时先看一眼，别往已关的窗口里塞控件。</summary>
    public bool IsAlive => !_closed;

    /// <summary>窗口关闭后完成：调用方用它等播放结束，再刷详情 / 拉新进度。</summary>
    public Task WaitForCloseAsync() => _closedSignal.Task;

    /// <summary>当前条目 id（原盘是 `iso:...`），自检写标记 / 日志用。</summary>
    public string ItemId => _itemId;

    /// <summary>选集晚一点才拼好时补进来（续播入口不再为了列集而卡住开窗）。</summary>
    public void SetPlaylist(List<PlayEpisode> playlist, string? seriesTitle, bool partial = false)
    {
        if (_closed)
        {
            return;
        }

        _playlist.Clear();
        _playlist.AddRange(playlist);
        _seriesTitle = seriesTitle;
        ResetMarkerKey();

        RenderPlaylist();
        UpdateChips();
        UpdatePlaylistSelection();
        ApplySourceToUi(_current);

        // 选集只取到一部分（服务端中途失败 / 触顶）：明说，
        // 否则用户会以为后面的集不存在。
        if (partial)
        {
            ShowToast("选集没取全：服务器只返回了一部分");
        }
    }

    private void ApplySourceToUi(PlaySourceDto source)
    {
        var title = DisplayTitle(source);
        Title = "DV Player — " + title;
        TopTitle.Text = title;
        LoadingTitle.Text = title;

        // 任务栏里那个窗口是视频层，标题跟着片名走。
        if (_surface is not null)
        {
            _surface.Title = Title;
        }
    }

    /// <summary>
    /// 顶栏片名。飞牛给单集时常常没有 title，这时用「剧名 + 集号」拼，
    /// 比「正在播放」有信息量；刮削占位的「（未命名）」也当成没有。
    /// </summary>
    private string DisplayTitle(PlaySourceDto source)
    {
        var episode = _playlist.FirstOrDefault(e => e.Id == source.ItemId);

        if (!string.IsNullOrWhiteSpace(_seriesTitle) && episode is not null)
        {
            return $"{_seriesTitle}  {episode.Badge}";
        }

        if (IsRealTitle(source.Title))
        {
            return source.Title!;
        }

        if (IsRealTitle(episode?.Title))
        {
            return episode!.Title!;
        }

        return episode?.Badge ?? "正在播放";
    }

    /// <summary>刮削失败时飞牛会写「（未命名）」，这种标题不算数。</summary>
    private static bool IsRealTitle(string? title) =>
        !string.IsNullOrWhiteSpace(title) &&
        !title.Contains("未命名", StringComparison.Ordinal) &&
        !title.Contains("未知", StringComparison.Ordinal);

    private void OnHostReady(object? sender, IntPtr hwnd)
    {
        _hwnd = hwnd;
        if (IsLoaded)
        {
            StartMpv();
        }
    }

    /// <summary>
    /// 先把视频层显示出来，再让浮层认视频层当 Owner：「视频 ← 浮层」是一条
    /// 固定的所有权链，浮层永远在视频上面，z 序不用抢。任务栏里露出来的是
    /// 视频窗口（缩略图有画面），浮层不进任务栏。
    ///
    /// 注意**不要**让视频层认主窗口当 Owner：那样最小化媒体库会把正在看的
    /// 播放窗口一起收进任务栏。库和播放器是两个独立窗口，最小化库就该继续看；
    /// 只有当主窗口关掉（整个应用退出）时，才把播放器一起关掉。
    /// </summary>
    public void AttachSurface(Window? owner)
    {
        if (_surface is null)
        {
            return;
        }

        _surface.Title = Title;
        _surface.Opacity = 0;
        _surface.Show();
        _surface.BeginAnimation(OpacityProperty, new DoubleAnimation(
            1, TimeSpan.FromMilliseconds(180))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        });
        _surface.Activated += OnSurfaceActivated;
        _surface.StateChanged += OnSurfaceStateChanged;
        Owner = _surface;

        // 主窗口关掉就跟着关（否则 App 会以为还有窗口活着而不退出）。
        _mainWindow = owner;
        if (_mainWindow is not null)
        {
            _mainWindow.Closed += OnMainWindowClosed;
        }

        HealWindowPair();
    }

    private void OnMainWindowClosed(object? sender, EventArgs e) => Close();

    private void OnSurfaceStateChanged(object? sender, EventArgs e) => HealWindowPair();

    /// <summary>
    /// 视频层和浮层必须同进同出：视频层收进任务栏时浮层也要藏起来，
    /// 视频层回来时浮层再跟着显示。否则最小化后桌面上只剩一条控制条。
    /// </summary>
    private void HealWindowPair()
    {
        if (_surface is null)
        {
            return;
        }

        var surfaceGone = _surface.WindowState == WindowState.Minimized || !_surface.IsVisible;

        if (surfaceGone)
        {
            if (IsVisible)
            {
                Hide();
            }

            return;
        }

        if (!IsVisible)
        {
            Show();
            SyncSurface();
            Activate();
            ShowChrome();
        }
    }

    /// <summary>从任务栏点回来时激活的是视频窗，把键盘焦点还给浮层。</summary>
    private void OnSurfaceActivated(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(() =>
        {
            HealWindowPair();

            if (IsVisible && !IsActive)
            {
                Activate();
            }
        });
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_surface is null)
        {
            return;
        }

        SyncSurface();

        if (_hwnd != IntPtr.Zero)
        {
            StartMpv();
        }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);

        if (!_windowPlaced)
        {
            _windowPlaced = true;
            PlaceInitialWindow();
        }

        LocationChanged += (_, _) => SyncSurface();
        SizeChanged += (_, _) =>
        {
            SyncSurface();
            UpdateChromeLayout();
            UpdateEpisodePanelSize();
            UpdateSeekBars();
        };
    }

    // —— 窗口尺寸 / 全屏 / 视频层同步 ——

    /// <summary>默认开成 16:9 的窗口，屏幕放不下就缩到九成高。</summary>
    private void PlaceInitialWindow()
    {
        var area = MonitorBounds();
        var width = Math.Min(1600, area.Width * 0.8);
        var height = width * 9 / 16;

        if (height > area.Height * 0.9)
        {
            height = area.Height * 0.9;
            width = height * 16 / 9;
        }

        var bounds = new Rect(
            area.Left + (area.Width - width) / 2,
            area.Top + (area.Height - height) / 2,
            width,
            height);

        ApplyBounds(bounds);
        _windowedBounds = bounds;
        SyncSurface();
    }

    /// <summary>
    /// 窗口窄（竖屏短剧）时不摆两行：只留传输 + 进度 + 「更多」，
    /// 静音 / 音量 / 音轨 / 字幕 / 倍速 / 全屏都收进「更多」菜单，
    /// 控制条保持一行，别把画面压出一块。
    /// </summary>
    private void UpdateChromeLayout()
    {
        var compact = Width > 0 && Width < 700;
        if (compact == _compactChrome)
        {
            return;
        }

        _compactChrome = compact;

        var tools = compact ? Visibility.Collapsed : Visibility.Visible;
        MuteButton.Visibility = tools;
        Volume.Visibility = tools;
        AudioButton.Visibility = tools;
        SubtitleButton.Visibility = tools;
        DanmakuButton.Visibility = tools;
        SpeedButton.Visibility = tools;
        FullscreenButton.Visibility = tools;

        // 窄窗左右各收一点边，给进度条多留几十像素。
        ChromeStack.Margin = compact
            ? new Thickness(16, 0, 16, 14)
            : new Thickness(24, 0, 24, 18);
        PositionText.Width = compact ? 46 : 58;
        DurationText.Width = compact ? 52 : 66;
    }

    /// <summary>
    /// 右侧选集 / 标题面板跟着窗口走：竖屏短剧的窗口只有 400 来像素宽，
    /// 固定 380 宽 + 右侧 74 的留白会让面板左边被切掉；矮窗口还要限高。
    /// 列表自己滚动，面板始终完整可见。
    /// </summary>
    private void UpdateEpisodePanelSize()
    {
        var width = ActualWidth > 0 ? ActualWidth : Width;
        var height = ActualHeight > 0 ? ActualHeight : Height;

        // 构造时窗口还没量过，Width/Height 是 NaN：保持 XAML 里的默认值，
        // 等 SizeChanged 再按真实尺寸算。
        if (!double.IsFinite(width) || !double.IsFinite(height) || width <= 0 || height <= 0)
        {
            return;
        }

        // 右边 74 留给截图 / 选集按钮，左边至少留 12，别贴着画面边缘。
        EpisodePanel.Width = Math.Clamp(width - 74 - 12, 280, 380);

        // 上下留白：大窗口 40，矮窗口收一点；高度不够就让列表滚动。
        var inset = height >= 640 ? 40 : 16;
        EpisodePanel.MaxHeight = Math.Clamp(height - inset * 2, 200, 580);

        // 面板窄的时候缩略图跟着缩，别把标题 / 时长挤没。
        var thumb = EpisodePanel.Width < 340 ? 100.0 : 132.0;
        var thumbHeight = Math.Round(thumb * 74 / 132);
        if (EpisodeList.ItemsSource is List<EpisodeRow> rows)
        {
            foreach (var row in rows)
            {
                row.SetThumb(thumb, thumbHeight);
            }
        }
    }

    private void ApplyBounds(Rect bounds)
    {
        Left = bounds.Left;
        Top = bounds.Top;
        Width = bounds.Width;
        Height = bounds.Height;
    }

    /// <summary>视频层始终铺满浮层窗口的客户区。</summary>
    private void SyncSurface()
    {
        if (_surface is null)
        {
            return;
        }

        if (Math.Abs(_surface.Left - Left) > 0.5 || Math.Abs(_surface.Top - Top) > 0.5)
        {
            _surface.Left = Left;
            _surface.Top = Top;
        }

        if (Math.Abs(_surface.Width - Width) > 0.5 || Math.Abs(_surface.Height - Height) > 0.5)
        {
            _surface.Width = Math.Max(1, Width);
            _surface.Height = Math.Max(1, Height);
        }
    }

    private void ToggleFullscreen()
    {
        if (_fullscreen)
        {
            ExitFullscreen();
        }
        else
        {
            EnterFullscreen();
        }
    }

    private void EnterFullscreen()
    {
        if (_fullscreen)
        {
            return;
        }

        _windowedBounds = new Rect(Left, Top, Width, Height);
        _fullscreen = true;
        ApplyBounds(MonitorBounds());
        UpdateFullscreenGlyph();
        ShowChrome();
    }

    private void ExitFullscreen()
    {
        if (!_fullscreen)
        {
            return;
        }

        _fullscreen = false;
        ApplyBounds(_windowedBounds.Width > 320 ? _windowedBounds : MonitorLessRect());
        _fitApplied = false;
        FitWindowToVideo();
        UpdateFullscreenGlyph();
        ShowChrome();
    }

    private void OnMinimizeClick(object sender, RoutedEventArgs e)
    {
        if (_surface is null)
        {
            WindowState = WindowState.Minimized;
            return;
        }

        // 两层一起收：只收视频层的话，透明浮层会留在桌面上飘着。
        Hide();
        _surface.WindowState = WindowState.Minimized;
    }

    private void OnMaximizeClick(object sender, RoutedEventArgs e) => ToggleMaximize();

    /// <summary>最大化 = 铺满工作区（不含任务栏），和全屏不是一回事。</summary>
    private void ToggleMaximize()
    {
        if (_fullscreen)
        {
            ExitFullscreen();
            return;
        }

        if (_maximized)
        {
            _maximized = false;
            ApplyBounds(_maximizedFrom.Width > 320 ? _maximizedFrom : MonitorLessRect());
            _fitApplied = false;
            FitWindowToVideo();
        }
        else
        {
            _maximizedFrom = new Rect(Left, Top, Width, Height);
            _maximized = true;
            ApplyBounds(WorkAreaBounds());
        }

        UpdateMaximizeGlyph();
        ShowChrome();
    }

    private void UpdateMaximizeGlyph()
    {
        // E922 = 最大化，E923 = 还原。
        MaximizeGlyph.Text = _maximized || _fullscreen ? "\uE923" : "\uE922";
        MaximizeButton.ToolTip = _maximized || _fullscreen ? "还原窗口" : "最大化";
    }

    /// <summary>当前显示器的工作区（去掉任务栏），换算成 DIP。</summary>
    private Rect WorkAreaBounds()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var monitor = MonitorFromWindow(handle == IntPtr.Zero ? IntPtr.Zero : handle, 2);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };

        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info))
        {
            return new Rect(0, 0, SystemParameters.WorkArea.Width, SystemParameters.WorkArea.Height);
        }

        var dpi = VisualTreeHelper.GetDpi(this);
        var scaleX = dpi.DpiScaleX <= 0 ? 1 : dpi.DpiScaleX;
        var scaleY = dpi.DpiScaleY <= 0 ? 1 : dpi.DpiScaleY;

        return new Rect(
            info.rcWork.Left / scaleX,
            info.rcWork.Top / scaleY,
            (info.rcWork.Right - info.rcWork.Left) / scaleX,
            (info.rcWork.Bottom - info.rcWork.Top) / scaleY);
    }

    private void UpdateFullscreenGlyph()
    {
        // E740 = 进全屏，E73F = 退出全屏。
        FullscreenGlyph.Text = _fullscreen ? "\uE73F" : "\uE740";
        FullscreenButton.ToolTip = _fullscreen
            ? "退出全屏（F11 / 双击画面 / Esc）"
            : "全屏（F11 / 双击画面）";

        UpdateMaximizeGlyph();
    }

    private Rect MonitorLessRect()
    {
        var area = MonitorBounds();
        return new Rect(
            area.Left + area.Width * 0.06,
            area.Top + area.Height * 0.06,
            area.Width * 0.88,
            area.Height * 0.88);
    }

    /// <summary>当前窗口所在显示器的整块区域（含任务栏），换算成 DIP。</summary>
    private Rect MonitorBounds()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var monitor = MonitorFromWindow(handle == IntPtr.Zero ? IntPtr.Zero : handle, 1);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };

        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info))
        {
            return new Rect(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight);
        }

        var dpi = VisualTreeHelper.GetDpi(this);
        var scaleX = dpi.DpiScaleX <= 0 ? 1 : dpi.DpiScaleX;
        var scaleY = dpi.DpiScaleY <= 0 ? 1 : dpi.DpiScaleY;

        return new Rect(
            info.rcMonitor.Left / scaleX,
            info.rcMonitor.Top / scaleY,
            (info.rcMonitor.Right - info.rcMonitor.Left) / scaleX,
            (info.rcMonitor.Bottom - info.rcMonitor.Top) / scaleY);
    }

    // —— 画面上的鼠标：单击暂停、双击全屏、滚轮音量 ——

    private void OnSurfaceMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        if (e.ClickCount == 2)
        {
            OnSurfaceDoubleClick();
            e.Handled = true;
            return;
        }

        var point = e.GetPosition(this);

        // 四边 8px：按住改窗口大小（分层窗口不吃系统的 WM_NCHITTEST，自己算）。
        if (!_fullscreen)
        {
            var edge = HitEdge(point);
            if (edge != DragKind.None)
            {
                BeginDrag(edge, e);
                e.Handled = true;
                return;
            }
        }

        _pressPoint = point;

        // 还没出画：黑底上整块都能拖窗口，单击只是选窗口，不切换暂停。
        if (!_fullscreen && !_ready)
        {
            _pressInTopBar = true;
            BeginDrag(DragKind.Move, e);
            e.Handled = true;
            return;
        }

        // 顶栏那一行按住就是拖窗口，松手也不算「点了画面」。
        if (!_fullscreen && point.Y <= TopBarHeight)
        {
            _pressInTopBar = true;
            BeginDrag(DragKind.Move, e);
            e.Handled = true;
            return;
        }

        _pressInTopBar = false;
    }

    /// <summary>
    /// 双击画面：出画后进 / 退全屏；打开 / 切集阶段（黑底 + 顶栏）按 Windows 习惯
    /// 最大化 / 还原。这段时间进全屏会把顶栏和右上角窗口按钮收掉，窗口也没法拖，
    /// 而且全屏里控制条是藏着的，鼠标指针会跟着一起消失。
    /// </summary>
    private void OnSurfaceDoubleClick()
    {
        // 双击时的第一次单击已经切过暂停，这里还原，只当全屏 / 最大化用。
        if (_clickToggledPause)
        {
            _clickToggledPause = false;
            TogglePause();
        }

        if (!_ready)
        {
            ToggleMaximize();
            return;
        }

        ToggleFullscreen();
    }

    private void OnSurfaceMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        if (_drag != DragKind.None)
        {
            EndDrag();
            return;
        }

        if (e.ClickCount > 1 || _ipc is null || _pressInTopBar)
        {
            return;
        }

        var delta = e.GetPosition(this) - _pressPoint;
        if (Math.Abs(delta.X) > 4 || Math.Abs(delta.Y) > 4)
        {
            return;
        }

        TogglePause();
        _clickToggledPause = true;
        ShowChrome();
        e.Handled = true;
    }

    private void BeginDrag(DragKind kind, MouseEventArgs e)
    {
        _drag = kind;
        _dragOrigin = ScreenPoint();
        _dragBounds = new Rect(Left, Top, Width, Height);
        _dragMoved = false;
        _dragTimer.Start();
    }

    private void EndDrag()
    {
        Trace.Write($"drag end {_drag} moved={_dragMoved} bounds={Left:0},{Top:0},{ActualWidth:0}x{ActualHeight:0}");
        _dragTimer.Stop();
        _drag = DragKind.None;
        _pressInTopBar = false;
    }

    private void OnDragTick(object? sender, EventArgs e)
    {
        if (_drag == DragKind.None)
        {
            _dragTimer.Stop();
            return;
        }

        if ((GetAsyncKeyState(VK_LBUTTON) & 0x8000) == 0)
        {
            EndDrag();
            return;
        }

        ApplyDrag();
    }

    private void ApplyDrag()
    {
        var now = ScreenPoint();
        var dx = now.X - _dragOrigin.X;
        var dy = now.Y - _dragOrigin.Y;

        if (!_dragMoved && Math.Abs(dx) < 3 && Math.Abs(dy) < 3)
        {
            return;
        }

        _dragMoved = true;

        const double minWidth = 480;
        const double minHeight = 270;
        var b = _dragBounds;

        switch (_drag)
        {
            case DragKind.Move:
                b = new Rect(b.X + dx, b.Y + dy, b.Width, b.Height);
                break;

            case DragKind.Left:
            {
                var width = Math.Max(minWidth, b.Width - dx);
                b = new Rect(b.Right - width, b.Y, width, b.Height);
                break;
            }

            case DragKind.Right:
                b = new Rect(b.X, b.Y, Math.Max(minWidth, b.Width + dx), b.Height);
                break;

            case DragKind.Top:
            {
                var height = Math.Max(minHeight, b.Height - dy);
                b = new Rect(b.X, b.Bottom - height, b.Width, height);
                break;
            }

            case DragKind.Bottom:
                b = new Rect(b.X, b.Y, b.Width, Math.Max(minHeight, b.Height + dy));
                break;

            case DragKind.TopLeft:
            {
                var width = Math.Max(minWidth, b.Width - dx);
                var height = Math.Max(minHeight, b.Height - dy);
                b = new Rect(b.Right - width, b.Bottom - height, width, height);
                break;
            }

            case DragKind.TopRight:
            {
                var height = Math.Max(minHeight, b.Height - dy);
                b = new Rect(b.X, b.Bottom - height, Math.Max(minWidth, b.Width + dx), height);
                break;
            }

            case DragKind.BottomLeft:
            {
                var width = Math.Max(minWidth, b.Width - dx);
                b = new Rect(b.Right - width, b.Y, width, Math.Max(minHeight, b.Height + dy));
                break;
            }

            case DragKind.BottomRight:
                b = new Rect(
                    b.X, b.Y,
                    Math.Max(minWidth, b.Width + dx),
                    Math.Max(minHeight, b.Height + dy));
                break;
        }

        ApplyBounds(new Rect(
            Math.Round(b.X), Math.Round(b.Y), Math.Round(b.Width), Math.Round(b.Height)));
    }

    /// <summary>鼠标在哪个边上（8px 以内）；拖动中或全屏时不算。</summary>
    private DragKind HitEdge(Point point)
    {
        if (_fullscreen || _drag != DragKind.None)
        {
            return DragKind.None;
        }

        const double grip = 8;
        var left = point.X <= grip;
        var right = point.X >= ActualWidth - grip;
        var top = point.Y <= grip;
        var bottom = point.Y >= ActualHeight - grip;

        return (left, right, top, bottom) switch
        {
            (true, _, true, _) => DragKind.TopLeft,
            (_, true, true, _) => DragKind.TopRight,
            (true, _, _, true) => DragKind.BottomLeft,
            (_, true, _, true) => DragKind.BottomRight,
            (true, _, _, _) => DragKind.Left,
            (_, true, _, _) => DragKind.Right,
            (_, _, true, _) => DragKind.Top,
            (_, _, _, true) => DragKind.Bottom,
            _ => DragKind.None,
        };
    }

    /// <summary>光标位置（屏幕物理像素）换算成 DIP，拖窗口时以它为准。</summary>
    private Point ScreenPoint()
    {
        if (!GetCursorPos(out var point))
        {
            return new Point(Left, Top);
        }

        var dpi = VisualTreeHelper.GetDpi(this);
        return new Point(
            point.X / (dpi.DpiScaleX <= 0 ? 1 : dpi.DpiScaleX),
            point.Y / (dpi.DpiScaleY <= 0 ? 1 : dpi.DpiScaleY));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);


    private void OnSurfaceWheel(object sender, MouseWheelEventArgs e)
    {
        ChangeVolume(e.Delta > 0 ? 2 : -2);
        ShowChrome();
        e.Handled = true;
    }

    private void OnFullscreenClick(object sender, RoutedEventArgs e) => ToggleFullscreen();

    private void StartMpv()
    {
        if (_started || _hwnd == IntPtr.Zero)
        {
            return;
        }

        _started = true;
        Launch(_current, _startSeconds);
    }

    /// <summary>
    /// 日志里不能出现凭据：Emby 的直链带 `api_key=`，URL 里也可能有 userinfo。
    /// 只保留 scheme://host/path。
    /// </summary>
    private static string RedactUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return url;
        }

        // GetComponents(SchemeAndServer|Path) 只要 scheme/host/port/path，
        // 天然不带 userinfo 和 query。
        return uri.GetComponents(
            UriComponents.SchemeAndServer | UriComponents.Path, UriFormat.UriEscaped);
    }

    private void Launch(PlaySourceDto source, double? startSeconds)
    {
        // 关闭流程已经开始：任何重试/延迟调用都不该再拉 mpv 起来。
        if (_closed)
        {
            return;
        }
        var launch = Playback.ToLaunch(source, startSeconds);
        if (_isLocalDisc)
        {
            launch = launch with
            {
                IsDisc = true,
                ExtraArgs = _discIsoPath is { Length: > 0 } isoPath
                    ? new[] { $"--bluray-device={isoPath}" }
                    : Array.Empty<string>(),
            };
        }
        _launchStart = launch.StartSeconds;
        _openingBase = launch.StartSeconds;
        _launchAt = DateTime.UtcNow;
        _pendingIntroSkip = null;
        _danmakuCount = 0;
        _danmakuBoundTrack = -1;
        _danmakuTrackId = -1;
        _videoAspect = 0;
        _videoWidth = 0;
        _videoHeight = 0;
        _fitApplied = false;
        _bufferedPosition = 0;
        _dvProfile = 0;
        _dvElType = null;
        _doviProbeStarted = false;
        _transfer = "";
        _videoCodec = "";
        _videoFps = 0;
        _videoBitrate = 0;
        UpdateSeekBars();
        SkipOutroButton.Visibility = Visibility.Collapsed;
        ShowOpeningCover();

        // 起播点落在片头里才跳；续播点已经在片头后面就不动。
        if (_markers.IntroEnd is { } intro && intro > 1)
        {
            var total = source.DurationSeconds > 0 ? source.DurationSeconds : _duration;
            if ((total <= 0 || intro < total - 1) && launch.StartSeconds < intro - 0.5)
            {
                _pendingIntroSkip = intro;
            }
        }

        Trace.Write($"mpv start url={RedactUrl(launch.Url)} headers={launch.Headers?.Count ?? 0} " +
                    $"start={launch.StartSeconds} resume={source.PositionSeconds} " +
                    $"aspect={_aspect.Key()} introSkip={_pendingIntroSkip?.ToString("0") ?? "-"} " +
                    $"buffer={MpvBackend.BufferSizeMb}MiB");

        try
        {
            _audioPrefsApplied = false;
            _subtitlePrefsApplied = false;
            _openingPaused = PauseUntilFirstFrame;
            _mpv.Start(_hwnd, launch);

            // mpv 的子窗口是异步建出来的：先试一次，再补一次。
            _surface?.Host.AttachMpvChild();
            _ = Task.Delay(800).ContinueWith(_ => Dispatcher.BeginInvoke(() =>
                _surface?.Host.AttachMpvChild()));
        }
        catch (Exception ex)
        {
            Trace.Write("mpv start failed: " + ex.Message);
            // MpvProcess.Start 在 Stop 之前就做存在性检查并抛异常（文件被删/挂载掉线），
            // 这时上一集的 mpv 还活着，而 _ipc 已置 null：不停掉的话声音继续放且壳控制不了。
            _mpv.Stop();
            ShowError(ex.Message);
            return;
        }

        // 首帧一直不来（慢网络 / 解码卡住）就放开播放，宁可声画不同步也别卡住。
        _openingGate?.Stop();
        if (_openingPaused)
        {
            _openingGate = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
            _openingGate.Tick += (_, _) =>
            {
                _openingGate?.Stop();
                ReleaseOpeningPause("timeout");
            };
            _openingGate.Start();
        }

        _ = AttachIpcAsync();
        if (!_isLocalDisc)
        {
            _ = LoadMediaInfoAsync(source.ItemId);
        }
    }

    private async Task AttachIpcAsync()
    {
        var session = ++_session;
        var ready = _mpv.ControlReady;
        var ipc = _mpv.Control;
        if (ready is null || ipc is null)
        {
            return;
        }

        if (!await ready.ConfigureAwait(true) || session != _session)
        {
            if (session != _session)
            {
                return;
            }

            // 起播时 mpv 停在第一帧，控制通道没连上就没人能放开它：
            // 与其留个永远不动的黑屏，不如报错让用户重试。
            Trace.Write("ipc connect failed");
            _mpv.Stop();
            ShowError("播放器控制通道没连上，请重试。");
            return;
        }

        _ipc = ipc;
        ipc.PropertyChanged += (name, value) =>
        {
            if (session == _session)
            {
                OnMpvProperty(name, value);
            }
        };

        ipc.Disconnected += () => Dispatcher.BeginInvoke(() =>
        {
            if (session != _session || _eof)
            {
                return;
            }

            Close();
        });

        foreach (var name in new[]
                 {
                     "time-pos", "duration", "pause", "volume", "mute", "eof-reached",
                     "track-list", "cache-speed", "speed", "hwdec",
                     "width", "height", "video-params/aspect", "demuxer-cache-time",
                     "audio-device-list", "audio-device", "audio-spdif",
                     "target-colorspace-hint", "current-tracks/video", "video-params",
                     "vo-configured", "video-frame-info", "estimated-vf-fps", "video-bitrate",
                     "paused-for-cache",
                 })
        {
            ipc.Observe(name);
        }

        // 换集 / 片尾倒回都会重启 mpv，声音和倍速得自己带过去。
        ipc.Command("set_property", "volume", (int)Math.Round(Volume.Value));
        if (_speed > 0 && Math.Abs(_speed - 1) > 0.001)
        {
            ipc.Command("set_property", "speed", _speed);
        }

        if (_muted)
        {
            ipc.Command("set_property", "mute", true);
        }

        ApplyAspect();
        _ = LoadDanmakuAsync();
    }

    private void OnMpvProperty(string name, JsonElement value)
    {
        Dispatcher.BeginInvoke(() =>
        {
            switch (name)
            {
                case "time-pos" when value.ValueKind == JsonValueKind.Number:
                    _position = value.GetDouble();
                    // 首帧判定看播放位置有没有真的往前走：慢网络下 mpv 会先报续播点
                    // （或者 0），但一帧都还没出来，这时收黑底就会透出桌面。
                    if (!_ready && !OpeningHold && _position > _openingBase + 0.5)
                    {
                        FinishOpening("position");
                    }
                    UpdatePositionUi();
                    ApplyPendingIntroSkip();
                    UpdateOutroPrompt();
                    break;

                case "duration" when value.ValueKind == JsonValueKind.Number:
                    _duration = value.GetDouble();
                    if (_duration > 0)
                    {
                        Seek.Maximum = _duration;
                        DurationText.Text = Format(_duration);
                        UpdateSeekBars();
                    }
                    break;

                case "demuxer-cache-time":
                    _bufferedPosition = value.ValueKind == JsonValueKind.Number
                        ? value.GetDouble()
                        : 0;
                    UpdateSeekBars();
                    break;

                case "audio-device-list" when value.ValueKind == JsonValueKind.Array:
                    _audioDevices = value.EnumerateArray()
                        .Select(device => (
                            Name: device.TryGetProperty("name", out var name)
                                ? name.GetString() ?? ""
                                : "",
                            Description: device.TryGetProperty("description", out var desc)
                                ? desc.GetString() ?? ""
                                : ""))
                        .Where(device => device.Name.Length > 0)
                        .ToList();
                    break;

                case "audio-device" when value.ValueKind == JsonValueKind.String:
                    _audioDevice = value.GetString() ?? "";
                    break;

                case "audio-spdif" when value.ValueKind == JsonValueKind.String:
                    _audioPassthrough = !string.IsNullOrWhiteSpace(value.GetString());
                    break;

                case "target-colorspace-hint" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    _hdrPassthrough = value.GetBoolean();
                    break;

                case "current-tracks/video" when value.ValueKind == JsonValueKind.Object:
                    // mpv 只在轨道对象里给 DV profile，没有 FEL/MEL（那要侧路解析 RPU）。
                    // 8.1 这类带小数的值按四舍五入取整，裸 GetInt32 会抛。
                    _dvProfile = Int(value, "dolby-vision-profile") ?? 0;
                    _videoCodec = Str(value, "codec") ?? "";
                    UpdateChips();
                    ProbeDolbyVisionIfNeeded();
                    break;

                case "estimated-vf-fps" when value.ValueKind == JsonValueKind.Number:
                    _videoFps = value.GetDouble();
                    UpdateChips();
                    break;

                case "video-bitrate" when value.ValueKind == JsonValueKind.Number:
                    _videoBitrate = value.GetDouble();
                    UpdateChips();
                    break;

                case "vo-configured" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    // 起播时 mpv 是暂停的，VO 就绪后再放开：声音不会抢在画面前面。
                    if (value.GetBoolean() && !_ready && !OpeningHold)
                    {
                        ReleaseOpeningPause("vo-ready");
                    }
                    break;

                case "video-frame-info" when value.ValueKind == JsonValueKind.Object:
                    // 这个属性只有 VO 真正拿到一帧后才出现，比等 time-pos 走 0.5 秒
                    // 早约半秒。放开暂停后它和声音几乎同时到，正好收黑底。
                    if (!_ready && !OpeningHold)
                    {
                        FinishOpening("first-frame");
                    }
                    break;

                case "video-params" when value.ValueKind == JsonValueKind.Object:
                    // mpv 把传递函数放在 gamma 里（pq / hlg / bt.1886），没有 transfer 字段。
                    _transfer =
                        value.TryGetProperty("gamma", out var gamma) &&
                        gamma.ValueKind == JsonValueKind.String
                            ? gamma.GetString() ?? ""
                            : value.TryGetProperty("transfer", out var transfer) &&
                              transfer.ValueKind == JsonValueKind.String
                                ? transfer.GetString() ?? ""
                                : "";
                    UpdateChips();
                    break;

                case "pause" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    _paused = value.GetBoolean();
                    PlayPauseGlyph.Text = _paused ? "\uE768" : "\uE769";
                    RefreshSleepBlocker();
                    break;

                case "paused-for-cache" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    SetBuffering(value.GetBoolean());
                    break;

                case "mute" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    _muted = value.GetBoolean();
                    TopMuteGlyph.Visibility = _muted ? Visibility.Visible : Visibility.Collapsed;
                    break;

                case "cache-speed" when value.ValueKind == JsonValueKind.Number:
                    // 刚起播或本地缓存时速度是 0，这时候没必要显示。
                    var megaBytes = value.GetDouble() / 1024 / 1024;
                    SpeedText.Text = $"{megaBytes:0.0} MB/s";
                    SpeedText.Visibility = megaBytes >= 0.05
                        ? Visibility.Visible
                        : Visibility.Collapsed;
                    break;

                case "speed" when value.ValueKind == JsonValueKind.Number:
                    _lastSpeed = value.GetDouble();
                    _speed = _lastSpeed;
                    SpeedGlyph.Text = $"{_lastSpeed:0.##}×";
                    break;

                case "hwdec" when value.ValueKind == JsonValueKind.String:
                    _hardwareDecode = value.GetString() is not ("no" or "");
                    UpdateChips();
                    break;

                case "width" when value.ValueKind == JsonValueKind.Number:
                    // 这个分支的 value 本身就是数字，不能按「对象属性」去取。
                    if (value.TryGetInt32(out var width))
                    {
                        _videoWidth = width;
                        UpdateVideoAspect();
                    }
                    break;

                case "height" when value.ValueKind == JsonValueKind.Number:
                    if (value.TryGetInt32(out var height))
                    {
                        _videoHeight = height;
                        UpdateVideoAspect();
                    }
                    break;

                case "video-params/aspect" when value.ValueKind == JsonValueKind.Number:
                    // 旋转过的视频（1920x1080 + rotate=90）宽高是编码尺寸，
                    // 这个属性才是 mpv 实际显示的宽高比。
                    SetVideoAspect(value.GetDouble());
                    break;

                case "track-list":
                    ParseTracks(value);
                    break;

                case "eof-reached" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    _eof = value.GetBoolean();
                    RefreshSleepBlocker();
                    if (_eof)
                    {
                        HandleEof();
                    }
                    break;
            }
        });
    }

    private void HandleEof()
    {
        // 续播点正好停在片尾（「已看完」的记录）：mpv 一加载就 EOF，
        // 这时候不该当成播完 —— 电影会当场关窗、剧集会立刻跳下一集。
        // 从头放一遍才是用户点开这部片的本意。
        var instant = (DateTime.UtcNow - _launchAt).TotalSeconds < 3;
        if (instant && _launchStart > 0 && _duration > 0 && _launchStart >= _duration - 2)
        {
            Trace.Write($"eof at resume point start={_launchStart:0} dur={_duration:0} -> restart");
            _eof = false;
            _ipc = null;
            _position = 0;
            Seek.Value = 0;
            Launch(_current, 0);
            return;
        }

        // 播完也要给服务端一个 Stopped，位置写片尾（Emby 会顺手标已看完）。
        ReportProgress(EffectiveDuration, EffectiveDuration, stopped: true);

        if (_sleepAtEof)
        {
            _sleepAtEof = false;
            Trace.Write("sleep at end of episode -> close");
            Close();
            return;
        }

        AdvanceOrClose();
    }

    /// <summary>
    /// 播完：剧集接下一集；最后一集或电影（没有选集）就直接关窗口。
    /// </summary>
    private void AdvanceOrClose()
    {
        // 原盘的标题是正片 / 花絮，不是剧集：播完这一段就收工，
        // 不自动跳到下一个标题。想换标题在右侧面板里点。
        if (_isLocalDisc)
        {
            Trace.Write($"eof disc {_itemId} -> close (titles={_playlist.Count})");
            Close();
            return;
        }

        var index = _playlist.FindIndex(episode => episode.Id == _itemId);
        if (index >= 0 && index + 1 < _playlist.Count)
        {
            Trace.Write($"eof {_itemId} -> next {_playlist[index + 1].Id}");
            _ = SwitchToAsync(_playlist[index + 1].Id);
            return;
        }

        Trace.Write($"eof {_itemId} -> close (playlist={_playlist.Count})");
        Close();
    }

    /// <summary>mpv 的轨道清单：音轨 / 字幕菜单和「按详情页的选择播放」都读它。</summary>
    /// <summary>安全读取字符串属性：mpv 在某些情况下给 null / 别的类型，裸 GetString 会抛。</summary>
    private static string? Str(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object &&
        obj.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;

    /// <summary>安全读取整数属性；8.1 这种带小数的数字按四舍五入取整。</summary>
    private static int? Int(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object &&
        obj.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.Number
            ? element.TryGetInt32(out var exact)
                ? exact
                : element.TryGetDouble(out var approx) ? (int)Math.Round(approx) : null
            : null;

    private void ParseTracks(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        _audioTracks.Clear();
        _subtitleTracks.Clear();

        var subtitles = new List<MpvTrack>();

        foreach (var track in value.EnumerateArray())
        {
            var type = Str(track, "type");
            if (type is not ("audio" or "sub"))
            {
                continue;
            }

            var item = new MpvTrack(
                Int(track, "id") ?? 0,
                type,
                Str(track, "lang"),
                Str(track, "title"),
                Str(track, "codec"),
                Int(track, "demux-channel-count"),
                track.TryGetProperty("selected", out var selected) &&
                selected.ValueKind == JsonValueKind.True,
                Str(track, "external-filename"));

            if (type == "audio")
            {
                _audioTracks.Add(item);
            }
            else
            {
                subtitles.Add(item);
            }
        }

        // 弹幕 ASS 只走 secondary-sid，不进字幕菜单。
        MpvTrack? danmaku = null;
        if (_danmakuFile is not null)
        {
            danmaku = subtitles.FirstOrDefault(t => IsDanmakuFile(t.ExternalFilename));
            if (danmaku is not null)
            {
                subtitles.Remove(danmaku);
            }
        }

        _subtitleTracks.AddRange(subtitles);

        // 有一条字幕被选中时记一笔，用来确认自动选字幕真的生效。
        if (_subtitleTracks.FirstOrDefault(t => t.Selected) is { } chosen &&
            chosen.Id != _loggedSubtitle)
        {
            _loggedSubtitle = chosen.Id;
            Trace.Write($"subtitle selected id={chosen.Id} lang={chosen.Language} " +
                        $"title={chosen.Title}");
        }

        // 刚 sub-add 进来的弹幕：绑定成第二字幕，别抢主字幕。
        if (danmaku is not null)
        {
            _danmakuTrackId = danmaku.Id;
            if (_danmakuEnabled && danmaku.Id != _danmakuBoundTrack)
            {
                _danmakuBoundTrack = danmaku.Id;
                _ipc?.Command("set_property", "secondary-sid", danmaku.Id);
                if (_sidBeforeDanmaku == 0)
                {
                    _ipc?.Command("set_property", "sid", "no");
                }

                Trace.Write($"danmaku bound secondary id={danmaku.Id} primary={_sidBeforeDanmaku}");
            }
        }

        // 每次轨道清单更新都试一次，内部按音轨 / 字幕各自只套用一次。
        // 外挂字幕常比音轨晚到，字幕没出现时不能把「已套用」标记掉。
        ApplyTrackPrefs();
    }

    /// <summary>详情页选了音轨 / 字幕，起播后立刻切过去。</summary>
    private void ApplyTrackPrefs()
    {
        if (_ipc is null)
        {
            return;
        }

        if (!_audioPrefsApplied && _audioTracks.Count > 0)
        {
            _audioPrefsApplied = true;
            if (TrackPrefs.Audio(_itemId) is { } audio && audio >= 0 && audio < _audioTracks.Count)
            {
                _ipc.Command("set_property", "aid", _audioTracks[audio].Id);
            }
        }

        if (_subtitlePrefsApplied)
        {
            return;
        }

        // 明确选了「关闭」：不依赖字幕轨，直接关。
        var saved = TrackPrefs.Subtitle(_itemId);
        if (saved == TrackPrefs.SubtitleOff)
        {
            _subtitlePrefsApplied = true;
            _ipc.Command("set_property", "sid", "no");
            return;
        }

        // 字幕轨还没出现（外挂字幕 / 原盘字幕索引较慢）：等下一次轨道清单。
        if (_subtitleTracks.Count == 0)
        {
            return;
        }

        // 没手动选时，自动选择要读服务器的字幕表；媒体信息还在路上就先等，
        // 否则会把「已套用」标记掉，等表到了也不再选。
        var server = _mediaInfo?.Subtitles;
        if (saved is null && server is null && !_mediaInfoLoaded && !_isLocalDisc)
        {
            return;
        }

        _subtitlePrefsApplied = true;

        // 播放页里手动选过：按服务器字幕表的下标对到 mpv 轨。
        if (saved is { } manual)
        {
            _ipc.Command("set_property", "sid", SubtitleSid(manual));
            Trace.Write($"subtitle saved index={manual} sid={SubtitleSid(manual)}");
            return;
        }

        // 没手动选：和详情页同一套规则（简体优先 / 中文 / 默认）。
        // 原盘 remux 的 mpv 轨常常只报 `HDMV PGS_SUBTITLE`、语言为空，
        // 光按 mpv 的 lang 猜不到中文，得借服务器的字幕表（ffprobe 读到语言）。
        if (server is { Count: > 0 })
        {
            var index = TrackPrefs.ResolveSubtitle(_itemId, server);
            Trace.Write($"subtitle resolve index={index} server={server.Count} " +
                        $"mpv={_subtitleTracks.Count}");
            if (index != TrackPrefs.SubtitleOff)
            {
                _ipc.Command("set_property", "sid", SubtitleSid(index));
                return;
            }
        }

        // 服务器也没给出可识别的字幕：mpv 自己带了语言信息就选中文兜底。
        if (_subtitleTracks.FirstOrDefault(t => TrackPrefs.IsChinese(t.Language, t.Title))
                 is { } chinese)
        {
            _ipc.Command("set_property", "sid", chinese.Id);
            Trace.Write($"subtitle auto zh id={chinese.Id} lang={chinese.Language} " +
                        $"title={chinese.Title}");
        }
    }

    /// <summary>
    /// 服务器字幕表的下标 → mpv 的 sid。轨序一致时直接用下标；
    /// 数量不同（比如弹幕 ASS 混进来）时按语言 / 标题找，找不到就让 mpv 自己选。
    /// </summary>
    private object SubtitleSid(int index)
    {
        if (index >= 0 && index < _subtitleTracks.Count)
        {
            return _subtitleTracks[index].Id;
        }

        if (_mediaInfo?.Subtitles is { } server && index >= 0 && index < server.Count)
        {
            var wanted = server[index];
            var match = _subtitleTracks.FirstOrDefault(t =>
                wanted.Language is not null &&
                string.Equals(t.Language, wanted.Language, StringComparison.OrdinalIgnoreCase));
            if (match is not null)
            {
                return match.Id;
            }
        }

        return "auto";
    }

    private void UpdatePositionUi()
    {
        if (!_seeking)
        {
            Seek.Value = Math.Clamp(_position, 0, Seek.Maximum);
            PositionText.Text = Format(_position);
        }

        UpdateSeekBars();
    }

    /// <summary>
    /// 进度条三层：已观看（主色）/ 已缓冲（亮白）/ 未观看（暗白）。
    /// 宽度按像素算，和 Slider 的轨道对齐。
    /// </summary>
    private void UpdateSeekBars()
    {
        var width = SeekHost.ActualWidth;
        var max = Seek.Maximum;
        if (width <= 0 || max <= 0)
        {
            SeekPlayedBar.Width = 0;
            SeekBufferedBar.Width = 0;
            return;
        }

        var played = _seeking ? Seek.Value : _position;
        SeekPlayedBar.Width = Math.Clamp(width * (played / max), 0, width);

        // 缓存位置有时比当前进度还靠后（刚 seek 回来），至少画到已观看那。
        var buffered = Math.Max(_bufferedPosition, played);
        SeekBufferedBar.Width = Math.Clamp(width * (buffered / max), 0, width);
    }

    /// <summary>
    /// mpv 有时迟迟不给 duration（网络流要等索引），而服务端本来就知道片长，
    /// 所以优先用 mpv 的，拿不到就退回播放源里的值。
    /// </summary>
    private double EffectiveDuration => _duration > 0 ? _duration : _current.DurationSeconds;

    /// <summary>
    /// 媒体库的片回写核心；原盘核心不认识，存到本地续播文件里。
    /// </summary>
    private void ReportProgress(
        double position, double duration, bool stopped = false, bool wait = false)
    {
        // 媒体库里的本地条目：进度仍然写核心，只是影片本身要走原盘流程。
        if (!string.IsNullOrEmpty(_coreItemId))
        {
            var task = Playback.Report(_coreItemId!, position, duration, stopped);
            // 关窗最多等 0.8s：等太久窗口看起来像卡死，丢一次上报还能靠播放中的周期上报补。
            if (wait) task.Wait(800);
            return;
        }

        if (!_isLocalDisc)
        {
            var task = Playback.Report(_itemId, position, duration, stopped);
            if (wait) task.Wait(800);
            return;
        }

        if (duration > 0 && position >= duration - 1)
        {
            LocalProgress.Clear(_itemId);
        }
        else if (position > 0)
        {
            LocalProgress.Save(_itemId, position, duration);
        }
    }

    private void OnTick(object? sender, EventArgs e)
    {
        HealWindowPair();
        CheckSleep();

        if (++_sinceReport < ReportEverySeconds || _position <= 0)
        {
            return;
        }

        _sinceReport = 0;
        ReportProgress(_position, EffectiveDuration);
    }

    // —— 媒体信息 / 规格标签 ——

    private async Task LoadMediaInfoAsync(string itemId)
    {
        if (AppServices.Instance.Core is not { } core)
        {
            return;
        }

        try
        {
            var result = await Task.Run(() => core.MediaInfo(itemId)).ConfigureAwait(true);
            if (itemId != _itemId)
            {
                return;
            }

            _mediaInfo = result.Ok ? result.Data : null;
        }
        catch (Exception ex)
        {
            // 核心在重连时被释放、或媒体信息解析失败：这一集当作没有规格信息，
            // 但不能把「已加载」标志卡死（否则字幕自动选择永远不生效）。
            Trace.Write("media info failed: " + ex.Message);
            if (itemId != _itemId)
            {
                return;
            }

            _mediaInfo = null;
        }

        _mediaInfoLoaded = true;

        try
        {
            UpdateChips();
            UpdateMediaInfoText();

            // 字幕的自动选择要读服务器的语言表，媒体信息晚到就再套一次。
            ApplyTrackPrefs();
        }
        catch (Exception ex)
        {
            Trace.Write("media info apply failed: " + ex.Message);
        }
    }

    /// <summary>
    /// 实际输出的动态范围：DV P5/P7/P8 → HDR10（PQ）→ HLG → SDR。
    /// 和 ARCHITECTURE §2.2 的「源格式 → 实际输出」对齐；mpv 没回报时返回 null。
    /// </summary>
    /// <summary>
    /// mpv 只给 P7 主层；增强层是 FEL 还是 MEL 要读码流的 RPU。
    /// 异步做，失败就算了（徽标退回「DV P7」）。
    /// </summary>
    private void ProbeDolbyVisionIfNeeded()
    {
        if (_dvProfile != 7 || _doviProbeStarted)
        {
            return;
        }

        // 原盘的 URL 是 bd://，没有可直接读的码流。
        if (_current.Url.StartsWith("bd://", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _doviProbeStarted = true;

        if (DoviCache.TryGetValue(_itemId, out var cached))
        {
            _dvElType = cached;
            UpdateChips();
            return;
        }

        var core = AppServices.Instance.Core;
        if (core is null)
        {
            return;
        }

        var item = _itemId;
        var url = _current.Url;
        var headers = _current.Headers;
        var proxy = _current.Proxy;

        _ = Task.Run(() =>
        {
            var result = core.ProbeDovi(url, headers, proxy);
            if (!result.Ok || result.Data is null)
            {
                Trace.Write($"dovi probe {item} skipped: {result.Error}");
                return;
            }

            var probe = result.Data;
            Dispatcher.BeginInvoke(() =>
            {
                if (_itemId != item || _dvProfile != 7)
                {
                    return;
                }

                _dvElType = probe.ElType;
                DoviCache[item] = probe.ElType;
                Trace.Write($"dovi probe {item} profile={probe.Profile} " +
                            $"el={probe.ElType.ToUpperInvariant()}");
                UpdateChips();
            });
        });
    }

    private string? OutputRange()
    {
        if (_dvProfile > 0)
        {
            if (_dvProfile == 7 && _dvElType is { Length: > 0 } elType)
            {
                return $"DV P7 ({elType.ToUpperInvariant()})";
            }

            return $"DV P{_dvProfile}";
        }

        return _transfer switch
        {
            "pq" => "HDR10",
            "hlg" => "HLG",
            "bt.1886" or "srgb" or "bt.709" => "SDR",
            "" => null,
            _ => "SDR",
        };
    }

    private void UpdateChips()
    {
        ChipsRow.Children.Clear();

        var video = _mediaInfo?.Video;
        var chips = new List<string>();

        if (_hardwareDecode)
        {
            chips.Add("HW");
        }

        if (video?.Codec is { Length: > 0 } codec)
        {
            chips.Add(codec);
        }
        else if (_videoCodec is { Length: > 0 } mpvCodec)
        {
            chips.Add(mpvCodec.ToUpperInvariant());
        }
        else if (_current.VideoCodec is { Length: > 0 } sourceCodec)
        {
            chips.Add(sourceCodec.ToUpperInvariant());
        }

        // 动态范围用 mpv 的实际输出（DV 源经 tone map 后就不一定是 DV 了），
        // mpv 还没回报时退回服务端刮削的值。
        var range = OutputRange() ?? video?.ColorRange ?? _current.ColorRange;
        if (!string.IsNullOrWhiteSpace(range))
        {
            chips.Add(range);
        }

        if (video?.Height is { } height && height > 0)
        {
            chips.Add($"{height}p");
        }
        else if (_videoHeight > 0)
        {
            // 原盘没有服务端媒体信息，分辨率直接取 mpv 解出来的画面。
            chips.Add($"{_videoHeight}p");
        }
        else if (!string.IsNullOrWhiteSpace(_current.Resolution))
        {
            chips.Add(_current.Resolution);
        }

        if (video?.FrameRate is { } fps && fps > 0)
        {
            chips.Add($"{fps:0}FPS");
        }
        else if (_videoFps > 0)
        {
            chips.Add($"{_videoFps:0}FPS");
        }

        if (video?.BitRate is { } bitRate && bitRate > 0)
        {
            chips.Add($"{bitRate / 1_000_000.0:0.0}mbps");
        }
        else if (_videoBitrate > 0)
        {
            chips.Add($"{_videoBitrate / 1_000_000.0:0.0}mbps");
        }

        if (_aspect != PlayerAspect.Fit)
        {
            chips.Add(_aspect.Label());
        }

        if (SleepLabel() is { } sleep)
        {
            chips.Add($"定时 {sleep}");
        }

        if (DanmakuActive)
        {
            chips.Add(_danmakuCount > 0 ? $"弹幕 {_danmakuCount}" : "弹幕");
        }

        foreach (var chip in chips)
        {
            ChipsRow.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x66, 0, 0, 0)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(7, 2, 7, 3),
                Margin = new Thickness(0, 0, 7, 0),
                Child = new TextBlock
                {
                    Text = chip,
                    FontSize = 11.5,
                    Foreground = new SolidColorBrush(Color.FromArgb(0xE6, 0xFF, 0xFF, 0xFF)),
                },
            });
        }

    }

    private void UpdateMediaInfoText()
    {
        var lines = new List<string>();

        void Add(string key, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                lines.Add($"{key}   {value}");
            }
        }

        Add("标题", DisplayTitle(_current));
        Add("直链", _current.IsDirect ? "是" : "服务端转码");
        Add("时长", Format(EffectiveDuration));
        Add("硬解码", _hardwareDecode ? "开" : "关");

        var video = _mediaInfo?.Video;
        if (video is not null)
        {
            lines.Add("");
            lines.Add("视频");
            Add("编码", video.Codec);
            Add("分辨率", video.Width is > 0 && video.Height is > 0 ? $"{video.Width} × {video.Height}" : null);
            Add("帧率", video.FrameRate is { } fps && fps > 0 ? $"{fps:0.##} fps" : null);
            Add("比特率", video.BitRate is { } rate && rate > 0 ? $"{rate / 1_000_000.0:0.0} mbps" : null);
            Add("动态范围", video.ColorRange ?? (video.DolbyVision ? "Dolby Vision" : null));
            Add("位深", video.BitDepth is { } depth && depth > 0 ? $"{depth} bit" : null);
        }

        var audios = _mediaInfo?.Audios ?? new List<AudioInfoDto>();
        if (audios.Count > 0)
        {
            lines.Add("");
            lines.Add("音轨");
            for (var i = 0; i < audios.Count; i++)
            {
                var audio = audios[i];
                var parts = new[]
                    {
                        audio.Language,
                        audio.Codec,
                        audio.Channels is > 0 ? $"{audio.Channels} ch" : null,
                        audio.SampleRate is > 0 ? $"{audio.SampleRate} Hz" : null,
                        audio.BitRate is > 0 ? $"{audio.BitRate / 1000} kbps" : null,
                        audio.IsDefault ? "默认" : null,
                    }
                    .Where(part => !string.IsNullOrWhiteSpace(part));

                lines.Add($"{i + 1}.  " + string.Join("  ", parts));
            }
        }

        var subtitles = _mediaInfo?.Subtitles ?? new List<SubtitleInfoDto>();
        if (subtitles.Count > 0)
        {
            lines.Add("");
            lines.Add("字幕");
            for (var i = 0; i < subtitles.Count; i++)
            {
                var sub = subtitles[i];
                var parts = new[]
                    {
                        sub.Language,
                        sub.Title,
                        sub.Codec,
                        sub.IsBitmap ? "图形" : null,
                        sub.IsExternal ? "外挂" : null,
                    }
                    .Where(part => !string.IsNullOrWhiteSpace(part));

                lines.Add($"{i + 1}.  " + string.Join("  ", parts));
            }
        }

        MediaInfoText.Text = string.Join(Environment.NewLine, lines);
    }

    // —— 控制条 ——

    private void OnPlayPauseClick(object sender, RoutedEventArgs e) => TogglePause();

    private void TogglePause()
    {
        if (_ipc is null)
        {
            return;
        }

        // 起播阶段用户自己按了暂停键：别让首帧回调再改一次状态。
        _openingPaused = false;
        _openingGate?.Stop();

        _paused = !_paused;
        _ipc.Command("set_property", "pause", _paused);
        PlayPauseGlyph.Text = _paused ? "\uE768" : "\uE769";
    }

    private void OnPrevEpisodeClick(object sender, RoutedEventArgs e) => JumpEpisode(-1);

    private void OnNextEpisodeClick(object sender, RoutedEventArgs e) => JumpEpisode(1);

    /// <summary>选集里前后跳一集；到头了就给个提示，不做静默失败。</summary>
    private void JumpEpisode(int delta)
    {
        if (_playlist.Count == 0)
        {
            ShowToast(_isLocalDisc ? "这条没有标题" : "这条没有选集");
            return;
        }

        var index = _playlist.FindIndex(episode => episode.Id == _itemId);
        if (index < 0)
        {
            return;
        }

        var target = index + delta;
        if (target < 0)
        {
            ShowToast(_isLocalDisc ? "已经是第一个标题" : "已经是第一集");
            return;
        }

        if (target >= _playlist.Count)
        {
            ShowToast(_isLocalDisc ? "已经是最后一个标题" : "已经是最后一集");
            return;
        }

        _ = SwitchToAsync(_playlist[target].Id);
    }

    private void SeekBy(double delta)
    {
        if (_ipc is null || _duration <= 0)
        {
            return;
        }

        var target = Math.Clamp(_position + delta, 0, _duration);
        _ipc.Command("set_property", "time-pos", target);
        _position = target;
        UpdatePositionUi();
    }

    private void OnSeekDragStarted(object sender, RoutedEventArgs e)
    {
        _seeking = true;
    }

    private void OnSeekDragCompleted(object sender, RoutedEventArgs e)
    {
        CommitSeek();
    }

    private void CommitSeek()
    {
        _seeking = false;
        _position = Seek.Value;
        UpdateSeekBars();
        if (_ipc is not null)
        {
            _ipc.Command("set_property", "time-pos", Seek.Value);
        }

        UpdatePositionUi();
    }

    // —— 进度条 / 音量条：点在轨道上直接跳过去，不用非得抓住那个小圆点 ——

    /// <summary>正在按着轨道拖的那个滑块（null = 没有）。</summary>
    private Slider? _clickSlider;

    private void OnSliderPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left ||
            SliderAt(e) is not { } slider ||
            IsThumbHit(e.OriginalSource as DependencyObject))
        {
            // 不在滑块上，或者点在圆点上（交给 Slider 自己的拖动）
            return;
        }

        if (ReferenceEquals(slider, Seek) && Seek.Maximum <= 0)
        {
            return;
        }

        _clickSlider = slider;
        if (ReferenceEquals(slider, Seek))
        {
            _seeking = true;
        }

        slider.CaptureMouse();
        ApplySliderPoint(slider, e.GetPosition(slider).X);
        e.Handled = true;
    }

    private void OnSliderPreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (_clickSlider is null)
        {
            return;
        }

        ApplySliderPoint(_clickSlider, e.GetPosition(_clickSlider).X);
        e.Handled = true;
    }

    private void OnSliderPreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || _clickSlider is null)
        {
            return;
        }

        FinishSlider();
        e.Handled = true;
    }

    /// <summary>鼠标捕获丢失：当成松手处理，别把拖动状态留在那儿。</summary>
    private void OnSliderLostCapture(object sender, MouseEventArgs e)
    {
        if (_clickSlider is null)
        {
            return;
        }

        FinishSlider();
    }

    /// <summary>结束一次「点轨道拖动」：seek 或音量都在这收尾。</summary>
    private void FinishSlider()
    {
        var slider = _clickSlider;
        _clickSlider = null;

        if (slider is null)
        {
            return;
        }

        if (slider.IsMouseCaptured)
        {
            slider.ReleaseMouseCapture();
        }

        if (ReferenceEquals(slider, Seek))
        {
            CommitSeek();
        }
        else if (ReferenceEquals(slider, Volume))
        {
            _volumeDragging = false;
            if (_ipc is not null)
            {
                _ipc.Command("set_property", "volume", (int)Math.Round(Volume.Value));
            }
        }
    }

    /// <summary>把点击位置换算成滑块值；进度条拖动时只动 UI，松手才 seek。</summary>
    private void ApplySliderPoint(Slider slider, double x)
    {
        var width = slider.ActualWidth;
        if (width <= 0)
        {
            return;
        }

        var ratio = Math.Clamp(x / width, 0, 1);
        slider.Value = slider.Minimum + ratio * (slider.Maximum - slider.Minimum);

        if (ReferenceEquals(slider, Seek))
        {
            PositionText.Text = Format(slider.Value);
        }
        else if (ReferenceEquals(slider, Volume) && _ipc is not null)
        {
            // 音量便宜，按住拖也实时跟手
            _ipc.Command("set_property", "volume", (int)Math.Round(slider.Value));
        }
    }

    /// <summary>
    /// 这次点击落在哪个滑块上。先看点击源（点在滑块模板里），
    /// 再按坐标兜底：分层窗口上偶尔拿到的源是底下的浮层，这时只靠源会漏。
    /// </summary>
    private Slider? SliderAt(MouseEventArgs e)
    {
        if (FindSlider(e.OriginalSource as DependencyObject) is { } fromSource)
        {
            return fromSource;
        }

        foreach (var slider in new[] { Seek, Volume })
        {
            var point = e.GetPosition(slider);
            if (point.X >= 0 && point.Y >= 0 &&
                point.X <= slider.ActualWidth && point.Y <= slider.ActualHeight)
            {
                return slider;
            }
        }

        return null;
    }

    /// <summary>从点击源往上找滑块；不在滑块里就返回 null。</summary>
    private static Slider? FindSlider(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is Slider slider)
            {
                return slider;
            }

            source = VisualTreeHelper.GetParent(source);
        }

        return null;
    }

    private static bool IsThumbHit(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is Thumb)
            {
                return true;
            }

            source = VisualTreeHelper.GetParent(source);
        }

        return false;
    }

    private void OnVolumeDragStarted(object sender, RoutedEventArgs e)
    {
        _volumeDragging = true;
    }

    private void OnVolumeDragCompleted(object sender, DragCompletedEventArgs e)
    {
        // 只有 DragStarted 时：松手后这个标志一直为 true，控制条永远不会自动隐藏。
        _volumeDragging = false;

        // 拖动中最后一个事件可能没发出去，松手时补一次最终值。
        if (_ipc is not null)
        {
            _ipc.Command("set_property", "volume", (int)Math.Round(Volume.Value));
        }
    }

    private void OnVolumeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_volumeDragging && _ipc is not null)
        {
            _ipc.Command("set_property", "volume", (int)Math.Round(e.NewValue));
        }

        Volume.ValueChanged -= OnVolumeChanged;
        Volume.Value = e.NewValue;
        Volume.ValueChanged += OnVolumeChanged;
    }

    private void OnMuteClick(object sender, RoutedEventArgs e) => ToggleMute();

    private void ToggleMute() => _ipc?.Command("cycle", "mute");

    // —— 音轨 / 字幕 / 速度 / 更多 ——

    private void OnAudioClick(object sender, RoutedEventArgs e)
    {
        if (OpenAudioMenu() is null)
        {
            ShowToast("这个文件只有一条音轨");
        }
    }

    private void OnSubtitleClick(object sender, RoutedEventArgs e) => OpenSubtitleMenu();

    private ContextMenu? OpenAudioMenu(FrameworkElement? anchor = null)
    {
        if (_audioTracks.Count == 0)
        {
            return null;
        }

        var choices = _audioTracks
            .Select(track => (
                Label: track.Describe(),
                Selected: track.Selected,
                Action: (Action)(() => SelectAudio(track.Id))))
            .ToList();

        choices.Add(("禁用", !_audioTracks.Any(t => t.Selected), () => SelectAudio("no")));

        return OpenMenu(anchor ?? AudioButton, choices);
    }

    private void SelectAudio(object id)
    {
        _ipc?.Command("set_property", "aid", id);
        if (id is int index)
        {
            var position = _audioTracks.FindIndex(t => t.Id == index);
            if (position >= 0)
            {
                TrackPrefs.SetAudio(_itemId, position);
            }
        }
    }

    private ContextMenu OpenSubtitleMenu(FrameworkElement? anchor = null)
    {
        var anySelected = _subtitleTracks.Any(t => t.Selected);
        var choices = new List<(string Label, bool Selected, Action Action)>
        {
            ("关闭字幕", !anySelected, TurnSubtitlesOff),
        };

        var tracks = _subtitleTracks.Select(t => (t.Language, t.Title)).ToList();

        // 原盘 / remux 的 mpv 轨常常只给 `HDMV PGS_SUBTITLE` 这种容器标题、语言为空；
        // 服务器的媒体信息里如果有 ffprobe 读到的语言，按轨序补回来（只补缺的）。
        var serverSubtitles = _mediaInfo?.Subtitles;
        if (serverSubtitles is not null)
        {
            for (var i = 0; i < tracks.Count && i < serverSubtitles.Count; i++)
            {
                var language = tracks[i].Language;
                var title = tracks[i].Title;
                if (TrackPrefs.LanguageName(language) is null)
                {
                    language = serverSubtitles[i].Language;
                }

                if (TrackPrefs.IsCodecLabel(title))
                {
                    title = serverSubtitles[i].Title;
                }

                tracks[i] = (language, title);
            }
        }

        Trace.Write("submenu mpv=" + string.Join(";", _subtitleTracks.Select(t =>
            $"{t.Language ?? "-"}|{t.Title ?? "-"}|{t.Codec ?? "-"}")));
        Trace.Write("submenu server=" + string.Join(";", (serverSubtitles ?? new List<SubtitleInfoDto>())
            .Select(s => $"{s.Language ?? "-"}|{s.Title ?? "-"}|{s.Codec ?? "-"}")));

        // 菜单只写「语言 · 标题」，没有标题的轨不再露编码，重名的追加序号。
        var labels = TrackPrefs.SubtitleLabels(tracks);

        for (var i = 0; i < _subtitleTracks.Count; i++)
        {
            var track = _subtitleTracks[i];
            var position = i;
            choices.Add((labels[i], track.Selected, (Action)(() => SelectSubtitle(position))));
        }

        Trace.Write("submenu labels=" + string.Join(";", labels));

        return OpenMenu(anchor ?? SubtitleButton, choices);
    }

    private void TurnSubtitlesOff()
    {
        _ipc?.Command("set_property", "sid", "no");
        TrackPrefs.SetSubtitle(_itemId, TrackPrefs.SubtitleOff);
    }

    private void SelectSubtitle(int index)
    {
        if (index < 0 || index >= _subtitleTracks.Count)
        {
            return;
        }

        _ipc?.Command("set_property", "sid", _subtitleTracks[index].Id);
        TrackPrefs.SetSubtitle(_itemId, index);
    }

    private void OnSpeedClick(object sender, RoutedEventArgs e) => OpenSpeedMenu();

    private void OpenSpeedMenu(FrameworkElement? anchor = null)
    {
        double[] speeds = { 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3 };
        var current = Math.Round(_lastSpeed, 2);

        var choices = speeds
            .Select(speed => (
                Label: speed == 1 ? "正常（1.0×）" : $"{speed:0.##}×",
                Selected: Math.Abs(speed - current) < 0.01,
                Action: (Action)(() => SetSpeed(speed))))
            .ToList();

        OpenMenu(anchor ?? SpeedButton, choices);
    }

    // —— 音频输出 / HDR ——

    private string AudioOutputLabel()
    {
        var device = _audioDevices.FirstOrDefault(item => item.Name == _audioDevice);
        var label = device.Description is { Length: > 0 }
            ? device.Description
            : _audioDevice is { Length: > 0 } ? _audioDevice : "系统默认";

        if (_audioPassthrough)
        {
            label += " · 直通";
        }

        if (_hdrPassthrough)
        {
            label += " · HDR";
        }

        return label;
    }

    private ContextMenu? OpenAudioOutputMenu(FrameworkElement? anchor = null)
    {
        var choices = new List<(string Label, bool Selected, Action Action)>();

        if (_audioDevices.Count == 0)
        {
            choices.Add(("还没读到音频设备，稍后再试", false, NoOp));
        }

        foreach (var device in _audioDevices)
        {
            var name = device.Name;
            var label = device.Description is { Length: > 0 } ? device.Description : name;
            choices.Add((label, name == _audioDevice,
                () => SetAudioDevice(name)));
        }

        choices.Add(("-", false, NoOp));
        choices.Add((_audioPassthrough ? "音频直通：开" : "音频直通：关", _audioPassthrough,
            ToggleAudioPassthrough));
        choices.Add((_hdrPassthrough ? "HDR 直通：开" : "HDR 直通：关", _hdrPassthrough,
            ToggleHdrPassthrough));
        choices.Add(($"HDR 亮度参考（{HdrPeakLabel()}）", _hdrPeakNits > 0,
            () => OpenHdrPeakMenu()));

        return OpenMenu(anchor ?? MoreButton, choices);
    }

    /// <summary>自检：打开「音频输出」菜单，截完再关。</summary>
    public ContextMenu? OpenAudioOutputForShot() => OpenAudioOutputMenu(MoreButton);

    /// <summary>自检：切一次音频直通 + HDR 直通，走完整的 set_property + 落盘。</summary>
    public string ToggleAudioOutputForShot()
    {
        ToggleAudioPassthrough();
        ToggleHdrPassthrough();
        return $"passthrough={_audioPassthrough} hdr={_hdrPassthrough} " +
               $"device={(_audioDevice.Length > 0 ? _audioDevice : "-")}";
    }

    private void SetAudioDevice(string name)
    {
        _ipc?.Command("set_property", "audio-device", name);

        var settings = AppServices.Instance.Settings;
        settings.AudioDevice = name;
        settings.Save();
        ShowToast($"音频输出：{AudioOutputLabel()}");
    }

    private void ToggleAudioPassthrough()
    {
        var enabled = !_audioPassthrough;
        _audioPassthrough = enabled;
        _ipc?.Command("set_property", "audio-spdif",
            enabled ? "ac3,eac3,dts,dts-hd,truehd" : "");

        var settings = AppServices.Instance.Settings;
        settings.AudioPassthrough = enabled;
        settings.Save();
        ShowToast(enabled ? "音频直通：开" : "音频直通：关");
    }

    private void ToggleHdrPassthrough()
    {
        var enabled = !_hdrPassthrough;
        _hdrPassthrough = enabled;
        _ipc?.Command("set_property", "target-colorspace-hint", enabled);

        var settings = AppServices.Instance.Settings;
        settings.HdrPassthrough = enabled;
        settings.Save();
        ShowToast(enabled ? "HDR 直通：开（系统要开 HDR）" : "HDR 直通：关");
    }

    private string HdrPeakLabel() => _hdrPeakNits <= 0 ? "自动" : $"{_hdrPeakNits} nit";

    /// <summary>HDR 亮度参考二级菜单（WPF 菜单模板没有子菜单，连开一层）。</summary>
    private ContextMenu OpenHdrPeakMenu()
    {
        var choices = new List<(string Label, bool Selected, Action Action)>
        {
            ("自动（跟随系统）", _hdrPeakNits <= 0, () => SetHdrPeakNits(0)),
            ("-", false, NoOp),
        };

        foreach (var nits in new[] { 60, 80, 100, 120, 150, 180, 200 })
        {
            var value = nits;
            choices.Add(($"{value} nit", _hdrPeakNits == value, () => SetHdrPeakNits(value)));
        }

        return OpenMenu(MoreButton, choices);
    }

    private void SetHdrPeakNits(int nits)
    {
        _hdrPeakNits = Math.Clamp(nits, 0, 400);
        _ipc?.Command("set_property", "target-peak",
            _hdrPeakNits > 0 ? (object)_hdrPeakNits : "auto");

        var settings = AppServices.Instance.Settings;
        settings.HdrPeakNits = _hdrPeakNits;
        settings.Save();

        ShowToast(_hdrPeakNits <= 0
            ? "HDR 亮度参考：自动（跟随系统）"
            : $"HDR 亮度参考：{_hdrPeakNits} nit");
    }

    /// <summary>自检：切一次亮度参考并落盘。</summary>
    public string SetHdrPeakForShot(int nits)
    {
        SetHdrPeakNits(nits);
        return $"hdrPeak={_hdrPeakNits}";
    }

    /// <summary>设置页改了「HDR 亮度参考」：同步到已经开着的播放窗口。</summary>
    public void ApplyHdrPeakFromSettings()
    {
        var nits = AppServices.Instance.Settings.HdrPeakNits;
        if (nits == _hdrPeakNits)
        {
            return;
        }

        _hdrPeakNits = nits;
        _ipc?.Command("set_property", "target-peak", nits > 0 ? (object)nits : "auto");
    }

    private double _lastSpeed = 1;

    private void SetSpeed(double speed)
    {
        _lastSpeed = speed;
        SpeedGlyph.Text = $"{speed:0.##}×";
        _ipc?.Command("set_property", "speed", speed);
    }

    private void OnMoreClick(object sender, RoutedEventArgs e) => OpenMoreMenu();

    private void OnDanmakuClick(object sender, RoutedEventArgs e) => SetDanmaku(!_danmakuEnabled);

    /// <summary>弹幕按钮跟着开关走：开着用强调色，提示也换个说法。</summary>
    private void SyncDanmakuButton()
    {
        DanmakuGlyph.Foreground = _danmakuEnabled
            ? (Brush)FindResource("AccentBrush")
            : new SolidColorBrush(Color.FromArgb(0xF2, 0xFF, 0xFF, 0xFF));
        ToolTipService.SetToolTip(DanmakuButton, _danmakuEnabled ? "弹幕：开" : "弹幕：关");
    }

    private ContextMenu OpenMoreMenu()
    {
        var choices = new List<(string Label, bool Selected, Action Action)>();

        var index = _playlist.FindIndex(episode => episode.Id == _itemId);
        if (index >= 0 && index + 1 < _playlist.Count)
        {
            var next = _playlist[index + 1];
            var nextLabel = _isLocalDisc ? "下一个标题" : "下一集";
            choices.Add(($"{nextLabel}：{next.Badge}", false, () => _ = SwitchToAsync(next.Id)));
        }

        choices.Add(("-", false, NoOp));
        choices.Add(($"画面比例（{_aspect.Label()}）", _aspect != PlayerAspect.Fit, () => OpenAspectMenu()));
        choices.Add((
            SleepLabel() is { } sleep ? $"定时关闭（{sleep}）" : "定时关闭",
            _sleepDeadline is not null || _sleepAtEof,
            () => OpenSleepMenu()));

        // 弹幕开关平时在控制条上（字幕后面），只有窄窗收进「更多」时才列在这里。
        if (_compactChrome)
        {
            choices.Add((_danmakuEnabled ? "弹幕：开" : "弹幕：关", _danmakuEnabled,
                () => SetDanmaku(!_danmakuEnabled)));
        }

        choices.Add(("-", false, NoOp));

        if (_markers.IntroEnd is { } intro)
        {
            choices.Add(($"清除片头标记（{Format(intro)}）", false, ClearIntro));
        }
        else
        {
            choices.Add(("把当前位置设为片头结束", false, MarkIntroEnd));
        }

        if (_markers.OutroStart is { } outro)
        {
            choices.Add(($"清除片尾标记（{Format(outro)}）", false, ClearOutro));
        }
        else
        {
            choices.Add(("把当前位置设为片尾开始", false, MarkOutroStart));
        }

        if (!_markers.IsEmpty)
        {
            choices.Add(("清除本剧全部标记", false, ClearMarkers));
        }

        choices.Add(("搜索字幕…", false, () => _ = SearchSubtitlesAsync()));
        choices.Add(($"音频输出（{AudioOutputLabel()}）", false, () => OpenAudioOutputMenu()));

        // 窄窗口控制条只留传输 + 进度，这些工具都收到这里。
        if (_compactChrome)
        {
            choices.Add(("-", false, NoOp));
            choices.Add((_muted ? "取消静音" : "静音", _muted, ToggleMute));
            choices.Add(("音量 +10", false, () => ChangeVolume(10)));
            choices.Add(("音量 −10", false, () => ChangeVolume(-10)));
            choices.Add(("音轨…", false, () => OpenAudioMenu(MoreButton)));
            choices.Add(("字幕…", false, () => OpenSubtitleMenu(MoreButton)));
            choices.Add(("倍速…", false, () => OpenSpeedMenu(MoreButton)));
        }

        choices.Add(("-", false, NoOp));
        choices.Add((_fullscreen ? "退出全屏" : "全屏", _fullscreen, ToggleFullscreen));
        choices.Add((
            _hardwareDecode ? "硬解码：开（HW / GPU）" : "硬解码：关（软解）",
            _hardwareDecode,
            ToggleHardwareDecode));
        choices.Add(("媒体信息", MediaInfoPanel.Visibility == Visibility.Visible, ToggleMediaInfo));
        choices.Add(("打开日志目录", false, OpenLogFolder));

        return OpenMenu(MoreButton, choices);
    }

    private static void NoOp()
    {
    }

    /// <summary>画面比例二级菜单：WPF 的菜单模板没有子菜单，改成连开一层。</summary>
    private ContextMenu OpenAspectMenu()
    {
        var choices = new List<(string Label, bool Selected, Action Action)>();
        foreach (var mode in Enum.GetValues<PlayerAspect>())
        {
            var value = mode;
            choices.Add((value.Label(), _aspect == value, () => SetAspect(value)));
        }

        return OpenMenu(MoreButton, choices);
    }

    private ContextMenu OpenSleepMenu()
    {
        var choices = new List<(string Label, bool Selected, Action Action)>
        {
            ("不定时", _sleepDeadline is null && !_sleepAtEof, CancelSleep),
            ("-", false, NoOp),
        };

        foreach (var minutes in new[] { 15, 30, 45, 60, 90 })
        {
            var value = minutes;
            var selected = _sleepDeadline is { } deadline &&
                           Math.Abs((deadline - DateTime.Now).TotalMinutes - value) < 1;
            choices.Add(($"{value} 分钟后", selected, () => SetSleep(value)));
        }

        choices.Add(("-", false, NoOp));
        choices.Add(("本集结束后", _sleepAtEof, SetSleepEndOfEpisode));

        return OpenMenu(MoreButton, choices);
    }

    private void ToggleHardwareDecode()
    {
        _hardwareDecode = !_hardwareDecode;
        _ipc?.Command("set_property", "hwdec", _hardwareDecode ? "auto-safe" : "no");
        UpdateChips();
        UpdateMediaInfoText();
    }

    private void ToggleMediaInfo()
    {
        EpisodePanel.Visibility = Visibility.Collapsed;
        MediaInfoPanel.Visibility = MediaInfoPanel.Visibility == Visibility.Visible
            ? Visibility.Collapsed
            : Visibility.Visible;

        if (MediaInfoPanel.Visibility == Visibility.Visible)
        {
            UpdateMediaInfoText();
        }

        ShowChrome();
    }

    private void OnCloseMediaInfoClick(object sender, RoutedEventArgs e) =>
        MediaInfoPanel.Visibility = Visibility.Collapsed;

    private void OpenLogFolder()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = Path.GetDirectoryName(MpvBackend.LogPath)!,
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            Trace.Write("open log folder failed: " + ex.Message);
        }
    }

    private ContextMenu OpenMenu(
        FrameworkElement anchor,
        IEnumerable<(string Label, bool Selected, Action Action)> choices)
    {
        var menu = new ContextMenu
        {
            Style = (Style)FindResource("DarkContextMenu"),
            PlacementTarget = anchor,
            Placement = PlacementMode.Top,
        };

        foreach (var choice in choices)
        {
            // 一个短横线当分隔线用，省得给菜单再抽一层类型。
            if (choice.Label == "-")
            {
                menu.Items.Add(new Separator
                {
                    Style = (Style)FindResource("DarkMenuSeparator"),
                });
                continue;
            }

            var item = new MenuItem
            {
                Header = choice.Label,
                Style = (Style)FindResource("DarkMenuItem"),
            };

            if (choice.Selected)
            {
                item.Icon = new TextBlock
                {
                    Text = "\uE73E",
                    FontFamily = (FontFamily)FindResource("IconFont"),
                    FontSize = 12,
                    Foreground = (Brush)FindResource("AccentBrush"),
                };
            }

            var action = choice.Action;
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        menu.IsOpen = true;
        return menu;
    }

    private async void ShowToast(string message)
    {
        ToastText.Text = message;
        ToastText.Visibility = Visibility.Visible;
        await Task.Delay(1800).ConfigureAwait(true);
        ToastText.Visibility = Visibility.Collapsed;
    }

    // —— 画面比例 / 定时关闭 / 片头片尾 / 弹幕 / 在线字幕 ——

    private bool DanmakuActive => _danmakuEnabled && _danmakuFile is not null;

    /// <summary>标记按剧记；电影没有剧名，就用条目 id（只对这部片生效）。</summary>
    private void ResetMarkerKey()
    {
        _markerKey = string.IsNullOrWhiteSpace(_seriesTitle) ? _itemId : _seriesTitle!;
        _markers = SkipMarkers.Get(_markerKey);
    }

    private void UpdateVideoAspect()
    {
        if (_videoWidth <= 0 || _videoHeight <= 0)
        {
            return;
        }

        SetVideoAspect((double)_videoWidth / _videoHeight);
    }

    private void SetVideoAspect(double aspect)
    {
        if (aspect is <= 0.05 or > 20 || double.IsNaN(aspect))
        {
            return;
        }

        if (Math.Abs(aspect - _videoAspect) < 0.001)
        {
            return;
        }

        _videoAspect = aspect;
        _fitApplied = false;
        FitWindowToVideo();
    }

    /// <summary>
    /// 适应窗口 = 窗口跟着视频的宽高比走（竖屏短剧就是竖窗口），
    /// 画面正好铺满客户区，不留左右 / 上下黑边。只有「适应窗口」这样做，
    /// 填充 / 拉伸 / 强制比例都是改画面、不动窗口。
    /// </summary>
    private void FitWindowToVideo()
    {
        if (_videoAspect <= 0 || _aspect != PlayerAspect.Fit || _fullscreen || _maximized)
        {
            return;
        }

        if (_fitApplied && Math.Abs(_fittedAspect - _videoAspect) < 0.001)
        {
            return;
        }

        var area = WorkAreaBounds();
        var height = Math.Min(Height > 0 ? Height : area.Height * 0.75, area.Height * 0.85);
        var width = height * _videoAspect;

        var maxWidth = area.Width * 0.95;
        if (width > maxWidth)
        {
            width = maxWidth;
            height = width / _videoAspect;
        }

        // 竖屏窗口太窄的话控制条挤成一团，给一个可用的最小宽度。
        const double minWidth = 420;
        if (width < minWidth)
        {
            width = minWidth;
            height = width / _videoAspect;
        }

        var maxHeight = area.Height * 0.95;
        if (height > maxHeight)
        {
            height = maxHeight;
            width = height * _videoAspect;
        }

        // 以当前窗口中心为中心缩放，再夹进工作区（别缩到屏幕外）。
        var centerX = Left + Width / 2;
        var centerY = Top + Height / 2;
        var left = Math.Clamp(centerX - width / 2, area.Left, Math.Max(area.Left, area.Right - width));
        var top = Math.Clamp(centerY - height / 2, area.Top, Math.Max(area.Top, area.Bottom - height));

        _fitApplied = true;
        _fittedAspect = _videoAspect;

        var bounds = new Rect(left, top, width, height);
        ApplyBounds(bounds);
        _windowedBounds = bounds;
        SyncSurface();

        Trace.Write($"fit window video={_videoWidth}x{_videoHeight} aspect={_videoAspect:0.###} " +
                    $"bounds={width:0}x{height:0} at {left:0},{top:0}");
    }

    private void ApplyAspect()
    {
        if (_ipc is null)
        {
            return;
        }

        var (keepAspect, panscan, aspectOverride) = _aspect.ToMpv();
        _ipc.Command("set_property", "keepaspect", keepAspect ? "yes" : "no");
        _ipc.Command("set_property", "panscan", panscan);
        // video-aspect-override 是逐文件的，换集后要重新套一次。
        _ipc.Command("set_property", "video-aspect-override", aspectOverride);
        Trace.Write($"aspect {_aspect.Key()} keep={keepAspect} panscan={panscan:0.00} " +
                    $"override={aspectOverride}");
    }

    private void SetAspect(PlayerAspect mode)
    {
        _aspect = mode;
        ApplyAspect();

        if (mode == PlayerAspect.Fit)
        {
            _fitApplied = false;
            FitWindowToVideo();
        }

        var settings = AppServices.Instance.Settings;
        settings.VideoAspect = mode.Key();
        settings.Save();

        ShowToast(mode.Label());
        UpdateChips();
        ShowChrome();
    }

    /// <summary>起播点落在片头里才跳；续播点已经在片头后面就不动。</summary>
    private void ApplyPendingIntroSkip()
    {
        if (_pendingIntroSkip is not { } intro)
        {
            return;
        }

        // time-pos 第一帧可能就是 0，等真正出画再判断。
        if (_position <= 0.2)
        {
            return;
        }

        if (_position >= intro - 0.5)
        {
            _pendingIntroSkip = null;
            return;
        }

        _pendingIntroSkip = null;
        _ipc?.Command("set_property", "time-pos", intro);
        _position = intro;
        // 片头跳过算一次大跳转，首帧判定从跳到的位置重新算。
        _openingBase = intro;
        UpdatePositionUi();
        Trace.Write($"skip intro -> {(int)intro}");
        ShowToast("已跳过片头");
    }

    /// <summary>进度进了片尾区间就浮出按钮，退回去再收起来。</summary>
    private void UpdateOutroPrompt()
    {
        var show = false;
        if (_markers.OutroStart is { } outro && outro > 1)
        {
            var duration = EffectiveDuration;
            if (duration > 0)
            {
                show = _position >= outro && _position < duration - 1;
            }
        }

        var visible = SkipOutroButton.Visibility == Visibility.Visible;
        if (visible != show)
        {
            SkipOutroButton.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            Trace.Write($"outro prompt {show} pos={(int)_position}");
        }
    }

    /// <summary>跳到片尾末尾，让 mpv 走正常的 EOF：接下一集或关窗。</summary>
    private void OnSkipOutroClick(object sender, RoutedEventArgs e) => SkipOutroNow();

    private void SkipOutroNow()
    {
        SkipOutroButton.Visibility = Visibility.Collapsed;

        var duration = EffectiveDuration;
        if (duration <= 1)
        {
            return;
        }

        var target = Math.Max(0, duration - 0.4);
        _ipc?.Command("set_property", "time-pos", target);
        _position = target;
        UpdatePositionUi();
        ShowToast("跳过片尾");
    }

    private void MarkIntroEnd()
    {
        if (_position <= 1)
        {
            ShowToast("先播一会儿再标记");
            return;
        }

        _markers.IntroEnd = _position;
        SkipMarkers.Save(_markerKey, _markers);
        Trace.Write($"mark intro end {(int)_position} key={_markerKey}");
        ShowToast($"片头结束：{Format(_position)}");
        UpdateChips();
        ShowChrome();
    }

    private void ClearIntro()
    {
        _markers.IntroEnd = null;
        SkipMarkers.Save(_markerKey, _markers);
        Trace.Write($"clear intro key={_markerKey}");
        ShowToast("已清除片头标记");
        UpdateChips();
        ShowChrome();
    }

    private void MarkOutroStart()
    {
        if (_position <= 1)
        {
            ShowToast("先播一会儿再标记");
            return;
        }

        _markers.OutroStart = _position;
        SkipMarkers.Save(_markerKey, _markers);
        Trace.Write($"mark outro start {(int)_position} key={_markerKey}");
        ShowToast($"片尾开始：{Format(_position)}");
        UpdateChips();
        ShowChrome();
    }

    private void ClearOutro()
    {
        _markers.OutroStart = null;
        SkipMarkers.Save(_markerKey, _markers);
        Trace.Write($"clear outro key={_markerKey}");
        ShowToast("已清除片尾标记");
        SkipOutroButton.Visibility = Visibility.Collapsed;
        UpdateChips();
        ShowChrome();
    }

    private void ClearMarkers()
    {
        _markers = new SkipMarker();
        SkipMarkers.Save(_markerKey, _markers);
        Trace.Write($"clear markers key={_markerKey}");
        ShowToast("已清除本剧标记");
        SkipOutroButton.Visibility = Visibility.Collapsed;
        UpdateChips();
        ShowChrome();
    }

    private void SetSleep(double minutes)
    {
        _sleepAtEof = false;
        _sleepDeadline = DateTime.Now.AddMinutes(Math.Max(1 / 60.0, minutes));
        var seconds = Math.Max(1, (int)Math.Round(minutes * 60));
        Trace.Write($"sleep set {seconds}s");
        ShowToast(seconds >= 60 ? $"{seconds / 60} 分钟后关闭" : $"{seconds} 秒后关闭");
        UpdateChips();
        ShowChrome();
    }

    private void SetSleepEndOfEpisode()
    {
        _sleepDeadline = null;
        _sleepAtEof = true;
        Trace.Write("sleep at end of episode");
        ShowToast("本集结束后关闭");
        UpdateChips();
        ShowChrome();
    }

    private void CancelSleep()
    {
        _sleepDeadline = null;
        _sleepAtEof = false;
        Trace.Write("sleep cancelled");
        ShowToast("已取消定时关闭");
        UpdateChips();
        ShowChrome();
    }

    /// <summary>菜单里显示的剩余时间；没设定时就是 null。</summary>
    private string? SleepLabel()
    {
        if (_sleepAtEof)
        {
            return "本集结束后";
        }

        if (_sleepDeadline is not { } deadline)
        {
            return null;
        }

        var remaining = Math.Max(0, (int)Math.Round((deadline - DateTime.Now).TotalSeconds));
        return $"{remaining / 60}:{remaining % 60:00}";
    }

    private void CheckSleep()
    {
        if (_sleepDeadline is not { } deadline || DateTime.Now < deadline)
        {
            return;
        }

        _sleepDeadline = null;
        Trace.Write($"sleep fired pos={(int)_position}");
        ShowToast("定时关闭");

        // 和 macOS 一样先提示一下再关，别让窗口凭空消失。
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(800) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (!_closed)
            {
                Close();
            }
        };
        timer.Start();
    }

    /// <summary>选集里这一集的集号（`E02` / `S01E02` 取末尾数字）。</summary>
    private int? EpisodeNumber()
    {
        var episode = _playlist.FirstOrDefault(e => e.Id == _itemId);
        if (episode is null)
        {
            return null;
        }

        var digits = new string(episode.Badge.Reverse().TakeWhile(char.IsDigit).Reverse().ToArray());
        return int.TryParse(digits, out var number) ? number : null;
    }

    /// <summary>季号从选集角标（`S01E02`）里取；电影没有季。</summary>
    private int? SeasonNumber()
    {
        var badge = _playlist.FirstOrDefault(e => e.Id == _itemId)?.Badge;
        if (badge is null || !badge.StartsWith('S'))
        {
            return null;
        }

        var e = badge.IndexOf('E');
        if (e <= 1)
        {
            return null;
        }

        return int.TryParse(badge[1..e], out var number) ? number : null;
    }

    private static bool IsDanmakuFile(string? filename) =>
        filename is not null &&
        filename.Contains("DVPlayer-danmaku", StringComparison.OrdinalIgnoreCase);

    private void SetDanmaku(bool enabled)
    {
        _danmakuEnabled = enabled;

        var settings = AppServices.Instance.Settings;
        settings.DanmakuEnabled = enabled;
        settings.Save();

        if (enabled)
        {
            Trace.Write("danmaku enabled");
            if (_danmakuTrackId > 0)
            {
                // 这一集之前已经加过弹幕轨，直接挂回第二字幕。
                _danmakuBoundTrack = _danmakuTrackId;
                _ipc?.Command("set_property", "secondary-sid", _danmakuTrackId);
            }
            else
            {
                _ = LoadDanmakuAsync();
            }
        }
        else
        {
            Trace.Write("danmaku disabled");
            _danmakuCts?.Cancel();
            _ipc?.Command("set_property", "secondary-sid", "no");
            _danmakuBoundTrack = -1;

            // 加弹幕时把主字幕可能的「未选」状态改过，关掉时按记下的值还原。
            if (_sidBeforeDanmaku > 0)
            {
                _ipc?.Command("set_property", "sid", _sidBeforeDanmaku);
            }
        }

        ShowToast(enabled ? "弹幕：开" : "弹幕：关");
        UpdateChips();
        SyncDanmakuButton();
        ShowChrome();
    }

    /// <summary>
    /// 按「剧名 + 集号」去弹弹play 找弹幕，写成 ASS 交给 mpv 当第二字幕。
    /// 没配置 AppId / AppSecret 就安静跳过（日志里留一行），不打扰观看。
    /// </summary>
    private async Task LoadDanmakuAsync()
    {
        _danmakuCts?.Cancel();

        if (!_danmakuEnabled)
        {
            return;
        }

        var series = _seriesTitle;
        if (string.IsNullOrWhiteSpace(series))
        {
            Trace.Write("danmaku skipped: 没有剧名");
            return;
        }

        var episode = EpisodeNumber();
        if (episode is null)
        {
            // 电影 / 没有 SxxExx 的条目：按片名去库里找剧场版。
            Trace.Write($"danmaku 没有集号，按剧场版查找 series={series}");
        }

        var appId = DanmakuCredential.AppId;
        var secret = DanmakuCredential.AppSecret;
        if (string.IsNullOrWhiteSpace(appId) || string.IsNullOrWhiteSpace(secret))
        {
            Trace.Write("danmaku skipped: 这个构建没有内置弹幕凭据");
            if (!_danmakuNoticeShown)
            {
                _danmakuNoticeShown = true;
                ShowToast("这个构建没有内置弹幕凭据");
            }

            return;
        }

        var item = _itemId;
        var cts = new CancellationTokenSource();
        _danmakuCts = cts;

        try
        {
            var episodeId = episode is { } number
                ? await DanmakuService.Shared
                    .EpisodeIdAsync(series!, number, appId!, secret!, cts.Token)
                    .ConfigureAwait(true)
                : await DanmakuService.Shared
                    .MovieEpisodeIdAsync(series!, appId!, secret!, cts.Token)
                    .ConfigureAwait(true);
            var comments = await DanmakuService.Shared
                .CommentsAsync(episodeId, appId!, secret!, cts.Token)
                .ConfigureAwait(true);

            if (cts.IsCancellationRequested || _closed || _itemId != item)
            {
                return;
            }

            var path = DanmakuAss.Write(comments, episodeId);
            _danmakuFile = path.Replace('\\', '/');
            _danmakuCount = comments.Count;
            _danmakuTrackId = -1;
            _danmakuBoundTrack = -1;
            _sidBeforeDanmaku = _subtitleTracks.FirstOrDefault(t => t.Selected)?.Id ?? 0;

            // auto：别抢主字幕；加完 track-list 会推一次，ParseTracks 里挂 secondary-sid。
            _ipc?.Command("sub-add", _danmakuFile, "auto");

            Trace.Write($"danmaku loaded {comments.Count} item={item} episodeId={episodeId}");
            UpdateChips();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            if (_closed || _itemId != item)
            {
                return;
            }

            Trace.Write($"danmaku failed: {ex.Message} item={item}");
            ShowToast(ex.Message);
        }
    }

    /// <summary>搜索当前这一集的在线字幕（OpenSubtitles）。</summary>
    private async Task SearchSubtitlesAsync()
    {
        if (_subtitleSearching)
        {
            return;
        }

        var settings = AppServices.Instance.Settings;
        var apiKey = settings.OpenSubtitlesApiKey;
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            ShowToast("字幕搜索需要先在「设置 → 弹幕 / 字幕」里填 OpenSubtitles API Key");
            Trace.Write("subtitles skipped: 未配置 openSubtitlesApiKey");
            return;
        }

        _subtitleSearching = true;
        _subtitleCts?.Cancel();
        _subtitleCts = new CancellationTokenSource();
        var token = _subtitleCts.Token;
        _subtitleResults.Clear();
        ShowToast("正在搜索字幕…");

        var query = string.IsNullOrWhiteSpace(_seriesTitle) ? _current.Title : _seriesTitle!;
        var season = SeasonNumber();
        var episode = EpisodeNumber();
        Trace.Write($"subtitles search {query} S{season?.ToString() ?? "-"}E{episode?.ToString() ?? "-"}");

        try
        {
            var results = await OpenSubtitlesService.Shared.SearchAsync(
                query, season, episode, apiKey!,
                settings.OpenSubtitlesUsername, settings.OpenSubtitlesPassword,
                settings.SubtitleLanguages ?? "zh-cn,zh-tw,en", token).ConfigureAwait(true);

            if (token.IsCancellationRequested || _closed)
            {
                return;
            }

            _subtitleResults.Clear();
            _subtitleResults.AddRange(results);
            Trace.Write($"subtitles results={results.Count}");
            OpenSubtitleResultsMenu();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            if (_closed)
            {
                return;
            }

            Trace.Write($"subtitles search failed: {ex.Message}");
            ShowToast(ex.Message);
        }
        finally
        {
            _subtitleSearching = false;
        }
    }

    private void OpenSubtitleResultsMenu()
    {
        if (_subtitleResults.Count == 0)
        {
            ShowToast("没搜到字幕");
            return;
        }

        var choices = new List<(string Label, bool Selected, Action Action)>();
        foreach (var result in _subtitleResults.Take(20))
        {
            var value = result;
            choices.Add((value.Detail, false, () => _ = DownloadSubtitleAsync(value)));
        }

        OpenMenu(MoreButton, choices);
    }

    /// <summary>下载并挂上主字幕；已经挂着的弹幕再绑回去，别被顶掉。</summary>
    private async Task DownloadSubtitleAsync(SubtitleResult result)
    {
        var settings = AppServices.Instance.Settings;
        var apiKey = settings.OpenSubtitlesApiKey;
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            ShowToast("字幕搜索需要先在「设置 → 弹幕 / 字幕」里填 OpenSubtitles API Key");
            return;
        }

        ShowToast("正在下载字幕…");
        try
        {
            _subtitleCts ??= new CancellationTokenSource();
            var path = await OpenSubtitlesService.Shared.DownloadAsync(
                result, apiKey!, settings.OpenSubtitlesUsername,
                settings.OpenSubtitlesPassword, _subtitleCts.Token).ConfigureAwait(true);

            if (_closed)
            {
                return;
            }

            _ipc?.Command("sub-add", path.Replace('\\', '/'), "select");
            if (DanmakuActive && _danmakuTrackId > 0)
            {
                _ipc?.Command("set_property", "secondary-sid", _danmakuTrackId);
            }

            ShowToast($"字幕已加载：{result.LanguageLabel}");
            Trace.Write($"subtitles applied {result.LanguageLabel} {Path.GetFileName(path)}");
            UpdateChips();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            Trace.Write($"subtitles download failed: {ex.Message}");
            ShowToast(ex.Message);
        }
    }

    // —— 截图 ——

    private void OnShotClick(object sender, RoutedEventArgs e) => TakeScreenshot();

    /// <summary>自检：让 mpv 把当前解码帧写成 PNG（不依赖桌面能不能截屏）。</summary>
    public bool SaveVideoFrameForShot(string file)
    {
        if (_ipc is null || string.IsNullOrWhiteSpace(file))
        {
            return false;
        }

        try
        {
            var folder = Path.GetDirectoryName(file);
            if (!string.IsNullOrWhiteSpace(folder))
            {
                Directory.CreateDirectory(folder);
            }

            _ipc.Command("screenshot-to-file", file.Replace('\\', '/'), "video");
            Trace.Write("frame " + file);
            return true;
        }
        catch (Exception ex)
        {
            Trace.Write("frame failed: " + ex.Message);
            return false;
        }
    }

    private void TakeScreenshot()
    {
        if (_ipc is null)
        {
            return;
        }

        try
        {
            var folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "DVPlayer");
            Directory.CreateDirectory(folder);

            var name = string.Join("_", (_current.Title ?? "截图")
                .Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
            var file = Path.Combine(folder, $"{name}_{DateTime.Now:yyyyMMdd_HHmmss}.png");

            // mpv 的路径参数用正斜杠，省得反斜杠被当成转义。
            _ipc.Command("screenshot-to-file", file.Replace('\\', '/'), "video");
            Trace.Write("screenshot " + file);
        }
        catch (Exception ex)
        {
            Trace.Write("screenshot failed: " + ex.Message);
        }
    }

    // —— 选集 ——

    private void RenderPlaylist()
    {
        EpisodesButton.Visibility = _playlist.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_playlist.Count == 0)
        {
            return;
        }

        EpisodePanelTitle.Text = _isLocalDisc ? "标题" : "选集";
        EpisodePanelMeta.Text = _isLocalDisc
            ? $"{_playlist.Count} 个标题"
            : $"{_playlist.Count} 集";
        EpisodesButton.ToolTip = _isLocalDisc ? "标题" : "选集";

        var rows = _playlist.Select(episode =>
        {
            var row = new EpisodeRow
            {
                Id = episode.Id,
                Badge = episode.Badge,
                Meta = episode.Meta,
                PosterPath = episode.PosterPath,
                Initial = Palette.InitialOf(episode.Badge),
                IsSelected = episode.Id == _itemId,
            };
            row.UseGradient(episode.Id + episode.Badge);
            return row;
        }).ToList();

        EpisodeList.ItemsSource = rows;
        _ = Task.WhenAll(rows.Select(row => row.ApplyPosterAsync(row.PosterPath)));
        UpdateEpisodePanelSize();
    }

    private void UpdatePlaylistSelection()
    {
        if (EpisodeList.ItemsSource is not List<EpisodeRow> rows)
        {
            return;
        }

        foreach (var row in rows)
        {
            row.IsSelected = row.Id == _itemId;
        }
    }

    private void OnEpisodesClick(object sender, RoutedEventArgs e)
    {
        MediaInfoPanel.Visibility = Visibility.Collapsed;
        UpdateEpisodePanelSize();
        EpisodePanel.Visibility = EpisodePanel.Visibility == Visibility.Visible
            ? Visibility.Collapsed
            : Visibility.Visible;

        if (EpisodePanel.Visibility == Visibility.Visible)
        {
            ScrollPlaylistToCurrent();
        }

        Trace.Write($"episodes panel={EpisodePanel.Visibility} n={_playlist.Count} " +
                    $"rows={EpisodeList.Items.Count}");
        ShowChrome();
    }

    private void ScrollPlaylistToCurrent()
    {
        if (EpisodeList.ItemsSource is not List<EpisodeRow> rows)
        {
            return;
        }

        var index = rows.FindIndex(row => row.Id == _itemId);
        if (index < 0)
        {
            return;
        }

        // 放到列表中间附近，前后都能看到。
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            if (EpisodeList.ItemContainerGenerator.ContainerFromIndex(index) is FrameworkElement container)
            {
                container.BringIntoView();
            }
        });
    }

    private async void OnEpisodePick(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string id } || string.IsNullOrEmpty(id) ||
            id == _itemId)
        {
            return;
        }

        await SwitchToAsync(id).ConfigureAwait(true);
    }

    /// <summary>切集：重新取播放源，在同一个窗口里重启 mpv，UI 状态跟着重置。</summary>
    private async Task SwitchToAsync(string itemId)
    {
        PlaySourceDto? source;
        string? error = null;
        // 这一集从哪里起播：网络集一律 0；侧栏直开的原盘切标题用它自己的本地进度。
        var startSeconds = 0d;
        var seq = ++_switchSeq;

        if (_isLocalDisc && _discIsoPath is { Length: > 0 } isoPath)
        {
            // 原盘标题不查核心：换一条 bd://mpls 地址，mpv 继续读同一张盘。
            var discTitle = _discTitles.FirstOrDefault(item => DiscItemId(isoPath, item) == itemId);
            if (discTitle is null)
            {
                ShowToast("找不到这个标题");
                return;
            }

            // 切走之前把当前标题的进度记下，下次切回来还能续。
            ReportProgress(_position, EffectiveDuration);

            // 侧栏直开的原盘：每个标题各存一份本地进度，切回来接着看。
            // 媒体库条目（进度在核心）只有一个续播点，切标题从头开始。
            var resume = _coreItemId is null ? LocalProgress.Get(itemId) : 0;
            source = DiscSource(isoPath, discTitle, _discDisplayName ?? "", resume);
            startSeconds = resume;
        }
        else
        {
            (source, error) = await Playback.ResolveAsync(itemId).ConfigureAwait(true);
        }

        // await 期间可能已经关窗，或用户又点了别的集：这一轮已经过期，丢弃结果。
        if (_closed || seq != _switchSeq)
        {
            return;
        }

        if (source is null)
        {
            ShowToast(error ?? "这一集打不开");
            return;
        }

        _ipc = null;
        _current = source;
        _itemId = itemId;
        _position = 0;
        _duration = 0;
        _bufferedPosition = 0;
        _eof = false;
        _audioPrefsApplied = false;
        _subtitlePrefsApplied = false;
        _loggedSubtitle = -1;
        _audioTracks.Clear();
        _subtitleTracks.Clear();
        _mediaInfo = null;
        _mediaInfoLoaded = false;
        _sinceReport = 0;
        _pendingIntroSkip = null;
        _danmakuFile = null;
        _danmakuCount = 0;
        _danmakuBoundTrack = -1;
        _danmakuTrackId = -1;
        _danmakuCts?.Cancel();
        SkipOutroButton.Visibility = Visibility.Collapsed;

        _seeking = false;
        Seek.Value = 0;
        Seek.Maximum = Math.Max(1, source.DurationSeconds);
        PositionText.Text = "00:00";
        DurationText.Text = Format(source.DurationSeconds);
        ChipsRow.Children.Clear();

        ApplySourceToUi(source);
        UpdatePlaylistSelection();
        LoadingPanel.Visibility = Visibility.Visible;
        LoadingStatus.Text = "正在打开…";

        // 切集一律从头开始：服务器给的续播点是「上次看到哪」，
        // 已经看完的集会带着片尾位置回来，起播就立刻 EOF 跳到下一集。
        // 原盘切标题是例外：起播点来自上面算好的本地进度。
        _startSeconds = startSeconds;
        Launch(source, startSeconds);
        await Task.CompletedTask;
    }

    /// <summary>
    /// 按当前状态决定要不要阻止关屏 / 睡眠。
    ///
    /// 只在**真正在播**时持有：
    /// - 暂停 → 释放，让系统按用户设置正常关屏（暂停了还亮着屏幕很怪）；
    /// - 播完（eof）→ 释放，已经没有内容了；
    /// - 关窗 → 释放。
    ///
    /// 两个必须注意的点：
    ///
    /// 1. <c>SetThreadExecutionState</c> 只作用于**调用它的线程**，而 mpv 的
    ///    property-change 是从读线程抛上来的（<see cref="OnMpvProperty"/> 没切
    ///    Dispatcher）。所以这里强制回 UI 线程，否则 Stop 清不掉。
    /// 2. 用一个「目标状态」而不是计数：mpv 会反复报 pause / eof，每次都 Start
    ///    会让计数只增不减，最后永远释放不掉。状态没变就什么都不做。
    /// </summary>
    private void RefreshSleepBlocker()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(RefreshSleepBlocker);
            return;
        }

        var want = _ready && !_paused && !_eof && !_closed;
        if (want == _sleepBlocked)
        {
            return;
        }

        _sleepBlocked = want;
        if (want)
        {
            SleepBlocker.Start();
        }
        else
        {
            SleepBlocker.Stop();
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    // —— 窗口 ——

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _closed = true;
        // 关窗就恢复系统关屏 / 睡眠，别让状态跟着进程活到退出。
        if (_sleepBlocked)
        {
            _sleepBlocked = false;
            SleepBlocker.Stop();
        }
        _ticker.Stop();
        _hideTimer.Stop();
        _dragTimer.Stop();
        _openingGate?.Stop();

        if (!_eof && _position > 0)
        {
            // 关窗是「停止播放」：Emby 靠 Stopped 才写 UserData。
            // 窗口关完进程就退，这里等一下这次上报，别让它被一起带走。
            try
            {
                ReportProgress(_position, EffectiveDuration, stopped: true, wait: true);
            }
            catch (Exception ex)
            {
                // 上报失败/超时不能挡住后面的 Dispose，否则 mpv 和 IPC 会漏。
                Trace.Write("close report failed: " + ex.Message);
            }
        }

        _danmakuCts?.Cancel();
        _subtitleCts?.Cancel();
        _ipc?.Dispose();
        _mpv.Dispose();

        if (_mainWindow is not null)
        {
            _mainWindow.Closed -= OnMainWindowClosed;
            _mainWindow = null;
        }

        if (_surface is not null)
        {
            _surface.Activated -= OnSurfaceActivated;
            _surface.StateChanged -= OnSurfaceStateChanged;
            _surface.Close();
            _surface = null;
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Space:
                TogglePause();
                break;

            case Key.Left:
                SeekBy(-10);
                break;

            case Key.Right:
                SeekBy(10);
                break;

            case Key.PageUp:
                JumpEpisode(-1);
                break;

            case Key.PageDown:
                JumpEpisode(1);
                break;

            case Key.Up:
                ChangeVolume(5);
                break;

            case Key.Down:
                ChangeVolume(-5);
                break;

            case Key.M:
                OnMuteClick(sender, e);
                break;

            case Key.Escape:
                if (EpisodePanel.Visibility == Visibility.Visible ||
                    MediaInfoPanel.Visibility == Visibility.Visible)
                {
                    EpisodePanel.Visibility = Visibility.Collapsed;
                    MediaInfoPanel.Visibility = Visibility.Collapsed;
                    break;
                }

                if (_fullscreen)
                {
                    ExitFullscreen();
                    break;
                }

                Close();
                break;

            case Key.F11:
                ToggleFullscreen();
                break;

            case Key.Enter:
                ToggleFullscreen();
                break;

            default:
                return;
        }

        e.Handled = true;
        ShowChrome();
    }

    private void ChangeVolume(double delta)
    {
        var value = Math.Clamp(Volume.Value + delta, 0, 100);
        Volume.Value = value;
        _ipc?.Command("set_property", "volume", (int)Math.Round(value));
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_drag != DragKind.None)
        {
            return;
        }

        ShowChrome();
        UpdateCursor(e.GetPosition(this));
    }

    /// <summary>鼠标贴近四边就换成改大小的光标。</summary>
    private void UpdateCursor(Point point)
    {
        // 打开 / 切集时控制条藏着，但窗口还能拖、四边还能改大小：
        // 光标不能跟着控制条一起消失，否则鼠标移上去像不见了。
        // 全屏里切集也一样——这时候顶上没有控制条可露，更不能把指针藏掉。
        var opening = !_ready;
        if (!opening && !_chromeVisible)
        {
            Cursor = Cursors.None;
            return;
        }

        Cursor = HitEdge(point) switch
        {
            DragKind.Left or DragKind.Right => Cursors.SizeWE,
            DragKind.Top or DragKind.Bottom => Cursors.SizeNS,
            DragKind.TopLeft or DragKind.BottomRight => Cursors.SizeNWSE,
            DragKind.TopRight or DragKind.BottomLeft => Cursors.SizeNESW,
            _ => Cursors.Arrow,
        };
    }

    private void ShowChrome()
    {
        // 黑底还盖着（正在打开 / 切集）时别弹控制条。
        if (!_ready)
        {
            return;
        }

        _chromeVisible = true;
        AnimateChrome(1);
        ResetHideTimer();
    }

    /// <summary>整窗黑底 + 「正在打开…」，控制条藏起来。每次起播 / 切集都重新盖一次。</summary>
    private void ShowOpeningCover()
    {
        _ready = false;
        _chromeVisible = false;
        _hideTimer.Stop();

        // 慢网络下 time-pos 会一直停在续播点，黑底要留到播放位置真的往前走。
        // 这里不设时限定时器：没出画就一直是「正在打开…」+ 转圈（Esc 可以关窗）。
        _buffering = false;
        _bufferingCts?.Cancel();
        BufferingPanel.BeginAnimation(OpacityProperty, null);
        BufferingPanel.Visibility = Visibility.Collapsed;

        LoadingPanel.Visibility = Visibility.Visible;
        LoadingStatus.Text = "正在打开…";
        StartSpinner();

        OpeningCover.BeginAnimation(OpacityProperty, null);
        OpeningCover.Opacity = 1;
        OpeningCover.Visibility = Visibility.Visible;
        SetChromeOpacity(0);

        // 打开 / 切集期间也保留顶栏（片名 + 右上角窗口按钮）：黑屏上总得能
        // 最小化 / 最大化 / 关窗，鼠标也有箭头可点。底部控制条仍然等首帧。
        TopBar.Opacity = 1;
        Cursor = Cursors.Arrow;
    }

    private void StartSpinner()
    {
        var spin = new DoubleAnimation(0, 360, TimeSpan.FromMilliseconds(900))
        {
            RepeatBehavior = RepeatBehavior.Forever,
        };
        SpinnerRotate.BeginAnimation(RotateTransform.AngleProperty, spin);
    }

    private void StopSpinner() =>
        SpinnerRotate.BeginAnimation(RotateTransform.AngleProperty, null);

    /// <summary>
    /// mpv 报「在等缓存」。打开阶段黑底自己写着「正在打开…」，不出这个状态；
    /// 出画后卡住才在播放窗中间浮一个小胶囊，画面和控制条都不盖掉。
    /// </summary>
    private void SetBuffering(bool value)
    {
        if (_buffering == value)
        {
            return;
        }

        _buffering = value;
        _bufferingCts?.Cancel();

        if (!value)
        {
            HideBuffering();
            return;
        }

        if (!_ready)
        {
            return;
        }

        // 拖动 / 切轨会短暂换一下缓存，只停不到 400ms 就不弹。
        var cts = new CancellationTokenSource();
        _bufferingCts = cts;
        _ = ShowBufferingAsync(cts.Token);
    }

    private async Task ShowBufferingAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(400, token);
        }
        catch (TaskCanceledException)
        {
            return;
        }

        if (!token.IsCancellationRequested && _buffering && _ready)
        {
            ShowBuffering();
        }
    }

    private void ShowBuffering()
    {
        BufferingPanel.BeginAnimation(OpacityProperty, null);
        BufferingPanel.Opacity = 1;
        BufferingPanel.Visibility = Visibility.Visible;

        var spin = new DoubleAnimation(0, 360, TimeSpan.FromMilliseconds(900))
        {
            RepeatBehavior = RepeatBehavior.Forever,
        };
        BufferingSpin.BeginAnimation(RotateTransform.AngleProperty, spin);
    }

    private void HideBuffering()
    {
        if (BufferingPanel.Visibility != Visibility.Visible)
        {
            return;
        }

        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(160))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        };
        fade.Completed += (_, _) =>
        {
            if (_buffering)
            {
                return;
            }

            BufferingPanel.Visibility = Visibility.Collapsed;
            BufferingPanel.Opacity = 1;
            BufferingSpin.BeginAnimation(RotateTransform.AngleProperty, null);
        };
        BufferingPanel.BeginAnimation(OpacityProperty, fade);
    }

    /// <summary>放开起播时的暂停：声音和画面从这里一起开始。</summary>
    private void ReleaseOpeningPause(string reason)
    {
        if (!_openingPaused)
        {
            return;
        }

        _openingPaused = false;
        _openingGate?.Stop();
        _ipc?.Command("set_property", "pause", false);
        Trace.Write($"opening unpause reason={reason} " +
                    $"after={(DateTime.UtcNow - _launchAt).TotalSeconds:0.00}s");
    }

    /// <summary>首帧到了：黑底淡出，控制条淡入。</summary>
    private void FinishOpening(string reason = "ready")
    {
        if (_ready)
        {
            return;
        }

        _ready = true;
        _openingGate?.Stop();
        ReleaseOpeningPause(reason);
        Trace.Write($"opening finish reason={reason} pos={_position:0.0} " +
                    $"launch={_launchStart:0.0} " +
                    $"after={(DateTime.UtcNow - _launchAt).TotalSeconds:0.0}s");
        // 真正出画了才算在播：这时按当前 _paused / _eof 决定是否阻止关屏。
        // 不在这里补一次的话，起播时 _paused 可能还是上一集的值。
        RefreshSleepBlocker();
        StopSpinner();
        LoadingPanel.Visibility = Visibility.Collapsed;

        // 打开期间 mpv 就在等缓存：出画后直接把播放窗的缓冲状态亮出来。
        if (_buffering)
        {
            ShowBuffering();
        }

        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(140))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        };
        fade.Completed += (_, _) =>
        {
            // 淡出期间又切集了：新一轮的黑底别被这次收掉。
            if (!_ready)
            {
                return;
            }

            OpeningCover.Visibility = Visibility.Collapsed;
            OpeningCover.Opacity = 1;
        };
        OpeningCover.BeginAnimation(OpacityProperty, fade);

        ShowChrome();

        if (BufferingHold)
        {
            _ = Dispatcher.BeginInvoke(() => SetBuffering(true));
        }
    }

    /// <summary>控制条淡入 / 淡出，别硬切。</summary>
    private void AnimateChrome(double target)
    {
        var fade = new DoubleAnimation(target, TimeSpan.FromMilliseconds(180))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        };

        foreach (var element in new FrameworkElement[] { TopBar, Chrome, RightActions })
        {
            element.BeginAnimation(OpacityProperty, fade);
        }

        Cursor = (target > 0 || !_ready) ? Cursors.Arrow : Cursors.None;
    }

    private void SetChromeOpacity(double opacity)
    {
        foreach (var element in new FrameworkElement[] { TopBar, Chrome, RightActions })
        {
            // 淡入 / 淡出的动画会 HoldEnd，直接改 Opacity 会被动画压住。
            element.BeginAnimation(OpacityProperty, null);
            element.Opacity = opacity;
        }

        Cursor = (opacity > 0 || !_ready) ? Cursors.Arrow : Cursors.None;
    }

    private void ResetHideTimer()
    {
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    private void OnHideTick(object? sender, EventArgs e)
    {
        _hideTimer.Stop();

        // 鼠标停在控制条上、正在拖动、或者面板开着，就别隐藏。
        if (_drag != DragKind.None || _pressInTopBar || _clickSlider is not null ||
            Chrome.IsMouseOver || TopBar.IsMouseOver || RightActions.IsMouseOver ||
            _seeking || _volumeDragging ||
            EpisodePanel.Visibility == Visibility.Visible ||
            MediaInfoPanel.Visibility == Visibility.Visible)
        {
            ResetHideTimer();
            return;
        }

        _chromeVisible = false;
        AnimateChrome(0);
    }

    private void ShowError(string message)
    {
        Trace.Write("play error shown: " + message);
        _ready = false;
        _buffering = false;
        _bufferingCts?.Cancel();
        HideBuffering();
        StopSpinner();
        OpeningCover.BeginAnimation(OpacityProperty, null);
        OpeningCover.Opacity = 1;
        OpeningCover.Visibility = Visibility.Visible;
        LoadingPanel.Visibility = Visibility.Collapsed;
        SetChromeOpacity(0);
        Overlay.Visibility = Visibility.Collapsed;
        ErrorRetryButton.Visibility = _closed ? Visibility.Collapsed : Visibility.Visible;
        ErrorText.Text = message;
        ErrorPanel.Visibility = Visibility.Visible;

        // 错误面板是最后一道操作口：顶栏藏掉了，至少窗口还能关（Esc / 关闭按钮）。
        Cursor = Cursors.Arrow;
        Focus();
    }

    /// <summary>
    /// 错误面板的「重试」：占位源（还没取到地址）就重新向核心要一次，
    /// 已经有地址（mpv 启动失败）就在同一个源上重起 mpv。
    /// </summary>
    private async void OnErrorRetryClick(object sender, RoutedEventArgs e)
    {
        if (_retrying || _closed)
        {
            return;
        }

        _retrying = true;
        ErrorPanel.Visibility = Visibility.Collapsed;
        var retryItem = _itemId;
        var retrySeq = _switchSeq;
        Trace.Write($"play retry item={_itemId} hasUrl={!string.IsNullOrEmpty(_current.Url)}");

        try
        {
            Overlay.Visibility = Visibility.Visible;
            ShowOpeningCover();

            if (!string.IsNullOrEmpty(_current.Url))
            {
                // 地址已经在手上：mpv 没起来 / 起播失败，直接再来一次。
                _ipc = null;
                _started = false;
                BeginPlayback(_current, _startSeconds);
                return;
            }

            var (source, error) = await Playback.ResolveAsync(_itemId).ConfigureAwait(true);

            // 重试期间关窗 / 切了别的集：这次结果已经过期，别把旧集拉回来。
            if (_closed || retrySeq != _switchSeq || _itemId != retryItem)
            {
                return;
            }

            if (source is null)
            {
                ShowError(error ?? "取播放地址失败");
                return;
            }

            // 这次才认出是原盘：换成原盘窗口（当前窗口的占位源没法带 --bluray-device）。
            if (source.Disc)
            {
                var iso = source.Url;
                var start = source.PositionSeconds > 0 ? source.PositionSeconds : (double?)null;
                var coreItemId = source.ItemId;
                Trace.Write($"play retry disc iso={iso}");
                Close();
                await OpenDiscAsync(null, iso, startOverride: start, coreItemId: coreItemId);
                return;
            }

            _ipc = null;
            _started = false;
            BeginPlayback(source, _startSeconds);
        }
        catch (Exception ex)
        {
            Trace.Write("play retry failed: " + ex.Message);
            ShowError(ex.Message);
        }
        finally
        {
            _retrying = false;
        }
    }

    private static string Format(double seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return time.TotalHours >= 1
            ? $"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}"
            : $"{time.Minutes:00}:{time.Seconds:00}";
    }

    // —— 截图巡检用的公开入口 ——

    /// <summary>截图巡检用：把浮层强制显示出来（不等首帧）。</summary>
    public void ShowChromeForShot()
    {
        _ready = true;
        AnimateChrome(1);
        ResetHideTimer();
    }

    /// <summary>巡检用：像点错误面板的「重试」一样再取一次地址。</summary>
    public void RetryForShot() =>
        ErrorRetryButton.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    /// <summary>
    /// 巡检用：模拟鼠标停在窗口中间，返回此刻的光标名。
    /// 打开阶段光标不能是 None（看不见鼠标），应当是 Arrow。
    /// </summary>
    public string ProbeCursorForShot()
    {
        UpdateCursor(new Point(ActualWidth / 2, ActualHeight / 2));
        return $"{Cursor} ready={_ready} chrome={_chromeVisible} " +
               $"fullscreen={_fullscreen} maximized={_maximized} " +
               $"bounds={Left:0},{Top:0},{ActualWidth:0}x{ActualHeight:0}";
    }

    /// <summary>巡检用：打开遮罩上走一遍双击逻辑（和手点同一条路径）。</summary>
    public string ProbeOpeningDoubleClick()
    {
        OnSurfaceDoubleClick();
        return "dblclick " + ProbeCursorForShot();
    }

    /// <summary>
    /// 巡检用：用真实鼠标事件验证「点画面暂停 / 顶栏拖动 / 右边缘改大小」。
    /// 走 SendInput 那套消息，和手点等价；中间让出消息泵，不然拖动不会生效。
    /// </summary>
    public async Task RunInputTestAsync()
    {
        var before = new Rect(Left, Top, ActualWidth, ActualHeight);

        // 1) 点画面正中：应当暂停
        MoveCursor(ActualWidth / 2, ActualHeight / 2);
        await Task.Delay(200);
        Click();
        await Task.Delay(400);
        Trace.Write($"input test click paused={_paused}");

        // 2) 按住顶栏往右下拖 120x60
        var bar = ToScreen(ActualWidth / 2, 28);
        SetCursorPos((int)bar.X, (int)bar.Y);
        await Task.Delay(200);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        await Task.Delay(120);

        for (var i = 1; i <= 10; i++)
        {
            SetCursorPos((int)(bar.X + i * 12), (int)(bar.Y + i * 6));
            await Task.Delay(40);
        }

        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        await Task.Delay(400);
        Trace.Write($"input test drag {before.Left:0},{before.Top:0} -> {Left:0},{Top:0}");

        // 3) 拖右边缘往右 120
        var edge = ToScreen(ActualWidth - 5, ActualHeight / 2);
        var width = ActualWidth;
        SetCursorPos((int)edge.X, (int)edge.Y);
        await Task.Delay(200);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        await Task.Delay(120);

        for (var i = 1; i <= 10; i++)
        {
            SetCursorPos((int)(edge.X + i * 12), (int)edge.Y);
            await Task.Delay(40);
        }

        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        await Task.Delay(400);
        Trace.Write($"input test resize {width:0} -> {ActualWidth:0}");

        // 4) 点进度条 70% 处：应该直接跳过去（不用抓圆点）
        ShowChrome();
        await Task.Delay(400);
        var seekFrom = _position;
        var pick = Seek.TranslatePoint(
            new Point(Seek.ActualWidth * 0.7, Seek.ActualHeight / 2), this);
        var spot = PointToScreen(pick);
        SetCursorPos((int)spot.X, (int)spot.Y);
        await Task.Delay(300);
        Trace.Write($"input test seek {seekFrom:0} -> {_position:0} " +
                    $"(target {Seek.Maximum * 0.7:0})");
    }

    private void MoveCursor(double x, double y)
    {
        var point = ToScreen(x, y);
        SetCursorPos((int)point.X, (int)point.Y);
    }

    private Point ToScreen(double x, double y) => PointToScreen(new Point(x, y));

    private void Click()
    {
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
    }

    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;

    private const int VK_LBUTTON = 0x01;

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, int extra);

    /// <summary>
    /// 巡检用：最小化再还原，确认浮层不会留在桌面上；顺带验证主窗口最小化时也一样。
    /// 每一步都从桌面抓图，只有 Session 2 里才有真实画面。
    /// </summary>
    public async Task RunMinimizeTestAsync(string dir)
    {
        // 1) 真点一下右上角的最小化按钮（验证它没被顶栏拖动吃掉）
        ShowChrome();
        await Task.Delay(500);
        var button = MinimizeButton.TranslatePoint(
            new Point(MinimizeButton.ActualWidth / 2, MinimizeButton.ActualHeight / 2), this);
        var target = PointToScreen(button);
        SetCursorPos((int)target.X, (int)target.Y);
        await Task.Delay(250);
        Click();
        await Task.Delay(1800);
        Trace.Write($"min test after player minimize visible={IsVisible} " + DescribeBounds());
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop-min.png"));

        // 2) 从任务栏还原
        if (_surface is not null)
        {
            _surface.WindowState = WindowState.Normal;
        }

        await Task.Delay(1800);
        Trace.Write("min test after restore " + DescribeBounds());
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop-restore.png"));

        // 3) 最大化铺满工作区，再还原
        ToggleMaximize();
        await Task.Delay(1200);
        Trace.Write("min test after maximize " + DescribeBounds());
        UiCapture.SaveDesktop(Path.Combine(dir, "desktop-max.png"));
        ToggleMaximize();
        await Task.Delay(1200);

        // 4) 主窗口最小化：播放窗是独立窗口，应该继续在桌面上放着，不能跟着收起
        if (_mainWindow is not null)
        {
            _mainWindow.WindowState = WindowState.Minimized;
            await Task.Delay(1800);
            Trace.Write($"min test main minimized player visible={IsVisible} " + DescribeBounds());
            UiCapture.SaveDesktop(Path.Combine(dir, "desktop-main-min.png"));
            _mainWindow.WindowState = WindowState.Normal;
            await Task.Delay(1800);
            UiCapture.SaveDesktop(Path.Combine(dir, "desktop-main-restore.png"));
        }
    }

    /// <summary>截图巡检用：片尾行为（接下一集 / 回到开头）看这一行。</summary>
    public string DescribePlaybackState() =>
        $"item={_itemId} pos={_position:0} dur={EffectiveDuration:0} eof={_eof} " +
        $"paused={_paused} playlist={_playlist.Count} visible={IsVisible}";

    /// <summary>截图巡检用：打一行几何信息，排查两个窗口没对齐。</summary>
    public string DescribeBounds()
    {
        var play = new WindowInteropHelper(this).Handle;
        var surface = _surface is null ? IntPtr.Zero : new WindowInteropHelper(_surface).Handle;
        return $"play={Left:0},{Top:0},{ActualWidth:0}x{ActualHeight:0} hwnd={play} " +
               $"surface={_surface?.Left:0},{_surface?.Top:0},{_surface?.ActualWidth:0}x{_surface?.ActualHeight:0} hwnd={surface}";
    }

    /// <summary>截图巡检用：跳到片尾前几秒，验证自动接下一集。</summary>
    public void SkipToEndForShot(double secondsBefore = 4)
    {
        if (_ipc is null || EffectiveDuration <= 0)
        {
            return;
        }

        _ipc.Command("set_property", "time-pos", Math.Max(0, EffectiveDuration - secondsBefore));
    }

    /// <summary>
    /// 截图巡检用：窗口是逐像素透明的，RenderTargetBitmap 截出来背景是空的。
    /// 垫黑只影响壳自己（视频在另一个窗口，抓不到），所以要拍真实画面时再关掉。
    /// </summary>
    public void SetShotBackground(bool black) =>
        Root.Background = black
            ? Brushes.Black
            : new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));

    /// <summary>截图巡检用：打开右侧选集面板。</summary>
    public void ShowEpisodesForShot() => OnEpisodesClick(this, new RoutedEventArgs());

    /// <summary>截图巡检用：右侧面板里有多少条（原盘标题 / 剧集集数）。</summary>
    public int EpisodeCount => _playlist.Count;

    /// <summary>截图巡检用：把窗口摆成指定大小（模拟竖屏短剧的窄窗口）。</summary>
    public void SetBoundsForShot(double width, double height)
    {
        var bounds = new Rect(Left, Top, Math.Max(320, width), Math.Max(240, height));
        ApplyBounds(bounds);
        _windowedBounds = bounds;
        SyncSurface();
        UpdateEpisodePanelSize();
    }

    /// <summary>截图巡检用：当前播放源的标题。</summary>
    public string CurrentTitle => _current.Title;

    /// <summary>截图巡检用：选集面板的可见性和尺寸。</summary>
    public string DescribeEpisodesPanel() =>
        $"{EpisodePanel.Visibility} {EpisodePanel.ActualWidth:0}x{EpisodePanel.ActualHeight:0} " +
        $"rows={EpisodeList.Items.Count}";

    /// <summary>截图巡检用：像点选集面板那样切到第 index 集（0 起）。</summary>
    public void PickEpisodeForShot(int index)
    {
        if (index >= 0 && index < _playlist.Count)
        {
            _ = SwitchToAsync(_playlist[index].Id);
        }
    }

    /// <summary>截图巡检用：打开音频菜单（菜单是独立窗口，需要单独截）。</summary>
    public ContextMenu? OpenAudioMenuForShot() => OpenAudioMenu();

    /// <summary>截图巡检用：直接打开字幕菜单（验证「语言 · 标题」文案）。</summary>
    public ContextMenu? OpenSubtitleMenuForShot() => OpenSubtitleMenu();

    /// <summary>截图巡检用：打开「更多」菜单。</summary>
    public ContextMenu OpenMoreMenuForShot() => OpenMoreMenu();

    /// <summary>截图巡检用：打开「画面比例」二级菜单。</summary>
    public ContextMenu OpenAspectMenuForShot() => OpenAspectMenu();

    /// <summary>截图巡检用：打开「定时关闭」二级菜单。</summary>
    public ContextMenu OpenSleepMenuForShot() => OpenSleepMenu();

    // —— 五项功能的自检入口（--play-check） ——

    /// <summary>自检用：把五项功能的状态串成一行写日志。</summary>
    public string DescribeFeatureState()
    {
        var intro = _markers.IntroEnd is { } i ? ((int)i).ToString() : "-";
        var outro = _markers.OutroStart is { } o ? ((int)o).ToString() : "-";
        var danmaku = DanmakuActive ? _danmakuFile! : "-";
        return $"aspect={_aspect.Key()} intro={intro} outro={outro} " +
               $"sleep={SleepLabel() ?? "-"} danmaku={danmaku} " +
               $"outroPrompt={SkipOutroButton.Visibility} pos={(int)_position} " +
               $"video={_videoWidth}x{_videoHeight} bounds={Width:0}x{Height:0} " +
               $"buffered={_bufferedPosition:0.0}";
    }

    public void SetAspectForShot(string key) => SetAspect(PlayerAspectExtensions.Parse(key));

    /// <summary>自检用：按秒设定时关闭（菜单里是分钟）。</summary>
    public void SetSleepSecondsForShot(double seconds) => SetSleep(seconds / 60.0);

    public void SearchSubtitlesForShot() => _ = SearchSubtitlesAsync();

    public void SkipOutroForShot() => SkipOutroNow();

    /// <summary>自检用：搜索 + 下载第一条字幕，走完整条链路。</summary>
    public async Task SubtitleRoundTripForShot()
    {
        await SearchSubtitlesAsync();
        if (_subtitleResults.Count == 0)
        {
            Trace.Write("subtitles round-trip: 没有结果");
            return;
        }

        await DownloadSubtitleAsync(_subtitleResults[0]);
    }

    /// <summary>
    /// 自检用：不带网络地跑一遍弹幕解析 + ASS 生成，确认滚动 / 顶部 / 底部三种都对。
    /// 真实接口要 AppId / AppSecret，远程机器上没有。
    /// </summary>
    public void TestDanmakuForShot()
    {
        const string xml =
            "<i><d p=\"1.5,1,25,16711680,0,0,0,0\">滚动弹幕</d>" +
            "<d p=\"2,5,25,255,0,0,0,0\">顶部弹幕</d>" +
            "<d p=\"3,4,25,16777215,0,0,0,0\">底部弹幕</d></i>";

        // v2 真实接口现在只回 JSON，`p` 是 time,mode,color,uid（没有字号）。
        // 只认 XML 的解析器在这里会得到 0 条，所以两种都要覆盖。
        const string json =
            "{\"count\":3,\"comments\":[" +
            "{\"p\":\"1.5,1,16711680,abc\",\"m\":\"JSON 滚动\"}," +
            "{\"p\":\"2,5,255,abc\",\"m\":\"JSON 顶部\"}," +
            "{\"p\":\"3,4,16777215,abc\",\"m\":\"JSON 底部\"}]}";

        var fromXml = DanmakuParser.Parse(xml);
        var fromJson = DanmakuParser.Parse(json);
        var comments = fromXml.Concat(fromJson).ToList();
        var ass = DanmakuAss.Build(comments);
        var path = DanmakuAss.Write(comments, 999999);

        var valid = fromXml.Count == 3 &&
                    fromJson.Count == 3 &&
                    ass.Contains("Dialogue:", StringComparison.Ordinal) &&
                    ass.Contains("\\move(", StringComparison.Ordinal) &&
                    ass.Contains("\\an8", StringComparison.Ordinal) &&
                    ass.Contains("\\an2", StringComparison.Ordinal) &&
                    File.Exists(path);

        Trace.Write($"danmaku self-test xml={fromXml.Count} json={fromJson.Count} " +
                    $"valid={valid} file={path}");
    }

    /// <summary>截图巡检用：直接打开媒体信息面板。</summary>
    public void ShowMediaInfoForShot()
    {
        EpisodePanel.Visibility = Visibility.Collapsed;
        MediaInfoPanel.Visibility = Visibility.Visible;
        UpdateMediaInfoText();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    private sealed class MpvTrack
    {
        public MpvTrack(int id, string type, string? language, string? title, string? codec,
            int? channels, bool selected, string? externalFilename = null)
        {
            Id = id;
            Type = type;
            Language = language;
            Title = title;
            Codec = codec;
            Channels = channels;
            Selected = selected;
            ExternalFilename = externalFilename;
        }

        public int Id { get; }
        public string Type { get; }
        public string? Language { get; }
        public string? Title { get; }
        public string? Codec { get; }
        public int? Channels { get; }
        public bool Selected { get; }
        /// <summary>外挂字幕文件路径；弹幕 ASS 靠它识别并排除。</summary>
        public string? ExternalFilename { get; }

        /// <summary>菜单文案：语言 / 标题 / 编码 / 声道，缺的跳掉。</summary>
        public string Describe()
        {
            var parts = new[]
                {
                    Language,
                    Title,
                    Codec is null ? null : Codec.ToUpperInvariant(),
                    Channels is > 0 ? $"{Channels}ch" : null,
                }
                .Where(part => !string.IsNullOrWhiteSpace(part));

            var text = string.Join("  ", parts);
            return string.IsNullOrWhiteSpace(text) ? $"轨道 {Id}" : text;
        }
    }

    private sealed class EpisodeRow : CardVisual
    {
        private bool _selected;
        private double _thumbWidth = 132;
        private double _thumbHeight = 74;

        public string Id { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Meta { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }

        /// <summary>缩略图尺寸：窄面板时由播放窗调小。</summary>
        public double ThumbWidth => _thumbWidth;
        public double ThumbHeight => _thumbHeight;

        public void SetThumb(double width, double height)
        {
            if (Math.Abs(_thumbWidth - width) < 0.5 && Math.Abs(_thumbHeight - height) < 0.5)
            {
                return;
            }

            _thumbWidth = width;
            _thumbHeight = height;
            Raise(nameof(ThumbWidth));
            Raise(nameof(ThumbHeight));
        }

        public bool IsSelected
        {
            get => _selected;
            set
            {
                if (_selected == value)
                {
                    return;
                }

                _selected = value;
                Raise(nameof(SelectedVisibility));
            }
        }

        public Visibility SelectedVisibility =>
            _selected ? Visibility.Visible : Visibility.Collapsed;
    }
}
