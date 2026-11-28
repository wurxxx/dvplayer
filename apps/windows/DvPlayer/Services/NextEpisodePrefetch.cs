using System.IO;
using System.Net.Http;

namespace DvPlayer.Services;

/// <summary>
/// 下一集预加载：本集快播完时提前把下一集的播放地址取好，再读一小段数据
/// 把连接和服务器会话热起来；真正切集时直接吃缓存，省掉一次取地址的往返
/// 和首包的等待。
///
/// 只预热、不预解码：切集仍走原来的 mpv 启动流程，预热失败或不命中也只是
/// 退回普通切集，不影响播放。开关在设置 → 播放 →「预加载下一集」。
/// </summary>
public static class NextEpisodePrefetch
{
    /// <summary>剩余多少秒开始预取。</summary>
    public const double LeadSeconds = 90;

    /// <summary>缓存多久算过期：直链里的签名 / 会话可能失效，太旧就别用。</summary>
    private static readonly TimeSpan Ttl = TimeSpan.FromMinutes(10);

    /// <summary>同一集失败后多久内不再重试，避免反复打服务器。</summary>
    private static readonly TimeSpan FailureBackoff = TimeSpan.FromSeconds(30);

    /// <summary>预热读多少字节就断开：够让服务端把会话和文件头准备好。</summary>
    private const int WarmBytes = 512 * 1024;

    private sealed record Entry(PlaySourceDto Source, DateTime At);

    private static readonly object Gate = new();
    private static readonly Dictionary<string, Entry> Cache = new();
    private static readonly HashSet<string> InFlight = new();
    private static readonly Dictionary<string, DateTime> FailedAt = new();

    /// <summary>
    /// 取缓存（取走即删）：命中说明这一集已经在后台取好地址了。
    /// </summary>
    public static PlaySourceDto? Take(string itemId)
    {
        lock (Gate)
        {
            if (!Cache.Remove(itemId, out var entry))
            {
                return null;
            }

            return DateTime.UtcNow - entry.At < Ttl ? entry.Source : null;
        }
    }

    /// <summary>后台预取。同一集只跑一份；失败 30 秒内不再试。</summary>
    /// <returns>是否真的发起了这次预取（已在缓存 / 在途 / 退避中返回 false）。</returns>
    public static bool Prefetch(string itemId)
    {
        if (string.IsNullOrEmpty(itemId))
        {
            return false;
        }

        lock (Gate)
        {
            if (Cache.ContainsKey(itemId) || !InFlight.Add(itemId))
            {
                return false;
            }

            if (FailedAt.TryGetValue(itemId, out var at) &&
                DateTime.UtcNow - at < FailureBackoff)
            {
                InFlight.Remove(itemId);
                return false;
            }
        }

        _ = Task.Run(() => RunAsync(itemId));
        return true;
    }

    /// <summary>关窗时清掉：地址和服务器会话都别留着。</summary>
    public static void Clear()
    {
        lock (Gate)
        {
            Cache.Clear();
            FailedAt.Clear();
        }
    }

    private static async Task RunAsync(string itemId)
    {
        var started = DateTime.UtcNow;
        try
        {
            var (source, error) = await Playback.ResolveAsync(itemId).ConfigureAwait(false);
            if (source is null)
            {
                Trace.Write($"[Prefetch] resolve fail item={Short(itemId)} err={error}");
                MarkFailed(itemId);
                return;
            }

            var read = await WarmAsync(source).ConfigureAwait(false);
            if (read < 0)
            {
                Trace.Write($"[Prefetch] warm fail item={Short(itemId)}");
                MarkFailed(itemId);
                return;
            }

            lock (Gate)
            {
                Cache[itemId] = new Entry(source, DateTime.UtcNow);
            }

            Trace.Write($"[Prefetch] ready item={Short(itemId)} bytes={read} " +
                        $"dur={source.DurationSeconds} " +
                        $"ms={(int)(DateTime.UtcNow - started).TotalMilliseconds}");
        }
        catch (Exception ex)
        {
            Trace.Write($"[Prefetch] fail item={Short(itemId)} {ex.Message}");
            MarkFailed(itemId);
        }
        finally
        {
            lock (Gate)
            {
                InFlight.Remove(itemId);
            }
        }
    }

    private static void MarkFailed(string itemId)
    {
        lock (Gate)
        {
            FailedAt[itemId] = DateTime.UtcNow;
        }
    }

    /// <summary>
    /// 读一小段数据把连接 / 服务端会话热起来。返回读到的字节数；
    /// 不需要预热（本地文件 / 原盘）返回 0，失败返回 -1。
    /// </summary>
    private static async Task<int> WarmAsync(PlaySourceDto source)
    {
        if (source.Disc ||
            !Uri.TryCreate(source.Url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return 0;
        }

        using var handler = new HttpClientHandler();
        if (!string.IsNullOrWhiteSpace(source.Proxy))
        {
            var address = source.Proxy.Contains("://", StringComparison.Ordinal)
                ? source.Proxy
                : "http://" + source.Proxy;
            handler.Proxy = new System.Net.WebProxy(address);
            handler.UseProxy = true;
        }

        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        using var request = new HttpRequestMessage(HttpMethod.Get, source.Url);
        // 只要开头一段：服务端支持 Range 就精确；不支持我们读够就断。
        request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(0, WarmBytes - 1);
        foreach (var header in source.Headers ?? new List<HttpHeaderDto>())
        {
            request.Headers.TryAddWithoutValidation(header.Name, header.Value);
        }

        try
        {
            using var response = await http
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return -1;
            }

            await using var stream = await response.Content
                .ReadAsStreamAsync().ConfigureAwait(false);
            var buffer = new byte[64 * 1024];
            var total = 0;
            while (total < WarmBytes)
            {
                var want = Math.Min(buffer.Length, WarmBytes - total);
                var read = await stream.ReadAsync(buffer.AsMemory(0, want)).ConfigureAwait(false);
                if (read <= 0)
                {
                    break;
                }

                total += read;
            }

            return total;
        }
        catch (Exception)
        {
            return -1;
        }
    }

    private static string Short(string itemId) =>
        itemId[..Math.Min(8, itemId.Length)];
}
