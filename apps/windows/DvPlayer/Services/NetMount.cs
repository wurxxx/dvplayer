using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace DvPlayer.Services;

/// <summary>
/// 文件协议源（SMB / NFS / WebDAV）。先让 Windows 挂载，再把挂载后的本地路径
/// （UNC 或盘符）当作 <c>kind=local</c> 交给共享核心：扫描、海报、季集推断、
/// ISO 原盘全部复用「本地文件夹源」那一套。
///
/// 不把网络客户端编进核心：随包的 mpv 没有 libsmbclient，就算核心能列目录，
/// 播放器也打不开 <c>smb://</c>；挂载以后两边都只认本地路径。
/// </summary>
internal static class NetMount
{
    /// <summary>挂载根（SMB 是 <c>\\host\share</c>，NFS / WebDAV 是盘符），按源 id 记。</summary>
    private static readonly Dictionary<string, string> Mounted = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object Gate = new();

    /// <summary>挂载类型；<c>local</c> 不在这里。</summary>
    public static bool IsMount(string kind) =>
        kind is "smb" or "cifs" or "nfs" or "webdav";

    /// <summary>把文件协议配置换成核心能用的本地目录；其它类型原样返回。</summary>
    public static SourceConfig Prepare(SourceConfig config)
    {
        var kind = config.Kind.ToLowerInvariant();
        if (!IsMount(kind))
        {
            return config;
        }

        var (root, path) = kind switch
        {
            "smb" or "cifs" => MountSmb(config),
            "nfs" => MountNfs(config),
            _ => MountWebDav(config),
        };

        if (!Directory.Exists(path))
        {
            throw new NetMountException($"已挂载 {root}，但读不到目录：{path}");
        }

        lock (Gate)
        {
            Mounted[config.Id] = root;
        }

        return config with
        {
            Kind = "local",
            Base = path,
            Username = string.Empty,
            Password = string.Empty,
        };
    }

    /// <summary>删源 / 换地址时卸载。没挂过就什么也不做。</summary>
    public static void Release(string id)
    {
        string? root;
        lock (Gate)
        {
            if (!Mounted.TryGetValue(id, out root))
            {
                return;
            }

            Mounted.Remove(id);
        }

        try
        {
            if (root.StartsWith(@"\\", StringComparison.Ordinal))
            {
                WNetCancelConnection2(root, 0, true);
            }
            else if (root.Length >= 2 && root[1] == ':')
            {
                Run("net", $"use {root} /delete /y");
            }
        }
        catch
        {
            // 卸载失败不影响删源本身，下次启动会重新挂。
        }
    }

    // ——— SMB ———

    private static (string Root, string Path) MountSmb(SourceConfig config)
    {
        var target = ParseSmb(config.Base, config.Username, config.Password);
        var resource = new NetResource
        {
            Type = ResourceTypeDisk,
            RemoteName = target.Root,
        };

        var code = WNetAddConnection2(
            ref resource,
            string.IsNullOrEmpty(target.Password) ? null : target.Password,
            string.IsNullOrEmpty(target.User) ? null : target.User,
            0);

        // 85 = 本地设备已映射；1219 = 已用另一套凭据连着同一个共享。
        if (code is not (0 or ErrorAlreadyAssigned or ErrorSessionCredentialConflict))
        {
            throw new NetMountException(
                $"SMB 连接失败（{code}）：{new Win32Exception(code).Message}\n{target.Root}");
        }

        return (target.Root, target.Path);
    }

    private static SmbTarget ParseSmb(string raw, string username, string password)
    {
        var text = raw.Trim();
        foreach (var prefix in new[] { "smb://", "cifs://" })
        {
            if (text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                text = text[prefix.Length..];
                break;
            }
        }

        text = text.Replace('\\', '/');
        if (text.StartsWith("//", StringComparison.Ordinal))
        {
            text = text[2..];
        }

        var user = username;
        var pass = password;

        // 地址里也可能带「用户名:密码@」，账号密码两项直接写在 @ 前面。
        var at = text.IndexOf('@');
        if (at > 0 && !text[..at].Contains('/'))
        {
            var credentials = text[..at];
            text = text[(at + 1)..];
            var colon = credentials.IndexOf(':');
            if (user.Length == 0)
            {
                user = Uri.UnescapeDataString(
                    colon >= 0 ? credentials[..colon] : credentials);
            }
            if (pass.Length == 0 && colon >= 0)
            {
                pass = Uri.UnescapeDataString(credentials[(colon + 1)..]);
            }
        }

        var pieces = text.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (pieces.Length < 2)
        {
            throw new NetMountException("SMB 地址要写到共享名，例如 smb://192.168.1.10/影视");
        }

        var root = $@"\\{pieces[0]}\{pieces[1]}";
        var sub = pieces.Skip(2).ToArray();
        var path = sub.Length == 0 ? root : root + @"\" + string.Join('\\', sub);
        return new SmbTarget(root, path, user, pass);
    }

