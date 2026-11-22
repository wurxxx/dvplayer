using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DvPlayer.Services;

/// <summary>
/// 一部剧的片头 / 片尾标记（手动标记，按剧记忆）。
///
/// 时间都是绝对秒数：<see cref="IntroEnd"/> 是片头结束，<see cref="OutroStart"/> 是片尾开始。
/// 和 macOS 的 `skip-markers.json` 同一个格式，将来搬进共享核心时可以直接迁移。
/// </summary>
public sealed class SkipMarker
{
    public double? IntroEnd { get; set; }
    public double? OutroStart { get; set; }

    [JsonIgnore]
    public bool IsEmpty => IntroEnd is null && OutroStart is null;
}

/// <summary>标记的本地存储：%LOCALAPPDATA%\dvplayer\skip-markers.json。</summary>
public static class SkipMarkers
{
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>UI 线程和播放线程都会写，串行化避免互相覆盖。</summary>
    private static readonly object Gate = new();

    private static string FilePath
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "dvplayer");
            Directory.CreateDirectory(dir);
            return Path.Combine(dir, "skip-markers.json");
        }
    }

    public static SkipMarker Get(string key)
    {
        try
        {
            var all = Load();
            return all.TryGetValue(key, out var marker) ? marker : new SkipMarker();
        }
        catch (Exception)
        {
            return new SkipMarker();
        }
    }

    public static void Save(string key, SkipMarker marker)
    {
        lock (Gate)
        {
            try
            {
                var all = Load();
                if (marker.IsEmpty)
                {
                    all.Remove(key);
                }
                else
                {
                    all[key] = marker;
                }

                var path = FilePath;
                var temp = path + ".tmp";

                // 先写临时文件再换名：写到一半崩掉不会留下坏 JSON，
                // 坏文件一旦被解析成空表，下一次 Save 就会清掉所有标记。
                System.IO.File.WriteAllText(temp, JsonSerializer.Serialize(all, Json));
                System.IO.File.Move(temp, path, overwrite: true);
            }
            catch (Exception)
            {
                // 写失败不影响播放。
            }
        }
    }

    private static Dictionary<string, SkipMarker> Load()
    {
        if (!System.IO.File.Exists(FilePath))
        {
            return new Dictionary<string, SkipMarker>();
        }

        var text = System.IO.File.ReadAllText(FilePath);
        return JsonSerializer.Deserialize<Dictionary<string, SkipMarker>>(text, Json)
               ?? new Dictionary<string, SkipMarker>();
    }
}
