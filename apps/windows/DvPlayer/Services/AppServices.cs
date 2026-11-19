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

    public bool IsConnected => Core is { IsValid: true };

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
