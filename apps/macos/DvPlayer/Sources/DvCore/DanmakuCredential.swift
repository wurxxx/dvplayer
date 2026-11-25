import Foundation

/// 弹幕（弹弹play）凭据：**打包时**由 `apps/macos/DvPlayer/build.sh` 从本地
/// 密钥文件（默认 `~/.config/dvplayer/danmaku.env`）写进 Info.plist，随包分发。
///
/// 为什么不在设置页里填：弹弹play 客户端必须内置 AppId / AppSecret 才能用，
/// 让每个用户自己去开放平台申请既麻烦又不现实（个人申请要审核）。
/// 这些值是公共凭据，所有用户共用同一份，所以只放在开发和打包环境，不进仓库。
///
/// 直接用 `swift build` 出来的二进制没有 bundle，读不到键 → 弹幕安静关闭，
/// 开发时不联网也不报错。
public enum DanmakuCredential {
    public static let appId: String = value(for: "DVDanmakuAppId")
    public static let appSecret: String = value(for: "DVDanmakuAppSecret")

    public static var isConfigured: Bool {
        !appId.isEmpty && !appSecret.isEmpty
    }

    private static func value(for key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
