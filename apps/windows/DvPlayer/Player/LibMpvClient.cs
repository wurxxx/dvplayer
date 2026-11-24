using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace DvPlayer.Player;

/// <summary>
/// libmpv 的控制通道，对外接口和 <see cref="MpvIpc"/>（子进程 + 命名管道 JSON）
/// **完全一致**，所以 <c>PlayWindow</c> 一行都不用改。
///
/// 区别只在传输层：
/// <list type="bullet">
/// <item>旧：<c>mpv.exe --input-ipc-server</c> → 命名管道 → JSON 文本</item>
/// <item>新：进程内 <c>mpv_*</c> C API → 直接读 <c>mpv_event</c></item>
/// </list>
///
/// 属性值仍然序列化成 <see cref="JsonElement"/>，因为上层是按
/// <c>ValueKind == Number / String / Object / Array</c> 分支处理的；
/// 换类型等于把 PlayWindow 里上百处判断全改一遍，收益为零、风险很高。
/// </summary>
public sealed class LibMpvClient : IMpvControl
{
    private IntPtr _ctx;
    private Thread? _reader;
    private CancellationTokenSource? _cts;
    private readonly object _lock = new();
    private ulong _nextObserveId = 1;
    private volatile bool _disposed;

    /// <summary>属性变化：(name, value)。形状和 <see cref="MpvIpc.PropertyChanged"/> 一致。</summary>
    public event Action<string, JsonElement>? PropertyChanged;

    public event Action? Disconnected;

    public bool IsConnected => _ctx != IntPtr.Zero && !_disposed;

    internal LibMpvClient(IntPtr ctx)
    {
        _ctx = ctx;
    }

    /// <summary>兼容 <see cref="MpvIpc.ConnectAsync"/> 的形状：libmpv 是进程内的，
    /// 初始化成功就已经连通，不需要握手。</summary>
    public Task<bool> ConnectAsync(TimeSpan timeout) => Task.FromResult(IsConnected);

    /// <summary>发一条 mpv 命令，例如 <c>Command("set_property", "pause", true)</c>。</summary>
    public void Command(params object?[] args)
    {
        if (_disposed || args.Length == 0)
        {
            return;
        }

        // 和 Dispose 抢：Dispose 会在 terminate_destroy 之前把 _ctx 置零，
        // 这里必须在锁内取句柄，否则可能拿到一个正在销毁的指针。
        IntPtr ctx;
        lock (_lock)
        {
            ctx = _ctx;
            if (ctx == IntPtr.Zero)
            {
                return;
            }
        }

        var rc = InvokeCommand(ctx, args);
        if (rc < 0)
        {
            Debug.WriteLine($"[libmpv] command 失败({rc}): {string.Join(' ', args)}");
        }
    }

    /// <summary>
    /// 用 <c>mpv_command</c> 的数组形式发命令。每个参数单独一个 C 字符串，
    /// mpv 不做分词，所以带空格 / 引号的路径是安全的。
    /// </summary>
    private static int InvokeCommand(IntPtr ctx, object?[] args)
    {
        var count = args.Length;
        var ptrs = new IntPtr[count + 1];   // 末尾必须是 NULL
        var allocations = new List<IntPtr>(count);

        try
        {
            for (var i = 0; i < count; i++)
            {
                var text = FormatArg(args[i]);
                var bytes = Encoding.UTF8.GetBytes(text + "\0");
                var mem = Marshal.AllocHGlobal(bytes.Length);
                Marshal.Copy(bytes, 0, mem, bytes.Length);
                allocations.Add(mem);
                ptrs[i] = mem;
            }

            ptrs[count] = IntPtr.Zero;

            var arrayMem = Marshal.AllocHGlobal(IntPtr.Size * ptrs.Length);
            try
            {
                Marshal.Copy(ptrs, 0, arrayMem, ptrs.Length);
                return LibMpv.mpv_command(ctx, arrayMem);
            }
            finally
            {
                Marshal.FreeHGlobal(arrayMem);
            }
        }
        finally
        {
            foreach (var mem in allocations)
            {
                Marshal.FreeHGlobal(mem);
            }
        }
    }

    /// <summary>订阅属性；libmpv 会先推一次当前值（和 IPC 的 observe_property 一致）。</summary>
    public void Observe(string name)
    {
        if (_disposed)
        {
            return;
        }

        IntPtr ctx;
        lock (_lock)
        {
            ctx = _ctx;
            if (ctx == IntPtr.Zero)
            {
                return;
            }
        }

        // format 用 Node：这样 mpv 把标量、数组、对象都按 JSON 兼容的结构推过来，
        // 和命名管道那条路的形状最接近（那条路本来就是 JSON）。
        var id = Interlocked.Increment(ref _nextObserveId);
        var rc = LibMpv.mpv_observe_property(ctx, id, name, LibMpv.MpvFormatNode);
        if (rc < 0)
        {
            Debug.WriteLine($"[libmpv] observe {name} 失败({rc})");
        }
    }

