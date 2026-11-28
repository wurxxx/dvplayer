using System.Windows;

namespace DvPlayer;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // 外观要在主窗口解析 XAML 之前定下来：--appearance / --accent 只影响这次运行
        // （截图自检用），不写回设置。色板换不起来也别让程序起不来。
        try
        {
            var settings = Services.AppServices.Instance.Settings;
            Services.ThemeService.ApplyAccent(AccentArgument() ?? settings.AccentColor);
            Services.ThemeService.Apply(AppearanceArgument() ?? settings.Appearance);
        }
        catch (Exception ex)
        {
            Services.Trace.Write("theme apply at startup failed: " + ex);
        }

        // 远程自检时没人看得到弹窗：崩溃原因直接写进 player.log。
        DispatcherUnhandledException += (_, args) =>
        {
            Services.Trace.Write("unhandled ui exception: " + args.Exception);

            // 重连换核心时，页面上还在飞的旧调用会撞上已释放的 SafeHandle。
            // 这不是程序错误：记一行就够，别把整个窗口退掉。其它异常照旧退出。
            args.Handled = args.Exception is ObjectDisposedException;
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex)
            {
                Services.Trace.Write("unhandled exception: " + ex);
            }
        };
    }

    /// <summary>--appearance light|dark|system（也认 --appearance=light）。</summary>
    private static string? AppearanceArgument() => Argument("--appearance");

    /// <summary>--accent blue|7C3AED|custom:3B82F6（也认 --accent=blue）。</summary>
    private static string? AccentArgument() => Argument("--accent");

    /// <summary>取 --name value 或 --name=value；没给就返回 null。</summary>
    private static string? Argument(string name)
    {
        var args = Environment.GetCommandLineArgs();

        var inline = args.FirstOrDefault(
            arg => arg.StartsWith(name + "=", StringComparison.Ordinal));
        if (inline is not null)
        {
            return inline[(name.Length + 1)..];
        }

        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
}
