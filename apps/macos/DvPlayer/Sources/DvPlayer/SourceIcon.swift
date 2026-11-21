import AppKit
import SwiftUI

/// 服务器图标：`Contents/Resources/sources/<kind>.png`，和 Windows 用同一份图
/// （`scripts/make-source-icons.py` 同时写到仓库 `assets/sources/` 与 Windows 工程）。
///
/// 飞牛是官方牛头剪影，Emby / Jellyfin 是播放三角，本地 / SMB / NFS / WebDAV
/// 各有一个通用标记；不认识的种类退到本地文件夹。
struct SourceIcon: View {
    let kind: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = Self.image(kind) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                // 直接跑 Swift 可执行文件（没有 .app 资源）时的兜底。
                RoundedRectangle(cornerRadius: size * 0.24)
                    .fill(Theme.surfaceHover)
                    .overlay(
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(Theme.muted)
                    )
            }
        }
        .frame(width: size, height: size)
    }

    /// 飞牛影视的几种写法都归到同一张图。
    static func name(_ kind: String) -> String {
        switch kind {
        case "feiniu": return "fnos"
        case "cifs": return "smb"
        case "fnos", "emby", "jellyfin", "local", "smb", "nfs", "webdav": return kind
        default: return "local"
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(_ kind: String) -> NSImage? {
        let name = name(kind)
        if let hit = cache[name] { return hit }

        guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                        subdirectory: "sources"),
              let image = NSImage(contentsOf: url) else { return nil }

        cache[name] = image
        return image
    }
}
