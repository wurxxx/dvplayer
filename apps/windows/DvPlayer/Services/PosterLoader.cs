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

    private static readonly Dictionary<string, BitmapSource> Memory = new();
    private static readonly Dictionary<string, Task<BitmapSource?>> Pending = new();
    private static readonly object Gate = new();

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

                using var response = await Http.SendAsync(request).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    return null;
                }

                bytes = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                await File.WriteAllBytesAsync(file, bytes).ConfigureAwait(false);
            }

            var bitmap = Decode(bytes, width);
            if (bitmap is not null)
            {
                lock (Gate)
                {
                    Memory[key] = bitmap;
                }
            }

            return bitmap;
        }
        catch (Exception)
        {
            // 海报失败不影响主流程，调用方回退到渐变占位。
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
        catch (Exception)
        {
            return null;
        }
    }

    private static string Hash(string value)
    {
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(bytes).ToLowerInvariant()[..20];
    }
}
