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
