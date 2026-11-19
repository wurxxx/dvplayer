using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Shell;
using System.Windows.Threading;
using DvPlayer.Windows.Player;
using Microsoft.Win32;
using Wpf.Ui.Controls;

namespace DvPlayer.Windows;

/// <summary>
/// A5 骨架：WPF + WPF-UI 外壳，视频区是 <see cref="MpvHost"/>，
/// 里面跑官方 mpv（--wid），所以 P7 FEL 的能力和 A4 完全一致。
///
/// 控制条和快捷键都走 mpv 的 JSON IPC（<see cref="MpvIpc"/>），
/// 不依赖视频子窗口有没有焦点。
/// </summary>
public partial class MainWindow : FluentWindow
{
    /// <summary>
    /// 默认样片：命令行第一个存在的文件 > DVPLAYER_FILE > 内置样本。
    /// 验收脚本靠这个逐个跑片源。
    /// </summary>
    private static string DefaultSample
    {
        get
        {
            foreach (var arg in Environment.GetCommandLineArgs().Skip(1))
            {
                if (File.Exists(arg))
                {
                    return arg;
                }
            }

            var fromEnv = Environment.GetEnvironmentVariable("DVPLAYER_FILE");
            if (!string.IsNullOrWhiteSpace(fromEnv) && File.Exists(fromEnv))
            {
                return fromEnv;
            }

            return @"D:\dvplayer\samples\p7-fel.mkv";
        }
    }

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_SHOWWINDOW = 0x0040;

    private readonly MpvProcess _mpv = new();
    private bool _isFullscreen;
    private bool _draggingSeek;
    private bool _updatingVolume;
    private double _duration;
    private RECT _restoreRect;
    private WindowChrome? _savedChrome;

    private string? _currentFile;
    private int? _dvProfile;
    private int? _dvLevel;
    private DvElType _dvElType = DvElType.Unknown;
    private bool _dvProbeStarted;
    private CancellationTokenSource? _dvProbeCts;

    public MainWindow()
    {
        InitializeComponent();

        Host.HostReady += OnHostReady;
        Loaded += OnLoaded;
        Closed += (_, _) => _mpv.Dispose();
        PreviewKeyDown += OnPreviewKeyDown;

        AllowDrop = true;
        Drop += OnDrop;
    }

