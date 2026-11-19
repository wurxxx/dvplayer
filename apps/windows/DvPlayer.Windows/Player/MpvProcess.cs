using System.Diagnostics;
using System.IO;

namespace DvPlayer.Windows.Player;

/// <summary>
/// 启动官方 Windows mpv（shinchiro 构建，带 FEL 合成），用 <c>--wid</c> 挂到
/// <see cref="MpvHost"/> 的窗口里。
///
/// 产品里所有播放能力都来自 mpv 本身：DV P7 FEL 的拆层、EL 合成、gpu-next
/// 的 DV 整形。壳只做窗口托管和 UI，不需要私有补丁（ADR-0001）。
/// </summary>
public sealed class MpvProcess : IDisposable
{
    private Process? _process;
    private FileStream? _logStream;
    private StreamWriter? _log;
    private readonly object _gate = new();

    public bool IsRunning
    {
        get
        {
            var p = _process;
            return p is not null && !p.HasExited;
        }
    }

    public event EventHandler? Exited;

    public void Start(IntPtr wid, string file, string? mpvPath = null)
    {
        if (wid == IntPtr.Zero)
        {
            throw new InvalidOperationException("MpvHost 还没建好窗口。");
        }

        if (!File.Exists(file))
        {
            throw new FileNotFoundException("找不到媒体文件。", file);
        }

        Stop();

        var exe = mpvPath ?? FindMpv();
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = AppContext.BaseDirectory,
        };

        foreach (var arg in BuildArgs(wid, file))
        {
            psi.ArgumentList.Add(arg);
        }

        OpenLog();

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => WriteLog(e.Data);
        process.ErrorDataReceived += (_, e) => WriteLog(e.Data);
        process.Exited += (_, _) => Exited?.Invoke(this, EventArgs.Empty);

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        lock (_gate)
        {
            _process = process;
        }
    }

    public void Stop()
    {
        Process? process;
        lock (_gate)
        {
            process = _process;
            _process = null;
        }

        if (process is null)
        {
            return;
        }

        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(3000);
            }
        }
        catch (InvalidOperationException)
        {
            // 已经退出，忽略。
        }
        finally
        {
            process.Dispose();
            CloseLog();
        }
    }

    public void Dispose() => Stop();

    /// <summary>
    /// mpv 日志：%LOCALAPPDATA%\dvplayer\mpv.log。直接双击 exe 时也能看。
    /// </summary>
    public static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "dvplayer", "mpv.log");

    private static IEnumerable<string> BuildArgs(IntPtr wid, string file)
    {
        yield return "--no-config";
        yield return "--vo=gpu-next";             // gpu-next；DV 整形只在这条路径上（ADR-0003）
        yield return "--hwdec=auto-safe";                // QSV/D3D11VA 可用就用，拿不到就软解
        yield return $"--wid={wid.ToInt64()}";           // 挂进壳的 HWND
        yield return "--osc=no";                         // UI 由壳提供
        yield return "--keep-open=no";
        yield return "--msg-level=all=info,vd=v,vf=v,mkv=v,vo/gpu-next=info";
        yield return file;
    }

    private static string FindMpv()
    {
        var fromEnv = Environment.GetEnvironmentVariable("DVPLAYER_MPV");
        if (!string.IsNullOrWhiteSpace(fromEnv) && File.Exists(fromEnv))
        {
            return fromEnv;
        }

        var beside = Path.Combine(AppContext.BaseDirectory, "mpv", "mpv.exe");
        if (File.Exists(beside))
        {
            return beside;
        }

        const string fallback = @"D:\dvplayer\mpv\mpv.exe";
        if (File.Exists(fallback))
        {
            return fallback;
        }

        throw new FileNotFoundException(
            "找不到 mpv.exe。设 DVPLAYER_MPV，或把它放在 exe 旁边的 mpv\\mpv.exe。");
    }

    private void OpenLog()
    {
        try
        {
            var dir = Path.GetDirectoryName(LogPath)!;
            Directory.CreateDirectory(dir);
            _logStream = new FileStream(LogPath, FileMode.Create, FileAccess.Write, FileShare.Read);
            _log = new StreamWriter(_logStream) { AutoFlush = true };
        }
        catch (IOException)
        {
            // 日志写不了不影响播放。
            _log = null;
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
            _log?.WriteLine(line);
        }
        catch (ObjectDisposedException)
        {
            // 进程在关闭，忽略。
        }

        Debug.WriteLine($"[mpv] {line}");
    }

    private void CloseLog()
    {
        _log?.Dispose();
        _log = null;
        _logStream = null;
    }
}
