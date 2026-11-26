using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;

namespace DvPlayer.Services;

/// <summary>
/// 共享核心（Rust）的 C ABI 绑定。所有业务逻辑在 core/media 里，
/// 这里只做 JSON ↔ 强类型对象的转换。
/// </summary>
public sealed class MediaCore : IDisposable
{
    private const string Lib = "dvplayer_media";

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>
    /// Hub 句柄。用 SafeHandle 而不是裸 IntPtr：P/Invoke 期间运行时会加引用，
    /// Dispose 会等在途调用返回后才 dv_hub_free，避免「重连时释放、页面还在调」的释放后使用。
    /// 已释放后再调用会抛 ObjectDisposedException，而不是把野指针交给原生侧。
    /// </summary>
    private readonly HubHandle _handle;

    private MediaCore(HubHandle handle) => _handle = handle;

    public bool IsValid => !_handle.IsInvalid && !_handle.IsClosed;

    public static string Version()
    {
        try
        {
            // ReadEnvelope 内部已经 dv_string_free，这里不能再释放一次（会堆损坏）。
            return ReadEnvelope<string>(dv_version()) ?? "unknown";
        }
        catch (Exception ex) when (ex is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException)
        {
            return "unavailable: " + ex.Message;
        }
    }

    /// <summary>核心支持的适配器类型（"fnos" / 以后的 "emby"）。</summary>
    public static List<string> SupportedKinds()
    {
        try
        {
            return ReadEnvelope<List<string>>(dv_source_kinds()) ?? new List<string>();
        }
        catch (Exception ex) when (ex is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException)
        {
            return new List<string>();
        }
    }

    /// <summary>新建一个空聚合句柄；随后用 <see cref="Add"/> 逐个接源。</summary>
    public static MediaCore? Create()
    {
        try
        {
            var handle = dv_hub_new();
            return handle == IntPtr.Zero ? null : new MediaCore(new HubHandle(handle));
        }
        catch (Exception ex) when (ex is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException)
        {
            throw new MediaCoreMissingException(ex);
        }
    }

    /// <summary>添加并登录一个源。单个源失败不影响已连上的源。</summary>
    public ApiResult<SourceInfoDto> Add(SourceConfig config)
    {
        var json = JsonSerializer.Serialize(config, Json);
        var ptr = dv_hub_add(_handle, json);
        return Read(ptr, root => root.Deserialize<SourceInfoDto>(Json)!);
    }

    /// <summary>
    /// 并行建连多个源：核心给每个源开一个线程去登录，全部完成后按入参顺序返回。
    /// 单次调用顶掉以前的逐个 Add，3 个服务器不用再等 3 份时间。
    /// </summary>
    public ApiResult<List<SourceConnectDto>> AddMany(IReadOnlyList<SourceConfig> configs)
    {
        var json = JsonSerializer.Serialize(configs, Json);
        var ptr = dv_hub_add_many(_handle, json);
        return Read(ptr, root => root.Deserialize<List<SourceConnectDto>>(Json) ?? new());
    }

    /// <summary>
    /// 并行建连多个源，`onEach` 在每个源刚连完时立即回调（哪个先完成哪个先到，
    /// 回调来自建连线程）。返回值仍是全部完成后的完整结果。
    /// </summary>
    public ApiResult<List<SourceConnectDto>> AddManyStream(
        IReadOnlyList<SourceConfig> configs, Action<SourceConnectDto> onEach)
    {
        var json = JsonSerializer.Serialize(configs, Json);
        void OnConnect(IntPtr ptr, IntPtr userData)
        {
            if (ptr == IntPtr.Zero)
            {
                return;
            }

            var text = Marshal.PtrToStringUTF8(ptr);
            if (string.IsNullOrEmpty(text))
            {
                return;
            }

            try
            {
                var dto = JsonSerializer.Deserialize<SourceConnectDto>(text, Json);
                if (dto is not null)
                {
                    onEach(dto);
                }
            }
            catch (JsonException)
            {
                // 单个源的回报格式不对不该拖垮其它源。
            }
        }

        ConnectCallback callback = OnConnect;
        var pinned = GCHandle.Alloc(callback);
        try
        {
            var ptr = dv_hub_add_many_stream(
                _handle, json, callback, GCHandle.ToIntPtr(pinned));
            return Read(ptr, root => root.Deserialize<List<SourceConnectDto>>(Json) ?? new());
        }
        finally
        {
            pinned.Free();
        }
    }

