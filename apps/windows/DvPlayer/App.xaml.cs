using System.Windows;

namespace DvPlayer;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // 远程自检时没人看得到弹窗：崩溃原因直接写进 player.log。
        DispatcherUnhandledException += (_, args) =>
        {
            Services.Trace.Write("unhandled ui exception: " + args.Exception);
            args.Handled = false;
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex)
            {
                Services.Trace.Write("unhandled exception: " + ex);
            }
        };
    }
}