    private void OnHostReady(object? sender, IntPtr hwnd)
    {
        // 自动播默认样本，方便验收；没有就等用户拖文件。
        if (File.Exists(DefaultSample))
        {
            Play(DefaultSample);
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (Host.HostHandle != IntPtr.Zero && !_mpv.IsRunning && File.Exists(DefaultSample))
        {
            Play(DefaultSample);
        }
    }

    private void Play(string file)
    {
        try
        {
            _mpv.Start(Host.HostHandle, file);
            AppTitleBar.Title = "DV Player — " + Path.GetFileName(file);
            ResetDvBadge(file);

            // mpv 建自己的子窗口是异步的，头几秒反复同步一次尺寸。
            var ticks = 0;
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            timer.Tick += (_, _) =>
            {
                Host.AttachMpvChild();
                if (++ticks >= 10)
                {
                    timer.Stop();
                }
            };
            timer.Start();

            var ready = _mpv.IpcReady;
            if (ready is not null)
            {
                _ = ready.ContinueWith(t =>
                {
                    if (t.Result)
                    {
                        Dispatcher.BeginInvoke(new Action(AttachIpc));
                    }
                }, TaskScheduler.Default);
            }
        }
        catch (Exception ex)
        {
            AppTitleBar.Title = "DV Player — " + ex.Message;
        }
    }

    private void AttachIpc()
    {
        var ipc = _mpv.Ipc;
        if (ipc is null)
        {
            return;
        }

        ipc.PropertyChanged -= OnMpvProperty;
        ipc.PropertyChanged += OnMpvProperty;

        foreach (var name in new[]
                 {
                     "time-pos", "duration", "pause", "volume", "media-title",
                     // DV 信息挂在轨道对象里，没有顶层的 dolby-vision-profile
                     "current-tracks/video",
                 })
        {
            ipc.Observe(name);
        }
    }

    private void OnMpvProperty(string name, JsonElement value)
    {
        Dispatcher.BeginInvoke(new Action(() => ApplyProperty(name, value)));
    }

    private void ApplyProperty(string name, JsonElement value)
    {
        switch (name)
        {
            case "time-pos":
                if (value.ValueKind == JsonValueKind.Number)
                {
                    var pos = value.GetDouble();
                    if (!_draggingSeek)
                    {
                        SeekSlider.Value = Math.Min(pos, SeekSlider.Maximum);
                    }

                    ElapsedText.Text = FormatTime(pos);
                }

                break;

            case "duration":
                if (value.ValueKind == JsonValueKind.Number)
                {
                    _duration = value.GetDouble();
                    SeekSlider.Maximum = Math.Max(1, _duration);
                    DurationText.Text = FormatTime(_duration);
                }

                break;

            case "pause":
                if (value.ValueKind is JsonValueKind.True or JsonValueKind.False)
                {
                    PlayButton.Content = value.GetBoolean() ? "▶" : "❚❚";
                }

                break;

            case "volume":
                if (value.ValueKind == JsonValueKind.Number && !_updatingVolume)
                {
                    var v = value.GetDouble();
                    if (Math.Abs(VolumeSlider.Value - v) > 0.5)
                    {
                        _updatingVolume = true;
                        VolumeSlider.Value = v;
                        _updatingVolume = false;
                    }
                }

                break;

            case "media-title":
                if (value.ValueKind == JsonValueKind.String)
                {
                    var title = value.GetString();
                    if (!string.IsNullOrWhiteSpace(title))
                    {
                        AppTitleBar.Title = "DV Player — " + title;
                    }
                }

                break;

            case "current-tracks/video":
                ApplyVideoTrack(value);
                break;
        }
    }

    /// <summary>
    /// 轨道对象里的 DV 字段。FEL / MEL 不在容器元数据里，要靠 RPU 的
    /// disable_residual_flag（ADR-0005，<see cref="DolbyVisionProbe"/> 走 dovi_tool 侧路）。
    /// 轨道先说 profile/level，徽标立刻有内容；FEL/MEL 等探测回来再补。
    /// </summary>
    private void ApplyVideoTrack(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            _dvProfile = null;
            _dvLevel = null;
            UpdateDvBadge();
            return;
        }

        int? profile = null;
        int? level = null;

        if (value.TryGetProperty("dolby-vision-profile", out var p))
        {
            profile = p.ValueKind switch
            {
                JsonValueKind.Number => p.GetInt32(),
                JsonValueKind.String when int.TryParse(p.GetString(), out var n) => n,
                _ => null,
            };
        }

        if (value.TryGetProperty("dolby-vision-level", out var l))
        {
            level = l.ValueKind switch
            {
                JsonValueKind.Number => l.GetInt32(),
                JsonValueKind.String when int.TryParse(l.GetString(), out var n) => n,
                _ => null,
            };
        }

        if (profile is null)
        {
            _dvProfile = null;
            _dvLevel = null;
            UpdateDvBadge();
            return;
        }

        _dvProfile = profile;
        _dvLevel = level;

        // P7 才需要判 FEL/MEL；同一个文件只探一次（含缓存命中）。
        if (profile == 7 && !_dvProbeStarted && _currentFile is not null)
        {
            StartDvProbe(_currentFile);
        }

        UpdateDvBadge();
    }

    private void ResetDvBadge(string file)
    {
        _currentFile = file;
        _dvProfile = null;
        _dvLevel = null;
        _dvElType = DvElType.Unknown;
        _dvProbeStarted = false;

        _dvProbeCts?.Cancel();
        _dvProbeCts?.Dispose();
        _dvProbeCts = null;

        UpdateDvBadge();
    }

    private void StartDvProbe(string file)
    {
        _dvProbeStarted = true;
        _dvProbeCts?.Cancel();
        _dvProbeCts?.Dispose();
        _dvProbeCts = new CancellationTokenSource();
        var token = _dvProbeCts.Token;

        _ = Task.Run(async () =>
        {
            var result = await DolbyVisionProbe.ProbeAsync(file, token).ConfigureAwait(false);
            if (result is null || token.IsCancellationRequested)
            {
                return;
            }

            await Dispatcher.InvokeAsync(() =>
            {
                if (token.IsCancellationRequested)
                {
                    return;
                }

                _dvElType = result.ElType;
                UpdateDvBadge();
            });
        }, token);
    }

    private void UpdateDvBadge()
    {
        if (_dvProfile is null)
        {
            DvBadge.Visibility = Visibility.Collapsed;
            DvBadge.ToolTip = null;
            return;
        }

        var suffix = _dvElType switch
        {
            DvElType.Fel => " (FEL)",
            DvElType.Mel => " (MEL)",
            _ => string.Empty,
        };

        DvBadgeText.Text = $"DV P{_dvProfile}{suffix}";

        var level = _dvLevel is null ? string.Empty : $" · Level {_dvLevel}";
        var layer = _dvElType switch
        {
            DvElType.Fel => " · 增强层 FEL（含完整残差）",
            DvElType.Mel => " · 增强层 MEL（仅低复杂度残差）",
            _ => _dvProfile == 7 ? " · 正在解析增强层…" : string.Empty,
        };

        DvBadge.ToolTip = $"Dolby Vision Profile {_dvProfile}{level}{layer}";
        DvBadge.Visibility = Visibility.Visible;
    }

