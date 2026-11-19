using System.IO;
using System.Runtime.InteropServices;
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
/// </summary>
public partial class MainWindow : FluentWindow
{
    private const string DefaultSample = @"D:\dvplayer\samples\p7-fel.mkv";

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_SHOWWINDOW = 0x0040;

    private readonly MpvProcess _mpv = new();
    private bool _isFullscreen;
    private RECT _restoreRect;
    private WindowChrome? _savedChrome;

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
        // 自动播默认样本，方便 A5 验收；没有就等用户拖文件。
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
            StatusText.Text = Path.GetFileName(file);

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
        }
        catch (Exception ex)
        {
            StatusText.Text = ex.Message;
        }
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
        if (e.Key == Key.F11)
        {
            ToggleFullscreen();
            e.Handled = true;
        }
        else if (e.Key == Key.Escape && _isFullscreen)
        {
            ToggleFullscreen();
            e.Handled = true;
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
            OverlayBar.Visibility = Visibility.Collapsed;

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
            OverlayBar.Visibility = Visibility.Visible;

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
