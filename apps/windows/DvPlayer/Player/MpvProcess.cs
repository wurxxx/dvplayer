using System.Diagnostics;
using System.Globalization;
using System.IO;

namespace DvPlayer.Player;

/// <summary>播放时要带的一个 HTTP 头（飞牛的 Authorization 走这里）。</summary>
public sealed record MpvHeader(string Name, string Value);

/// <summary>
/// 一次播放要交给 mpv 的东西。**不关心源是飞牛还是 Emby**，
/// 上层拿到 <c>PlaySource</c> 后照这里的形状填就行。
/// </summary>
public sealed record MpvLaunch(
    string Url,
    IReadOnlyList<MpvHeader>? Headers = null,
    double StartSeconds = 0,
    string? Title = null,
    bool IsNetwork = true,
    /// <summary>蓝光原盘：URL 是 <c>bd://mpls/&lt;n&gt;</c>，不是磁盘上真实存在的文件。</summary>
    bool IsDisc = false,
    /// <summary>原盘额外参数，例如 <c>--bluray-device=D:\disc.iso</c>。</summary>
    IReadOnlyList<string>? ExtraArgs = null,
    /// <summary>服务器设的 HTTP 代理；空 = 直连。</summary>
    string? Proxy = null);

/// <summary>
/// 启动官方 Windows mpv（shinchiro 构建，带 FEL 合成），用 <c>--wid</c> 挂到
/// <see cref="MpvHost"/> 的窗口里。
///
/// 产品里所有播放能力都来自 mpv 本身：DV P7 FEL 的拆层、EL 合成、gpu-next
/// 的 DV 整形。壳只做窗口托管和 UI，不需要私有补丁（ADR-0001）。
/// </summary>
public sealed class MpvProcess : IDisposable
{

    /// <summary>播放缓冲上限（MB）：设置页的值，夹在 128MB–8GB。
    /// `DVPLAYER_BUFFER_MB` 可强制覆盖，供无桌面环境的自检用（压小才看得到未缓冲段）。</summary>
    public static int BufferSizeMb
    {
        get
        {
            var mb = Math.Clamp(
                DvPlayer.Services.AppServices.Instance.Settings.BufferSizeMb, 128, 8192);

            if (int.TryParse(Environment.GetEnvironmentVariable("DVPLAYER_BUFFER_MB"),
                    out var forced) && forced > 0)
            {
                mb = forced;
            }

            return mb;
        }
    }
    private Process? _process;
    private FileStream? _logStream;
    private StreamWriter? _log;
    private MpvIpc? _ipc;
    private int _session;
    private readonly object _gate = new();
    /// <summary>日志流同时被 stdout/stderr 两个回调线程写，必须串行。</summary>
    private readonly object _logGate = new();
    /// <summary>当前日志属于哪一次 Start；旧播放的收尾不能关掉新日志。</summary>
    private int _logSession;

    public bool IsRunning
    {
        get
        {
            var p = _process;
            return p is not null && !p.HasExited;
        }
    }

    /// <summary>当前这次播放的 IPC 通道；连上之前是 null。</summary>
    public MpvIpc? Ipc => _ipc;

    /// <summary>连上 IPC 的任务；<see cref="Start"/> 之后才有值。</summary>
    public Task<bool>? IpcReady { get; private set; }

    public event EventHandler? Exited;

    /// <summary>播放本地文件。</summary>
    public void Start(IntPtr wid, string file, string? mpvPath = null)
        => Start(wid, new MpvLaunch(file, IsNetwork: false), mpvPath);

    /// <summary>播放任意地址：本地文件或带鉴权头的 HTTP 流。</summary>
    public void Start(IntPtr wid, MpvLaunch launch, string? mpvPath = null)
    {
        if (wid == IntPtr.Zero)
        {
            throw new InvalidOperationException("MpvHost 还没建好窗口。");
        }

        if (!launch.IsNetwork && !launch.IsDisc && !File.Exists(launch.Url))
        {
            throw new FileNotFoundException("找不到媒体文件。", launch.Url);
        }

        Stop();

        var exe = mpvPath ?? FindMpv();
        var pipeName = $"dvplayer-{Environment.ProcessId}-{++_session}";

        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = AppContext.BaseDirectory,
        };

        foreach (var arg in BuildArgs(wid, launch, pipeName))
        {
            psi.ArgumentList.Add(arg);
        }

        OpenLog(_session);
        WriteLog("args: " + string.Join(" ", psi.ArgumentList.Select(RedactArg)));

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => WriteLog(e.Data);
        process.ErrorDataReceived += (_, e) => WriteLog(e.Data);
        process.Exited += (_, _) => Exited?.Invoke(this, EventArgs.Empty);