    // ——— NFS / WebDAV（走系统命令，报错要说清楚缺什么） ———

    private static (string Root, string Path) MountNfs(SourceConfig config)
    {
        var remote = NfsRemote(config.Base);
        var drive = ReuseOrPickDrive(config.Id);

        if (!Directory.Exists(drive + "\\"))
        {
            var (ok, output) = Run("mount", $"-o anon \"{remote}\" {drive}");
            if (!ok)
            {
                throw new NetMountException(
                    $"NFS 挂载失败：{output}\n" +
                    "Windows 需要先启用「NFS 客户端」功能，并用管理员身份运行 DVPlayer。");
            }
        }

        return (drive, drive + "\\");
    }

    private static string NfsRemote(string raw)
    {
        var text = raw.Trim();
        if (text.StartsWith("nfs://", StringComparison.OrdinalIgnoreCase))
        {
            text = text[6..];
        }

        text = text.Replace('/', '\\');
        // `host:\export` 的冒号是分隔符，不是路径的一部分。
        var colon = text.IndexOf(':');
        if (colon > 0)
        {
            text = text[..colon] + text[(colon + 1)..];
        }

        var pieces = text.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        if (pieces.Length < 2)
        {
            throw new NetMountException("NFS 地址要写到导出目录，例如 nfs://192.168.1.10:/volume1/media");
        }

        return $@"\\{pieces[0]}\{string.Join('\\', pieces.Skip(1))}";
    }

    private static (string Root, string Path) MountWebDav(SourceConfig config)
    {
        var url = config.Base.Trim();
        if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            url = "https://" + url;
        }

        var drive = ReuseOrPickDrive(config.Id);
        if (!Directory.Exists(drive + "\\"))
        {
            var arguments = $"use {drive} \"{url}\" /persistent:no";
            if (!string.IsNullOrEmpty(config.Username))
            {
                arguments += $" /user:\"{config.Username}\"";
                if (!string.IsNullOrEmpty(config.Password))
                {
                    arguments += $" \"{config.Password}\"";
                }
            }

            var (ok, output) = Run("net", arguments);
            if (!ok)
            {
                throw new NetMountException(
                    $"WebDAV 挂载失败：{output}\n" +
                    "Windows 需要启用「WebClient」服务（默认关闭），服务器要支持 WebDAV。");
            }
        }

        return (drive, drive + "\\");
    }

    private static string ReuseOrPickDrive(string id)
    {
        lock (Gate)
        {
            if (Mounted.TryGetValue(id, out var existing) &&
                existing is not null &&
                existing.Length >= 2 && existing[1] == ':' &&
                Directory.Exists(existing + "\\"))
            {
                return existing;
            }

            var used = new HashSet<string>(
                DriveInfo.GetDrives().Select(d => d.Name.TrimEnd('\\')),
                StringComparer.OrdinalIgnoreCase);
            foreach (var letter in "ZYXWVUTSRQPONMLK")
            {
                var name = letter + ":";
                if (!used.Contains(name))
                {
                    return name;
                }
            }
        }

        throw new NetMountException("没有空闲盘符可以挂载网络目录");
    }

    // ——— Win32 / 进程 ———

    private const int ResourceTypeDisk = 1;
    private const int ErrorAlreadyAssigned = 85;
    private const int ErrorSessionCredentialConflict = 1219;

    [StructLayout(LayoutKind.Sequential)]
    private struct NetResource
    {
        public int Scope;
        public int Type;
        public int DisplayType;
        public int Usage;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? LocalName;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? RemoteName;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? Comment;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? Provider;
    }

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    private static extern int WNetAddConnection2(
        ref NetResource netResource, string? password, string? username, int flags);

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    private static extern int WNetCancelConnection2(string name, int flags, bool force);

    private static (bool Ok, string Output) Run(string file, string arguments)
    {
        var info = new ProcessStartInfo(file, arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        using var process = Process.Start(info);
        if (process is null)
        {
            return (false, "无法启动 " + file);
        }

        var outTask = process.StandardOutput.ReadToEndAsync();
        var errTask = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(20_000))
        {
            try
            {
                process.Kill(true);
            }
            catch
            {
                // 已经退了。
            }

            return (false, $"{file} 超时（20 秒没有响应）");
        }

        var output = (outTask.GetAwaiter().GetResult() +
                      errTask.GetAwaiter().GetResult()).Trim();
        return (process.ExitCode == 0, output);
    }

    private readonly record struct SmbTarget(
        string Root, string Path, string User, string Password);
}

internal sealed class NetMountException(string message) : Exception(message);