    /// <summary>已连上的源（设置页显示状态用）。</summary>
    public ApiResult<List<SourceInfoDto>> Sources()
    {
        var ptr = dv_hub_sources(_handle);
        return Read(ptr, root => root.Deserialize<List<SourceInfoDto>>(Json) ?? new());
    }

    public ApiResult<List<MediaLibraryDto>> Libraries()
    {
        var ptr = dv_hub_libraries(_handle);
        return Read(ptr, root => root.Deserialize<List<MediaLibraryDto>>(Json) ?? new());
    }

    public ApiResult<PagedDto<MediaItemDto>> Items(
        string libraryId, int page, int pageSize, ListQuery? query = null)
    {
        var ptr = dv_hub_items(_handle, libraryId, page, pageSize, QueryJson(query));
        return Read(ptr, root => root.Deserialize<PagedDto<MediaItemDto>>(Json)!);
    }

    public ApiResult<PagedDto<MediaItemDto>> Children(
        string parentId, int page, int pageSize, ListQuery? query = null)
    {
        var ptr = dv_hub_children(_handle, parentId, page, pageSize, QueryJson(query));
        return Read(ptr, root => root.Deserialize<PagedDto<MediaItemDto>>(Json)!);
    }

    /// <summary>这个库里可用的风格（飞牛是 TMDB genre，Emby 是 Genres 名）。</summary>
    public ApiResult<List<GenreDto>> Genres(string scopeId)
    {
        var ptr = dv_hub_genres(_handle, scopeId);
        return Read(ptr, root => root.Deserialize<List<GenreDto>>(Json) ?? new());
    }

    private static string QueryJson(ListQuery? query) =>
        query is null ? "" : JsonSerializer.Serialize(query, Json);

    /// <summary>跨源关键词搜索。返回平铺的条目，集/文件由界面按父级归并。</summary>
    public ApiResult<SearchResultDto> Search(string query)
    {
        var ptr = dv_hub_search(_handle, query);
        return Read(ptr, root => root.Deserialize<SearchResultDto>(Json)
                               ?? new SearchResultDto(new List<MediaItemDto>()));
    }

    public ApiResult<List<PlayRecordDto>> Records()
    {
        var ptr = dv_hub_records(_handle);
        return Read(ptr, root => root.Deserialize<List<PlayRecordDto>>(Json) ?? new());
    }

    /// <summary>跨源收藏列表。</summary>
    public ApiResult<PagedDto<MediaItemDto>> Favorites(int page, int pageSize)
    {
        var ptr = dv_hub_favorites(_handle, page, pageSize);
        return Read(ptr, root => root.Deserialize<PagedDto<MediaItemDto>>(Json)!);
    }

    public ApiResult<bool> ReportProgress(string itemId, long position, long duration)
    {
        var ptr = dv_hub_report_progress(_handle, itemId, position, duration);
        return ReadOk(ptr);
    }

    /// <summary>播放结束 / 关窗：Emby 要这个 Stopped 才会把位置写进 UserData。</summary>
    public ApiResult<bool> ReportStopped(string itemId, long position, long duration)
    {
        var ptr = dv_hub_report_stopped(_handle, itemId, position, duration);
        return ReadOk(ptr);
    }

    /// <summary>
    /// 判定 Dolby Vision P7 是 FEL 还是 MEL：只读码流前缀（8 MB），
    /// 扫 RPU 的 <c>disable_residual_flag</c>。不需要 hub 句柄。
    /// </summary>
    public ApiResult<DoviProbeDto> ProbeDovi(
        string url, IReadOnlyList<HttpHeaderDto>? headers, string? proxy)
    {
        var headersJson = JsonSerializer.Serialize(
            (headers ?? Array.Empty<HttpHeaderDto>())
                .Select(header => new { name = header.Name, value = header.Value }),
            Json);
        var ptr = dv_probe_dovi(url, headersJson, proxy ?? "");
        return Read(ptr, root => root.Deserialize<DoviProbeDto>(Json)!);
    }

