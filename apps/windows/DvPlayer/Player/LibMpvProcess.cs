using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace DvPlayer.Player;

/// <summary>
/// 进程内 libmpv 后端：<c>libmpv-2.dll</c> 直接加载进本进程，
/// 用 <c>wid</c> 选项把画面画进壳的 HWND。
///
/// 和 <see cref="MpvProcess"/>（子进程 <c>mpv.exe --wid</c>）的关系：
/// 两者喂给 mpv 的选项**逐条对应**——那边的 <c>--hwdec=auto-safe</c>
/// 就是这边的 <c>mpv_set_option_string(ctx, "hwdec", "auto-safe")</c>。
/// 所以 DV P7 的拆层、EL 合成、gpu-next 整形走的是同一套代码（ADR-0001），
/// 差别只在"谁来装这份 mpv"。
///
/// 体积：**几乎不省**。官方（shinchiro）的 dev 包里 <c>libmpv-2.dll</c> 是
/// 静态链接的，116.1 MB，和 <c>mpv.exe</c> 的 116.2 MB 一样大；实测 zip
/// 只从 110.1 MB 降到 107.2 MB（省的是 mpv 目录里的 doc / d3dcompiler）。
/// 要真正瘦身必须自己编共享链接的 ffmpeg + libmpv（见 ADR-0012）。
///
/// 代价：mpv 和壳在同一个进程里，mpv 崩了壳也一起死。所以默认后端仍是
/// 子进程；用 <c>DVPLAYER_MPV_BACKEND=libmpv</c> 显式切换。
/// </summary>
public sealed class LibMpvProcess : IMpvEngine
{
    private IntPtr _ctx;
    private LibMpvClient? _client;
    private int _session;
    private readonly object _gate = new();
    private readonly object _logGate = new();
    private StreamWriter? _log;
    private int _logSession;

    /// <summary>
    /// 自检开关：把 libbluray 的调试位全开（mpv 的 stream 日志到 trace）。
    /// 只有查盘内菜单问题时才打开，平时别让日志涨起来。
    /// </summary>
    public static bool TraceLibbluray { get; set; }

    /// <summary>日志路径和子进程后端一致，排查时不用记两套。</summary>
    public static string LogPath => MpvProcess.LogPath;

    /// <summary>
    /// 壳自己那几行（初始化失败、选项设置失败、terminate 错误）写这个文件。
    /// 不能和 <see cref="LogPath"/> 共用：进程内后端把 mpv 日志交给
    /// <c>log-file</c> 写，两边各持一个写句柄会互相把对方顶掉。
    /// </summary>
    private static string ShellLogPath =>
        Path.Combine(Path.GetDirectoryName(MpvProcess.LogPath)!, "mpv-shell.log");

    public bool IsRunning
    {
        get
        {
            lock (_gate)
            {
                return _ctx != IntPtr.Zero;
            }
        }
    }

    public IMpvControl? Control => _client;

    public Task<bool>? ControlReady { get; private set; }

    public event EventHandler? Exited;

    public void Start(IntPtr wid, MpvLaunch launch, string? mpvPath = null)
    {
        // mpvPath 是子进程后端用来指定 mpv.exe 的，进程内后端不需要。
        _ = mpvPath;

        if (wid == IntPtr.Zero)
        {
            throw new InvalidOperationException("MpvHost 还没建好窗口。");
        }

        if (!launch.IsNetwork && !launch.IsDisc && !File.Exists(launch.Url))
        {
            throw new FileNotFoundException("找不到媒体文件。", launch.Url);
        }

        Stop();

        var session = ++_session;
        OpenLog(session);

        IntPtr ctx;
        try
        {
            ctx = LibMpv.mpv_create();
        }
        catch (DllNotFoundException ex)
        {
            CloseLog(session);
            throw new InvalidOperationException(
                "找不到 libmpv-2.dll。用进程内后端时它必须和 DvPlayer.exe 放在同一目录。",
                ex);
        }
        catch (BadImageFormatException ex)
        {
            CloseLog(session);
            throw new InvalidOperationException(
                "libmpv-2.dll 架构不匹配（需要 x64 版本）。", ex);
        }

        if (ctx == IntPtr.Zero)
        {
            CloseLog(session);
            throw new InvalidOperationException(
                "创建 libmpv 实例失败。libmpv-2.dll 可能没随包发布。");
        }

        try
        {
            ApplyOptions(ctx, wid, launch);
        }
        catch
        {
            LibMpv.mpv_terminate_destroy(ctx);
            CloseLog(session);
            throw;
        }

        var rc = LibMpv.mpv_initialize(ctx);
        if (rc < 0)
        {
            var msg = Marshal.PtrToStringUTF8(LibMpv.mpv_error_string(rc)) ?? rc.ToString();
            LibMpv.mpv_terminate_destroy(ctx);
            CloseLog(session);
            throw new InvalidOperationException($"libmpv 初始化失败：{msg}");
        }

        WriteLog("libmpv 已初始化，开始加载媒体");

        var client = new LibMpvClient(ctx);
        client.StartPump();

        lock (_gate)
        {
            _ctx = ctx;
            _client = client;
        }

        // 加载媒体：loadfile <url>。原盘用 bd:// 协议，走同一入口。
        client.Command("loadfile", launch.Url);

        ControlReady = client.ConnectAsync(TimeSpan.FromSeconds(10));
    }

