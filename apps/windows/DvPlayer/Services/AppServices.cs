namespace DvPlayer.Services;

/// <summary>一个源的连接结果，设置页与顶栏用它显示状态。</summary>
/// <param name="LatencyMs">网络往返延迟（毫秒）；本地源或探测失败为 null。</param>
/// <param name="ConnectedAt">这次连上的时刻，卡片上显示 HH:mm。</param>
public sealed record SourceConnection(
    string Id,
    string Name,
    string Kind,
    bool Ok,
    string? Error,
    long? LatencyMs = null,
    DateTime? ConnectedAt = null);

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

        // 文件协议源（SMB / NFS / WebDAV）先让系统挂载，再当本地目录接核心。
        // 挂载也是网络等待，同样每个源一个 Task 并行做。
        var prepared = await Task.WhenAll(configs.Select(async config =>
        {
            try
            {
                return (Config: config,
                        Effective: await Task.Run(() => NetMount.Prepare(config)).ConfigureAwait(false),
                        Error: (string?)null);
            }
            catch (Exception ex)
            {
                return (Config: config, Effective: config, Error: ex.Message);
            }
        })).ConfigureAwait(false);

        // 挂好的一次性交给核心：核心内部每个源一个线程建连，3 个服务器并行登录。
        var toConnect = prepared.Where(p => p.Error is null).Select(p => p.Effective).ToList();
        ApiResult<List<SourceConnectDto>> batch;
        var watch = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            batch = toConnect.Count == 0
                ? ApiResult<List<SourceConnectDto>>.Success(new List<SourceConnectDto>())
                : await Task.Run(() => core.AddMany(toConnect)).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            batch = ApiResult<List<SourceConnectDto>>.Fail("调用共享核心失败：" + ex.Message);
        }
        watch.Stop();

        // 并行连接的总耗时应接近最慢的那个源，而不是各源相加；日志留着对比。
        Trace.Write(batch.Ok
            ? $"connect {toConnect.Count} source(s) in {watch.ElapsedMilliseconds} ms: " +
              string.Join("; ", batch.Data!.Select(c =>
                  $"{c.Name} ok={c.Ok} ms={c.Ms} latency={c.LatencyMs?.ToString() ?? "-"}"))
            : "connect failed: " + batch.Error);

        var byId = batch.Ok && batch.Data is not null
            ? batch.Data.ToDictionary(c => c.Id)
            : new Dictionary<string, SourceConnectDto>();

        var connectedAt = DateTime.Now;
        var results = prepared.Select(p =>
        {
            if (p.Error is not null)
            {
                return new SourceConnection(p.Config.Id, p.Config.Name, p.Config.Kind, false, p.Error);
            }

            if (!batch.Ok)
            {
                return new SourceConnection(
                    p.Config.Id, p.Config.Name, p.Config.Kind, false, batch.Error ?? "连接失败");
            }

            return byId.TryGetValue(p.Config.Id, out var connect)
                ? new SourceConnection(
                    p.Config.Id,
                    p.Config.Name,
                    p.Config.Kind,
                    connect.Ok,
                    connect.Ok ? null : connect.Error ?? "连接失败",
                    connect.LatencyMs,
                    connect.Ok ? connectedAt : null)
                : new SourceConnection(
                    p.Config.Id, p.Config.Name, p.Config.Kind, false, "核心未返回该源的连接结果");
        }).ToList();

        Connections = results;

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