    /// <summary>启动事件泵线程。<paramref name="ctx"/> 已 initialize 完成。</summary>
    internal void StartPump()
    {
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        _reader = new Thread(() => Pump(token)) { IsBackground = true, Name = "libmpv-events" };
        _reader.Start();
    }

    private void Pump(CancellationToken token)
    {
        var ctx = _ctx;
        if (ctx == IntPtr.Zero)
        {
            return;
        }

        try
        {
            while (!token.IsCancellationRequested)
            {
                // 100ms 超时：既有事件立刻返回，又能定期检查取消。
                var evPtr = LibMpv.mpv_wait_event(ctx, 0.1);
                if (evPtr == IntPtr.Zero)
                {
                    continue;
                }

                var ev = Marshal.PtrToStructure<LibMpv.MpvEvent>(evPtr);

                if (ev.EventId == LibMpv.MpvEventShutdown)
                {
                    break;
                }

                if (ev.EventId != LibMpv.MpvEventPropertyChange || ev.Data == IntPtr.Zero)
                {
                    continue;
                }

                var prop = Marshal.PtrToStructure<LibMpv.MpvEventProperty>(ev.Data);
                if (prop.Name == IntPtr.Zero)
                {
                    continue;
                }

                var name = Marshal.PtrToStringUTF8(prop.Name);
                if (string.IsNullOrEmpty(name))
                {
                    continue;
                }

                var json = ConvertToJson(prop);
                PropertyChanged?.Invoke(name, json);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine("[libmpv] 事件泵异常: " + ex.Message);
        }
        finally
        {
            if (!token.IsCancellationRequested)
            {
                Disconnected?.Invoke();
            }
        }
    }

    /// <summary>
    /// 把 <c>mpv_event_property</c> 的 <c>data</c> 转成 <see cref="JsonElement"/>。
    /// 用 Node 格式订阅时，data 指向 <c>mpv_node</c>，需要递归展开。
    /// </summary>
    private static JsonElement ConvertToJson(in LibMpv.MpvEventProperty prop)
    {
        switch (prop.Format)
        {
            case LibMpv.MpvFormatNone:
                return default;

            case LibMpv.MpvFormatString:
            case LibMpv.MpvFormatOsdString:
                if (prop.Data == IntPtr.Zero)
                {
                    return default;
                }
                // data 是 char**（见 client.h:1410 的示例：`char *value = *(char **)data`）。
                // 直接 PtrToStringUTF8(data) 会把指针本身当字符串读，得到乱码或崩溃。
                var strPtr = Marshal.ReadIntPtr(prop.Data);
                if (strPtr == IntPtr.Zero)
                {
                    return default;
                }
                return ToElement(JsonSerializer.Serialize(Marshal.PtrToStringUTF8(strPtr)));

            case LibMpv.MpvFormatFlag:
                return ToElement(prop.Data != IntPtr.Zero && Marshal.ReadInt32(prop.Data) != 0
                    ? "true" : "false");

            case LibMpv.MpvFormatInt64:
                return prop.Data == IntPtr.Zero
                    ? default
                    : ToElement(Marshal.ReadInt64(prop.Data).ToString(CultureInfo.InvariantCulture));

            case LibMpv.MpvFormatDouble:
                return prop.Data == IntPtr.Zero
                    ? default
                    : ToElement(Marshal.ReadDouble(prop.Data)
                        .ToString("R", CultureInfo.InvariantCulture));

            case LibMpv.MpvFormatNode:
                return prop.Data == IntPtr.Zero
                    ? default
                    : NodeToJson(prop.Data);

            default:
                return default;
        }
    }

    /// <summary><c>mpv_node</c> 递归展开成 JSON 文本，再交给 JsonDocument 解析。</summary>
    private static JsonElement NodeToJson(IntPtr nodePtr)
    {
        var sb = new StringBuilder(256);
        WriteNode(sb, nodePtr);
        return ToElement(sb.ToString());
    }

    private static void WriteNode(StringBuilder sb, IntPtr nodePtr)
    {
        if (nodePtr == IntPtr.Zero)
        {
            sb.Append("null");
            return;
        }

        var node = Marshal.PtrToStructure<MpvNode>(nodePtr);

        switch (node.Format)
        {
            case LibMpv.MpvFormatNone:
                sb.Append("null");
                break;

            case LibMpv.MpvFormatString:
            case LibMpv.MpvFormatOsdString:
                var str = node.Data == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(node.Data);
                sb.Append(str is null ? "null" : JsonSerializer.Serialize(str));
                break;

            case LibMpv.MpvFormatFlag:
                // union 里 flag 是内联的 int，不是指针。
                sb.Append((int)(long)node.Data != 0 ? "true" : "false");
                break;

            case LibMpv.MpvFormatInt64:
                // 同理：int64 内联在 union 里，值就是这 8 个字节本身。
                sb.Append(((long)node.Data).ToString(CultureInfo.InvariantCulture));
                break;

            case LibMpv.MpvFormatDouble:
                sb.Append(BitConverter.Int64BitsToDouble((long)node.Data)
                    .ToString("R", CultureInfo.InvariantCulture));
                break;

            case LibMpv.MpvFormatNodeArray:
                WriteArray(sb, node);
                break;

            case LibMpv.MpvFormatNodeMap:
                WriteMap(sb, node);
                break;

            case LibMpv.MpvFormatByteArray:
                // byte_array：data 指向 mpv_byte_array{data,size}，播放层用不到，
                // 当 null 处理比编造一个字符串安全。
                sb.Append("null");
                break;

            default:
                sb.Append("null");
                break;
        }
    }

    private static void WriteArray(StringBuilder sb, in MpvNode node)
    {
        // node.data 指向 mpv_node_list{num, values, keys}
        if (node.Data == IntPtr.Zero)
        {
            sb.Append("[]");
            return;
        }

        var list = Marshal.PtrToStructure<MpvNodeList>(node.Data);
        sb.Append('[');
        for (var i = 0; i < list.Num; i++)
        {
            if (i > 0)
            {
                sb.Append(',');
            }

            var item = IntPtr.Add(list.Values, i * Marshal.SizeOf<MpvNode>());
            WriteNode(sb, item);
        }
        sb.Append(']');
    }

    private static void WriteMap(StringBuilder sb, in MpvNode node)
    {
        if (node.Data == IntPtr.Zero)
        {
            sb.Append("{}");
            return;
        }

        var list = Marshal.PtrToStructure<MpvNodeList>(node.Data);
        sb.Append('{');
        for (var i = 0; i < list.Num; i++)
        {
            if (i > 0)
            {
                sb.Append(',');
            }

            // keys 是 char** 数组
            var keyPtr = Marshal.ReadIntPtr(list.Keys, i * IntPtr.Size);
            var key = keyPtr == IntPtr.Zero ? "" : Marshal.PtrToStringUTF8(keyPtr) ?? "";
            sb.Append(JsonSerializer.Serialize(key));
            sb.Append(':');

            var item = IntPtr.Add(list.Values, i * Marshal.SizeOf<MpvNode>());
            WriteNode(sb, item);
        }
        sb.Append('}');
    }

    /// <summary>
    /// <c>mpv_node</c>：**union 在前、format 在后**（见 client.h:764）。
    /// 顺序写反会让所有属性解析全盘错位——union 最大 8 字节，
    /// format 是 int，两者对调后 format 会读到 union 的高 4 字节。
    /// <code>
    /// typedef struct mpv_node {
    ///     union { char *string; int flag; int64_t int64; double double_;
    ///             struct mpv_node_list *list; struct mpv_byte_array *ba; } u;
    ///     mpv_format format;
    /// } mpv_node;
    /// </code>
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct MpvNode
    {
        /// <summary>union 里最大的成员是 8 字节指针 / int64 / double，用 IntPtr 承载。</summary>
        public IntPtr Data;

        public int Format;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MpvNodeList
    {
        public int Num;
        public IntPtr Values;
        public IntPtr Keys;
    }

    private static JsonElement ToElement(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
    }

    private static string FormatArg(object? arg)
    {
        switch (arg)
        {
            case null:
                return "no";
            case bool b:
                return b ? "yes" : "no";
            case double d:
                return d.ToString("R", CultureInfo.InvariantCulture);
            case float f:
                return f.ToString("R", CultureInfo.InvariantCulture);
            case string s:
                return s;
            default:
                return Convert.ToString(arg, CultureInfo.InvariantCulture) ?? "";
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        try
        {
            _cts?.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }

        // 等事件泵真的退出。它正在 mpv_wait_event 里，句柄这时还活着；
        // 如果直接 terminate_destroy，泵线程会访问已释放的内存。
        // 100ms 超时 + 取消，正常情况下 1-2 轮就退出了。
        var reader = _reader;
        if (reader is not null && reader.IsAlive)
        {
            reader.Join(TimeSpan.FromSeconds(2));
        }

        IntPtr ctx;
        lock (_lock)
        {
            ctx = _ctx;
            _ctx = IntPtr.Zero;
        }

        if (ctx != IntPtr.Zero)
        {
            // terminate_destroy 会先让 mpv 正常收尾（关 VO、落进度），再释放。
            try
            {
                LibMpv.mpv_terminate_destroy(ctx);
            }
            catch (Exception ex)
            {
                Debug.WriteLine("[libmpv] terminate 失败: " + ex.Message);
            }
        }

        _cts?.Dispose();
        _cts = null;
    }
}
