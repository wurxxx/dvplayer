using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

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

    private IntPtr _handle;

    private MediaCore(IntPtr handle) => _handle = handle;

    public bool IsValid => _handle != IntPtr.Zero;

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
            return handle == IntPtr.Zero ? null : new MediaCore(handle);
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
    public ApiResult<List<MediaItemDto>> Search(string query)
    {
        var ptr = dv_hub_search(_handle, query);
        return Read(ptr, root => root.Deserialize<List<MediaItemDto>>(Json) ?? new());
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

    public void Dispose()
    {
        if (_handle != IntPtr.Zero)
        {
            dv_hub_free(_handle);
            _handle = IntPtr.Zero;
        }
    }

    // —— P/Invoke ——

    [DllImport(Lib, EntryPoint = "dv_hub_new", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_new();

    [DllImport(Lib, EntryPoint = "dv_hub_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void dv_hub_free(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_hub_add", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_add(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configJson);

    [DllImport(Lib, EntryPoint = "dv_hub_sources", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_sources(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_source_kinds", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_source_kinds();

    [DllImport(Lib, EntryPoint = "dv_string_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void dv_string_free(IntPtr text);

    [DllImport(Lib, EntryPoint = "dv_hub_libraries", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_libraries(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_hub_items", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_items(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string libraryId,
        int page,
        int pageSize,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query);

    [DllImport(Lib, EntryPoint = "dv_hub_children", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_children(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string parentId,
        int page,
        int pageSize,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query);

    [DllImport(Lib, EntryPoint = "dv_hub_genres", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_genres(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string scopeId);

    [DllImport(Lib, EntryPoint = "dv_hub_records", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_records(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_hub_favorites", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_favorites(
        IntPtr handle,
        int page,
        int pageSize);

    [DllImport(Lib, EntryPoint = "dv_hub_report_progress", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_report_progress(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        long position,
        long duration);

    [DllImport(Lib, EntryPoint = "dv_hub_set_favorite", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_set_favorite(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        int favorite);

    [DllImport(Lib, EntryPoint = "dv_hub_set_watched", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_set_watched(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        int watched);

    [DllImport(Lib, EntryPoint = "dv_hub_remove_record", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_remove_record(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_version", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_version();

    [DllImport(Lib, EntryPoint = "dv_hub_search", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_search(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string query);

    [DllImport(Lib, EntryPoint = "dv_hub_detail", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_detail(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_hub_play_source", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_play_source(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId);

    [DllImport(Lib, EntryPoint = "dv_hub_image_source", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_hub_image_source(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string posterPath);
}

public sealed record SourceConfig(
    string Id,
    string Name,
    string Kind,
    string Base,
    string Username,
    string Password);

public sealed record SourceInfoDto(string Id, string Name, string Kind);

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
    string? SingleChildId);

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
    string? SingleChildId);

public sealed record PlayRecordDto(
    string ItemId,
    string Title,
    string SourceId,
    string? SeriesTitle,
    int? SeasonNumber,
    int? EpisodeNumber,
    string? PosterPath,
    long PositionSeconds,
    long DurationSeconds,
    long? LastPlayed);

public sealed record HttpHeaderDto(string Name, string Value);

public sealed record ImageSourceDto(string Url, List<HttpHeaderDto> Headers);

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
    List<SubtitleTrackDto> SubtitleStreams);

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
