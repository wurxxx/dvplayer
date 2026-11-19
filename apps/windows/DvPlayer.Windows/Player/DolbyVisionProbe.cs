using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace DvPlayer.Windows.Player;

/// <summary>增强层类型：P7 的 RPU 里 <c>disable_residual_flag</c> 是 false 为 FEL，true 为 MEL。</summary>
public enum DvElType
{
    Unknown,
    Fel,
    Mel,
}

public sealed record DvProbeResult(int? Profile, DvElType ElType, bool? DisableResidualFlag);

/// <summary>
/// 侧路判定 DV P7 是 FEL 还是 MEL（ADR-0005）。
///
/// mpv 只暴露 <c>current-tracks/video/dolby-vision-profile</c>，没有
/// <c>disable_residual_flag</c>，所以这里用 ffmpeg 抽出 EL 轨的前几秒，
/// 交给 dovi_tool 提取 RPU 并读第一帧。
///
/// 结果按「路径 + 大小 + mtime」缓存在 <c>%LOCALAPPDATA%\dvplayer\dvprobe.json</c>，
/// 同一个文件第二次播放直接命中，不再起进程。
/// </summary>
public static class DolbyVisionProbe
{
    private static readonly TimeSpan ToolTimeout = TimeSpan.FromMinutes(2);
    private static readonly object CacheGate = new();

