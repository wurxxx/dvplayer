import Foundation

/// 本地配置：媒体源列表与播放偏好。
/// 存 `~/Library/Application Support/DvPlayer/settings.json`。
public struct AppSettings: Codable, Sendable {
    public var sources: [SourceConfig] = []
    public var lastSourceId: String?
    public var autoConnect: Bool = true
    public var startPage: String = "libraries"
    /// 搜索页上次的查询词：切到别的页再回来、重启应用都还在。
    public var searchKeyword: String?
    public var pageSize: Int = 60
    public var showResolution: Bool = true
    public var resumePlayback: Bool = true

    /// 播放缓冲上限（MB）。默认 512，设置页可选 256 / 512 / 1024 / 2048 / 4096。
    /// 用可选值是为了老配置（没有这个键）能直接解出来，读的时候用 `?? 512`。
    public var bufferSizeMb: Int?

    /// 画面比例模式（`fit` / `fill` / `stretch` / `16:9` / `4:3`）。
    /// 用可选值是为了老配置能直接解出来。
    public var videoAspect: String?

    /// 音频输出设备（mpv 的 `audio-device` 名字）；空 = 系统默认。
    public var audioDevice: String?

    /// 音频直通（AC3 / EAC3 / DTS / TrueHD 交给功放解码）。
    public var audioPassthrough: Bool?

    /// HDR 直通（mpv 的 `target-colorspace-hint`，系统开了 HDR 才有效）。
    public var hdrPassthrough: Bool?

    /// 播放窗是否置顶（播放页的图钉按钮）。跨会话保留。
    public var alwaysOnTop: Bool?

    /// 弹幕（弹弹play）。AppId / AppSecret 在弹弹play 控制台申请。
    public var danmakuEnabled: Bool?
    public var danmakuAppId: String?
    public var danmakuAppSecret: String?

    /// 在线字幕（OpenSubtitles）。API Key 注册即得；用户名 / 密码可选，
    /// 配了才会去换下载用的 token。
    public var openSubtitlesApiKey: String?
    public var openSubtitlesUsername: String?
    public var openSubtitlesPassword: String?
    public var subtitleLanguages: String?

    public init() {}

    /// 缺字段一律回退默认值：Swift 合成的 Decodable 不会用属性默认值补键，
    /// 老配置少一个非可选字段就会整份解码失败、随后被 save() 清空。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([SourceConfig].self, forKey: .sources) ?? []
        lastSourceId = try c.decodeIfPresent(String.self, forKey: .lastSourceId)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        startPage = try c.decodeIfPresent(String.self, forKey: .startPage) ?? "libraries"
        searchKeyword = try c.decodeIfPresent(String.self, forKey: .searchKeyword)
        pageSize = try c.decodeIfPresent(Int.self, forKey: .pageSize) ?? 60
        showResolution = try c.decodeIfPresent(Bool.self, forKey: .showResolution) ?? true
        resumePlayback = try c.decodeIfPresent(Bool.self, forKey: .resumePlayback) ?? true
        bufferSizeMb = try c.decodeIfPresent(Int.self, forKey: .bufferSizeMb)
        videoAspect = try c.decodeIfPresent(String.self, forKey: .videoAspect)
        audioDevice = try c.decodeIfPresent(String.self, forKey: .audioDevice)
        audioPassthrough = try c.decodeIfPresent(Bool.self, forKey: .audioPassthrough)
        hdrPassthrough = try c.decodeIfPresent(Bool.self, forKey: .hdrPassthrough)
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop)
        danmakuEnabled = try c.decodeIfPresent(Bool.self, forKey: .danmakuEnabled)
        danmakuAppId = try c.decodeIfPresent(String.self, forKey: .danmakuAppId)
        danmakuAppSecret = try c.decodeIfPresent(String.self, forKey: .danmakuAppSecret)
        openSubtitlesApiKey = try c.decodeIfPresent(String.self, forKey: .openSubtitlesApiKey)
        openSubtitlesUsername = try c.decodeIfPresent(String.self, forKey: .openSubtitlesUsername)
        openSubtitlesPassword = try c.decodeIfPresent(String.self, forKey: .openSubtitlesPassword)
        subtitleLanguages = try c.decodeIfPresent(String.self, forKey: .subtitleLanguages)
    }

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
            // 但不要把坏文件直接留着等下一次 save() 覆盖：先备份一份，方便找回源和凭据。
            if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = Self.directory.appendingPathComponent("settings.json.broken-\(stamp)")
                try? FileManager.default.moveItem(at: Self.fileURL, to: backup)
            }
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
            // 文件里有服务器密码、弹幕 AppSecret、OpenSubtitles 凭据：
            // 默认 0644 会让同机其它本地用户读到，收紧到 0600。
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        } catch {
            NSLog("[DvPlayer] 写入配置失败：\(error.localizedDescription)")
        }
    }
}
