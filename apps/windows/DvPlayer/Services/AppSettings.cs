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

    /// <summary>启动后先打开哪一页：home / libraries / records。</summary>
    public string StartPage { get; set; } = "libraries";

    /// <summary>列表每页条数（媒体库与搜索共用）。</summary>
    public int PageSize { get; set; } = 60;

    /// <summary>列表卡片上是否显示分辨率角标。</summary>
    public bool ShowResolution { get; set; } = true;

    /// <summary>打开播放时是否从上次停下的位置继续。</summary>
    public bool ResumePlayback { get; set; } = true;

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
