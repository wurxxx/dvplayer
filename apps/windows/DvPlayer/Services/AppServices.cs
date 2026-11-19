namespace DvPlayer.Services;

/// <summary>进程级服务容器。正式项目会用依赖注入，这里先保持简单。</summary>
public sealed class AppServices
{
    public static AppServices Instance { get; } = new();

    private AppServices()
    {
        Settings = AppSettings.Load();
    }

    public AppSettings Settings { get; }

    public MediaCore? Core { get; private set; }

    public SourceConfig? CurrentSource { get; private set; }

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

    /// <summary>连接（或切换）一个媒体源。失败时把旧连接保留为 null。</summary>
    public async Task<(bool Ok, string? Error)> ConnectAsync(SourceConfig config)
    {
        Core?.Dispose();
        Core = null;
        CurrentSource = null;

        MediaCore? core;
        try
        {
            core = MediaCore.Create(config);
        }
        catch (MediaCoreMissingException ex)
        {
            return (false, ex.Message);
        }

        if (core is null)
        {
            return (false, "无法加载共享核心 dvplayer_media（检查 DLL 是否在输出目录）");
        }

        ApiResult<string> result;
        try
        {
            result = await Task.Run(core.Connect).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            core.Dispose();
            return (false, "调用共享核心失败：" + ex.Message);
        }
        if (!result.Ok)
        {
            core.Dispose();
            return (false, result.Error ?? "连接失败");
        }

        Core = core;
        CurrentSource = config;
        Settings.LastSourceId = config.Id;
        Settings.Save();

        ConnectionChanged?.Invoke(this, EventArgs.Empty);
        return (true, null);
    }

    /// <summary>按配置里的 LastSourceId 自动连一次。</summary>
    public async Task<(bool Ok, string? Error)> ConnectLastAsync()
    {
        if (IsConnected)
        {
            return (true, null);
        }

        var source = Settings.Sources.FirstOrDefault(s => s.Id == Settings.LastSourceId)
                     ?? Settings.Sources.FirstOrDefault();

        return source is null ? (false, "还没有配置媒体源") : await ConnectAsync(source).ConfigureAwait(false);
    }
}
