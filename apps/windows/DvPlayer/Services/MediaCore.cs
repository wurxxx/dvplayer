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
            var ptr = dv_version();
            try
            {
                return ReadEnvelope<string>(ptr) ?? "unknown";
            }
            finally
            {
                dv_string_free(ptr);
            }
        }
        catch (Exception ex) when (ex is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException)
        {
            return "unavailable: " + ex.Message;
        }
    }

    public static MediaCore? Create(SourceConfig config)
    {
        var json = JsonSerializer.Serialize(config, Json);
        try
        {
            var handle = dv_source_create(json);
            return handle == IntPtr.Zero ? null : new MediaCore(handle);
        }
        catch (Exception ex) when (ex is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException)
        {
            throw new MediaCoreMissingException(ex);
        }
    }

    public ApiResult<string> Connect()
    {
        var ptr = dv_connect(_handle);
        return Read(ptr, root => root.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "");
    }

    public ApiResult<List<MediaLibraryDto>> Libraries()
    {
        var ptr = dv_libraries(_handle);
        return Read(ptr, root => root.Deserialize<List<MediaLibraryDto>>(Json) ?? new());
    }

    public ApiResult<PagedDto<MediaItemDto>> Items(string libraryId, int page, int pageSize)
    {
        var ptr = dv_items(_handle, libraryId, page, pageSize);
        return Read(ptr, root => root.Deserialize<PagedDto<MediaItemDto>>(Json)!);
    }

    public ApiResult<PagedDto<MediaItemDto>> Children(string parentId, int page, int pageSize)
    {
        var ptr = dv_children(_handle, parentId, page, pageSize);
        return Read(ptr, root => root.Deserialize<PagedDto<MediaItemDto>>(Json)!);
    }

    public ApiResult<List<PlayRecordDto>> Records()
    {
        var ptr = dv_records(_handle);
        return Read(ptr, root => root.Deserialize<List<PlayRecordDto>>(Json) ?? new());
    }

    public ApiResult<bool> ReportProgress(string itemId, long position, long duration)
    {
        var ptr = dv_report_progress(_handle, itemId, position, duration);
        return ReadOk(ptr);
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
            dv_source_free(_handle);
            _handle = IntPtr.Zero;
        }
    }

    // —— P/Invoke ——

    [DllImport(Lib, EntryPoint = "dv_source_create", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_source_create([MarshalAs(UnmanagedType.LPUTF8Str)] string configJson);

    [DllImport(Lib, EntryPoint = "dv_source_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void dv_source_free(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_string_free", CallingConvention = CallingConvention.Cdecl)]
    private static extern void dv_string_free(IntPtr text);

    [DllImport(Lib, EntryPoint = "dv_connect", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_connect(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_libraries", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_libraries(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_items", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_items(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string libraryId,
        int page,
        int pageSize);

    [DllImport(Lib, EntryPoint = "dv_children", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_children(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string parentId,
        int page,
        int pageSize);

    [DllImport(Lib, EntryPoint = "dv_records", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_records(IntPtr handle);

    [DllImport(Lib, EntryPoint = "dv_report_progress", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_report_progress(
        IntPtr handle,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string itemId,
        long position,
        long duration);

    [DllImport(Lib, EntryPoint = "dv_version", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr dv_version();
}

public sealed record SourceConfig(
    string Id,
    string Name,
    string Kind,
    string Base,
    string Username,
    string Password);

public sealed record MediaLibraryDto(
    string Id,
    string Title,
    string SourceId,
    string? PosterPath,
    string Category);

public sealed record PagedDto<T>(List<T> Items, int Total, int Page, int PageSize);

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
    long? LastPlayed);

public sealed record PlayRecordDto(
    string ItemId,
    string Title,
    string SourceId,
    string? PosterPath,
    long PositionSeconds,
    long DurationSeconds,
    long? LastPlayed);

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
