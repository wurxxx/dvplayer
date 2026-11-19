namespace DvPlayer.Services;

/// <summary>一个源的连接结果，设置页与顶栏用它显示状态。</summary>
public sealed record SourceConnection(string Id, string Name, string Kind, bool Ok, string? Error);

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

        var results = new List<SourceConnection>();
        foreach (var config in configs)
        {
            ApiResult<SourceInfoDto> added;
            try
            {
                added = await Task.Run(() => core.Add(config)).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                added = ApiResult<SourceInfoDto>.Fail("调用共享核心失败：" + ex.Message);
            }

            results.Add(new SourceConnection(
                config.Id,
                config.Name,
                config.Kind,
                added.Ok,
                added.Ok ? null : added.Error ?? "连接失败"));
        }

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
