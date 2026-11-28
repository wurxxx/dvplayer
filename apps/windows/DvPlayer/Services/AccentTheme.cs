using System.Globalization;
using System.Windows.Media;

namespace DvPlayer.Services;

/// <summary>一个预设主题色。只存主色（填充色），其余档位由 <see cref="AccentTheme"/> 派生。</summary>
public sealed record AccentPreset(string Id, string Title, Color Fill);

/// <summary>
/// 主题色（强调色）：预设若干主色，也允许用户自选。
///
/// 和 macOS 的 AccentTheme.swift 同一套预设、同一套 HSL 派生规则：
/// 只存一个主色，文字色 / 选中块底 / 填充上的文字都按它的色相自动算，
/// 换颜色不用手调一整套色板。
///
/// 存储格式：预设 id（amber / blue …），或 <c>custom:RRGGBB</c>。
/// </summary>
public static class AccentTheme
{
    public const string Default = "amber";

    private const string CustomPrefix = "custom:";

    /// <summary>预设色：都取自 UI 配色库里验证过的强调色（影视 / 音频 / 游戏场景）。</summary>
    public static readonly IReadOnlyList<AccentPreset> Presets = new[]
    {
        new AccentPreset("amber", "琥珀", Hex(0xFFB020)),   // 现有默认
        new AccentPreset("orange", "橙", Hex(0xF97316)),    // 深色音频场景的暖橙
        new AccentPreset("red", "玫红", Hex(0xE11D48)),     // 影院深色 + 播放红
        new AccentPreset("purple", "紫", Hex(0x7C3AED)),   // 游戏霓虹紫
        new AccentPreset("blue", "蓝", Hex(0x2563EB)),     // 流媒体 / 社交蓝
        new AccentPreset("cyan", "青", Hex(0x0891B2)),     // 编辑器滤镜青
        new AccentPreset("green", "绿", Hex(0x22C55E)),    // 音乐 / 仪表盘绿
    };

    /// <summary>当前主色：预设 / custom:RRGGBB / 裸 hex，认不出来就用琥珀。</summary>
    public static Color Fill(string? stored) =>
        Preset(stored)?.Fill ?? Custom(stored) ?? ParseHex(stored) ?? Presets[0].Fill;

    public static AccentPreset? Preset(string? stored)
    {
        if (string.IsNullOrWhiteSpace(stored))
        {
            return null;
        }

        var id = stored.Trim().ToLowerInvariant();
        foreach (var preset in Presets)
        {
            if (preset.Id == id)
            {
                return preset;
            }
        }

        return null;
    }

