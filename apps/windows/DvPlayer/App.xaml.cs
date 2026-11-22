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
}
