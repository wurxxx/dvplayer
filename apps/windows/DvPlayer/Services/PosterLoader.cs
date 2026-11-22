using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Media.Imaging;

namespace DvPlayer.Services;

/// <summary>
/// 海报加载：飞牛的图片接口只认 <c>Authorization</c> 头，不能把 URL 直接丢给
/// <see cref="System.Windows.Controls.Image"/>，所以这里自己下字节、落盘缓存、再解码。
/// </summary>
public static class PosterLoader
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private static readonly Dictionary<string, HttpClient> Proxied = new();

    /// <summary>按服务器的代理设置挑 HttpClient：海报请求和播放请求走同一个代理。</summary>
    private static HttpClient ClientFor(string? proxy)
    {
        var value = proxy?.Trim();
        if (string.IsNullOrEmpty(value))
        {
            return Http;
        }

        var address = value.Contains("://", StringComparison.Ordinal) ? value : "http://" + value;
        lock (Gate)
        {
            if (Proxied.TryGetValue(address, out var cached))
            {
                return cached;
            }

            try
            {
                var handler = new HttpClientHandler
                {
                    Proxy = new System.Net.WebProxy(address),
                    UseProxy = true,
                };
                var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
                Proxied[address] = client;
                return client;
            }
            catch (UriFormatException)
            {
                // 代理写得不像地址：这张图直连，别让海报拖垮页面。
                Trace.Write($"poster proxy invalid {address}");
                return Http;
            }
        }
    }

    private static readonly Dictionary<string, BitmapSource> Memory = new();
    private static readonly LinkedList<string> MemoryOrder = new();
    private static readonly Dictionary<string, Task<BitmapSource?>> Pending = new();
    private static readonly object Gate = new();

    /// <summary>内存里最多留多少张：翻几十页也不会一直涨。</summary>
    private const int MemoryLimit = 240;

    /// <summary>放进内存缓存并按 LRU 淘汰最旧的。</summary>
    private static void Remember(string key, BitmapSource bitmap)
    {
        lock (Gate)
        {
            Memory[key] = bitmap;
            MemoryOrder.Remove(key);
            MemoryOrder.AddLast(key);

            while (MemoryOrder.Count > MemoryLimit)
            {
                var oldest = MemoryOrder.First!.Value;
                MemoryOrder.RemoveFirst();
                Memory.Remove(oldest);
            }
        }
    }

    private static string CacheDir
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "dvplayer",
                "cache");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>
    /// 取图。<paramref name="width"/> 是解码宽度：卡片 400 就够，
    /// 详情页的横版背景要 1280，不然铺满窗口会糊。
    /// </summary>
    public static Task<BitmapSource?> LoadAsync(string? posterPath, int width = 400)
    {
        if (string.IsNullOrWhiteSpace(posterPath))
        {
            return Task.FromResult<BitmapSource?>(null);
        }

        var key = $"{width}:{posterPath}";

        lock (Gate)
        {
            if (Memory.TryGetValue(key, out var cached))
            {
                return Task.FromResult<BitmapSource?>(cached);
            }

            if (Pending.TryGetValue(key, out var running))
            {
                return running;
            }

            var task = Task.Run(() => LoadCoreAsync(posterPath, key, width));
            Pending[key] = task;
            return task;
        }
    }

    private static async Task<BitmapSource?> LoadCoreAsync(string posterPath, string key, int width)
    {
        try
        {
            var core = AppServices.Instance.Core;
            if (core is null)
            {
                return null;
            }

            var source = await Task.Run(() => core.ImageSource(posterPath)).ConfigureAwait(false);
            if (!source.Ok || source.Data is null)
            {
                Trace.Write($"poster src fail {posterPath} {source.Error}");
                return null;
            }

            var file = Path.Combine(CacheDir, Hash(source.Data.Url) + ".img");
            byte[] bytes;
            if (File.Exists(file))
            {
                bytes = await File.ReadAllBytesAsync(file).ConfigureAwait(false);
            }
            else
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, source.Data.Url);
                foreach (var header in source.Data.Headers)
                {
                    request.Headers.TryAddWithoutValidation(header.Name, header.Value);
                }

                using var response = await ClientFor(source.Data.Proxy)
                    .SendAsync(request).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    Trace.Write($"poster http {(int)response.StatusCode} {posterPath}");
                    return null;
                }

                bytes = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);

                // 原子写：半截文件会被下一次 File.Exists 当成有效图，
                // 解码失败后这张海报就永久空白。
                var temp = file + ".part";
                await File.WriteAllBytesAsync(temp, bytes).ConfigureAwait(false);
                File.Move(temp, file, overwrite: true);
            }

            var bitmap = Decode(bytes, width);
            if (bitmap is null)
            {
                // 坏缓存（半截 / 不支持的格式）删掉，下次重新下载。
                try { File.Delete(file); } catch (IOException) { }
            }
            else
            {
                Remember(key, bitmap);
            }

            return bitmap;
        }
        catch (Exception ex)
        {
            // 海报失败不影响主流程，调用方回退到渐变占位。
            Trace.Write($"poster err {posterPath} {ex.Message}");
            return null;
        }
        finally
        {
            lock (Gate)
            {
                Pending.Remove(key);
            }
        }
    }

    private static BitmapSource? Decode(byte[] bytes, int width)
    {
        try
        {
            // 原图比要求的小时不要放大解码：先糊一次再缩回去只会更软。
            int natural;
            using (var probe = new MemoryStream(bytes))
            {
                natural = BitmapFrame
                    .Create(probe, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None)
                    .PixelWidth;
            }

            using var stream = new MemoryStream(bytes);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            image.DecodePixelWidth = Math.Min(width, natural);
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception ex)
        {
            Trace.Write($"poster decode {ex.GetType().Name} {ex.Message}");
            return null;
        }
    }

    private static string Hash(string value)
    {
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes).ToLowerInvariant()[..20];
    }
}
