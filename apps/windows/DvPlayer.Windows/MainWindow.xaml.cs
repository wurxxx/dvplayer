using System.IO;
using System.Windows;
using System.Windows.Input;
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

    private readonly MpvProcess _mpv = new();
    private bool _isFullscreen;

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

    private void ToggleFullscreen()
    {
        _isFullscreen = !_isFullscreen;

        if (_isFullscreen)
        {
            WindowState = WindowState.Normal;
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            WindowState = WindowState.Maximized;
        }
        else
        {
            WindowState = WindowState.Normal;
            WindowStyle = WindowStyle.SingleBorderWindow;
            ResizeMode = ResizeMode.CanResize;
        }
    }
}
