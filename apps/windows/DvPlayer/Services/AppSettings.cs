using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace DvPlayer.Services;

/// <summary>本地配置：媒体源列表与上次选择。存 %LOCALAPPDATA%\dvplayer\settings.json。</summary>
public sealed class AppSettings
{
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>UI 线程和线程池都会 Save，写盘必须串行。</summary>
    private static readonly object SaveLock = new();

    /// <summary>凭据在文件里的前缀。旧配置没有前缀，按明文读，存的时候自动转成密文。</summary>
    private const string SealedPrefix = "dpapi:v1:";

    /// <summary>不弹任何 UI（后台保存时不能弹授权框）。</summary>
    private const int CryptProtectUiForbidden = 0x1;

    public List<SourceConfig> Sources { get; set; } = new();

    public string? LastSourceId { get; set; }

    /// <summary>启动时自动连接所有源。</summary>
    public bool AutoConnect { get; set; } = true;

    /// <summary>启动后先打开哪一页：sources / records / search / settings。</summary>
    public string StartPage { get; set; } = "sources";

    /// <summary>搜索页上次的查询词：切到别的页再回来、重启应用都还在。</summary>
    public string? SearchKeyword { get; set; }

    /// <summary>列表每页条数（媒体库与搜索共用）。</summary>
    public int PageSize { get; set; } = 60;

    /// <summary>列表卡片上是否显示分辨率角标。</summary>
    public bool ShowResolution { get; set; } = true;

    /// <summary>打开播放时是否从上次停下的位置继续。</summary>
    public bool ResumePlayback { get; set; } = true;

    /// <summary>画面比例：fit / fill / stretch / 16:9 / 4:3。</summary>
    public string? VideoAspect { get; set; }

    /// <summary>播放缓冲上限（MB）。默认 512，设置页可选 256 / 512 / 1024 / 2048 / 4096。</summary>
    public int BufferSizeMb { get; set; } = 512;

    /// <summary>音频直通（AC3 / EAC3 / DTS / TrueHD 交给功放解码）。</summary>
    public bool AudioPassthrough { get; set; }

    /// <summary>HDR 直通（mpv 的 target-colorspace-hint，系统开了 HDR 才有效）。</summary>
    public bool HdrPassthrough { get; set; }

    /// <summary>
    /// HDR → SDR 的亮度参考（nits）。0 = 自动（跟随系统 SDR 白点，
    /// Windows 实测是 80 nit）。个别显示器观感不同时用户可以覆盖。
    /// </summary>
    public int HdrPeakNits { get; set; }

    /// <summary>音频输出设备（mpv audio-device 的名字）；空 = 系统默认。</summary>
    public string? AudioDevice { get; set; }

    /// <summary>弹幕默认开关。凭据不在这里：打包时写进程序集元数据
    /// （见 Services/DanmakuCredential.cs），用户不用填。</summary>
    public bool? DanmakuEnabled { get; set; }

    /// <summary>Trakt 观看记录同步：播放时自动 scrobble。</summary>
    public bool? TraktEnabled { get; set; }

    /// <summary>Trakt 应用凭据；留空就用打包时注入的程序集元数据。</summary>
    public string? TraktClientId { get; set; }
    public string? TraktClientSecret { get; set; }

    /// <summary>Trakt 账号 token（OAuth）。存盘时走 DPAPI 密封。</summary>
    public string? TraktAccessToken { get; set; }
    public string? TraktRefreshToken { get; set; }
    /// <summary>access token 的过期时间（Unix 秒）。</summary>
    public long? TraktExpiresAt { get; set; }
    public string? TraktUsername { get; set; }

    /// <summary>在线字幕（OpenSubtitles）。API Key 注册即得；用户名 / 密码可选。</summary>
    public string? OpenSubtitlesApiKey { get; set; }
    public string? OpenSubtitlesUsername { get; set; }
    public string? OpenSubtitlesPassword { get; set; }
    public string? SubtitleLanguages { get; set; }

