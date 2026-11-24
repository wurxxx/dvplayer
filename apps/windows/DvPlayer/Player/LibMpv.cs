using System.Runtime.InteropServices;

namespace DvPlayer.Player;

/// <summary>
/// libmpv 的 C API 声明（<c>libmpv-2.dll</c>，shinchiro 构建）。
///
/// 只声明播放层实际用到的那一小部分：建实例、设选项、发命令、订阅属性、
/// 取事件。render API（<c>render.h</c>）**不需要**——我们用 <c>wid</c> 选项
/// 让 mpv 自己把画面画进壳的 HWND，和现在 <c>mpv.exe --wid</c> 是同一套
/// gpu-next VO 代码，DV P7 的 FEL 合成路径完全一致（ADR-0001）。
///
/// 为什么不用 render API：那要自己建 D3D11 设备、管交换链、处理 resize，
/// 代码量翻倍，而且 DV 的 <c>target-colorspace-hint</c> 还得手工接。
/// <c>wid</c> 这条路和现在验证过的子进程方案行为一致，风险最低。
/// </summary>
internal static class LibMpv
{
    private const string Dll = "libmpv-2";

    // —— 句柄 ——
    [StructLayout(LayoutKind.Sequential)]
    internal struct MpvHandle
    {
        private IntPtr _unused;
    }

    // —— 事件 ——
    /// <summary>
    /// <c>mpv_event</c> 的布局（按 client.h 的定义）：
    /// <code>
    /// typedef struct mpv_event {
    ///     mpv_event_id event_id;   // int
    ///     int error;               // int
    ///     uint64_t reply_userdata;
    ///     void *data;
    /// } mpv_event;
    /// </code>
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct MpvEvent
    {
        public int EventId;
        public int Error;
        public ulong ReplyUserdata;
        public IntPtr Data;
    }

    /// <summary>
    /// <c>mpv_event_property</c>：<c>property-change</c> 事件的 <c>data</c>。
    /// <code>
    /// typedef struct mpv_event_property {
    ///     const char *name;
    ///     mpv_format format;
    ///     void *data;
    /// } mpv_event_property;
    /// </code>
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct MpvEventProperty
    {
        public IntPtr Name;
        public int Format;
        public IntPtr Data;
    }

    // mpv_format 枚举里我们关心的几个
    internal const int MpvFormatNone = 0;
    internal const int MpvFormatString = 1;
    internal const int MpvFormatOsdString = 2;
    internal const int MpvFormatFlag = 3;
    internal const int MpvFormatInt64 = 4;
    internal const int MpvFormatDouble = 5;
    internal const int MpvFormatNode = 6;
    internal const int MpvFormatNodeArray = 7;
    internal const int MpvFormatNodeMap = 8;
    internal const int MpvFormatByteArray = 9;

    // mpv_event_id 里我们关心的几个
    internal const int MpvEventNone = 0;
    internal const int MpvEventShutdown = 1;
    internal const int MpvEventLogMessage = 2;
    internal const int MpvEventEndFile = 7;
    internal const int MpvEventFileLoaded = 8;
    internal const int MpvEventPropertyChange = 22;

    /// <summary><c>mpv_wait_event</c> 的 <c>timeout</c>：0 = 立即返回（不阻塞）。</summary>
    internal const double NoTimeout = 0;

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr mpv_create();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int mpv_initialize(IntPtr ctx);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mpv_terminate_destroy(IntPtr ctx);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int mpv_set_option_string(
        IntPtr ctx, [MarshalAs(UnmanagedType.LPUTF8Str)] string name,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string data);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int mpv_set_property_string(
        IntPtr ctx, [MarshalAs(UnmanagedType.LPUTF8Str)] string name,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string data);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr mpv_get_property_string(
        IntPtr ctx, [MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int mpv_command_string(
        IntPtr ctx, [MarshalAs(UnmanagedType.LPUTF8Str)] string command);

    /// <summary>
    /// <c>int mpv_command(mpv_handle *ctx, const char **args)</c>。
    ///
    /// 用它而不是 <c>mpv_command_string</c>：字符串版要走 mpv 自己的分词器，
    /// URL / Windows 路径里有空格或引号就会被切错（比如
    /// <c>screenshot-to-file C:\Users\a b\x.jpg</c>）。数组版没有这个问题。
    /// </summary>
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int mpv_command(IntPtr ctx, IntPtr args);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int mpv_observe_property(
        IntPtr ctx, ulong replyUserdata, [MarshalAs(UnmanagedType.LPUTF8Str)] string name,
        int format);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr mpv_wait_event(IntPtr ctx, double timeout);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mpv_wakeup(IntPtr ctx);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr mpv_error_string(int error);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void mpv_free(IntPtr data);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr mpv_client_api_version();
}
