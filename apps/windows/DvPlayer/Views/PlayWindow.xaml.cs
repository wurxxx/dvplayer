using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
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
/// 播放窗口：逐像素透明的浮层控制条，视频在下面那个
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

    private readonly PlaySourceDto _source;
    private readonly double? _startSeconds;
    private readonly MpvProcess _mpv = new();

    private readonly DispatcherTimer _ticker = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    private readonly List<PlayEpisode> _playlist;
    private readonly string? _seriesTitle;

    private IntPtr _hwnd;
    private bool _started;
    private MpvIpc? _ipc;
    private int _session;

    private string _itemId;
    private PlaySourceDto _current;

    private MediaInfoDto? _mediaInfo;
    private readonly List<MpvTrack> _audioTracks = new();
    private readonly List<MpvTrack> _subtitleTracks = new();
    private bool _tracksApplied;

    private double _position;
    private double _duration;
    private bool _seeking;
    private bool _volumeDragging;
    private bool _paused;
    private bool _eof;
    private int _sinceReport;
    private bool _chromeVisible = true;
    private bool _hardwareDecode = true;

    /// <summary>视频层，跟这个窗口保持同一矩形。</summary>
    private PlayerSurfaceWindow? _surface;

    private bool _fullscreen;
    private Rect _windowedBounds;
    private bool _windowPlaced;

    private Point _pressPoint;

    /// <summary>双击里的第一次点击已经切过暂停，双击时要还原。</summary>
    private bool _clickToggledPause;

    public PlayWindow(
        PlaySourceDto source,
        double? startSeconds = null,
        List<PlayEpisode>? playlist = null,
        string? seriesTitle = null)
    {
        _source = source;
        _current = source;
        _startSeconds = startSeconds;
        _playlist = playlist ?? new List<PlayEpisode>();
        _seriesTitle = seriesTitle;
        _itemId = source.ItemId;

        InitializeComponent();

        ApplySourceToUi(source);
        DurationText.Text = Format(source.DurationSeconds);

        _surface = new PlayerSurfaceWindow();
        _surface.Host.HostReady += OnHostReady;
        Loaded += OnLoaded;
        Closing += OnClosing;

        _ticker.Tick += OnTick;
        _hideTimer.Tick += OnHideTick;
        _ticker.Start();
        ResetHideTimer();

        RenderPlaylist();
    }

    /// <summary>
    /// 解析播放源并打开窗口。失败时在主窗口提示，不抛异常。
    /// </summary>
    /// <param name="startSeconds">0 = 重头看；null = 按服务器给的续播点。</param>
    /// <param name="playlist">剧集的选集列表；电影传 null。</param>
    public static async Task<PlayWindow?> OpenAsync(
        Window? owner,
        string itemId,
        double? startSeconds = null,
        List<PlayEpisode>? playlist = null,
        string? seriesTitle = null)
    {
        var (source, error) = await Playback.ResolveAsync(itemId).ConfigureAwait(true);
        if (source is null)
        {
            MessageBox.Show(owner, error ?? "取播放地址失败", "DV Player",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }

        var window = new PlayWindow(source, startSeconds, playlist, seriesTitle) { Owner = owner };
        window.Show();
        return window;
    }

    private void ApplySourceToUi(PlaySourceDto source)
    {
        var title = DisplayTitle(source);
        Title = "DV Player — " + title;
        TopTitle.Text = title;
        LoadingTitle.Text = title;
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

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_surface is null)
        {
            return;
        }

        // 视频层也挂在主窗口名下：否则点了主窗口之后，视频会沉到它后面，
        // 只剩浮层（透明窗口）孤零零地压在库页面上。
        if (Owner is { IsVisible: true } owner && !ReferenceEquals(_surface.Owner, owner))
        {
            _surface.Owner = owner;
        }

        // 先把视频层摆到同一个矩形再显示，避免它先在 (-10000,-10000) 冒一下。
        SyncSurface();
        if (!_surface.IsVisible)
        {
            _surface.Show();
        }

        PushSurfaceBelow();

        if (_hwnd != IntPtr.Zero)
        {
            StartMpv();
        }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);

        (PresentationSource.FromVisual(this) as HwndSource)?.AddHook(WindowProc);

        if (!_windowPlaced)
        {
            _windowPlaced = true;
            PlaceInitialWindow();
        }

        LocationChanged += (_, _) => SyncSurface();
        SizeChanged += (_, _) => SyncSurface();
        Activated += (_, _) => PushSurfaceBelow();
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

    /// <summary>把视频层塞到这个窗口正下方（不抢激活）。</summary>
    private void PushSurfaceBelow()
    {
        if (_surface is null)
        {
            return;
        }

        var play = new WindowInteropHelper(this).Handle;
        var surface = new WindowInteropHelper(_surface).Handle;
        if (play == IntPtr.Zero || surface == IntPtr.Zero)
        {
            return;
        }

        SetWindowPos(surface, play, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
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
        UpdateFullscreenGlyph();
        ShowChrome();
    }

    private void UpdateFullscreenGlyph()
    {
        // E740 = 进全屏，E73F = 退出全屏。
        FullscreenGlyph.Text = _fullscreen ? "\uE73F" : "\uE740";
        FullscreenButton.ToolTip = _fullscreen
            ? "退出全屏（F11 / 双击画面 / Esc）"
            : "全屏（F11 / 双击画面）";
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

    /// <summary>无边框窗口自己算边角：靠近边缘 6px 就交给系统改窗口大小。</summary>
    private IntPtr WindowProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_NCHITTEST || _fullscreen)
        {
            return IntPtr.Zero;
        }

        var value = lParam.ToInt64();
        var screenPoint = new Point((short)(value & 0xFFFF), (short)((value >> 16) & 0xFFFF));
        var point = PointFromScreen(screenPoint);

        const double grip = 6;
        var left = point.X <= grip;
        var right = point.X >= ActualWidth - grip;
        var top = point.Y <= grip;
        var bottom = point.Y >= ActualHeight - grip;

        var code = (left, right, top, bottom) switch
        {
            (true, _, true, _) => HTTOPLEFT,
            (_, true, true, _) => HTTOPRIGHT,
            (true, _, _, true) => HTBOTTOMLEFT,
            (_, true, _, true) => HTBOTTOMRIGHT,
            (true, _, _, _) => HTLEFT,
            (_, true, _, _) => HTRIGHT,
            (_, _, true, _) => HTTOP,
            (_, _, _, true) => HTBOTTOM,
            _ => 0,
        };

        if (code == 0)
        {
            return IntPtr.Zero;
        }

        handled = true;
        return new IntPtr(code);
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
            // 双击时的第一次单击已经切过暂停，这里还原，只当全屏用。
            if (_clickToggledPause)
            {
                _clickToggledPause = false;
                TogglePause();
            }

            ToggleFullscreen();
            e.Handled = true;
            return;
        }

        _pressPoint = e.GetPosition(this);
    }

    private void OnSurfaceMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || e.ClickCount > 1 || _ipc is null)
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

    private void OnSurfaceWheel(object sender, MouseWheelEventArgs e)
    {
        ChangeVolume(e.Delta > 0 ? 2 : -2);
        ShowChrome();
        e.Handled = true;
    }

    /// <summary>按住顶栏空白处拖窗口（全屏时不需要）。</summary>
    private void OnTitleBarDrag(object sender, MouseButtonEventArgs e)
    {
        if (_fullscreen || e.ButtonState != MouseButtonState.Pressed)
        {
            return;
        }

        try
        {
            DragMove();
        }
        catch (InvalidOperationException)
        {
            // 鼠标已经松开：忽略。
        }
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

    private void Launch(PlaySourceDto source, double? startSeconds)
    {
        var launch = Playback.ToLaunch(source, startSeconds);
        Trace.Write($"mpv start url={launch.Url} headers={launch.Headers?.Count ?? 0} " +
                    $"start={launch.StartSeconds}");

        try
        {
            _tracksApplied = false;
            _mpv.Start(_hwnd, launch);

            // mpv 的子窗口是异步建出来的：先试一次，再补一次。
            _surface?.Host.AttachMpvChild();
            _ = Task.Delay(800).ContinueWith(_ => Dispatcher.BeginInvoke(() =>
                _surface?.Host.AttachMpvChild()));
        }
        catch (Exception ex)
        {
            Trace.Write("mpv start failed: " + ex.Message);
            ShowError(ex.Message);
            return;
        }

        _ = AttachIpcAsync();
        _ = LoadMediaInfoAsync(source.ItemId);
    }

    private async Task AttachIpcAsync()
    {
        var session = ++_session;
        var ready = _mpv.IpcReady;
        var ipc = _mpv.Ipc;
        if (ready is null || ipc is null)
        {
            return;
        }

        // 控制条不是必需品：IPC 连不上也让它继续播。
        if (!await ready.ConfigureAwait(true) || session != _session)
        {
            LoadingStatus.Text = "已开始播放（控制通道未连上）";
            await Task.Delay(1200).ConfigureAwait(true);
            LoadingPanel.Visibility = Visibility.Collapsed;
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
                 })
        {
            ipc.Observe(name);
        }

        ipc.Command("set_property", "volume", (int)Math.Round(Volume.Value));
        LoadingPanel.Visibility = Visibility.Collapsed;
    }

    private void OnMpvProperty(string name, JsonElement value)
    {
        Dispatcher.BeginInvoke(() =>
        {
            switch (name)
            {
                case "time-pos" when value.ValueKind == JsonValueKind.Number:
                    _position = value.GetDouble();
                    UpdatePositionUi();
                    break;

                case "duration" when value.ValueKind == JsonValueKind.Number:
                    _duration = value.GetDouble();
                    if (_duration > 0)
                    {
                        Seek.Maximum = _duration;
                        DurationText.Text = Format(_duration);
                    }
                    break;

                case "pause" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    _paused = value.GetBoolean();
                    PlayPauseGlyph.Text = _paused ? "\uE768" : "\uE769";
                    break;

                case "mute" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    TopMuteGlyph.Visibility = value.GetBoolean() ? Visibility.Visible : Visibility.Collapsed;
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
                    SpeedGlyph.Text = $"{_lastSpeed:0.##}×";
                    break;

                case "hwdec" when value.ValueKind == JsonValueKind.String:
                    _hardwareDecode = value.GetString() is not ("no" or "");
                    UpdateChips();
                    break;

                case "track-list":
                    ParseTracks(value);
                    break;

                case "eof-reached" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    _eof = value.GetBoolean();
                    if (_eof)
                    {
                        Playback.Report(_itemId, EffectiveDuration, EffectiveDuration);
                        AdvanceOrClose();
                    }
                    break;
            }
        });
    }

    /// <summary>播完自动接下一集；已经是最后一集就关窗口。</summary>
    private void AdvanceOrClose()
    {
        var index = _playlist.FindIndex(episode => episode.Id == _itemId);
        if (index >= 0 && index + 1 < _playlist.Count)
        {
            _ = SwitchToAsync(_playlist[index + 1].Id);
            return;
        }

        Close();
    }

    /// <summary>mpv 的轨道清单：音轨 / 字幕菜单和「按详情页的选择播放」都读它。</summary>
    private void ParseTracks(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        _audioTracks.Clear();
        _subtitleTracks.Clear();

        foreach (var track in value.EnumerateArray())
        {
            var type = track.TryGetProperty("type", out var typeElement) ? typeElement.GetString() : null;
            if (type is not ("audio" or "sub"))
            {
                continue;
            }

            var item = new MpvTrack(
                track.TryGetProperty("id", out var idElement) ? idElement.GetInt32() : 0,
                type,
                track.TryGetProperty("lang", out var lang) ? lang.GetString() : null,
                track.TryGetProperty("title", out var title) ? title.GetString() : null,
                track.TryGetProperty("codec", out var codec) ? codec.GetString() : null,
                track.TryGetProperty("demux-channel-count", out var channels) && channels.ValueKind == JsonValueKind.Number
                    ? channels.GetInt32()
                    : null,
                track.TryGetProperty("selected", out var selected) && selected.ValueKind == JsonValueKind.True);

            (type == "audio" ? _audioTracks : _subtitleTracks).Add(item);
        }

        // 只在第一次拿到轨道清单时套用详情页的选择，之后是用户在播放页里改。
        // 没有音轨的文件也要能套用字幕选择，所以两个清单任一非空即可。
        if (!_tracksApplied && (_audioTracks.Count > 0 || _subtitleTracks.Count > 0))
        {
            _tracksApplied = true;
            ApplyTrackPrefs();
        }
    }

    /// <summary>详情页选了音轨 / 字幕，起播后立刻切过去。</summary>
    private void ApplyTrackPrefs()
    {
        if (_ipc is null)
        {
            return;
        }

        if (TrackPrefs.Audio(_itemId) is { } audio && audio >= 0 && audio < _audioTracks.Count)
        {
            _ipc.Command("set_property", "aid", _audioTracks[audio].Id);
        }

        if (TrackPrefs.Subtitle(_itemId) is { } subtitle)
        {
            _ipc.Command("set_property", "sid", subtitle == TrackPrefs.SubtitleOff
                ? "no"
                : subtitle >= 0 && subtitle < _subtitleTracks.Count
                    ? _subtitleTracks[subtitle].Id
                    : "auto");
        }
    }

    private void UpdatePositionUi()
    {
        if (!_seeking)
        {
            Seek.Value = Math.Clamp(_position, 0, Seek.Maximum);
        }

        PositionText.Text = Format(_position);
    }

    /// <summary>
    /// mpv 有时迟迟不给 duration（网络流要等索引），而服务端本来就知道片长，
    /// 所以优先用 mpv 的，拿不到就退回播放源里的值。
    /// </summary>
    private double EffectiveDuration => _duration > 0 ? _duration : _current.DurationSeconds;

    private void OnTick(object? sender, EventArgs e)
    {
        // 两个窗口必须一直贴在一起：谁被激活、桌面怎么切，都靠这一下兜底。
        PushSurfaceBelow();

        if (++_sinceReport < ReportEverySeconds || _position <= 0)
        {
            return;
        }

        _sinceReport = 0;
        Playback.Report(_itemId, _position, EffectiveDuration);
    }

    // —— 媒体信息 / 规格标签 ——

    private async Task LoadMediaInfoAsync(string itemId)
    {
        if (AppServices.Instance.Core is not { } core)
        {
            return;
        }

        var result = await Task.Run(() => core.MediaInfo(itemId)).ConfigureAwait(true);
        if (itemId != _itemId)
        {
            return;
        }

        _mediaInfo = result.Ok ? result.Data : null;
        UpdateChips();
        UpdateMediaInfoText();
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
        else if (_current.VideoCodec is { Length: > 0 } sourceCodec)
        {
            chips.Add(sourceCodec.ToUpperInvariant());
        }

        var range = video?.ColorRange ?? _current.ColorRange;
        if (!string.IsNullOrWhiteSpace(range))
        {
            chips.Add(range);
        }

        if (video?.Height is { } height && height > 0)
        {
            chips.Add($"{height}p");
        }
        else if (!string.IsNullOrWhiteSpace(_current.Resolution))
        {
            chips.Add(_current.Resolution);
        }

        if (video?.FrameRate is { } fps && fps > 0)
        {
            chips.Add($"{fps:0}FPS");
        }

        if (video?.BitRate is { } bitRate && bitRate > 0)
        {
            chips.Add($"{bitRate / 1_000_000.0:0.0}mbps");
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
            ShowToast("这条没有选集");
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
            ShowToast("已经是第一集");
            return;
        }

        if (target >= _playlist.Count)
        {
            ShowToast("已经是最后一集");
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
        _seeking = false;
        if (_ipc is not null)
        {
            _ipc.Command("set_property", "time-pos", Seek.Value);
        }
    }

    private void OnVolumeDragStarted(object sender, RoutedEventArgs e)
    {
        _volumeDragging = true;
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

    private void OnMuteClick(object sender, RoutedEventArgs e)
    {
        _ipc?.Command("cycle", "mute");
    }

    // —— 音轨 / 字幕 / 速度 / 更多 ——

    private void OnAudioClick(object sender, RoutedEventArgs e)
    {
        if (OpenAudioMenu() is null)
        {
            ShowToast("这个文件只有一条音轨");
        }
    }

    private void OnSubtitleClick(object sender, RoutedEventArgs e) => OpenSubtitleMenu();

    private ContextMenu? OpenAudioMenu()
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

        return OpenMenu(AudioButton, choices);
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

    private ContextMenu OpenSubtitleMenu()
    {
        var anySelected = _subtitleTracks.Any(t => t.Selected);
        var choices = new List<(string Label, bool Selected, Action Action)>
        {
            ("关闭字幕", !anySelected, TurnSubtitlesOff),
        };

        for (var i = 0; i < _subtitleTracks.Count; i++)
        {
            var track = _subtitleTracks[i];
            var position = i;
            choices.Add((track.Describe(), track.Selected, (Action)(() => SelectSubtitle(position))));
        }

        return OpenMenu(SubtitleButton, choices);
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

    private void OnSpeedClick(object sender, RoutedEventArgs e)
    {
        double[] speeds = { 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3 };
        var current = Math.Round(_lastSpeed, 2);

        var choices = speeds
            .Select(speed => (
                Label: speed == 1 ? "正常（1.0×）" : $"{speed:0.##}×",
                Selected: Math.Abs(speed - current) < 0.01,
                Action: (Action)(() => SetSpeed(speed))))
            .ToList();

        OpenMenu(SpeedButton, choices);
    }

    private double _lastSpeed = 1;

    private void SetSpeed(double speed)
    {
        _lastSpeed = speed;
        SpeedGlyph.Text = $"{speed:0.##}×";
        _ipc?.Command("set_property", "speed", speed);
    }

    private void OnMoreClick(object sender, RoutedEventArgs e) => OpenMoreMenu();

    private ContextMenu OpenMoreMenu()
    {
        var choices = new List<(string Label, bool Selected, Action Action)>();

        var index = _playlist.FindIndex(episode => episode.Id == _itemId);
        if (index >= 0 && index + 1 < _playlist.Count)
        {
            var next = _playlist[index + 1];
            choices.Add(($"下一集：{next.Badge}", false, () => _ = SwitchToAsync(next.Id)));
        }

        choices.Add((_fullscreen ? "退出全屏" : "全屏", _fullscreen, ToggleFullscreen));
        choices.Add((
            _hardwareDecode ? "硬解码：开（HW / GPU）" : "硬解码：关（软解）",
            _hardwareDecode,
            ToggleHardwareDecode));
        choices.Add(("媒体信息", MediaInfoPanel.Visibility == Visibility.Visible, ToggleMediaInfo));
        choices.Add(("打开日志目录", false, OpenLogFolder));

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
                FileName = Path.GetDirectoryName(MpvProcess.LogPath)!,
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

    // —— 截图 ——

    private void OnShotClick(object sender, RoutedEventArgs e) => TakeScreenshot();

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

        EpisodePanelTitle.Text = "选集";
        EpisodePanelMeta.Text = $"{_playlist.Count} 集";

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
        EpisodePanel.Visibility = EpisodePanel.Visibility == Visibility.Visible
            ? Visibility.Collapsed
            : Visibility.Visible;

        if (EpisodePanel.Visibility == Visibility.Visible)
        {
            ScrollPlaylistToCurrent();
        }

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
        var (source, error) = await Playback.ResolveAsync(itemId).ConfigureAwait(true);
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
        _eof = false;
        _tracksApplied = false;
        _audioTracks.Clear();
        _subtitleTracks.Clear();
        _mediaInfo = null;
        _sinceReport = 0;

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

        Launch(source, null);
        await Task.CompletedTask;
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    // —— 窗口 ——

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _ticker.Stop();
        _hideTimer.Stop();

        if (!_eof && _position > 0)
        {
            Playback.Report(_itemId, _position, EffectiveDuration);
        }

        _ipc?.Dispose();
        _mpv.Dispose();

        _surface?.Close();
        _surface = null;
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

    private void OnMouseMove(object sender, MouseEventArgs e) => ShowChrome();

    private void ShowChrome()
    {
        if (!_chromeVisible)
        {
            _chromeVisible = true;
            SetChromeOpacity(1);
        }

        ResetHideTimer();
    }

    private void SetChromeOpacity(double opacity)
    {
        TopBar.Opacity = opacity;
        Chrome.Opacity = opacity;
        RightActions.Opacity = opacity;
        Cursor = opacity > 0 ? Cursors.Arrow : Cursors.None;
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
        if (Chrome.IsMouseOver || TopBar.IsMouseOver || RightActions.IsMouseOver ||
            _seeking || _volumeDragging ||
            EpisodePanel.Visibility == Visibility.Visible ||
            MediaInfoPanel.Visibility == Visibility.Visible)
        {
            ResetHideTimer();
            return;
        }

        _chromeVisible = false;
        SetChromeOpacity(0);
    }

    private void ShowError(string message)
    {
        LoadingPanel.Visibility = Visibility.Collapsed;
        Overlay.Visibility = Visibility.Collapsed;
        ErrorText.Text = message;
        ErrorPanel.Visibility = Visibility.Visible;
    }

    private static string Format(double seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return time.TotalHours >= 1
            ? $"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}"
            : $"{time.Minutes:00}:{time.Seconds:00}";
    }

    // —— 截图巡检用的公开入口 ——

    /// <summary>截图巡检用：把浮层强制显示出来。</summary>
    public void ShowChromeForShot() => ShowChrome();

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

    /// <summary>截图巡检用：打开音频菜单（菜单是独立窗口，需要单独截）。</summary>
    public ContextMenu? OpenAudioMenuForShot() => OpenAudioMenu();

    /// <summary>截图巡检用：打开「更多」菜单。</summary>
    public ContextMenu OpenMoreMenuForShot() => OpenMoreMenu();

    /// <summary>截图巡检用：直接打开媒体信息面板。</summary>
    public void ShowMediaInfoForShot()
    {
        EpisodePanel.Visibility = Visibility.Collapsed;
        MediaInfoPanel.Visibility = Visibility.Visible;
        UpdateMediaInfoText();
    }

    private const int WM_NCHITTEST = 0x0084;
    private const int HTLEFT = 10;
    private const int HTRIGHT = 11;
    private const int HTTOP = 12;
    private const int HTTOPLEFT = 13;
    private const int HTTOPRIGHT = 14;
    private const int HTBOTTOM = 15;
    private const int HTBOTTOMLEFT = 16;
    private const int HTBOTTOMRIGHT = 17;

    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_NOOWNERZORDER = 0x0200;

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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);

    private sealed class MpvTrack
    {
        public MpvTrack(int id, string type, string? language, string? title, string? codec,
            int? channels, bool selected)
        {
            Id = id;
            Type = type;
            Language = language;
            Title = title;
            Codec = codec;
            Channels = channels;
            Selected = selected;
        }

        public int Id { get; }
        public string Type { get; }
        public string? Language { get; }
        public string? Title { get; }
        public string? Codec { get; }
        public int? Channels { get; }
        public bool Selected { get; }

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

        public string Id { get; init; } = "";
        public string Badge { get; init; } = "";
        public string Meta { get; init; } = "";
        public string Initial { get; init; } = "";
        public string? PosterPath { get; init; }

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
