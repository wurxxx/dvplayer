using System;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace DvPlayer.Services;

public enum UpdateCheckStatus
{
    UpToDate,
    Available,
    NoRelease,
    Failed,
}

public sealed record UpdateCheckResult(
    UpdateCheckStatus Status,
    string Message,
    string? Version = null,
    string? Url = null);

/// <summary>
/// 更新检查：问 GitHub 最新 Release，和当前版本比。
///
/// 成功结果在进程内缓存 10 分钟：设置页来回切不重复打接口（未登录的
/// GitHub API 每小时只有 60 次）。手动点「重新检查」走 force 绕过缓存。
/// </summary>
public static class UpdateService
{
    public const string Repo = "wurxxx/dvplayer";
    public const string RepoUrl = "https://github.com/" + Repo;
    public const string ReleasesUrl = RepoUrl + "/releases";

    private const string LatestReleaseApi =
        "https://api.github.com/repos/" + Repo + "/releases/latest";

    private static readonly HttpClient Http = CreateClient();
    private static readonly object Gate = new();
    private static readonly object StateGate = new();
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(10);
    private static (DateTime at, string version, UpdateCheckResult result)? _cached;

    /// <summary>最近一次查到的可用版本（nil = 已是最新 / 还没查到）。</summary>
    public static string? AvailableVersion { get; private set; }

    public static string? AvailableUrl { get; private set; }

    /// <summary>可用版本变化时触发（启动检查和设置页检查都会走到这里）。</summary>
    public static event Action? AvailabilityChanged;

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("DVPlayer");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    public static async Task<UpdateCheckResult> CheckAsync(string currentVersion, bool force = false)
    {
        UpdateCheckResult? cached = null;
        lock (Gate)
        {
            if (!force && _cached is { } hit &&
                hit.version == currentVersion &&
                DateTime.UtcNow - hit.at < CacheTtl)
            {
                cached = hit.result;
            }
        }

        if (cached is not null)
        {
            SetAvailability(cached);
            return cached;
        }

        var result = await FetchAsync(currentVersion).ConfigureAwait(false);

        // 只缓存确定的结果；断网 / 超时下次还能立刻重试。
        if (result.Status is UpdateCheckStatus.UpToDate or UpdateCheckStatus.Available)
        {
            lock (Gate)
            {
                _cached = (DateTime.UtcNow, currentVersion, result);
            }
        }

        if (result.Status is UpdateCheckStatus.UpToDate or UpdateCheckStatus.Available)
        {
            SetAvailability(result);
        }

        return result;
    }

    /// <summary>把「有没有新版本」写给侧栏；只有变化时才触发事件。</summary>
    private static void SetAvailability(UpdateCheckResult result)
    {
        var version = result.Status == UpdateCheckStatus.Available ? result.Version : null;
        var url = result.Status == UpdateCheckStatus.Available ? result.Url : null;

        bool changed;
        lock (StateGate)
        {
            changed = AvailableVersion != version;
            AvailableVersion = version;
            AvailableUrl = url;
        }

        if (changed)
        {
            AvailabilityChanged?.Invoke();
        }
    }

    private static async Task<UpdateCheckResult> FetchAsync(string currentVersion)
    {
        try
        {
            using var response = await Http.GetAsync(LatestReleaseApi).ConfigureAwait(false);

            // 仓库还没有发布过 Release：不是错误，只是没得更新。
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                return new UpdateCheckResult(UpdateCheckStatus.NoRelease, "GitHub 上还没有发布版本");
            }

            if (!response.IsSuccessStatusCode)
            {
                return new UpdateCheckResult(
                    UpdateCheckStatus.Failed,
                    $"GitHub 返回 HTTP {(int)response.StatusCode}");
            }

            await using var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
            using var doc = await JsonDocument.ParseAsync(stream).ConfigureAwait(false);
            var root = doc.RootElement;

            var tag = root.TryGetProperty("tag_name", out var tagElement)
                ? tagElement.GetString()
                : null;
            var url = root.TryGetProperty("html_url", out var urlElement)
                ? urlElement.GetString()
                : null;

            if (string.IsNullOrWhiteSpace(tag))
            {
                return new UpdateCheckResult(UpdateCheckStatus.Failed, "发布信息不完整");
            }

            var latest = Normalize(tag);
            var link = string.IsNullOrWhiteSpace(url) ? ReleasesUrl : url;

            return IsNewer(latest, currentVersion)
                ? new UpdateCheckResult(
                    UpdateCheckStatus.Available, $"发现新版本 v{latest}", latest, link)
                : new UpdateCheckResult(
                    UpdateCheckStatus.UpToDate,
                    $"已是最新版本（v{Normalize(currentVersion)}）");
        }
        catch (TaskCanceledException)
        {
            return new UpdateCheckResult(UpdateCheckStatus.Failed, "检查更新超时");
        }
        catch (HttpRequestException ex)
        {
            return new UpdateCheckResult(
                UpdateCheckStatus.Failed,
                "网络不可用：" + (ex.Message.Length > 80 ? ex.Message[..80] : ex.Message));
        }
        catch (JsonException)
        {
            return new UpdateCheckResult(UpdateCheckStatus.Failed, "解析 GitHub 返回失败");
        }
    }

    /// <summary>`v0.1.5` / `0.1.5-beta` / `0.1.5+abc` → `0.1.5`。</summary>
    public static string Normalize(string raw)
    {
        var value = (raw ?? "").Trim();
        if (value.StartsWith("v", StringComparison.OrdinalIgnoreCase))
        {
            value = value[1..];
        }

        var cut = value.IndexOfAny(new[] { '-', '+' });
        return cut >= 0 ? value[..cut] : value;
    }

    /// <summary>按数字段比较（0.1.10 &gt; 0.1.9）；缺的段当 0。</summary>
    public static bool IsNewer(string candidate, string current)
    {
        var left = Split(Normalize(candidate));
        var right = Split(Normalize(current));
        for (var index = 0; index < Math.Max(left.Length, right.Length); index++)
        {
            var a = index < left.Length ? left[index] : 0;
            var b = index < right.Length ? right[index] : 0;
            if (a != b)
            {
                return a > b;
            }
        }

        return false;
    }

    private static int[] Split(string version) =>
        Array.ConvertAll(version.Split('.', StringSplitOptions.RemoveEmptyEntries),
            part => int.TryParse(part, out var number) ? number : 0);
}
