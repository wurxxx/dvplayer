using System.Reflection;

namespace DvPlayer.Services;

/// <summary>
/// 弹幕（弹弹play）凭据：**打包时**由 <c>apps/windows/packaging/build-release.ps1</c>
/// 从本地密钥文件（默认 <c>~\.config\dvplayer\danmaku.env</c>）读出来，以程序集元数据
/// 写进 exe：
/// <code>
/// dotnet publish -p:DanmakuAppId=... -p:DanmakuAppSecret=...
/// </code>
///
/// 为什么不在设置页里填：弹弹play 客户端必须内置一份 AppId / AppSecret 才能用，
/// 让每个用户自己去开放平台申请既麻烦又不现实。这是公共凭据，所有用户共用，
/// 所以只放在开发和打包环境，不进仓库、不进 settings.json。
///
/// 普通 <c>dotnet build</c>（开发）没有这两个属性 → 弹幕安静关闭，不联网也不报错。
/// </summary>
internal static class DanmakuCredential
{
    public static string AppId { get; } = Read("DvDanmakuAppId");

    public static string AppSecret { get; } = Read("DvDanmakuAppSecret");

    public static bool IsConfigured =>
        !string.IsNullOrWhiteSpace(AppId) && !string.IsNullOrWhiteSpace(AppSecret);

    private static string Read(string key) =>
        Assembly.GetEntryAssembly()
            ?.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => attribute.Key == key)?.Value
        ?? "";
}
