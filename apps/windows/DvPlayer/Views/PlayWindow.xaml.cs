using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using DvPlayer.Player;
using DvPlayer.Services;

namespace DvPlayer.Views;

/// <summary>
/// 播放窗口：一个 <see cref="MpvHost"/> + 底部控制条。
///
/// 视频画面完全由 mpv 渲染（<c>--wid</c> 挂进来），壳只负责控制条、
/// 快捷键和进度回写。构造函数只接收 <see cref="PlaySourceDto"/>，
/// 所以飞牛、Emby 以及以后任何源都走同一个窗口。
/// </summary>
public partial class PlayWindow : Window
{
    /// <summary>每隔几秒回写一次进度。</summary>
    private const int ReportEverySeconds = 10;

    private readonly PlaySourceDto _source;
    private readonly MpvProcess _mpv = new();

    private readonly DispatcherTimer _ticker = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(3) };

    private IntPtr _hwnd;
    private bool _started;
    private MpvIpc? _ipc;

    private double _position;
    private double _duration;
    private bool _seeking;
    private bool _volumeDragging;
    private bool _paused;
    private bool _eof;
    private int _sinceReport;
    private bool _chromeVisible = true;

    public PlayWindow(PlaySourceDto source)
    {
        _source = source;
        InitializeComponent();

        TitleText.Text = source.Title;
        LoadingTitle.Text = source.Title;
        DurationText.Text = Format(source.DurationSeconds);

        Host.HostReady += OnHostReady;
        Loaded += OnLoaded;
        Closing += OnClosing;

        _ticker.Tick += OnTick;
        _hideTimer.Tick += OnHideTick;
        _ticker.Start();
        ResetHideTimer();
    }

    /// <summary>
    /// 解析播放源并打开窗口。失败时在主窗口提示，不抛异常。
    /// </summary>
    public static async Task<PlayWindow?> OpenAsync(Window? owner, string itemId)
    {
        var (source, error) = await Playback.ResolveAsync(itemId).ConfigureAwait(true);
        if (source is null)
        {
            MessageBox.Show(owner, error ?? "取播放地址失败", "DV Player",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }

        var window = new PlayWindow(source) { Owner = owner };
        window.Show();
        return window;
    }

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
        if (_hwnd != IntPtr.Zero)
        {
            StartMpv();
        }
    }

    private void StartMpv()
    {
        if (_started || _hwnd == IntPtr.Zero)
        {
            return;
        }

        _started = true;

        var launch = Playback.ToLaunch(_source);
        Trace.Write($"mpv start url={launch.Url} headers={launch.Headers?.Count ?? 0} start={launch.StartSeconds}");

        try
        {
            _mpv.Start(_hwnd, launch);
        }
        catch (Exception ex)
        {
            Trace.Write("mpv start failed: " + ex.Message);
            ShowError(ex.Message);
            return;
        }

        _ = AttachIpcAsync();
    }

    private async Task AttachIpcAsync()
    {
        var ready = _mpv.IpcReady;
        var ipc = _mpv.Ipc;
        if (ready is null || ipc is null)
        {
            return;
        }

        // 控制条不是必需品：IPC 连不上也让它继续播。
        if (!await ready.ConfigureAwait(true))
        {
            LoadingStatus.Text = "已开始播放（控制通道未连上）";
            await Task.Delay(1200).ConfigureAwait(true);
            LoadingPanel.Visibility = Visibility.Collapsed;
            return;
        }

        _ipc = ipc;
        ipc.PropertyChanged += OnMpvProperty;
        ipc.Disconnected += () => Dispatcher.BeginInvoke(() =>
        {
            if (!_eof)
            {
                Close();
            }
        });

        foreach (var name in new[] { "time-pos", "duration", "pause", "volume", "eof-reached" })
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

                case "eof-reached" when value.ValueKind is JsonValueKind.True or JsonValueKind.False:
                    _eof = value.GetBoolean();
                    if (_eof)
                    {
                        Playback.Report(_source.ItemId, EffectiveDuration, EffectiveDuration);
                        Close();
                    }
                    break;
            }
        });
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
    private double EffectiveDuration => _duration > 0 ? _duration : _source.DurationSeconds;

    private void OnTick(object? sender, EventArgs e)
    {
        if (++_sinceReport < ReportEverySeconds || _position <= 0)
        {
            return;
        }

        _sinceReport = 0;
        Playback.Report(_source.ItemId, _position, EffectiveDuration);
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

    private void OnBack10Click(object sender, RoutedEventArgs e) => SeekBy(-10);

    private void OnForward10Click(object sender, RoutedEventArgs e) => SeekBy(10);

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

    private void OnTracksClick(object sender, RoutedEventArgs e)
    {
        // 音轨/字幕面板：下一轮补；这里先把当前轨道写进日志，便于确认直链里的轨道。
        if (_ipc is not null)
        {
            _ipc.Command("script-message", "dv-tracks");
        }
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    // —— 窗口 ——

    private void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _ticker.Stop();
        _hideTimer.Stop();

        if (!_eof && _position > 0)
        {
            Playback.Report(_source.ItemId, _position, EffectiveDuration);
        }

        _ipc?.Dispose();
        _mpv.Dispose();
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
                Close();
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
            Chrome.Opacity = 1;
            Chrome.IsHitTestVisible = true;
            Cursor = Cursors.Arrow;
        }

        ResetHideTimer();
    }

    private void ResetHideTimer()
    {
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    private void OnHideTick(object? sender, EventArgs e)
    {
        _hideTimer.Stop();

        // 鼠标停在控制条上、或正在拖动时别隐藏。
        if (Chrome.IsMouseOver || _seeking || _volumeDragging)
        {
            ResetHideTimer();
            return;
        }

        _chromeVisible = false;
        Chrome.Opacity = 0;
        Chrome.IsHitTestVisible = false;
        Cursor = Cursors.None;
    }

    private void ShowError(string message)
    {
        LoadingPanel.Visibility = Visibility.Collapsed;
        Chrome.Visibility = Visibility.Collapsed;
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
}
