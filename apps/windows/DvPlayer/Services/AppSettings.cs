using System.IO;
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

    /// <summary>音频输出设备（mpv audio-device 的名字）；空 = 系统默认。</summary>
    public string? AudioDevice { get; set; }

    /// <summary>弹幕（弹弹play）。AppId / AppSecret 在弹弹play 控制台申请。</summary>
    public bool? DanmakuEnabled { get; set; }
    public string? DanmakuAppId { get; set; }
    public string? DanmakuAppSecret { get; set; }

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
        try
        {
            if (File.Exists(FilePath))
            {
                var text = File.ReadAllText(FilePath);
                return JsonSerializer.Deserialize<AppSettings>(text, Json) ?? new AppSettings();
            }
        }
        catch (Exception)
        {
            // 配置损坏就当空的，不让启动失败。
        }

        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
        }
        catch (Exception)
        {
            // 写失败不影响播放。
        }
    }
}
