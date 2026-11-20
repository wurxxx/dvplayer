using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DvPlayer.Services;

/// <summary>
/// 把窗口内容渲染成 PNG。用于无桌面环境的 UI 回归：
/// DvPlayer.exe --screenshot D:\path\to\dir
///
/// <see cref="Save"/> 走 RenderTargetBitmap，只画 WPF 自己的内容（浮层）；
/// 视频是另一个窗口里的原生画面，要用 <see cref="SaveScreen"/> 从桌面抓，
/// 那样才是用户真正看到的样子。
/// </summary>
public static class UiCapture
{
    /// <param name="flattenOnBlack">
    /// 播放页的浮层窗口是逐像素透明的，直接把 RTB 存下来背景是空的；
    /// 垫一层黑再存，截图才看得清。
    /// </param>
    public static void Save(FrameworkElement element, string path, bool flattenOnBlack = false)
    {
        element.UpdateLayout();

        var width = (int)Math.Max(1, element.ActualWidth);
        var height = (int)Math.Max(1, element.ActualHeight);

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(element);

        if (flattenOnBlack)
        {
            var flat = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(Brushes.Black, null, new Rect(0, 0, width, height));
                dc.DrawImage(bitmap, new Rect(0, 0, width, height));
            }

            flat.Render(visual);
            bitmap = flat;
        }

        Write(bitmap, path);
    }

    /// <summary>从桌面抓这块窗口的真实画面（包含下面那层视频）。</summary>
    public static void SaveScreen(Window window, string path)
    {
        var dpi = VisualTreeHelper.GetDpi(window);
        var x = (int)Math.Round(window.Left * dpi.DpiScaleX);
        var y = (int)Math.Round(window.Top * dpi.DpiScaleY);
        var width = (int)Math.Max(1, Math.Round(window.ActualWidth * dpi.DpiScaleX));
        var height = (int)Math.Max(1, Math.Round(window.ActualHeight * dpi.DpiScaleY));

        var screen = GetDC(IntPtr.Zero);
        var memory = CreateCompatibleDC(screen);
        var bitmap = CreateCompatibleBitmap(screen, width, height);
        var previous = SelectObject(memory, bitmap);

        try
        {
            BitBlt(memory, 0, 0, width, height, screen, x, y, SRCCOPY);

            var source = Imaging.CreateBitmapSourceFromHBitmap(
                bitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            Write(source, path);
        }
        finally
        {
            SelectObject(memory, previous);
            DeleteObject(bitmap);
            DeleteDC(memory);
            ReleaseDC(IntPtr.Zero, screen);
        }
    }

    private static void Write(BitmapSource bitmap, string path)
    {
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

    private const int SRCCOPY = 0x00CC0020;

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr dc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);

    [DllImport("gdi32.dll")]
    private static extern bool BitBlt(
        IntPtr destination, int x, int y, int width, int height,
        IntPtr source, int sourceX, int sourceY, int rop);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr obj);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr dc);
}
