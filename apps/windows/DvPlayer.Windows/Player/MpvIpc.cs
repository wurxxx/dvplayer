using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace DvPlayer.Windows.Player;

/// <summary>
/// mpv 的 JSON IPC 客户端（Windows 命名管道）。
///
/// mpv 以 <c>--input-ipc-server=\\.\pipe\&lt;name&gt;</c> 启动后，这里连上去发命令、
/// 订阅属性。壳的快捷键、进度条、音量全走这条通道，所以视频子窗口有没有焦点都无所谓。
/// </summary>
public sealed class MpvIpc : IDisposable
{
    private NamedPipeClientStream? _pipe;
    private StreamWriter? _writer;
    private Thread? _reader;
    private CancellationTokenSource? _cts;
    private int _nextId = 1;
    private readonly object _writeLock = new();

    public MpvIpc(string pipeName)
    {
        PipeName = pipeName;
    }

    public string PipeName { get; }

    /// <summary>属性变化：(name, value)。mpv 没数据时 value 是 JsonElement 的 Null。</summary>
    public event Action<string, JsonElement>? PropertyChanged;

    public event Action? Disconnected;

    public bool IsConnected => _pipe is { IsConnected: true };

    public async Task<bool> ConnectAsync(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;

        while (DateTime.UtcNow < deadline)
        {
            var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                await pipe.ConnectAsync(500).ConfigureAwait(false);
                _pipe = pipe;
                _writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
                _cts = new CancellationTokenSource();
                _reader = new Thread(() => ReadLoop(_cts.Token)) { IsBackground = true, Name = "mpv-ipc" };
                _reader.Start();
                return true;
            }
            catch (Exception)
            {
                pipe.Dispose();
                await Task.Delay(150).ConfigureAwait(false);
            }
        }

        return false;
    }

    /// <summary>发一条 mpv 命令，例如 Command("set_property", "pause", true)。</summary>
    public void Command(params object?[] args)
    {
        var payload = JsonSerializer.Serialize(new Dictionary<string, object?> { ["command"] = args });
        WriteLine(payload);
    }

    /// <summary>订阅属性；mpv 会先推一次当前值。</summary>
    public void Observe(string name)
    {
        Command("observe_property", _nextId++, name);
    }

    public void Dispose()
    {
        try
        {
            _cts?.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }

        try
        {
            _writer?.Dispose();
        }
        catch (IOException)
        {
        }

        try
        {
            _pipe?.Dispose();
        }
        catch (IOException)
        {
        }

        _pipe = null;
        _writer = null;
        _cts?.Dispose();
        _cts = null;
    }

    private void WriteLine(string json)
    {
        var writer = _writer;
        if (writer is null)
        {
            return;
        }

        try
        {
            lock (_writeLock)
            {
                writer.WriteLine(json);
            }
        }
        catch (IOException)
        {
            // mpv 退了，等下次 Play 重连。
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private void ReadLoop(CancellationToken token)
    {
        var pipe = _pipe;
        if (pipe is null)
        {
            return;
        }

        var reader = new StreamReader(pipe, new UTF8Encoding(false));

        try
        {
            while (!token.IsCancellationRequested)
            {
                var line = reader.ReadLine();
                if (line is null)
                {
                    break;
                }

                if (line.Length == 0)
                {
                    continue;
                }

                try
                {
                    using var doc = JsonDocument.Parse(line);
                    var root = doc.RootElement;

                    if (!root.TryGetProperty("event", out var ev) ||
                        ev.GetString() != "property-change")
                    {
                        continue;
                    }

                    if (!root.TryGetProperty("name", out var nameElement))
                    {
                        continue;
                    }

                    var name = nameElement.GetString();
                    if (string.IsNullOrEmpty(name))
                    {
                        continue;
                    }

                    var value = root.TryGetProperty("data", out var data)
                        ? data.Clone()
                        : default;

                    PropertyChanged?.Invoke(name, value);
                }
                catch (JsonException)
                {
                    // 半行/异常数据，忽略。
                }
            }
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        finally
        {
            Disconnected?.Invoke();
        }
    }
}
