using System.Windows;
using System.Windows.Media;

namespace DvPlayer.Player;

/// <summary>
/// 视频层：一个无边框黑窗，里面只放 <see cref="MpvHost"/>。
///
/// 为什么要单独一个窗口：WPF 的 <see cref="MpvHost"/>（HwndHost）是原生子窗口，
/// 永远盖在同一个窗口的 WPF 内容之上（airspace），浮层控制条放在同一个窗口里
/// 根本看不见。所以视频沉在下面这个窗口，控制条是上面一个逐像素透明的窗口，
/// 两个窗口保持同一矩形，由播放窗口负责同步和 z 序。
/// </summary>
public sealed class PlayerSurfaceWindow : Window
{
    public PlayerSurfaceWindow()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowInTaskbar = false;
        ShowActivated = false;
        Background = Brushes.Black;
        Left = -10000;
        Top = -10000;
        Width = 320;
        Height = 180;

        Content = Host = new MpvHost();
    }

    public MpvHost Host { get; }
}
