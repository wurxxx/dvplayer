using System.IO;
using System.Text.Json;

namespace DvPlayer.Services;

/// <summary>
/// 原盘 / 本地文件的续播点。媒体库的进度由核心回写，本地盘核心不知道，
/// 所以单独存一份：%LOCALAPPDATA%\dvplayer\local-progress.json。
/// </summary>
public static class LocalProgress
{
    private sealed class Entry
    {
        public double Position { get; set; }
        public double Duration { get; set; }
        public long UpdatedAt { get; set; }
    }

    private static readonly object Gate = new();
    private static Dictionary<string, Entry>? _entries;
    private static readonly Dictionary<string, double> LastSaved = new();

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "dvplayer", "local-progress.json");

    /// <summary>续播点；看完的（停在片尾）或太短的不算，返回 0 从头播。</summary>
    public static double Get(string key)
    {
        if (string.IsNullOrWhiteSpace(key))
        {
            return 0;
        }

        lock (Gate)
        {
            var entries = Load();
            if (!entries.TryGetValue(key, out var entry))
            {
                return 0;
            }

            if (entry.Position < 5 ||
                (entry.Duration > 0 && entry.Position >= entry.Duration - 1))
            {
                return 0;
            }

            return entry.Position;
        }
    }

    /// <summary>记一次进度；位置没怎么变就不写盘（每 10 秒来一次）。</summary>
    public static void Save(string key, double position, double duration)
    {
        if (string.IsNullOrWhiteSpace(key) || position < 0)
        {
            return;
        }

        lock (Gate)
        {
            if (LastSaved.TryGetValue(key, out var last) && Math.Abs(last - position) < 5)
            {
                return;
            }

            var entries = Load();
            entries[key] = new Entry
            {
                Position = position,
                Duration = Math.Max(0, duration),
                UpdatedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            };
            LastSaved[key] = position;
            Persist(entries);
        }
    }

    /// <summary>播完之后清掉续播点，下次从头看。</summary>
    public static void Clear(string key)
    {
        lock (Gate)
        {
            LastSaved.Remove(key);
            var entries = Load();
            if (entries.Remove(key))
            {
                Persist(entries);
            }
        }
    }

    private static Dictionary<string, Entry> Load()
    {
        if (_entries is not null)
        {
            return _entries;
        }

        try
        {
            if (File.Exists(FilePath))
            {
                _entries = JsonSerializer.Deserialize<Dictionary<string, Entry>>(
                    File.ReadAllText(FilePath)) ?? new();
                return _entries;
            }
        }
        catch (Exception ex)
        {
            Trace.Write("local progress load failed: " + ex.Message);
        }

        _entries = new();
        return _entries;
    }

    private static void Persist(Dictionary<string, Entry> entries)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(entries));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception ex)
        {
            Trace.Write("local progress save failed: " + ex.Message);
        }
    }
}
