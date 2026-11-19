using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DvPlayer.Services;

/// <summary>
/// 把窗口内容渲染成 PNG。用于无桌面环境的 UI 回归：
/// DvPlayer.exe --screenshot D:\path\to\dir
/// </summary>
public static class UiCapture
{
    public static void Save(FrameworkElement element, string path)
    {
        element.UpdateLayout();

        var width = (int)Math.Max(1, element.ActualWidth);
        var height = (int)Math.Max(1, element.ActualHeight);

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(element);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));

        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }

        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
