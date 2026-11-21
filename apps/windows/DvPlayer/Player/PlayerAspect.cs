namespace DvPlayer.Player;

/// <summary>播放页的画面比例（和 macOS 的 `PlayerAspect` 一一对应）。</summary>
public enum PlayerAspect
{
    Fit,
    Fill,
    Stretch,
    Ratio16x9,
    Ratio4x3,
}

public static class PlayerAspectExtensions
{
    /// <summary>存配置用的键。</summary>
    public static string Key(this PlayerAspect aspect) => aspect switch
    {
        PlayerAspect.Fill => "fill",
        PlayerAspect.Stretch => "stretch",
        PlayerAspect.Ratio16x9 => "16:9",
        PlayerAspect.Ratio4x3 => "4:3",
        _ => "fit",
    };

    public static PlayerAspect Parse(string? key) => key switch
    {
        "fill" => PlayerAspect.Fill,
        "stretch" => PlayerAspect.Stretch,
        "16:9" => PlayerAspect.Ratio16x9,
        "4:3" => PlayerAspect.Ratio4x3,
        _ => PlayerAspect.Fit,
    };

    public static string Label(this PlayerAspect aspect) => aspect switch
    {
        PlayerAspect.Fill => "填充窗口（裁切）",
        PlayerAspect.Stretch => "拉伸铺满",
        PlayerAspect.Ratio16x9 => "强制 16:9",
        PlayerAspect.Ratio4x3 => "强制 4:3",
        _ => "适应窗口",
    };

    /// <summary>mpv 的三个属性：keepaspect / panscan / video-aspect-override。</summary>
    public static (bool KeepAspect, double Panscan, string Override) ToMpv(this PlayerAspect aspect)
        => aspect switch
        {
            PlayerAspect.Fill => (true, 1, "no"),
            PlayerAspect.Stretch => (false, 0, "no"),
            PlayerAspect.Ratio16x9 => (true, 0, "16:9"),
            PlayerAspect.Ratio4x3 => (true, 0, "4:3"),
            _ => (true, 0, "no"),
        };
}
