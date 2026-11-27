using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace DvPlayer.Services;

/// <summary>原盘里的一个标题（libbluray 的 title / edition 一一对应）。</summary>
public sealed record BluRayTitle(int Edition, int TitleNumber, int Mpls, double DurationSeconds)
{
    /// <summary>`1:21:47` 这种短时长，列表里对齐用。</summary>
    public string DurationLabel => Format(DurationSeconds);

    public static string Format(double seconds)
    {
        if (double.IsNaN(seconds) || seconds <= 0)
        {
            return "00:00";
        }

        var total = (int)Math.Round(seconds);
        var hours = total / 3600;
        var minutes = total % 3600 / 60;
        return hours > 0
            ? $"{hours}:{minutes:00}:{total % 60:00}"
            : $"{minutes}:{total % 60:00}";
    }
}

/// <summary>原盘一个标题的章节：`Time` 是从标题开头算的秒数（可直接当起播点）。</summary>
public sealed record BluRayChapter(int Index, double Time)
{
    public string TimeLabel => BluRayTitle.Format(Time);
}

/// <summary>
/// 探到的整个原盘：盘名 + 标题列表 + 菜单是不是 BD-J。
///
/// BD-J 菜单要 Java VM 和 libbluray 的 BD-J jar；随包的 mpv 没有，
/// libbluray 会打 "Playing without menus"，进菜单只剩背景视频。
/// </summary>
public sealed record BluRayProbe(
    string? DiscName, IReadOnlyList<BluRayTitle> Titles, bool IsBDJ = false)
{
    /// <summary>
    /// 正片：时长接近最长标题的那几个。2in1 这种双正片原盘会有两个，
    /// 花絮通常明显短一截。
    /// </summary>
    public bool IsFeature(BluRayTitle title)
    {
        if (Titles.Count == 0)
        {
            return false;
        }

        var longest = Titles.Max(item => item.DurationSeconds);
        return longest > 0 && title.DurationSeconds >= longest * 0.9;
    }
}

/// <summary>
/// 蓝光原盘：借 mpv 自己的 libbluray 列出标题，再交给 libbluray 播放。
///
/// 为什么不自己挂 ISO 读 mpls：libbluray 的 title 不保证就是 mpls 编号，
/// 真实原盘里 title 1 常常是 00800.mpls。mpv 在打开盘时会把
/// “title N (时长) (xxxxx.mpls)” 打在日志里，直接读这行最准，也不用挂载。
/// </summary>
public static partial class BluRayDisc
{
    /// <summary>mpv 打开原盘时列 title 的那一行（bd 日志）。</summary>
    [GeneratedRegex(
        @"--edition=(?<edition>\d+)\s+'title:\s*(?<title>\d+)\s+\((?<duration>[\d:.]+)\)\s+\((?<mpls>\d+)\.mpls\)'",
        RegexOptions.CultureInvariant)]
    private static partial Regex TitleLine();

    [GeneratedRegex(@"^Title:\s*(?<name>.+?)\s*$", RegexOptions.Multiline)]
    private static partial Regex DiscNameLine();

    /// <summary>libbluray 打开盘时打的 `HDMV Titles: N, BD-J Titles: M`。</summary>
    [GeneratedRegex(@"BD-J Titles:\s*(?<n>\d+)", RegexOptions.CultureInvariant)]
    private static partial Regex BdjTitlesLine();

    /// <summary>
    /// 读 ISO 的标题列表。mpv 用 `--frames=1` 只读元数据、不开窗。
    /// </summary>
    public static async Task<(BluRayProbe? Probe, string? Error)> ProbeAsync(
        string isoPath, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(isoPath))
        {
            return (null, "找不到 ISO 文件。");
        }

