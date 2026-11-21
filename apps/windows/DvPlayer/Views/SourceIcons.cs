namespace DvPlayer.Views;

/// <summary>
/// 服务器图标：按源的种类取仓库里生成的 PNG（`scripts/make-source-icons.py`）。
/// 飞牛是官方牛头剪影，Emby / Jellyfin 是播放三角，本地 / SMB / NFS / WebDAV
/// 各有一个通用标记。WPF 的 `Image Source` 只认工程内资源，图标由脚本同时
/// 写进 `Assets/sources/`，csproj 里作为 Resource 编进程序集。
/// </summary>
internal static class SourceIcons
{
    /// <summary>飞牛影视的几种写法都归到同一张图。</summary>
    public static string Name(string kind) => kind switch
    {
        "feiniu" => "fnos",
        "cifs" => "smb",
        "fnos" or "emby" or "jellyfin" or "local" or "smb" or "nfs" or "webdav" => kind,
        _ => "local",
    };

    /// <summary>给 `Image.Source` 用的 pack URI。</summary>
    public static string Pack(string kind) =>
        $"pack://application:,,,/Assets/sources/{Name(kind)}.png";
}
