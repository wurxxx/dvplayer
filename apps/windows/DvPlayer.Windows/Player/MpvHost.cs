using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace DvPlayer.Windows.Player;

/// <summary>
/// 交给 mpv <c>--wid</c> 的父 HWND。
///
/// mpv 会在这个窗口里创建自己的子窗口并用 gpu-next 渲染（官方构建带 FEL 合成）。
/// 壳不负责画视频，只负责：把窗口尺寸同步给 mpv、避免擦背景时的闪烁。
///
/// DPI：进程在 app.manifest 里声明了 PerMonitorV2，WPF 会在跨屏/改缩放时
/// 重新布局，这里的 HWND 随之收到 WM_SIZE，再把客户区尺寸推给 mpv 的子窗口。
/// A4 的教训是宿主不声明 DPI 感知就会被系统虚拟化坐标，画面裁切。
/// </summary>
public sealed class MpvHost : HwndHost
{
    private const int WS_CHILD = 0x40000000;
    private const int WS_VISIBLE = 0x10000000;
    private const int WS_CLIPCHILDREN = 0x02000000;
    private const int WS_CLIPSIBLINGS = 0x04000000;

    private const int WM_SIZE = 0x0005;
    private const int WM_ERASEBKGND = 0x0014;
    private const int WM_DPICHANGED = 0x02E0;

    private const uint GW_CHILD = 5;

    private const string WindowClass = "DvPlayerMpvHost";

    // HWND -> 实例。WndProc 必须是静态的（窗口类持有函数指针），
    // 用这张表把消息转发回对应的控件。
    private static readonly Dictionary<IntPtr, MpvHost> Instances = new();
    private static readonly WndProcDelegate WndProcHolder = WndProc;
    private static bool _classRegistered;

    private IntPtr _hwnd;
    private IntPtr _mpvChild;

    /// <summary>mpv 可以挂上来的父窗口句柄；在 <see cref="BuildWindowCore"/> 之前是 <see cref="IntPtr.Zero"/>。</summary>
    public IntPtr HostHandle => _hwnd;

    /// <summary>窗口建好之后触发，壳在这里启动 mpv。</summary>
    public event EventHandler<IntPtr>? HostReady;

    /// <summary>记下 mpv 创建的子窗口，尺寸变化时跟着调。</summary>
    public void AttachMpvChild()
    {
        if (_hwnd == IntPtr.Zero)
        {
            return;
        }

        _mpvChild = GetWindow(_hwnd, GW_CHILD);
        ResizeMpvChild();
    }

    protected override HandleRef BuildWindowCore(HandleRef hwndParent)
    {
        EnsureClassRegistered();

        _hwnd = CreateWindowEx(
            0,
            WindowClass,
            string.Empty,
            WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
            0, 0, 1, 1,
            hwndParent.Handle,
            IntPtr.Zero,
            IntPtr.Zero,
            IntPtr.Zero);

        if (_hwnd == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                $"CreateWindowEx failed: {Marshal.GetLastWin32Error()}");
        }

        Instances[_hwnd] = this;
        HostReady?.Invoke(this, _hwnd);
        return new HandleRef(this, _hwnd);
    }

    protected override void DestroyWindowCore(HandleRef hwnd)
    {
        if (hwnd.Handle != IntPtr.Zero)
        {
            Instances.Remove(hwnd.Handle);
            DestroyWindow(hwnd.Handle);
        }

        _mpvChild = IntPtr.Zero;
        _hwnd = IntPtr.Zero;
    }

    private static void EnsureClassRegistered()
    {
        if (_classRegistered)
        {
            return;
        }

        var wc = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = WndProcHolder,
            lpszClassName = WindowClass,
        };

        if (RegisterClassEx(ref wc) == 0)
        {
            var err = Marshal.GetLastWin32Error();
            // 1410 = ERROR_CLASS_ALREADY_EXISTS，重载/重复创建时正常。
            if (err != 1410)
            {
                throw new InvalidOperationException($"RegisterClassEx failed: {err}");
            }
        }

        _classRegistered = true;
    }

    private static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam)
    {
        if (!Instances.TryGetValue(hwnd, out var self))
        {
            return DefWindowProc(hwnd, msg, wParam, lParam);
        }

        switch (msg)
        {
            case WM_ERASEBKGND:
                return new IntPtr(1);   // mpv 自己画，别擦成白闪

            case WM_SIZE:
                if (self._mpvChild == IntPtr.Zero)
                {
                    self._mpvChild = GetWindow(hwnd, GW_CHILD);
                }

                self.ResizeMpvChild();
                return IntPtr.Zero;

            case WM_DPICHANGED:
                // WPF 会按新 DPI 重新布局，随后收到 WM_SIZE；
                // 这里只要保证 mpv 的子窗口跟得上。
                self.ResizeMpvChild();
                return IntPtr.Zero;
        }

        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private void ResizeMpvChild()
    {
        if (_hwnd == IntPtr.Zero || _mpvChild == IntPtr.Zero)
        {
            return;
        }

        if (!GetClientRect(_hwnd, out var rc))
        {
            return;
        }

        var width = Math.Max(1, rc.Right - rc.Left);
        var height = Math.Max(1, rc.Bottom - rc.Top);
        MoveWindow(_mpvChild, 0, 0, width, height, true);
    }

    private delegate IntPtr WndProcDelegate(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSEX
    {
        public int cbSize;
        public uint style;
        public WndProcDelegate lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassEx(ref WNDCLASSEX lpwcx);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        int dwExStyle,
        string lpClassName,
        string lpWindowName,
        int dwStyle,
        int x, int y, int nWidth, int nHeight,
        IntPtr hWndParent,
        IntPtr hMenu,
        IntPtr hInstance,
        IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr DefWindowProc(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);
}