    private static string CachePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "dvplayer", "dvprobe.json");

    public static async Task<DvProbeResult?> ProbeAsync(string file, CancellationToken ct = default)
    {
        if (!TryFindTools(out var ffmpeg, out var doviTool))
        {
            return null;
        }

        var stamp = StampOf(file);
        if (stamp is null)
        {
            return null;
        }

        if (TryReadCache(stamp) is { } cached)
        {
            return cached;
        }

        var work = Path.Combine(Path.GetTempPath(), "dvplayer-dvprobe", Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(work);

        try
        {
            var hevc = Path.Combine(work, "el.hevc");
            var rpu = Path.Combine(work, "rpu.bin");

            // P7 有两种封装：
            //   单轨带内交织（主流）：整条码流里 BL/EL/RPU 的 NAL 都在，extract-rpu 直接能抓；
            //   双轨：第二轨才是 EL+RPU。
            // 所以先试第一轨，抓不到 RPU 再试第二轨。
            foreach (var map in new[] { "0:v:0", "0:v:1" })
            {
                if (File.Exists(hevc))
                {
                    File.Delete(hevc);
                }

                if (File.Exists(rpu))
                {
                    File.Delete(rpu);
                }

                if (await RunAsync(ffmpeg, new[]
                    {
                        "-v", "error", "-y", "-i", file,
                        "-map", map, "-c", "copy", "-t", "3", "-f", "hevc", hevc,
                    }, ct).ConfigureAwait(false) != 0
                    || !File.Exists(hevc) || new FileInfo(hevc).Length < 8192)
                {
                    continue;
                }

                if (await RunAsync(doviTool, new[]
                    {
                        "extract-rpu", "-i", hevc, "-o", rpu,
                    }, ct).ConfigureAwait(false) != 0
                    || !File.Exists(rpu) || new FileInfo(rpu).Length < 1024)
                {
                    continue;
                }

                var (code, stdout) = await RunCaptureAsync(doviTool, new[]
                {
                    "info", "-i", rpu, "-f", "0",
                }, ct).ConfigureAwait(false);

                if (code != 0)
                {
                    continue;
                }

                var result = ParseInfo(stdout);
                if (result is not null)
                {
                    WriteCache(stamp, result);
                    return result;
                }
            }

            return null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        finally
        {
            TryDeleteDirectory(work);
        }
    }

    /// <summary>dovi_tool info 会在 JSON 前面打一行 "Parsing RPU file..."，跳过它再解析。</summary>
    private static DvProbeResult? ParseInfo(string stdout)
    {
        var start = stdout.IndexOf('{');
        if (start < 0)
        {
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(stdout[start..]);
            var root = doc.RootElement;

            int? profile = null;
            if (root.TryGetProperty("dovi_profile", out var p) && p.ValueKind == JsonValueKind.Number)
            {
                profile = p.GetInt32();
            }

            bool? residual = null;
            if (root.TryGetProperty("header", out var header) &&
                header.ValueKind == JsonValueKind.Object &&
                header.TryGetProperty("disable_residual_flag", out var r) &&
                r.ValueKind is JsonValueKind.True or JsonValueKind.False)
            {
                residual = r.GetBoolean();
            }

            var elType = DvElType.Unknown;
            if (root.TryGetProperty("el_type", out var e) && e.ValueKind == JsonValueKind.String)
            {
                elType = e.GetString()?.ToUpperInvariant() switch
                {
                    "FEL" => DvElType.Fel,
                    "MEL" => DvElType.Mel,
                    _ => DvElType.Unknown,
                };
            }

            // el_type 缺失时退回标志位。
            if (elType == DvElType.Unknown && residual is not null)
            {
                elType = residual.Value ? DvElType.Mel : DvElType.Fel;
            }

            return new DvProbeResult(profile, elType, residual);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool TryFindTools(out string ffmpeg, out string doviTool)
    {
        ffmpeg = FindTool("ffmpeg.exe", "DVPLAYER_FFMPEG");
        doviTool = FindTool("dovi_tool.exe", "DVPLAYER_DOVI_TOOL");
        return ffmpeg.Length > 0 && doviTool.Length > 0;
    }

    private static string FindTool(string name, string envName)
    {
        var fromEnv = Environment.GetEnvironmentVariable(envName);
        if (!string.IsNullOrWhiteSpace(fromEnv) && File.Exists(fromEnv))
        {
            return fromEnv;
        }

        var beside = Path.Combine(AppContext.BaseDirectory, "tools", name);
        if (File.Exists(beside))
        {
            return beside;
        }

        var fallback = Path.Combine(@"D:\dvplayer\tools", name);
        return File.Exists(fallback) ? fallback : string.Empty;
    }

    private static async Task<int> RunAsync(string exe, string[] args, CancellationToken ct)
    {
        var (code, _) = await RunCaptureAsync(exe, args, ct).ConfigureAwait(false);
        return code;
    }

    private static async Task<(int Code, string Stdout)> RunCaptureAsync(
        string exe, string[] args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(exe) ?? AppContext.BaseDirectory,
        };

        foreach (var a in args)
        {
            psi.ArgumentList.Add(a);
        }

        using var process = new Process { StartInfo = psi };
        process.Start();

        var stdout = process.StandardOutput.ReadToEndAsync(ct);
        var stderr = process.StandardError.ReadToEndAsync(ct);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(ToolTimeout);

        try
        {
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
            }

            throw;
        }

        // 把 stderr 读空，避免子进程写满管道卡住。
        _ = await stderr.ConfigureAwait(false);
        var text = await stdout.ConfigureAwait(false);
        return (process.ExitCode, text);
    }

    private sealed record CacheKey(string Path, long Length, long Ticks);

    private sealed record CacheEntry(string Path, long Length, long Ticks, int? Profile, string ElType, bool? Residual);

    private static CacheKey? StampOf(string file)
    {
        try
        {
            var info = new FileInfo(file);
            return info.Exists ? new CacheKey(info.FullName.ToLowerInvariant(), info.Length, info.LastWriteTimeUtc.Ticks) : null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private static DvProbeResult? TryReadCache(CacheKey key)
    {
        lock (CacheGate)
        {
            var entries = ReadCacheFile();
            var hit = entries.FirstOrDefault(e =>
                e.Path == key.Path && e.Length == key.Length && e.Ticks == key.Ticks);

            if (hit is null)
            {
                return null;
            }

            var elType = hit.ElType switch
            {
                "FEL" => DvElType.Fel,
                "MEL" => DvElType.Mel,
                _ => DvElType.Unknown,
            };

            return new DvProbeResult(hit.Profile, elType, hit.Residual);
        }
    }

    private static void WriteCache(CacheKey key, DvProbeResult result)
    {
        lock (CacheGate)
        {
            var entries = ReadCacheFile()
                .Where(e => !(e.Path == key.Path && e.Length == key.Length && e.Ticks == key.Ticks))
                .ToList();

            entries.Add(new CacheEntry(
                key.Path, key.Length, key.Ticks, result.Profile,
                result.ElType switch
                {
                    DvElType.Fel => "FEL",
                    DvElType.Mel => "MEL",
                    _ => "UNKNOWN",
                },
                result.DisableResidualFlag));

            // 只留最近 200 条，别让缓存无限长。
            if (entries.Count > 200)
            {
                entries = entries.TakeLast(200).ToList();
            }

            try
            {
                var dir = Path.GetDirectoryName(CachePath)!;
                Directory.CreateDirectory(dir);
                File.WriteAllText(CachePath, JsonSerializer.Serialize(entries));
            }
            catch (IOException)
            {
                // 缓存写不了不影响判定。
            }
        }
    }

    private static List<CacheEntry> ReadCacheFile()
    {
        try
        {
            if (!File.Exists(CachePath))
            {
                return new List<CacheEntry>();
            }

            return JsonSerializer.Deserialize<List<CacheEntry>>(File.ReadAllText(CachePath))
                   ?? new List<CacheEntry>();
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            return new List<CacheEntry>();
        }
    }

    private static void TryDeleteDirectory(string dir)
    {
        try
        {
            Directory.Delete(dir, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