    /// <summary>收藏 / 取消收藏。</summary>
    public ApiResult<bool> SetFavorite(string itemId, bool favorite)
    {
        var ptr = dv_hub_set_favorite(_handle, itemId, favorite ? 1 : 0);
        return ReadOk(ptr);
    }

    /// <summary>标记已观看 / 未观看。</summary>
    public ApiResult<bool> SetWatched(string itemId, bool watched)
    {
        var ptr = dv_hub_set_watched(_handle, itemId, watched ? 1 : 0);
        return ReadOk(ptr);
    }

    /// <summary>移除观看记录（从「继续观看」里清掉）。</summary>
    public ApiResult<bool> RemovePlayRecord(string itemId)
    {
        var ptr = dv_hub_remove_record(_handle, itemId);
        return ReadOk(ptr);
    }

    /// <summary>条目详情：背景图、简介、季集数、播放入口。</summary>
    public ApiResult<MediaDetailDto> ItemDetail(string itemId)
    {
        var ptr = dv_hub_detail(_handle, itemId);
        return Read(ptr, root => root.Deserialize<MediaDetailDto>(Json)!);
    }

    /// <summary>取播放源：直链 + 请求头 + 续播点 + 音轨字幕。</summary>
    public ApiResult<PlaySourceDto> PlaySource(string itemId)
    {
        var ptr = dv_hub_play_source(_handle, itemId);
        return Read(ptr, root => root.Deserialize<PlaySourceDto>(Json)!);
    }

    /// <summary>
    /// 详情页「资源」：同一部片在各源的条目。核心按详情标题跨源找回，
    /// 去重规则和搜索一样；第一项是最佳来源。
    /// </summary>
    public ApiResult<List<ItemSourceDto>> ItemSources(string itemId)
    {
        var ptr = dv_hub_item_sources(_handle, itemId);
        return Read(ptr, root => root.Deserialize<List<ItemSourceDto>>(Json) ?? new());
    }

    /// <summary>详情页「媒体信息」：编码、分辨率、比特率、音轨明细。</summary>
    public ApiResult<MediaInfoDto> MediaInfo(string itemId)
    {
        var ptr = dv_hub_media_info(_handle, itemId);
        return Read(ptr, root => root.Deserialize<MediaInfoDto>(Json)!);
    }

    /// <summary>某个演职人员参与过的作品。</summary>
    public ApiResult<List<MediaItemDto>> PersonWorks(string personId)
    {
        var ptr = dv_hub_person_works(_handle, personId);
        return Read(ptr, root => root.Deserialize<List<MediaItemDto>>(Json) ?? new());
    }

    /// <summary>演职人员（演员 / 导演 / 编剧）。</summary>
    public ApiResult<List<PersonDto>> People(string itemId)
    {
        var ptr = dv_hub_people(_handle, itemId);
        return Read(ptr, root => root.Deserialize<List<PersonDto>>(Json) ?? new());
    }

    /// <summary>海报地址与鉴权头（图片不能直接给 Image，要自己下载）。</summary>
    public ApiResult<ImageSourceDto> ImageSource(string posterPath)
    {
        var ptr = dv_hub_image_source(_handle, posterPath);
        return Read(ptr, root => root.Deserialize<ImageSourceDto>(Json)!);
    }

    /// <summary>只关心 ok/error 的调用（成功时没有 data）。</summary>
    private static ApiResult<bool> ReadOk(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero)
        {
            return ApiResult<bool>.Fail("native call returned null");
        }

