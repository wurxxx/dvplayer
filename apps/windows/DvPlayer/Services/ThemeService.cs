using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace DvPlayer.Services;

/// <summary>外观模式：跟随系统 / 深色 / 浅色。</summary>
public enum AppearanceMode
{
    System,
    Dark,
    Light,
}

/// <summary>
/// 主题切换：把整套色板换成 Palette.Dark / Palette.Light，并把 WPF-UI 自带的
/// 控件主题一起切过去（滚动条、圆角窗口这些内置样式不走我们的色板）。
///
/// 页面里的颜色引用一律用 DynamicResource，换字典后已经画出来的控件会立刻跟着变；
/// 压在图片上的文字、播放窗（固定深色）不参与切换。
/// </summary>
public static class ThemeService
{
    private static bool _watching;

    /// <summary>当前是不是浅色。派生强调色各档位时要用。</summary>
    private static bool _light;

    /// <summary>当前是不是浅色：详情页这类「文字压在图上」的地方要按它换配色。</summary>
    public static bool IsLight => _light;

    /// <summary>主题色存储值：预设 id 或 custom:RRGGBB。</summary>
    private static string _accent = AccentTheme.Default;

    public static AppearanceMode Mode { get; private set; } = AppearanceMode.System;

    /// <summary>当前主题色（存储值）。</summary>
    public static string Accent => _accent;

    /// <summary>当前主题色的主色（填充色）。</summary>
    public static Color AccentFill => AccentTheme.Fill(_accent);

    /// <summary>切换完成后触发。代码里写死过颜色的地方可以挂这个事件重新取色。</summary>
    public static event Action? Changed;

    public static void Apply(string? mode) => Apply(Parse(mode));

    public static void Apply(AppearanceMode mode)
    {
        Mode = mode;
        _light = mode == AppearanceMode.Light ||
                 (mode == AppearanceMode.System && IsSystemLight());

        SwapPalette(_light);
        ApplyAccentOverrides();

        try
        {
            // backdrop 传 None、updateAccent 传 false：只换 WPF-UI 自带的字典，
            // 不碰窗口背景（我们的 BgBrush 是不透明自绘，Mica 会把它抹掉），
            // 也不改强调色（色板里自己那档强调色才是准的）。
            ApplicationThemeManager.Apply(
                _light ? ApplicationTheme.Light : ApplicationTheme.Dark,
                WindowBackdropType.None,
                updateAccent: false);
        }
        catch (Exception ex)
        {
            // WPF-UI 的版本换了 API 也不至于让整个界面起不来：色板已经换了。
            Trace.Write("theme wpf-ui apply failed: " + ex.Message);
        }

        WatchSystemChanges();
        Trace.Write($"appearance {Name(mode)} -> {(_light ? "light" : "dark")}");
        Changed?.Invoke();
    }

    /// <summary>
    /// 应用主题色（预设 id 或 custom:RRGGBB）：只改强调色那几个资源，
    /// 已经画出来的控件靠 DynamicResource 立刻跟着变。空 / 认不出来 = 琥珀。
    /// </summary>
    public static void ApplyAccent(string? stored)
    {
        var next = AccentTheme.Normalize(stored);
        if (next == _accent)
        {
            return;
        }

        _accent = next;
        ApplyAccentOverrides();
        Trace.Write($"accent {_accent}");
        Changed?.Invoke();
    }

    /// <summary>
    /// 把强调色的四个档位覆盖到 App 资源上。覆盖写在最外层字典里，
    /// 层级比 Palette.* 高，换外观整本替换色板时也不会被冲掉。
    /// </summary>
    private static void ApplyAccentOverrides()
    {
        if (Application.Current is not { } app)
        {
            return;
        }

        var fill = AccentTheme.Fill(_accent);
        var ink = AccentTheme.Ink(fill, _light);
        var resources = app.Resources;

        resources["AccentColor"] = fill;
        resources["AccentInkColor"] = ink;
        resources["OnAccentColor"] = AccentTheme.OnFill(fill);
        resources["AccentBrush"] = Brush(fill);
        resources["AccentInkBrush"] = Brush(ink);
        resources["AccentSoftBrush"] = Brush(AccentTheme.Soft(fill, _light));
        resources["OnAccentBrush"] = Brush(AccentTheme.OnFill(fill));
    }

    /// <summary>
    /// 把一个窗口自己的资源换成当前主题色。播放窗固定深色（窗口级 merge 了
    /// 深色色板），主题色也得按深色那套派生，否则控制条上的强调色会跟设置不一致。
    /// </summary>
    public static void ApplyAccentTo(ResourceDictionary target)
    {
        var fill = AccentTheme.Fill(_accent);
        target["AccentColor"] = fill;
        target["AccentInkColor"] = AccentTheme.Ink(fill, light: false);
        target["OnAccentColor"] = AccentTheme.OnFill(fill);
        target["AccentBrush"] = Brush(fill);
        target["AccentInkBrush"] = Brush(AccentTheme.Ink(fill, light: false));
        target["AccentSoftBrush"] = Brush(AccentTheme.Soft(fill, light: false));
        target["OnAccentBrush"] = Brush(AccentTheme.OnFill(fill));
    }

    private static SolidColorBrush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    public static string Name(AppearanceMode mode) => mode switch
    {
        AppearanceMode.Light => "light",
        AppearanceMode.Dark => "dark",
        _ => "system",
    };

    private static AppearanceMode Parse(string? mode) => mode?.Trim().ToLowerInvariant() switch
    {
        "light" => AppearanceMode.Light,
        "dark" => AppearanceMode.Dark,
        _ => AppearanceMode.System,
    };

    /// <summary>Windows 设置 → 个性化 → 颜色 → 「选择默认应用模式」。</summary>
    private static bool IsSystemLight()
    {
        try
        {
            var value = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 0);
            return value is int i && i != 0;
        }
        catch (Exception ex)
        {
            Trace.Write("read system theme failed: " + ex.Message);
            return false;
        }
    }

    private static void SwapPalette(bool light)
    {
        if (Application.Current is not { } app)
        {
            return;
        }

        var palette = new ResourceDictionary
        {
            Source = new Uri(
                $"pack://application:,,,/DvPlayer;component/Themes/Palette.{(light ? "Light" : "Dark")}.xaml",
                UriKind.Absolute),
        };

        var merged = app.Resources.MergedDictionaries;
        for (var index = 0; index < merged.Count; index++)
        {
            var source = merged[index].Source?.OriginalString;
            if (source is not null && source.Contains("Palette.", StringComparison.Ordinal))
            {
                merged[index] = palette;
                return;
            }
        }

        // 没找到（比如启动时字典被别的地方替换过）：插在 AppTheme 前面。
        merged.Insert(Math.Max(0, merged.Count - 1), palette);
    }

    /// <summary>
    /// 只在「跟随系统」时监听系统外观变化。只订阅一次，重复 Apply 不会叠加。
    /// </summary>
    private static void WatchSystemChanges()
    {
        if (_watching)
        {
            return;
        }

        _watching = true;
        try
        {
            SystemEvents.UserPreferenceChanged += (_, args) =>
            {
                if (Mode != AppearanceMode.System)
                {
                    return;
                }

                if (args.Category is not (UserPreferenceCategory.General or
                    UserPreferenceCategory.VisualStyle))
                {
                    return;
                }

                Application.Current?.Dispatcher.BeginInvoke(() => Apply(AppearanceMode.System));
            };
        }
        catch (Exception ex)
        {
            Trace.Write("theme watch failed: " + ex.Message);
        }
    }
}
