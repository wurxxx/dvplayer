import Foundation
import DvCore

/// 文件协议源（SMB / NFS / WebDAV）。
///
/// 做法是让系统去挂载，挂好以后交给共享核心的就是一个普通目录（`kind=local`），
/// 扫描、海报、季集推断、ISO 原盘播放全部复用「本地文件夹源」那一套，
/// 播放器读的也是本地路径——4K 原盘直接读 SMB 比在 mpv 里拼 smb:// 稳。
///
/// 为什么不把 SMB 客户端编进核心：随包的 mpv 没有 libsmbclient，即使核心能列
/// 目录，播放器也打不开 `smb://`；挂载则两边都不用改。
enum MountSources {
    /// 挂载的几种协议。`local` 不在这里。
    static let kinds = ["smb", "cifs", "nfs", "webdav"]

    static func isMount(_ kind: String) -> Bool {
        kinds.contains(kind.lowercased())
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("DvPlayer/mounts", isDirectory: true)
    }

    static func mountPoint(_ id: String) -> URL {
        root.appendingPathComponent(safeName(id), isDirectory: true)
    }

    /// 把配置转成核心能用的本地目录；`local` 和其它服务器源原样返回。
    static func prepare(_ config: SourceConfig) async throws -> SourceConfig {
        guard isMount(config.kind) else { return config }

        let target = try Target(config)
        let point = mountPoint(config.id)

        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: point,
                                                    withIntermediateDirectories: true)

            if !isMounted(point) {
                // 目录里可能还留着上次的残影，挂载前清空（只清挂载点本身）。
                try? FileManager.default.removeItem(at: point)
                try FileManager.default.createDirectory(at: point,
                                                        withIntermediateDirectories: true)
                try target.mount(to: point.path)
            }

            // SMB / NFS 的 URL 可以带子路径（共享里的某个文件夹）。
            let local = point.appendingPathComponent(target.subPath, isDirectory: true)
            if !target.subPath.isEmpty,
               !FileManager.default.fileExists(atPath: local.path) {
                // 别悄悄退回共享根：用户会以为整个共享都进库了。
                throw MountError("共享里没有这个目录：\(target.subPath)")
            }

            var effective = config
            effective.kind = "local"
            effective.base = local.path
            effective.username = ""
            effective.password = ""
            NSLog("[Mount] \(config.kind) \(target.display) -> \(local.path)")
            return effective
        }.value
    }
}

private struct Target {
    let kind: String
    let host: String
    let share: String
    let subPath: String
    let user: String
    let password: String
    let scheme: String
    /// WebDAV 的完整 URL（含 `/dav` 这类路径），mount_webdav 要整条。
    private let webdavURL: String

    var display: String {
        switch scheme {
        case "smb": return "smb://\(host)/\(share)"
        case "nfs": return "nfs://\(host):\(share)"
        // WebDAV 的 URL 可能带 `user:password@`，日志和错误里不能原样输出。
        case "webdav": return Self.redacted(webdavURL)
        default: return "webdav://\(host)"
        }
    }

    /// 去掉 URL 里的 userinfo，只留 scheme / host / path / query。
    static func redacted(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.user = nil
        components.password = nil
        return components.string ?? url
    }

    init(_ config: SourceConfig) throws {
        let raw = config.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw MountError("地址是空的")
        }

        kind = config.kind.lowercased()
        var user = config.username
        var password = config.password

