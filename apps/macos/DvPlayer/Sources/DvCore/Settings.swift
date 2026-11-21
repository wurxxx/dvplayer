import Foundation

/// 本地配置：媒体源列表与播放偏好。
/// 存 `~/Library/Application Support/DvPlayer/settings.json`。
public struct AppSettings: Codable, Sendable {
    public var sources: [SourceConfig] = []
    public var lastSourceId: String?
    public var autoConnect: Bool = true
    public var startPage: String = "libraries"
    public var pageSize: Int = 60
    public var showResolution: Bool = true
    public var resumePlayback: Bool = true

    /// 画面比例模式（`fit` / `fill` / `stretch` / `16:9` / `4:3`）。
    /// 用可选值是为了老配置能直接解出来。
    public var videoAspect: String?

    public init() {}

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("DvPlayer", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    public static func load() -> AppSettings {
        do {
            let data = try Data(contentsOf: fileURL)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            NSLog("[DvPlayer] 配置：\(fileURL.path)（\(settings.sources.count) 个源）")
            return settings
        } catch {
            // 配置损坏 / 第一次启动都当空的，不让界面起不来。
            NSLog("[DvPlayer] 读配置失败 \(fileURL.path)：\(error.localizedDescription)")
            return AppSettings()
        }
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("[DvPlayer] 写入配置失败：\(error.localizedDescription)")
        }
    }
}
