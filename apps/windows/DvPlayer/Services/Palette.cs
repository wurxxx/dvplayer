using System.Windows.Media;

namespace DvPlayer.Services;

/// <summary>
/// 没有海报时用的程序化占位：从一组克制的影院色调里按标题散列取一个，
/// 保证同一部片每次颜色一致，整体也不会花。
/// </summary>
public static class Palette
{
    // (顶部, 底部, 强调) —— 深青、墨蓝、酒红、橄榄、岩灰、暗紫。
    private static readonly (uint Top, uint Bottom)[] Tones =
    {
        (0xFF16333A, 0xFF0C1D22), // 深青
        (0xFF1B2740, 0xFF0E1526), // 墨蓝
        (0xFF35202A, 0xFF1C1016), // 酒红
        (0xFF2C2E22, 0xFF171812), // 橄榄
        (0xFF262A2E, 0xFF131518), // 岩灰
        (0xFF2A2336, 0xFF14101C), // 暗紫
        (0xFF1F322C, 0xFF101B17), // 松绿
        (0xFF34291D, 0xFF1B150E), // 焦糖
    };

    public static LinearGradientBrush GradientFor(string key)
    {
        var tone = Tones[StableHash(key) % Tones.Length];

        var brush = new LinearGradientBrush(
            ToColor(tone.Top),
            ToColor(tone.Bottom),
            new System.Windows.Point(0, 0),
            new System.Windows.Point(0.35, 1));
        brush.Freeze();
        return brush;
    }

    public static string InitialOf(string title)
    {
        foreach (var ch in title)
        {
            if (!char.IsWhiteSpace(ch))
            {
                return ch.ToString();
            }
        }

        return "?";
    }

    private static Color ToColor(uint argb) => Color.FromArgb(
        (byte)(argb >> 24),
        (byte)(argb >> 16),
        (byte)(argb >> 8),
        (byte)argb);

    private static int StableHash(string value)
    {
        unchecked
        {
            var hash = 17;
            foreach (var ch in value)
            {
                hash = (hash * 31) + ch;
            }

            return hash == int.MinValue ? 1 : Math.Abs(hash);
        }
    }
}