        try
        {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            // 兜底：DvPlayer 被强杀/崩溃时，mpv 也一起结束，不留后台进程。
            ChildProcessJob.Assign(process);
        }
        catch
        {
            // 启动失败（mpv 被删、无权限）：把刚打开的日志流关掉，别留下句柄。
            CloseLog(_session);
            process.Dispose();
            throw;
        }

        lock (_gate)
        {
            _process = process;
        }

        // 命名管道要等 mpv 起来才存在，这里后台重试，不阻塞 UI。
        var ipc = new MpvIpc(pipeName);
        lock (_gate)
        {
            _ipc = ipc;
        }

        IpcReady = ipc.ConnectAsync(TimeSpan.FromSeconds(10));
    }

    public void Stop()
    {
        Process? process;
        MpvIpc? ipc;
        lock (_gate)
        {
            process = _process;
            _process = null;
            ipc = _ipc;
            _ipc = null;
        }

        IpcReady = null;
        ipc?.Dispose();

        if (process is null)
        {
            return;
        }

        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);

                // 关窗发生在 UI 线程：Kill 之后不能再同步等（WaitForExit(3000)
                // 最坏卡 3 秒，窗口看起来像没响应）。后台收尾，等输出回调结束再关日志。
                var stopping = _session;
                _ = Task.Run(() => Finish(process, stopping));
                return;
            }
        }
        catch (Exception ex)
        {
            // 已退出 / 无权限 / 进程被系统回收：关窗不能因此失败。
            Debug.WriteLine("[mpv] stop failed: " + ex.Message);
        }

        Finish(process, _session);
    }

    /// <summary>
    /// 等 mpv 真正退出后释放进程和日志流。必须在后台线程调用。
    /// <paramref name="session"/> 用来避免关掉下一次 Start 刚打开的新日志。
    /// </summary>
    private void Finish(Process process, int session)
    {
        try
        {
            process.WaitForExit(3000);
        }
        catch (Exception ex)
        {
            Debug.WriteLine("[mpv] wait exit failed: " + ex.Message);
        }
        finally
        {
            process.Dispose();
            CloseLog(session);
        }
    }

    public void Dispose() => Stop();

    /// <summary>
    /// mpv 日志：%LOCALAPPDATA%\dvplayer\mpv.log。直接双击 exe 时也能看。
    /// </summary>
    public static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "dvplayer", "mpv.log");

    /// <summary>
    /// 日志脱敏：鉴权头只留头名，URL 去掉 query 和 userinfo。
    /// mpv 的参数里既有 `--http-header-fields-add=Authorization: ...`，
    /// 也有带 `api_key=` 的直链，原样落盘等于把 token 写进 mpv.log。
    /// </summary>
    private static string RedactArg(string arg)
    {
        if (arg.StartsWith("--http-header-fields", StringComparison.Ordinal))
        {
            var colon = arg.IndexOf(':');
            return colon > 0 ? arg[..(colon + 1)] + " ***" : arg + "=***";
        }

        // GetComponents(SchemeAndServer|Path) 只要 scheme/host/port/path，
        // 天然不带 userinfo 和 query，比 UriBuilder 逐个清字段更稳。
        if (arg.StartsWith("http", StringComparison.OrdinalIgnoreCase) &&
            Uri.TryCreate(arg, UriKind.Absolute, out var uri) &&
            (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
        {
            return uri.GetComponents(
                UriComponents.SchemeAndServer | UriComponents.Path, UriFormat.UriEscaped);
        }

        return arg;
    }

    private static IEnumerable<string> BuildArgs(IntPtr wid, MpvLaunch launch, string pipeName)
    {
        yield return "--no-config";
        yield return "--vo=gpu-next";                    // DV 整形只在这条路径上（ADR-0003）
        yield return "--hwdec=auto-safe";                // QSV/D3D11VA 可用就用，拿不到就软解
        yield return $"--wid={wid.ToInt64()}";           // 挂进壳的 HWND
        yield return "--osc=no";                         // UI 由壳提供
        yield return "--keep-open=yes";                  // 播完留住最后一帧，别闪回桌面

        // 起播先停在第一帧：音频约 0.4 秒就出声，而首帧要 1 秒左右，直接播
        // 会「声音先出来、画面晚约 1 秒」。壳等 `vo-configured` 就绪（或 4 秒
        // 兜底）后才 unpause，声音和画面就一起开始。
        // 无头自检没有真实 VO，收不到 VO 就绪，保持原来的直接播放。
        if (Environment.GetEnvironmentVariable("DVPLAYER_MPV_HEADLESS") != "1")
        {
            yield return "--pause=yes";
        }

        // 远程自检：SSH 会话里没有可用的 D3D 交换链（swapchain 0x887a0022），
        // 用 null 输出让时间轴照常走，五项功能才能按位置验证。
        if (Environment.GetEnvironmentVariable("DVPLAYER_MPV_HEADLESS") == "1")
        {
            yield return "--vo=null";
            yield return "--ao=null";
        }

        // 音频直通 / HDR 直通 / 输出设备从设置带进来：换集重启 mpv 也一直是用户选的。
        var settings = DvPlayer.Services.AppServices.Instance.Settings;
        if (settings.AudioPassthrough)
        {
            yield return "--audio-spdif=ac3,eac3,dts,dts-hd,truehd";
        }

        if (settings.HdrPassthrough)
        {
            yield return "--target-colorspace-hint=yes";
        }

        if (!string.IsNullOrWhiteSpace(settings.AudioDevice))
        {
            yield return "--audio-device=" + settings.AudioDevice;
        }

        yield return $"--input-ipc-server=\\\\.\\pipe\\{pipeName}";
        yield return "--input-default-bindings=no";      // 快捷键归壳，mpv 不抢键盘
        yield return "--input-vo-keyboard=no";
        yield return "--msg-level=all=info,vd=v,vf=v,mkv=v,vo/gpu-next=info";

        if (!string.IsNullOrWhiteSpace(launch.Title))
        {
            yield return "--force-media-title=" + launch.Title;
        }

        if (launch.IsNetwork)
        {
            // 缓冲大小跟着设置走：默认 512MB，蓝光原盘可以调到 2G / 4G。
            var bufferMb = BufferSizeMb;
            yield return "--cache=yes";
            yield return $"--demuxer-max-bytes={bufferMb}MiB";
            yield return $"--demuxer-max-back-bytes={Math.Max(64, bufferMb / 2)}MiB";
            yield return "--network-timeout=30";

            // 服务器的代理设置：该源的接口、海报和播放请求都走它。
            if (!string.IsNullOrWhiteSpace(launch.Proxy))
            {
                yield return "--http-proxy=" + NormalizeProxy(launch.Proxy);
            }

            // 飞牛、Emby 都要带鉴权头；-add 形式不会把值里的逗号切开。
            foreach (var header in launch.Headers ?? Array.Empty<MpvHeader>())
            {
                yield return $"--http-header-fields-add={header.Name}: {header.Value}";
            }
        }

        if (launch.StartSeconds > 1)
        {
            // 小数点必须是 "."：某些区域设置会输出 ","，mpv 会把 --start=12,5 解析错。
            yield return "--start=" + launch.StartSeconds.ToString("0.###", CultureInfo.InvariantCulture);
        }

        // 原盘：`--bluray-device=<iso>`，URL 是 `bd://mpls/<n>`。
        foreach (var arg in launch.ExtraArgs ?? Array.Empty<string>())
        {
            yield return arg;
        }

        yield return launch.Url;
    }

    /// <summary>代理地址允许只写 <c>127.0.0.1:7890</c>，mpv 要完整的 scheme。</summary>
    private static string NormalizeProxy(string proxy)
    {
        var value = proxy.Trim();
        return value.Contains("://", StringComparison.Ordinal) ? value : "http://" + value;
    }

    private static string FindMpv()
    {
        return MpvLocator.Find()
            ?? throw new FileNotFoundException(
                "找不到 mpv.exe。设 DVPLAYER_MPV，或把它放在 exe 旁边的 mpv\\mpv.exe。");
    }

    private void OpenLog(int session)
    {
        var dir = Path.GetDirectoryName(LogPath)!;

        try
        {
            Directory.CreateDirectory(dir);
            var stream = new FileStream(LogPath, FileMode.Create, FileAccess.Write, FileShare.Read);
            var writer = new StreamWriter(stream) { AutoFlush = true };

            lock (_logGate)
            {
                // 上一次 Start 失败可能留下没关的流，先收掉再挂新的。
                try { _log?.Dispose(); } catch (IOException) { }
                _logStream = stream;
                _log = writer;
                _logSession = session;
            }
        }
        catch (IOException)
        {
            // 日志写不了不影响播放。
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
            // stdout 和 stderr 各一个回调线程，StreamWriter 不是线程安全的。
            lock (_logGate)
            {
                _log?.WriteLine(line);
            }
        }
        catch (ObjectDisposedException)
        {
            // 进程在关闭，忽略。
        }
        catch (IOException)
        {
            // 磁盘满 / 日志被占用：写日志失败不能打断播放。
        }

        Debug.WriteLine($"[mpv] {line}");
    }

    private void CloseLog(int session)
    {
        lock (_logGate)
        {
            // 会话已经换了：这是旧播放的收尾，别关掉新一代的日志流。
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
                // 刷盘失败也不能卡住关窗。
            }

            _log = null;
            _logStream = null;
        }
    }
}
