using System.Text.Json;

namespace DvPlayer.Player;

/// <summary>
/// 播放器控制通道的抽象。<see cref="MpvIpc"/>（子进程 + 命名管道）和
/// <see cref="LibMpvClient"/>（进程内 libmpv C API）都实现它，
/// <c>PlayWindow</c> 只认这个接口，不关心底层是哪种。
/// </summary>
public interface IMpvControl : IDisposable
{
    /// <summary>属性变化：(name, value)。mpv 没数据时 value 是 JsonElement 的 Null。</summary>
    event Action<string, JsonElement>? PropertyChanged;

    event Action? Disconnected;

    bool IsConnected { get; }

    Task<bool> ConnectAsync(TimeSpan timeout);

    /// <summary>发一条 mpv 命令，例如 <c>Command("set_property", "pause", true)</c>。</summary>
    void Command(params object?[] args);

    /// <summary>订阅属性；mpv 会先推一次当前值。</summary>
    void Observe(string name);
}

/// <summary>
/// 播放引擎的抽象：负责起播放器、把画面挂到壳的 HWND、给出控制通道。
///
/// 两个实现：
/// <list type="bullet">
/// <item><see cref="MpvProcess"/>：子进程 <c>mpv.exe --wid</c> + 命名管道（默认，已验证）</item>
/// <item><see cref="LibMpvProcess"/>：进程内 <c>libmpv-2.dll</c> + C API（体积小，待验证）</item>
/// </list>
///
/// 用 <c>DVPLAYER_MPV_BACKEND=libmpv</c> 切到进程内后端，默认走子进程，
/// 这样新路径出问题时不影响现有可用版本。
/// </summary>
public interface IMpvEngine : IDisposable
{
    bool IsRunning { get; }

    /// <summary>控制通道；<see cref="Start"/> 之后才有值。</summary>
    IMpvControl? Control { get; }

    /// <summary>控制通道就绪；连接失败返回 false。</summary>
    Task<bool>? ControlReady { get; }

    event EventHandler? Exited;

    void Start(IntPtr wid, MpvLaunch launch, string? mpvPath = null);

    void Stop();
}