    /// <summary>
    /// 把子进程后端的命令行参数逐条搬到 libmpv 选项上。
    /// **必须和 <see cref="MpvProcess"/> 的 BuildArgs 保持一致**：
    /// 任何一条漏了或写错，DV 处理路径就会和已验证的子进程版本不同。
    /// </summary>
    private void ApplyOptions(IntPtr ctx, IntPtr wid, MpvLaunch launch)
    {
        void Opt(string name, string value)
        {
            var rc = LibMpv.mpv_set_option_string(ctx, name, value);
            if (rc < 0)
            {
                var msg = Marshal.PtrToStringUTF8(LibMpv.mpv_error_string(rc)) ?? rc.ToString();
                WriteLog($"选项 {name}={value} 设置失败：{msg}");
            }
        }

        Opt("config", "no");                       // --no-config
        Opt("vo", "gpu-next");                     // DV 整形只在这条路径上（ADR-0003）
        Opt("hwdec", "auto-safe");
        Opt("wid", wid.ToInt64().ToString(CultureInfo.InvariantCulture));
        Opt("osc", "no");
        Opt("keep-open", "yes");
        // 和子进程后端保持一致：同目录外挂字幕由壳自己加。
        Opt("sub-auto", "no");

        if (Environment.GetEnvironmentVariable("DVPLAYER_MPV_HEADLESS") != "1")
        {
            Opt("pause", "yes");
        }

        if (Environment.GetEnvironmentVariable("DVPLAYER_MPV_HEADLESS") == "1")
        {
            Opt("vo", "null");
            Opt("ao", "null");
        }

        var settings = DvPlayer.Services.AppServices.Instance.Settings;

        if (settings.AudioPassthrough)
        {
            Opt("audio-spdif", "ac3,eac3,dts,dts-hd,truehd");
        }

        if (settings.HdrPassthrough)
        {
            Opt("target-colorspace-hint", "yes");
        }

        // HDR 亮度参考：0 = 自动（跟随系统 SDR 白点）。
        if (settings.HdrPeakNits > 0)
        {
            Opt("target-peak", settings.HdrPeakNits.ToString(CultureInfo.InvariantCulture));
        }

        // 弹幕 ASS 走第二字幕：默认 strip 会剥掉样式（滚动 / 颜色 / 字号）。
        Opt("secondary-sub-ass-override", "no");

        if (!string.IsNullOrWhiteSpace(settings.AudioDevice))
        {
            Opt("audio-device", settings.AudioDevice);
        }

        // 进程内后端没有 IPC 管道，这两项只在子进程后端有意义，但保持
        // 选项一致能避免行为分叉（比如 mpv 抢键盘）。
        Opt("input-default-bindings", "no");
        Opt("input-vo-keyboard", "no");

        // mpv 自己的日志落盘。子进程后端靠重定向 stderr 拿到这些行，
        // 进程内没有 stderr，不设 log-file 的话 `[el_pair]`、滤镜、
        // 解码器这类信息在真机上根本看不到（DV 回归就没法验）。
        Opt("log-file", LogPath);
        // 自检：libbluray 的 debug 位只在 mpv 的 trace 级别才全开，
        // 查盘内菜单的鼠标命中 / 页面切换时用它。
        Opt("msg-level", TraceLibbluray
            ? "all=info,stream=trace"
            : "all=info,vd=v,vf=v,mkv=v,vo/gpu-next=info");

        if (!string.IsNullOrWhiteSpace(launch.Title))
        {
            Opt("force-media-title", launch.Title);
        }

        if (launch.IsNetwork)
        {
            var bufferMb = MpvProcess.BufferSizeMb;
            Opt("cache", "yes");
            Opt("demuxer-max-bytes", $"{bufferMb}MiB");
            Opt("demuxer-max-back-bytes", $"{Math.Max(64, bufferMb / 2)}MiB");
            Opt("network-timeout", "30");

            if (!string.IsNullOrWhiteSpace(launch.Proxy))
            {
                Opt("http-proxy", NormalizeProxy(launch.Proxy));
            }

            // 飞牛 / Emby 的鉴权头。libmpv 的 http-header-fields 是列表选项，
            // 必须一次给出完整列表；`set_option_string` 不认命令行里的 `-add` 后缀。
            // 多个头用 , 分隔——但值里本身可能带逗号（cookie、UA 常见），
            // 所以逐条用 mpv 的转义规则包一层。
            var headers = launch.Headers ?? Array.Empty<MpvHeader>();
            if (headers.Count > 0)
            {
                var joined = string.Join(",", headers.Select(h => EscapeListValue($"{h.Name}: {h.Value}")));
                Opt("http-header-fields", joined);
            }
        }

        if (launch.StartSeconds > 1)
        {
            Opt("start", launch.StartSeconds.ToString("0.###", CultureInfo.InvariantCulture));
        }

        // 原盘参数：--bluray-device=<iso> 这类，逐条转成选项。
        foreach (var arg in launch.ExtraArgs ?? Array.Empty<string>())
        {
            if (!arg.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            var body = arg[2..];
            var eq = body.IndexOf('=');
            if (eq > 0)
            {
                Opt(body[..eq], body[(eq + 1)..]);
            }
            else
            {
                Opt(body, "yes");
            }
        }
    }

    private static string NormalizeProxy(string proxy)
    {
        var value = proxy.Trim();
        return value.Contains("://", StringComparison.Ordinal) ? value : "http://" + value;
    }

    /// <summary>
    /// mpv 列表选项的分隔符是 <c>,</c>；值本身含逗号或反斜杠时要转义。
    /// mpv 的规则是 <c>\,</c> 和 <c>\\</c>（见 options.rst 的 List Options）。
    /// </summary>
    private static string EscapeListValue(string value) =>
        value.Replace("\\", "\\\\").Replace(",", "\\,");

    public void Stop()
    {
        LibMpvClient? client;
        IntPtr ctx;

        lock (_gate)
        {
            client = _client;
            ctx = _ctx;
            _client = null;
            _ctx = IntPtr.Zero;
        }

        ControlReady = null;

        if (client is null && ctx == IntPtr.Zero)
        {
            return;
        }

        // 先停事件泵（它会碰 ctx），再销毁 ctx。顺序反了会崩在
        // mpv_wait_event 里。client.Dispose() 内部会做 terminate_destroy。
        client?.Dispose();

        // 兜底：client 已经没了但 ctx 还在（初始化后立刻 Stop 的窗口期），
        // 直接销毁，别泄漏。
        if (client is null && ctx != IntPtr.Zero)
        {
            try
            {
                LibMpv.mpv_terminate_destroy(ctx);
            }
            catch (Exception ex)
            {
                WriteLog("terminate 失败：" + ex.Message);
            }
        }

        CloseLog(_session);
    }

    public void Dispose() => Stop();

    private void OpenLog(int session)
    {
        var dir = Path.GetDirectoryName(ShellLogPath)!;

        try
        {
            Directory.CreateDirectory(dir);
            var stream = new FileStream(ShellLogPath, FileMode.Create, FileAccess.Write, FileShare.Read);
            var writer = new StreamWriter(stream) { AutoFlush = true };

            lock (_logGate)
            {
                try { _log?.Dispose(); } catch (IOException) { }
                _log = writer;
                _logSession = session;
            }
        }
        catch (IOException)
        {
        }
    }

    private void WriteLog(string? line)
    {
        if (line is null)
        {
            return;
        }

        try
        {
            lock (_logGate)
            {
                _log?.WriteLine(line);
            }
        }
        catch (ObjectDisposedException)
        {
        }
        catch (IOException)
        {
        }

        Debug.WriteLine($"[libmpv] {line}");
    }

    private void CloseLog(int session)
    {
        lock (_logGate)
        {
            if (_logSession != session)
            {
                return;
            }

            try
            {
                _log?.Dispose();
            }
            catch (IOException)
            {
            }

            _log = null;
        }
    }
}