    public static string FilePath
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "dvplayer");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "settings.json");
        }
    }

    public static AppSettings Load()
    {
        var path = FilePath;

        try
        {
            if (File.Exists(path))
            {
                var text = File.ReadAllText(path);
                var settings =
                    JsonSerializer.Deserialize<AppSettings>(text, Json) ?? new AppSettings();
                settings.Unseal();
                return settings;
            }
        }
        catch (Exception ex)
        {
            // 配置损坏就当空的，不让启动失败；但先备份坏文件：
            // 否则下一次 Save() 会把空对象写回去，源和凭据全没了。
            try
            {
                var backup = path + ".broken-" + DateTime.Now.ToString("yyyyMMddHHmmss");
                File.Move(path, backup, overwrite: true);
                Trace.Write($"settings load failed, moved to {backup}: {ex.Message}");
            }
            catch (Exception)
            {
                // 备份都失败就维持原状，至少别让启动崩掉。
            }
        }

        return new AppSettings();
    }

    public void Save()
    {
        lock (SaveLock)
        {
            var path = FilePath;
            var temp = path + ".tmp";

            try
            {
                // 先写临时文件再原子替换：写到一半崩溃/断电不会留下半截 JSON。
                // 凭据用当前用户的 DPAPI 密钥加密：配置文件被拷走 / 被别的账户读到也解不开。
                File.WriteAllText(temp, JsonSerializer.Serialize(SealedForStorage(), Json));
                File.Move(temp, path, overwrite: true);
            }
            catch (Exception)
            {
                // 写失败不影响播放。
                try { File.Delete(temp); } catch (Exception) { }
            }
        }
    }

    // —— 凭据保护（DPAPI，按当前 Windows 用户） ——

    /// <summary>存盘用的副本：内存里的对象不变，只把要落盘的凭据换成密文。</summary>
    private AppSettings SealedForStorage()
    {
        var copy = (AppSettings)MemberwiseClone();
        copy.Sources = (Sources ?? new List<SourceConfig>())
            .Select(source => source with { Password = Seal(source.Password) })
            .ToList();
        copy.OpenSubtitlesPassword = Seal(OpenSubtitlesPassword);
        copy.OpenSubtitlesApiKey = Seal(OpenSubtitlesApiKey);
        copy.TraktClientSecret = Seal(TraktClientSecret);
        copy.TraktAccessToken = Seal(TraktAccessToken);
        copy.TraktRefreshToken = Seal(TraktRefreshToken);
        return copy;
    }

    /// <summary>读到内存的副本：旧版明文原样保留，下次保存时自动转成密文。</summary>
    private void Unseal()
    {
        Sources = (Sources ?? new List<SourceConfig>())
            .Select(source => source with { Password = Unseal(source.Password) })
            .ToList();
        OpenSubtitlesPassword = Unseal(OpenSubtitlesPassword);
        OpenSubtitlesApiKey = Unseal(OpenSubtitlesApiKey);
        TraktClientSecret = Unseal(TraktClientSecret);
        TraktAccessToken = Unseal(TraktAccessToken);
        TraktRefreshToken = Unseal(TraktRefreshToken);
    }

    private static string Seal(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        if (value.StartsWith(SealedPrefix, StringComparison.Ordinal))
        {
            return value;
        }

        var bytes = Encoding.UTF8.GetBytes(value);
        var handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            var input = new DataBlob { Size = bytes.Length, Data = handle.AddrOfPinnedObject() };
            if (!CryptProtectData(ref input, "dvplayer", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    CryptProtectUiForbidden, out var output))
            {
                // 极少数失败（服务被禁用）：宁可明文存，也别丢凭据。
                return value;
            }

            try
            {
                var sealedBytes = new byte[output.Size];
                Marshal.Copy(output.Data, sealedBytes, 0, output.Size);
                return SealedPrefix + Convert.ToBase64String(sealedBytes);
            }
            finally
            {
                LocalFree(output.Data);
            }
        }
        catch (Exception)
        {
            return value;
        }
        finally
        {
            handle.Free();
        }
    }

    private static string Unseal(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        // 没有前缀 = 旧版明文配置。
        if (!value.StartsWith(SealedPrefix, StringComparison.Ordinal))
        {
            return value;
        }

        byte[] sealedBytes;
        try
        {
            sealedBytes = Convert.FromBase64String(value[SealedPrefix.Length..]);
        }
        catch (FormatException)
        {
            return string.Empty;
        }

        var handle = GCHandle.Alloc(sealedBytes, GCHandleType.Pinned);
        try
        {
            var input = new DataBlob
            {
                Size = sealedBytes.Length,
                Data = handle.AddrOfPinnedObject(),
            };
            if (!CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    CryptProtectUiForbidden, out var output))
            {
                // 配置文件被拷到别的用户 / 别的机器：解不开就当没填密码，
                // 别让整份配置读不出来（源列表、其它设置都还在）。
                return string.Empty;
            }

            try
            {
                var plain = new byte[output.Size];
                Marshal.Copy(output.Data, plain, 0, output.Size);
                return Encoding.UTF8.GetString(plain);
            }
            finally
            {
                LocalFree(output.Data);
            }
        }
        catch (Exception)
        {
            return string.Empty;
        }
        finally
        {
            handle.Free();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn, string? description, IntPtr optionalEntropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn, IntPtr description, IntPtr optionalEntropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
