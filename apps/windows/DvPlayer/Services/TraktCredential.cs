using System.Reflection;

namespace DvPlayer.Services;

/// <summary>
/// Trakt 应用凭据：打包时由打包脚本从本地密钥文件
/// （默认 <c>~\.config\dvplayer\trakt.env</c>）读出来，以程序集元数据写进 exe：
/// <code>
/// dotnet publish -p:TraktClientId=... -p:TraktClientSecret=...
/// </code>
///
/// 和弹幕凭据一样：这是「哪个应用在请求」的公共标识，用户不需要自己申请；
/// 设置页里也可以填自己的应用，留空就用这里的默认值。普通
/// <c>dotnet build</c> 没有这两个属性 → 设置页显示凭据输入框。
/// </summary>
internal static class TraktCredential
{
    public static string ClientId { get; } = Read("DvTraktClientId");

    public static string ClientSecret { get; } = Read("DvTraktClientSecret");

    public static bool IsConfigured => !string.IsNullOrWhiteSpace(ClientId);

    private static string Read(string key) =>
        Assembly.GetEntryAssembly()
            ?.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => attribute.Key == key)?.Value
        ?? "";
}
