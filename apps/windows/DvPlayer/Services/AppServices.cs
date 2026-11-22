namespace DvPlayer.Services;

/// <summary>一个源的连接结果，设置页与顶栏用它显示状态。</summary>
/// <param name="LatencyMs">网络往返延迟（毫秒）；本地源或探测失败为 null。</param>
/// <param name="ConnectedAt">这次连上的时刻，卡片上显示 HH:mm。</param>
/// <param name="Connecting">这个源还在建连，卡片显示「正在连接…」。</param>
public sealed record SourceConnection(
    string Id,
    string Name,
    string Kind,
    bool Ok,
    string? Error,
    long? LatencyMs = null,
    DateTime? ConnectedAt = null,
    bool Connecting = false);

/// <summary>进程级服务容器。正式项目会用依赖注入，这里先保持简单。</summary>
public sealed class AppServices
{
    public static AppServices Instance { get; } = new();

    private AppServices()
    {
        Settings = AppSettings.Load();
    }

    public AppSettings Settings { get; }

    /// <summary>聚合句柄：内部持有所有已连上的源。</summary>
    public MediaCore? Core { get; private set; }

    /// <summary>每个配置源的连接结果（失败的也留着，好让设置页说明原因）。</summary>
    public IReadOnlyList<SourceConnection> Connections { get; private set; } = Array.Empty<SourceConnection>();

    /// <summary>顶栏那一行：一个源显示名字，多个源显示数量。</summary>
    public string SourceSummary => Connections.Count(c => c.Ok) switch
    {
        0 => "未连接",
        1 => Connections.First(c => c.Ok).Name,
        var n => $"{n} 个源",
    };

