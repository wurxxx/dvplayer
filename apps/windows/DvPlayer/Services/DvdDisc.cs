using System.Diagnostics;
using System.IO;
using System.Text;

namespace DvPlayer.Services;

/// <summary>
/// DVD-Video 镜像（`VIDEO_TS`）：Windows 的 mpv 带 libdvdnav，直接用
/// `--dvd-device=<iso>` + `dvdnav://` 进盘自己的 DVD 菜单，
/// 键鼠转发和蓝光菜单是同一条 `discnav` 路。
///
/// 播放器是独立进程（mpv.exe），libdvdnav 的 GPL 不传染到壳里；
/// mac 那边是进程内 libmpv（LGPL），所以 mac 只能按 VOB 顺序连播。
/// </summary>
public static class DvdDisc
{
    /// <summary>
    /// 用 mpv 的 dvdnav 打开一帧：能打开就是 DVD 镜像。
    ///
    /// 蓝光探测失败后才走这里；不能只看扩展名——`.iso` 可能是 DVD，
    /// 也可能根本不是盘。
    /// </summary>
    public static async Task<bool> ProbeAsync(
        string isoPath, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(isoPath))
        {
            return false;
        }

        var mpv = FindMpv();
        if (mpv is null)
        {
            return false;
        }

        var psi = new ProcessStartInfo(mpv)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = AppContext.BaseDirectory,
        };

        foreach (var arg in new[]
                 {
                     "--no-config",
                     "--terminal=yes",
                     "--vo=null",
                     "--ao=null",
                     "--osc=no",
                     "--no-input-default-bindings",
                     "--frames=1",
                     $"--dvd-device={isoPath}",
                     "dvdnav://",
                 })
        {
            psi.ArgumentList.Add(arg);
        }

        using var process = new Process { StartInfo = psi };
        var output = new StringBuilder();
        try
        {
            process.Start();
            var stdout = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var stderr = process.StandardError.ReadToEndAsync(cancellationToken);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(20));
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch (InvalidOperationException)
                {
                    // 已经退出。
                }

                return false;
            }

            output.Append(await stdout.ConfigureAwait(false));
            output.Append(await stderr.ConfigureAwait(false));
        }
        catch (Exception)
        {
            return false;
        }

        var text = output.ToString();
        // 打开成功时 mpv 会打出「DVDNAV, switched to title……」；失败是
        // 「dvdnav: Unable to open……」。
        var opened = text.Contains("DVDNAV", StringComparison.OrdinalIgnoreCase) ||
                     text.Contains("libdvdnav", StringComparison.OrdinalIgnoreCase);
        if (!opened)
        {
            Trace.Write("dvd probe no: " + string.Join(" ", text
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(line => line.Trim())
                .TakeLast(3)));
        }

        return opened;
    }

    private static string? FindMpv()
    {
        if (MpvLocator.FindDirectory() is not { } dir)
        {
            return null;
        }

        // 控制台版才拿得到 stdout。
        var console = Path.Combine(dir, "mpv.com");
        if (File.Exists(console))
        {
            return console;
        }

        var exe = Path.Combine(dir, "mpv.exe");
        return File.Exists(exe) ? exe : null;
    }
}