        try
        {
            var text = Marshal.PtrToStringUTF8(ptr);
            if (string.IsNullOrEmpty(text))
            {
                return ApiResult<bool>.Fail("empty native response");
            }

            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            var ok = root.TryGetProperty("ok", out var okProp) && okProp.ValueKind == JsonValueKind.True;
            if (ok)
            {
                return ApiResult<bool>.Success(true);
            }

            var error = root.TryGetProperty("error", out var e) ? e.GetString() : "unknown error";
            return ApiResult<bool>.Fail(error ?? "unknown error");
        }
        catch (JsonException ex)
        {
            return ApiResult<bool>.Fail("bad json: " + ex.Message);
        }
        finally
        {
            dv_string_free(ptr);
        }
    }

    /// <summary>统一的 JSON 解析：{ok, data, error, code}。</summary>
    private static ApiResult<T> Read<T>(IntPtr ptr, Func<JsonElement, T> map)
    {
        if (ptr == IntPtr.Zero)
        {
            return ApiResult<T>.Fail("native call returned null");
        }

        try
        {
            var text = Marshal.PtrToStringUTF8(ptr);
            if (string.IsNullOrEmpty(text))
            {
                return ApiResult<T>.Fail("empty native response");
            }

            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;

            var ok = root.TryGetProperty("ok", out var okProp) && okProp.ValueKind == JsonValueKind.True;
            if (!ok)
            {
                var error = root.TryGetProperty("error", out var e) ? e.GetString() : "unknown error";
                return ApiResult<T>.Fail(error ?? "unknown error");
            }

            if (!root.TryGetProperty("data", out var data) || data.ValueKind == JsonValueKind.Null)
            {
                return ApiResult<T>.Fail("missing data");
            }

            return ApiResult<T>.Success(map(data));
        }
        catch (JsonException ex)
        {
            return ApiResult<T>.Fail("bad json: " + ex.Message);
        }
        finally
        {
            dv_string_free(ptr);
        }
    }

    private static T? ReadEnvelope<T>(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero)
        {
            return default;
        }

        try
        {
            var text = Marshal.PtrToStringUTF8(ptr);
            using var doc = JsonDocument.Parse(text ?? "{}");
            if (doc.RootElement.TryGetProperty("data", out var data))
            {
                return data.Deserialize<T>(Json);
            }
            return default;
        }
        catch (JsonException)
        {
            return default;
        }
        finally
        {
            dv_string_free(ptr);
        }
    }

    public void Dispose() => _handle.Dispose();

    /// <summary>
    /// dv_hub_free 只在没有在途 P/Invoke 时执行（SafeHandle 的引用计数负责）。
    /// 重复 Dispose 是安全的。
    /// </summary>
    private sealed class HubHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public HubHandle(IntPtr handle) : base(ownsHandle: true) => SetHandle(handle);

        protected override bool ReleaseHandle()
        {
            dv_hub_free(handle);
            return true;
        }
    }

    // —— P/Invoke ——

    [DllImport(Lib, EntryPoint = "dv_hub_new", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_new();

    [DllImport(Lib, EntryPoint = "dv_hub_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void dv_hub_free(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_hub_add", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_add(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configJson);

    [DllImport(Lib, EntryPoint = "dv_hub_add_many", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_add_many(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configsJson);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ConnectCallback(IntPtr json, IntPtr userData);

    [DllImport(Lib, EntryPoint = "dv_hub_add_many_stream", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_add_many_stream(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configsJson,
        ConnectCallback callback,
        IntPtr userData);

    [DllImport(Lib, EntryPoint = "dv_hub_sources", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_sources(HubHandle handle);

    [DllImport(Lib, EntryPoint = "dv_source_kinds", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_source_kinds();

    [DllImport(Lib, EntryPoint = "dv_string_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void dv_string_free(IntPtr text);

    [DllImport(Lib, EntryPoint = "dv_hub_libraries", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_libraries(HubHandle handle);

    [DllImport(Lib, EntryPoint = "dv_hub_items", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_items(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string libraryId,
        int page,
        int pageSize,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query);

    [DllImport(Lib, EntryPoint = "dv_hub_children", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_children(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string parentId,
        int page,
        int pageSize,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query);

    [DllImport(Lib, EntryPoint = "dv_hub_genres", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_genres(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string scopeId);

    [DllImport(Lib, EntryPoint = "dv_hub_records", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_records(HubHandle handle);

    [DllImport(Lib, EntryPoint = "dv_hub_favorites", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_favorites(
        HubHandle handle,
        int page,
        int pageSize);

    [DllImport(Lib, EntryPoint = "dv_probe_dovi", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_probe_dovi(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string url,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string headersJson,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string proxy);

    [DllImport(Lib, EntryPoint = "dv_hub_report_stopped", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_report_stopped(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        long position,
        long duration);

    [DllImport(Lib, EntryPoint = "dv_hub_report_progress", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_report_progress(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        long position,
        long duration);

    [DllImport(Lib, EntryPoint = "dv_hub_set_favorite", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_set_favorite(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        int favorite);

    [DllImport(Lib, EntryPoint = "dv_hub_set_watched", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_set_watched(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        int watched);

    [DllImport(Lib, EntryPoint = "dv_hub_remove_record", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_remove_record(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_version", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_version();

    [DllImport(Lib, EntryPoint = "dv_hub_search", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_search(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query);

    [DllImport(Lib, EntryPoint = "dv_hub_detail", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_detail(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_hub_person_works", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_person_works(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string personId);

    [DllImport(Lib, EntryPoint = "dv_hub_people", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_people(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_hub_item_sources", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_item_sources(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_hub_media_info", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_media_info(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_hub_play_source", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_play_source(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_hub_image_source", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_image_source(
        HubHandle handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string posterPath);
}

public sealed record SourceConfig(
    string Id,
    string Name,
    string Kind,
    string Base,
    string Username,
    string Password,
    /// <summary>本地源把进度写这里；服务器源留空。</summary>
    string DataDir = "",
    /// <summary>网络服务器的 HTTP 代理（如 http://127.0.0.1:7890）；空 = 直连。</summary>
    string Proxy = "");

public sealed record SourceInfoDto(string Id, string Name, string Kind);

/// <summary>并行建连的单个结果：连没连上、耗时多久、网络往返延迟多少毫秒。</summary>
public sealed record SourceConnectDto(
    string Id,
    string Name,
    string Kind,
    bool Ok,
    string? Error,
    long Ms,
    long? LatencyMs);

public sealed record MediaLibraryDto(
    string Id,
    string Title,
    string SourceId,
    string? PosterPath,
    string Category);

public sealed record PagedDto<T>(List<T> Items, int Total, int Page, int PageSize);

/// <summary>列表筛选与排序。字段名与核心的 ListQuery 对齐（camelCase）。</summary>
public sealed record ListQuery
{
    /// <summary>tv / movie / folder；空表示不按类型过滤。</summary>
    public List<string> Kinds { get; init; } = new();

    /// <summary>风格 id，来自 Genres()。</summary>
    public string? Genre { get; init; }

    /// <summary>name / added / release / rating。</summary>
    public string? Sort { get; init; }

    public bool Descending { get; init; }
}

public sealed record GenreDto(string Id, string Title);

public sealed record MediaItemDto(
    string Id,
    string Title,
    string Kind,
    string SourceId,
    string? PosterPath,
    string? ParentId,
    string? ParentTitle,
    int? Year,
    long? RuntimeSeconds,
    double Progress,
    bool IsFavorite,
    string? Overview,
    string? Resolution,
    long? LastPlayed,
    int? SeasonNumber,
    int? EpisodeNumber,
    int? EpisodeCount,
    int? LocalEpisodeCount,
    int? SeasonCount,
    double? Rating,
    string? ReleaseDate,
    string? Status,
    string? BackdropPath,
    string? SingleChildId,
    /// <summary>同一部片在各源的条目；聚合搜索填，其它地方是空数组。</summary>
    List<ItemSourceDto>? Sources = null);

/// <summary>同一部片在某个源里的条目（搜索结果的多来源）。</summary>
public sealed record ItemSourceDto(
    string ItemId,
    string SourceId,
    string SourceName,
    string? Resolution,
    double Progress);

/// <summary>搜索时没有响应的源。</summary>
public sealed record SourceFailureDto(
    string SourceId,
    string SourceName,
    string Error);

/// <summary>聚合搜索结果：去重后的条目 + 失败的源。</summary>
public sealed record SearchResultDto(
    List<MediaItemDto> Items,
    List<SourceFailureDto>? Failed = null);

public sealed record MediaDetailDto(
    string Id,
    string Title,
    string Kind,
    string? OriginalTitle,
    string? Overview,
    string? PosterPath,
    string? BackdropPath,
    string? LogoPath,
    double? Rating,
    string? ReleaseDate,
    long? RuntimeSeconds,
    int? SeasonCount,
    int? LocalSeasonCount,
    int? EpisodeCount,
    int? LocalEpisodeCount,
    string? Status,
    string? Resolution,
    string? AudioType,
    string? ColorRange,
    string? PlayItemId,
    string? SingleChildId,
    bool? IsFavorite,
    bool? IsWatched,
    /// <summary>外部库 id（Emby / Jellyfin 的 ProviderIds）：Trakt 精确匹配、详情页链接用。</summary>
    string? TmdbId,
    string? ImdbId);

public sealed record PersonDto(
    string Id,
    string Name,
    string? Role,
    string? Job,
    string? ImagePath);

public sealed record MediaInfoDto(
    VideoInfoDto? Video,
    List<AudioInfoDto> Audios,
    List<SubtitleInfoDto> Subtitles,
    string? Path);

public sealed record SubtitleInfoDto(
    string? Title,
    string? Language,
    string? Codec,
    string? Format,
    bool IsDefault,
    bool IsBitmap,
    bool IsExternal);

public sealed record VideoInfoDto(
    string? Title,
    string? Codec,
    int? Width,
    int? Height,
    double? FrameRate,
    long? BitRate,
    string? ColorRange,
    string? Profile,
    double? Level,
    string? AspectRatio,
    bool? Interlaced,
    int? BitDepth,
    string? PixelFormat,
    bool DolbyVision);

public sealed record AudioInfoDto(
    string? Title,
    string? Language,
    string? Codec,
    string? Profile,
    string? Layout,
    long? BitRate,
    int? Channels,
    int? SampleRate,
    bool IsDefault,
    bool IsExternal);

public sealed record PlayRecordDto(
    string ItemId,
    string Title,
    string SourceId,
    string? SeriesTitle,
    string? ParentId,
    int? SeasonNumber,
    int? EpisodeNumber,
    string? PosterPath,
    long PositionSeconds,
    long DurationSeconds,
    long? LastPlayed);

public sealed record HttpHeaderDto(string Name, string Value);

/// <summary>Dolby Vision P7 的增强层类型：<c>ElType</c> 是 "fel" / "mel"。</summary>
public sealed record DoviProbeDto(int Profile, string ElType, bool DisableResidual);

public sealed record ImageSourceDto(
    string Url,
    List<HttpHeaderDto> Headers,
    /// <summary>服务器设的 HTTP 代理；空 = 直连。</summary>
    string? Proxy = null);

public sealed record AudioTrackDto(
    string Guid,
    string? Language,
    string? Codec,
    string? Profile,
    int Channels,
    bool IsDefault);

public sealed record SubtitleTrackDto(
    string Guid,
    string? Language,
    string? Codec,
    string? Format,
    bool IsExternal,
    bool IsBitmap);

public sealed record PlaySourceDto(
    string ItemId,
    string Title,
    string Url,
    List<HttpHeaderDto> Headers,
    bool IsDirect,
    bool Disc,
    string MediaGuid,
    string? VideoGuid,
    string? AudioGuid,
    string? SubtitleGuid,
    long PositionSeconds,
    long DurationSeconds,
    string? Overview,
    string? PosterPath,
    string? Resolution,
    string? ColorRange,
    bool DolbyVision,
    string? VideoCodec,
    string? AudioCodec,
    List<AudioTrackDto> AudioStreams,
    List<SubtitleTrackDto> SubtitleStreams,
    /// <summary>服务器设的 HTTP 代理；空 = 直连。播放请求也走它。</summary>
    string? Proxy = null);

public readonly record struct ApiResult<T>(bool Ok, T? Data, string? Error)
{
    public static ApiResult<T> Success(T data) => new(true, data, null);

    public static ApiResult<T> Fail(string error) => new(false, default, error);

    public T Value => Ok && Data is not null ? Data : throw new InvalidOperationException(Error);
}

/// <summary>dvplayer_media 动态库缺失或位数不对。</summary>
public sealed class MediaCoreMissingException : Exception
{
    public MediaCoreMissingException(Exception inner)
        : base($"无法加载共享核心 dvplayer_media.dll（应与 DvPlayer.exe 同目录）：{inner.Message}", inner)
    {
    }
}