    private static string FormatTime(double seconds)
    {
        if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < 0)
        {
            return "00:00";
        }

        var total = (int)seconds;
        return $"{total / 60:00}:{total % 60:00}";
    }

    private void TogglePause() => _mpv.Ipc?.Command("cycle", "pause");

    private void SeekBy(double delta) => _mpv.Ipc?.Command("seek", delta, "relative");

    private void SeekTo(double seconds) => _mpv.Ipc?.Command("seek", seconds, "absolute");

    private void NudgeVolume(double delta)
    {
        var target = Math.Clamp(VolumeSlider.Value + delta, 0, 100);
        VolumeSlider.Value = target;
    }

    private void OnPlayClick(object sender, RoutedEventArgs e) => TogglePause();

    private void OnSeekDown(object sender, MouseButtonEventArgs e) => _draggingSeek = true;

    private void OnSeekUp(object sender, MouseButtonEventArgs e)
    {
        _draggingSeek = false;
        SeekTo(SeekSlider.Value);
    }

    private void OnVolumeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_updatingVolume)
        {
            return;
        }

        _mpv.Ipc?.Command("set_property", "volume", Math.Round(e.NewValue));
    }

    private void OnOpenClick(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "打开视频",
            Filter = "视频|*.mkv;*.mp4;*.m2ts;*.ts;*.mov|所有文件|*.*",
        };

        if (dialog.ShowDialog(this) == true)
        {
            Play(dialog.FileName);
        }
    }

    private void OnFullscreenClick(object sender, RoutedEventArgs e) => ToggleFullscreen();

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.F11:
                ToggleFullscreen();
                e.Handled = true;
                break;

            case Key.Escape when _isFullscreen:
                ToggleFullscreen();
                e.Handled = true;
                break;

            case Key.Space:
                TogglePause();
                e.Handled = true;
                break;

            case Key.Left:
                SeekBy(-5);
                e.Handled = true;
                break;

            case Key.Right:
                SeekBy(5);
                e.Handled = true;
                break;

            case Key.Up:
                NudgeVolume(5);
                e.Handled = true;
                break;

            case Key.Down:
                NudgeVolume(-5);
                e.Handled = true;
                break;

            case Key.O when Keyboard.Modifiers == ModifierKeys.Control:
                OnOpenClick(this, new RoutedEventArgs());
                e.Handled = true;
                break;
        }
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0)
        {
            Play(files[0]);
        }
    }

    /// <summary>
    /// 真全屏：不碰 WindowStyle（那会让 WPF 重建 HWND，HwndHost 和 mpv 的子窗口
    /// 会一起被销毁，画面直接黑掉）。这里只做三件事：
    /// 收起标题栏/控制条、把窗口摆到显示器物理矩形、把 WindowChrome 的边框清零。
    /// </summary>
    private void ToggleFullscreen()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero)
        {
            return;
        }

        _isFullscreen = !_isFullscreen;

        if (_isFullscreen)
        {
            GetWindowRect(hwnd, out _restoreRect);

            TitleBarRow.Height = new GridLength(0);
            ControlsRow.Height = new GridLength(0);

            _savedChrome = WindowChrome.GetWindowChrome(this);
            WindowChrome.SetWindowChrome(this, new WindowChrome
            {
                CaptionHeight = 0,
                ResizeBorderThickness = new Thickness(0),
                GlassFrameThickness = new Thickness(0),
                CornerRadius = new CornerRadius(0),
                UseAeroCaptionButtons = false,
            });

            var monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(monitor, ref info))
            {
                var r = info.rcMonitor;
                SetWindowPos(hwnd, IntPtr.Zero, r.Left, r.Top,
                    r.Right - r.Left, r.Bottom - r.Top, SWP_NOZORDER | SWP_SHOWWINDOW);
            }
        }
        else
        {
            TitleBarRow.Height = GridLength.Auto;
            ControlsRow.Height = GridLength.Auto;

            if (_savedChrome is not null)
            {
                WindowChrome.SetWindowChrome(this, _savedChrome);
            }

            SetWindowPos(hwnd, IntPtr.Zero, _restoreRect.Left, _restoreRect.Top,
                _restoreRect.Right - _restoreRect.Left, _restoreRect.Bottom - _restoreRect.Top,
                SWP_NOZORDER | SWP_SHOWWINDOW);
        }
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after,
        int x, int y, int cx, int cy, uint flags);
}