    /// <summary>共享核心版本号；DLL 缺失时返回 null。</summary>
    public string? CoreVersion
    {
        get
        {
            try
            {
                return MediaCore.Version();
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    public bool IsConnected => Core is { IsValid: true };

    /// <summary>
    /// 连接状态变化。冷启动时页面先加载、登录后完成，页面靠这个事件重新拉数据，
    /// 否则首页会一直停在「未连接媒体源」。
    /// </summary>
    public event EventHandler? ConnectionChanged;

    /// <summary>
    /// 把所有配置好的源接进聚合句柄。单个源失败不影响其它源：
    /// 只要有一个连上就算成功，失败的会在设置页标出来。
    /// </summary>
    public async Task<(bool Ok, string? Error)> ConnectAllAsync()
    {
        Core?.Dispose();
        Core = null;

        var configs = Settings.Sources.ToList();
        if (configs.Count == 0)
        {
            Connections = Array.Empty<SourceConnection>();
            return (false, "还没有配置媒体源");
        }

        MediaCore? core;
        try
        {
            core = MediaCore.Create();
        }
        catch (MediaCoreMissingException ex)
        {
            return (false, ex.Message);
        }

        if (core is null)
        {
            return (false, "无法加载共享核心 dvplayer_media（检查 DLL 是否在输出目录）");
        }

        // 每个源先以「正在连接」出现在列表里，之后谁先连完谁先变状态，
        // 不用等最慢的那个（以前是全部完成才一次性写结果）。
        var gate = new object();
        var results = configs
            .Select(c => new SourceConnection(c.Id, c.Name, c.Kind, false, null, Connecting: true))
            .ToList();
        var indexById = configs
            .Select((c, i) => (c.Id, i))
            .ToDictionary(x => x.Id, x => x.i);

        void Publish()
        {
            ConnectionChanged?.Invoke(this, EventArgs.Empty);
        }

        void Update(SourceConnection connection)
        {
            lock (gate)
            {
                results[indexById[connection.Id]] = connection;
                Connections = results.ToArray();
            }

            // 逐源记录：日志里应该看到快源先 ok、慢源后 ok，而不是最后一起出现。
            Trace.Write("source " + connection.Name + " -> " +
                        (connection.Connecting ? "connecting"
                            : connection.Ok ? "ok" : "fail: " + connection.Error));
            Publish();
        }

        Connections = results.ToArray();

        // 先让侧栏 / 服务器页把所有源标成「正在连接」（灰点），
        // 之后谁先连完谁先变绿，不用一开始全显示成失败的红点。
        Publish();

        // 文件协议源（SMB / NFS / WebDAV）先让系统挂载，再当本地目录接核心。
        // 挂载也是网络等待，同样每个源一个 Task 并行做，失败的这个源立刻标出来。
        var effective = new SourceConfig?[configs.Count];
        var mountErrors = new string?[configs.Count];
        await Task.WhenAll(configs.Select(async (config, i) =>
        {
            try
            {
                effective[i] = await Task.Run(() => NetMount.Prepare(config)).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                mountErrors[i] = ex.Message;
                Update(new SourceConnection(config.Id, config.Name, config.Kind, false, ex.Message));
            }
        })).ConfigureAwait(false);

        // 挂好的一次性交给核心：核心内部每个源一个线程建连，谁先连完谁先回调。
        var toConnect = configs
            .Where((_, i) => mountErrors[i] is null && effective[i] is not null)
            .Select((_, i) => effective[i]!)
            .ToList();
        ApiResult<List<SourceConnectDto>> batch;
        var watch = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            batch = toConnect.Count == 0
                ? ApiResult<List<SourceConnectDto>>.Success(new List<SourceConnectDto>())
                : await Task.Run(() => core.AddManyStream(toConnect, dto =>
                {
                    Update(new SourceConnection(
                        dto.Id,
                        dto.Name,
                        dto.Kind,
                        dto.Ok,
                        dto.Ok ? null : dto.Error ?? "连接失败",
                        dto.LatencyMs,
                        dto.Ok ? DateTime.Now : null));
                })).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            batch = ApiResult<List<SourceConnectDto>>.Fail("调用共享核心失败：" + ex.Message);
        }
        watch.Stop();

        // 核心整体失败时，还没拿到单独结果的源统一标失败。
        if (!batch.Ok)
        {
            foreach (var config in toConnect)
            {
                Update(new SourceConnection(
                    config.Id, config.Name, config.Kind, false, batch.Error ?? "连接失败"));
            }
        }

        // 并行连接的总耗时应接近最慢的那个源，而不是各源相加；日志留着对比。
        Trace.Write(batch.Ok
            ? $"connect {toConnect.Count} source(s) in {watch.ElapsedMilliseconds} ms: " +
              string.Join("; ", batch.Data!.Select(c =>
                  $"{c.Name} ok={c.Ok} ms={c.Ms} latency={c.LatencyMs?.ToString() ?? "-"}"))
            : "connect failed: " + batch.Error);

        List<SourceConnection> snapshot;
        lock (gate)
        {
            snapshot = results.ToList();
        }

        // 还有源停在「正在连接」说明核心没回报（异常路径），按失败处理。
        for (var i = 0; i < snapshot.Count; i++)
        {
            if (snapshot[i].Connecting)
            {
                var config = configs[i];
                snapshot[i] = new SourceConnection(
                    config.Id, config.Name, config.Kind, false, "核心未返回该源的连接结果");
            }
        }

        results = snapshot;
        Connections = snapshot;

        if (!results.Any(r => r.Ok))
        {
            core.Dispose();
            var errors = results.Select(r => $"{r.Name}：{r.Error}");
            return (false, string.Join("；", errors));
        }

        Core = core;
        Settings.Save();

        ConnectionChanged?.Invoke(this, EventArgs.Empty);

        var failed = results.Where(r => !r.Ok).ToList();
        return (true, failed.Count == 0
            ? null
            : "部分源不可用：" + string.Join("；", failed.Select(r => $"{r.Name}：{r.Error}")));
    }

    /// <summary>启动时自动连一次。</summary>
    public Task<(bool Ok, string? Error)> ConnectSavedAsync()
    {
        if (IsConnected)
        {
            return Task.FromResult((true, (string?)null));
        }

        return ConnectAllAsync();
    }

    /// <summary>断开所有源（删除最后一个源时用）。</summary>
    public void Disconnect()
    {
        Core?.Dispose();
        Core = null;
        Connections = Array.Empty<SourceConnection>();
        ConnectionChanged?.Invoke(this, EventArgs.Empty);
    }
}