    /// <summary>自定义色的 24 位值；不是自定义色时为 null。</summary>
    public static Color? Custom(string? stored)
    {
        if (stored is null)
        {
            return null;
        }

        var text = stored.Trim();
        if (!text.StartsWith(CustomPrefix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return ParseHex(text[CustomPrefix.Length..]);
    }

    /// <summary>规范化存储值；认不出来返回琥珀（老配置 / 手改坏了都不影响启动）。</summary>
    public static string Normalize(string? stored)
    {
        if (Preset(stored) is { } preset)
        {
            return preset.Id;
        }

        if (Custom(stored) is { } custom)
        {
            return CustomValue(custom);
        }

        // 自检参数允许直接写 6 位 hex（`--accent 7C3AED`），存的时候统一成 custom:。
        if (ParseHex(stored) is { } hex)
        {
            return CustomValue(hex);
        }

        return Default;
    }

    public static string CustomValue(Color color) =>
        CustomPrefix + $"{color.R:X2}{color.G:X2}{color.B:X2}";

    public static string HexText(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

    /// <summary>解析 <c>#RRGGBB</c> / <c>RRGGBB</c>（设置页的自定义输入也能用）。</summary>
    public static Color? ParseHex(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var value = text.Trim().TrimStart('#');
        if (value.Length != 6 ||
            !uint.TryParse(value, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var hex))
        {
            return null;
        }

        return Hex(hex);
    }

    // —— 派生档位（和 macOS AccentPalette 一致） ——

    /// <summary>
    /// 填充上的文字：深字和白字里取对比度更高的那个。
    /// 不能只看「亮底深字」的固定阈值——橙 F97316、绿 22C55E 用白字
    /// 只有 2.3–2.8:1，换成深字才过 AA，而深蓝反过来要白字。
    /// </summary>
    public static Color OnFill(Color fill)
    {
        var dark = Hex(0x1A1200);
        return Contrast(dark, fill) >= Contrast(Colors.White, fill) ? dark : Colors.White;
    }

    /// <summary>
    /// 当文字 / 图标 / 细描边用：浅色下压到页面底色 ≥4.5:1，深色下提到卡片底 ≥4.5:1。
    /// 按对比度反推而不是写死 L：用户自定义的颜色再浅再暗也能读。
    /// 浅色取页面底色 F4F5F7（比卡片白更暗，是最坏情况），深色取卡片 1F1F27
    /// （比页面底色更亮，也是最坏情况）。
    /// </summary>
    public static Color Ink(Color fill, bool light)
    {
        var hsl = ToHsl(fill);

        if (light)
        {
            var page = Hex(0xF4F5F7);
            hsl.L = Math.Min(hsl.L, 0.42);
            var color = FromHsl(hsl);
            while (hsl.L > 0.04 && Contrast(color, page) < 4.5)
            {
                hsl.L = Math.Max(0.04, hsl.L - 0.01);
                color = FromHsl(hsl);
            }

            return color;
        }

        hsl.S *= 0.9;
        hsl.L = Math.Max(hsl.L, 0.5);
        var surface = Hex(0x1F1F27);
        var ink = FromHsl(hsl);
        while (hsl.L < 0.96 && Contrast(ink, surface) < 4.5)
        {
            hsl.L = Math.Min(0.96, hsl.L + 0.01);
            ink = FromHsl(hsl);
        }

        return ink;
    }

    /// <summary>选中块的底：浅色下接近白，深色下接近黑，保留一点色相。</summary>
    public static Color Soft(Color fill, bool light)
    {
        var hsl = ToHsl(fill);
        hsl.L = light ? 0.95 : 0.14;
        hsl.S = light ? hsl.S * 0.85 : hsl.S * 0.6;
        return FromHsl(hsl);
    }

    /// <summary>写死三位的 0xRRGGBB。</summary>
    public static Color Hex(uint rgb) =>
        Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    // —— 工具 ——

    /// <summary>WCAG 对比度（1…21）。</summary>
    private static double Contrast(Color a, Color b)
    {
        var la = Luminance(a);
        var lb = Luminance(b);
        return (Math.Max(la, lb) + 0.05) / (Math.Min(la, lb) + 0.05);
    }

    private static double Luminance(Color color)
    {
        static double Linear(double value) =>
            value <= 0.03928 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);

        return 0.2126 * Linear(color.R / 255.0)
            + 0.7152 * Linear(color.G / 255.0)
            + 0.0722 * Linear(color.B / 255.0);
    }

    private static Hsl ToHsl(Color color)
    {
        var r = color.R / 255.0;
        var g = color.G / 255.0;
        var b = color.B / 255.0;
        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        var l = (max + min) / 2;
        var d = max - min;

        if (d < 0.0001)
        {
            return new Hsl(0, 0, l);
        }

        var s = d / (1 - Math.Abs(2 * l - 1));
        double h;
        if (max == r)
        {
            h = ((g - b) / d) % 6;
        }
        else if (max == g)
        {
            h = (b - r) / d + 2;
        }
        else
        {
            h = (r - g) / d + 4;
        }

        h *= 60;
        if (h < 0)
        {
            h += 360;
        }

        return new Hsl(h, s, l);
    }

    private static Color FromHsl(Hsl hsl)
    {
        var c = (1 - Math.Abs(2 * hsl.L - 1)) * hsl.S;
        var x = c * (1 - Math.Abs(hsl.H / 60 % 2 - 1));
        var m = hsl.L - c / 2;

        double r = 0, g = 0, b = 0;
        switch (hsl.H)
        {
            case < 60: r = c; g = x; break;
            case < 120: r = x; g = c; break;
            case < 180: g = c; b = x; break;
            case < 240: g = x; b = c; break;
            case < 300: r = x; b = c; break;
            default: r = c; b = x; break;
        }

        static byte ToByte(double value) =>
            (byte)Math.Clamp(Math.Round(value * 255), 0, 255);

        // 已经把 m 加进分量再取整，避免先截断再相加偏一档。
        return Color.FromRgb(ToByte(r + m), ToByte(g + m), ToByte(b + m));
    }

    private struct Hsl
    {
        public Hsl(double h, double s, double l)
        {
            H = h;
            S = s;
            L = l;
        }

        public double H { get; }
        public double S { get; set; }
        public double L { get; set; }
    }
}
