namespace DvPlayer.Player;

/// <summary>
/// 选播放后端。默认走**子进程**（<c>mpv.exe --wid</c>）——这条路径在真机上
/// 验证过 DV P7 FEL，是最稳的。
///
/// 设 <c>DVPLAYER_MPV_BACKEND=libmpv</c> 切到进程内 libmpv。注意它**不省体积**：
/// 官方 dev 包的 libmpv-2.dll 同样是静态链接（116 MB），和 mpv.exe 一样大。
/// 而且 mpv 崩了会连累整个 App（DV 链路真机验过，见 ADR-0012）。
///
/// 两条路径共用同一份 <see cref="MpvLaunch"/> 和选项集，行为差异只在
/// "谁来装 mpv"。
/// </summary>
internal static class MpvBackend
{
    public const string EnvVar = "DVPLAYER_MPV_BACKEND";

    /// <summary>当前选中的后端名：<c>process</c>（默认）或 <c>libmpv</c>。</summary>
    public static string Name
    {
        get
        {
            var raw = Environment.GetEnvironmentVariable(EnvVar);
            return string.Equals(raw, "libmpv", StringComparison.OrdinalIgnoreCase)
                ? "libmpv"
                : "process";
        }
    }

    public static bool IsLibMpv =>
        string.Equals(Name, "libmpv", StringComparison.OrdinalIgnoreCase);

    /// <summary>按当前选择造一个引擎。</summary>
    public static IMpvEngine Create() =>
        IsLibMpv ? new LibMpvProcess() : new MpvProcess();

    /// <summary>播放缓冲上限（MB）：两个后端共用同一份设置和同一个环境变量覆盖。</summary>
    public static int BufferSizeMb => MpvProcess.BufferSizeMb;

    /// <summary>mpv 日志路径：两个后端写同一个文件，排查时不用记两套。</summary>
    public static string LogPath => MpvProcess.LogPath;
}