        // `smb://host/share/sub`、`//host/share/sub`、`\\host\share\sub` 都认。
        var text = raw
        var detected = kind
        for prefix in ["smb://", "cifs://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            detected = "smb"
        }
        for prefix in ["nfs://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            detected = "nfs"
        }
        for prefix in ["webdav://", "dav://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            detected = "webdav"
        }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            detected = "webdav"
        }
        // 反斜杠形式统一成正斜杠。
        text = text.replacingOccurrences(of: "\\", with: "/")
        if text.hasPrefix("//") {
            text.removeFirst(2)
        }

        // 地址里可能已经带了 `user:pass@`。
        if let at = text.lastIndex(of: "@"), !text[..<at].contains("/") {
            let credentials = String(text[..<at])
            text = String(text[text.index(after: at)...])
            if !credentials.isEmpty {
                let parts = credentials.split(separator: ":", maxSplits: 1)
                if user.isEmpty {
                    user = String(parts[0])
                }
                if password.isEmpty, parts.count > 1 {
                    password = String(parts[1])
                }
            }
        }

        self.user = user
        self.password = password
        scheme = detected
        var davURL = ""
        let pieces = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch detected {
        case "nfs":
            // `host:/export/sub` 或 `host/export/sub`
            let head = pieces.first ?? ""
            if let colon = head.firstIndex(of: ":") {
                host = String(head[..<colon])
                let export = String(head[head.index(after: colon)...])
                let rest = pieces.dropFirst()
                if export.isEmpty {
                    // `nfs://host:/volume1/media`：按 `/` 切开后前导斜杠没了，
                    // 导出目录要补回 `/volume1`，否则 mount 会去找 `host:volume1`。
                    share = rest.first.map { "/" + $0 } ?? "/"
                    subPath = rest.dropFirst().joined(separator: "/")
                } else {
                    share = export.hasPrefix("/") ? export : "/" + export
                    subPath = rest.joined(separator: "/")
                }
            } else {
                host = head
                // `nfs://host/volume1/media`：第一段是导出目录，其余是子路径。
                share = pieces.count > 1 ? "/" + pieces[1] : "/"
                subPath = pieces.dropFirst(2).joined(separator: "/")
            }
        case "webdav":
            // WebDAV 的路径（`/dav`）属于挂载 URL，不能当成子路径。
            host = pieces.first ?? ""
            share = ""
            subPath = ""
            var url = raw
            if !url.lowercased().hasPrefix("http://"),
               !url.lowercased().hasPrefix("https://") {
                url = "https://" + url
            }
            // 地址里没写账号时，把表单里的账号插到 scheme 后面。
            if !raw.contains("@"), !user.isEmpty,
               let range = url.range(of: "://") {
                url = String(url[..<range.upperBound]) + percentEncode(user)
                    + (password.isEmpty ? "" : ":" + percentEncode(password)) + "@"
                    + String(url[range.upperBound...])
            }
            davURL = url
        default:
            host = pieces.first ?? ""
            share = pieces.count > 1 ? pieces[1] : ""
            subPath = pieces.dropFirst(2).joined(separator: "/")
        }

        webdavURL = davURL

        guard !host.isEmpty else {
            throw MountError("地址里没有主机名：\(Self.redacted(raw))")
        }
        if detected == "smb" && share.isEmpty {
            throw MountError("SMB 地址要写到共享名，例如 smb://192.168.1.10/影视")
        }
    }

    func mount(to point: String) throws {
        switch kind {
        case "smb", "cifs":
            var url = "//"
            if !user.isEmpty {
                url += percentEncode(user)
                if !password.isEmpty {
                    url += ":" + percentEncode(password)
                }
                url += "@"
            }
            url += "\(host)/\(percentEncode(share))"
            try run("/sbin/mount_smbfs", [url, point])

        case "nfs":
            try run("/sbin/mount", [
                "-t", "nfs",
                "-o", "vers=3,resvport,nolocks,soft",
                "\(host):\(share)",
                point,
            ])

        default:
            guard !webdavURL.isEmpty else {
                throw MountError("WebDAV 地址是空的")
            }
            try run("/sbin/mount_webdav", [webdavURL, point])
        }
    }

}

/// SMB / WebDAV 的 URL 解析器对 `@ / : ?` 很敏感，一律百分号编码。
private func percentEncode(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

struct MountError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 挂载点是否真的挂着（`mount` 输出里出现 ` on <点> (`）。
func isMounted(_ point: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/mount")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.contains(" on \(point.path) (")
}

/// 跑一个挂载命令，最多等 20 秒；失败时把 stderr 带回去，界面能直接显示。
func run(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    try process.run()

    let deadline = Date().addingTimeInterval(20)
    while process.isRunning && Date() < deadline {
        usleep(100_000)
    }
    if process.isRunning {
        process.terminate()
        throw MountError("\(path) 超时（20 秒没有响应）")
    }
    if process.terminationStatus != 0 {
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        throw MountError(message.isEmpty ? "\(path) 失败（\(process.terminationStatus)）" : message)
    }
}

/// 卸载并清掉挂载点。删源 / 换地址时调用。
/// umount 可能要几秒，放到后台线程，别卡住主线程（删源的按钮会看起来像没响应）。
func releaseMount(_ id: String) async {
    await Task.detached(priority: .utility) {
        releaseMountSync(id)
    }.value
}

private func releaseMountSync(_ id: String) {
    let point = MountSources.mountPoint(id)
    guard FileManager.default.fileExists(atPath: point.path) else { return }

    if isMounted(point) {
        _ = try? run("/sbin/umount", ["-f", point.path])
    }
    try? FileManager.default.removeItem(at: point)
}

/// 启动时清理：已不存在的源留下的挂载点。
func cleanupStaleMounts(keep ids: Set<String>) async {
    await Task.detached(priority: .utility) {
        cleanupStaleMountsSync(keep: ids)
    }.value
}

private func cleanupStaleMountsSync(keep ids: Set<String>) {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: MountSources.root, includingPropertiesForKeys: nil) else {
        return
    }

    for entry in entries {
        let name = entry.lastPathComponent
        if ids.contains(name) { continue }
        if isMounted(entry) {
            _ = try? run("/sbin/umount", ["-f", entry.path])
        }
        try? FileManager.default.removeItem(at: entry)
    }
}

/// 挂载点目录名只用字母数字和短横线，避免 id 里的特殊字符。
func safeName(_ id: String) -> String {
    let mapped = id.map { character -> Character in
        character.isLetter || character.isNumber ? character : "-"
    }
    return String(mapped)
}