        var mpv = FindConsoleMpv();
        if (mpv is null)
        {
            return (null, "找不到 mpv（同目录的 mpv.com 或 mpv.exe）。");
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
                     "--msg-level=all=info,bd=v",
                     "--frames=1",
                     $"--bluray-device={isoPath}",
                     "bd://",
                 })
        {
            psi.ArgumentList.Add(arg);
        }

        using var process = new Process { StartInfo = psi };
        var output = new StringBuilder();
        try
        {
            process.Start();
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(45));
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                await process.WaitForExitAsync().ConfigureAwait(false);
                return (null, cancellationToken.IsCancellationRequested
                    ? "已取消。"
                    : "读原盘超时（45 秒）。");
            }

            output.Append(await stdout.ConfigureAwait(false));
            output.Append(await stderr.ConfigureAwait(false));
        }
        catch (Exception ex)
        {
            TryKill(process);
            return (null, "读原盘失败：" + ex.Message);
        }

        var text = output.ToString();
        var titles = new List<BluRayTitle>();
        foreach (Match match in TitleLine().Matches(text))
        {
            if (!int.TryParse(match.Groups["mpls"].Value, out var mpls))
            {
                continue;
            }

            var duration = TimeSpan.TryParse(
                match.Groups["duration"].Value, CultureInfo.InvariantCulture, out var parsed)
                ? parsed.TotalSeconds
                : 0;

            titles.Add(new BluRayTitle(
                int.Parse(match.Groups["edition"].Value, CultureInfo.InvariantCulture),
                int.Parse(match.Groups["title"].Value, CultureInfo.InvariantCulture),
                mpls,
                duration));
        }

        if (titles.Count == 0)
        {
            var tail = string.Join(" ", text
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(line => line.Trim())
                .TakeLast(4));
            Trace.Write("disc probe no titles: " + tail);
            return (null, "没有从这张盘里读到可播放的标题。");
        }

        var discName = DiscNameLine().Match(text) is { Success: true } nameMatch
            ? nameMatch.Groups["name"].Value.Trim()
            : null;

        var ordered = titles
            .OrderBy(item => item.Edition)
            .ThenBy(item => item.TitleNumber)
            .ToList();

        // BD-J 盘：libbluray 没有可用的 Java VM / BD-J jar 时会明说
        // “Playing without menus”；日志里也有 `BD-J Titles: N`。
        var bdj = BdjTitlesLine().Match(text) is { Success: true } bdjMatch
                  && int.TryParse(bdjMatch.Groups["n"].Value, out var bdjCount)
                  && bdjCount > 0;
        bdj |= text.Contains("Playing without menus", StringComparison.OrdinalIgnoreCase);

        return (new BluRayProbe(
            string.IsNullOrWhiteSpace(discName) ? null : discName,
            ordered,
            bdj), null);
    }

    /// <summary>
    /// 读一个标题（mpls）的章节列表。
    ///
    /// 章节只在 `BDMV/PLAYLIST/*.mpls` 的 PlayListMark 段里，libbluray 不提供
    /// 机器可读接口；所以借 mpv 自己打开这条 mpls，用一小段 Lua 在 file-loaded
    /// 后打印 `chapter-list` 再退出（`--pause` 保证来得及读）。libbluray 给的
    /// 时间已经换算成 playlist 相对时间，可以直接当起播点。
    /// </summary>
    public static async Task<List<BluRayChapter>> ProbeChaptersAsync(
        string isoPath, int mpls, CancellationToken cancellationToken = default)
    {
        var chapters = new List<BluRayChapter>();
        var mpv = FindConsoleMpv();
        if (mpv is null)
        {
            return chapters;
        }

        string luaPath;
        try
        {
            var folder = Path.Combine(Path.GetTempPath(), "dvplayer");
            Directory.CreateDirectory(folder);
            luaPath = Path.Combine(folder, "disc-chapters.lua");
            await File.WriteAllTextAsync(luaPath, ChapterProbeLua, new UTF8Encoding(false),
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Trace.Write("disc chapters lua failed: " + ex.Message);
            return chapters;
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
                     "--pause",
                     "--msg-level=all=info",
                     $"--bluray-device={isoPath}",
                     $"bd://mpls/{mpls}",
                     $"--script={luaPath}",
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
            timeout.CancelAfter(TimeSpan.FromSeconds(25));
            try
            {
                await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                TryKill(process);
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }

            output.Append(await stdout.ConfigureAwait(false));
            output.Append(await stderr.ConfigureAwait(false));
        }
        catch (Exception ex)
        {
            TryKill(process);
            Trace.Write($"disc chapters probe failed mpls={mpls}: {ex.Message}");
            return chapters;
        }

        foreach (var line in output.ToString().Split('\n'))
        {
            var match = ChapterLine().Match(line);
            if (!match.Success)
            {
                continue;
            }

            var index = int.Parse(match.Groups["index"].Value, CultureInfo.InvariantCulture);
            var time = double.Parse(match.Groups["time"].Value, CultureInfo.InvariantCulture);
            chapters.Add(new BluRayChapter(index, time));
        }

        chapters.Sort((left, right) => left.Time.CompareTo(right.Time));
        Trace.Write($"disc chapters mpls={mpls} count={chapters.Count}");
        return chapters;
    }

    /// <summary>
    /// 打开 mpls 后打印 chapter-list 并退出。`--pause` 让 mpv 停在第一帧，
    /// 否则 `--frames=1` 会在脚本拿到属性前就退出。
    /// </summary>
    private const string ChapterProbeLua = """
        local function dump()
            local chapters = mp.get_property_native("chapter-list") or {}
            print(string.format("PROBE chapters=%d", #chapters))
            for i, c in ipairs(chapters) do
                print(string.format("PROBE chap %d %.3f", i, c.time))
            end
            mp.commandv("quit")
        end
        mp.register_event("file-loaded", dump)
        mp.add_timeout(15, function()
            print("PROBE timeout")
            mp.commandv("quit")
        end)
        """;

    [GeneratedRegex(@"PROBE chap (?<index>\d+) (?<time>[\d.]+)", RegexOptions.CultureInvariant)]
    private static partial Regex ChapterLine();

    private static void TryKill(Process process)
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
    }

    /// <summary>
    /// 探标题要用控制台版 mpv：GUI 版（mpv.exe）的 stdout 在部分机器上拿不到。
    /// </summary>
    private static string? FindConsoleMpv()
    {
        static string? ConsoleFor(string exe)
        {
            var dir = Path.GetDirectoryName(exe);
            if (dir is null)
            {
                return null;
            }

            var console = Path.Combine(dir, "mpv.com");
            return File.Exists(console) ? console : (File.Exists(exe) ? exe : null);
        }

        // 环境变量 / exe 旁 / 开发树上游，统一由 MpvLocator 找。
        if (MpvLocator.FindDirectory() is { } dir &&
            ConsoleFor(Path.Combine(dir, "mpv.exe")) is { } found)
        {
            return found;
        }

        return null;
    }
}
