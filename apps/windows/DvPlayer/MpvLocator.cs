using System.IO;

namespace DvPlayer;

/// <summary>
/// 找 mpv 可执行文件：环境变量 → exe 旁的 <c>mpv\</c> → 开发树上游的 <c>mpv\</c>。
///
/// 不写死某个盘符路径：产品里执行写死路径上的任意 exe 等于给了一个可被替换的入口。
/// 开发 / 测试机直接从 <c>bin\Release\net10.0-windows</c> 跑时，往上几层就是仓库根的
/// <c>mpv\</c>；安装版则用 exe 旁边打包进去的那份。
/// </summary>
internal static class MpvLocator
{
    public const string EnvVar = "DVPLAYER_MPV";

    /// <summary>找不到返回 null；<paramref name="fileName"/> 可以是 mpv.exe / mpv.com。</summary>
    public static string? Find(string fileName = "mpv.exe")
    {
        var fromEnv = Environment.GetEnvironmentVariable(EnvVar);
        if (!string.IsNullOrWhiteSpace(fromEnv))
        {
            // 环境变量可能直接指向目录。
            if (File.Exists(fromEnv))
            {
                return fromEnv;
            }

            if (Directory.Exists(fromEnv))
            {
                var inside = Path.Combine(fromEnv, fileName);
                if (File.Exists(inside))
                {
                    return inside;
                }
            }
        }

        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; depth < 8 && dir is not null; depth++, dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "mpv", fileName);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    /// <summary>mpv 所在目录（找不到就是 null）。</summary>
    public static string? FindDirectory()
    {
        var exe = Find();
        return exe is null ? null : Path.GetDirectoryName(exe);
    }
}
