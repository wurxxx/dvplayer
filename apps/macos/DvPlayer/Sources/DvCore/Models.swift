import Foundation

// 与 core/media/src/models.rs 一一对应（serde camelCase）。
// 这里不做业务判断，只做 JSON ↔ 强类型；字段名故意和后端保持一致，
// 两边对照着看不用翻译。

public struct ApiError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SourceConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var base: String
    public var username: String
    public var password: String
    /// 本地源把进度写这里；服务器源留空。可选是为了老配置能直接解出来。
    public var dataDir: String?
    /// 网络服务器的 HTTP 代理（如 `http://127.0.0.1:7890`）；空 = 直连。
    /// 可选同样是为了老配置能直接解出来。
    public var proxy: String?

    public init(id: String = UUID().uuidString, name: String, kind: String = "fnos",
                base: String, username: String = "", password: String = "",
                dataDir: String? = nil, proxy: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.base = base
        self.username = username
        self.password = password
        self.dataDir = dataDir
        self.proxy = proxy
    }
}

public struct SourceInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
}

/// 一个源连没连上。设置页和侧栏都用它。
public struct SourceConnection: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let ok: Bool
    public let error: String?
    /// 网络往返延迟（毫秒）；本地源或探测失败为 nil。
    public let latencyMs: Int?

    public init(id: String, name: String, kind: String, ok: Bool, error: String?,
                latencyMs: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ok = ok
        self.error = error
        self.latencyMs = latencyMs
    }
}

public struct MediaLibrary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let sourceId: String
    public let posterPath: String?
    public let category: String
}

public struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let kind: String
    public let sourceId: String
    public var posterPath: String?
    public var parentId: String?
    public var parentTitle: String?
    public var year: Int?
    public var runtimeSeconds: Int?
    public var progress: Double = 0
    public var isFavorite: Bool = false
    public var overview: String?
    public var resolution: String?
    public var lastPlayed: Int?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var episodeCount: Int?
    public var localEpisodeCount: Int?
    public var seasonCount: Int?
    public var rating: Double?
    public var releaseDate: String?
    public var status: String?
    public var backdropPath: String?
    public var singleChildId: String?
    /// 同一部片在各源的条目（聚合搜索填，其它地方是空数组）。第一项就是自己。
    public var sources: [ItemSource] = []

    public var isSeason: Bool { kind.lowercased() == "season" }
    public var isSeries: Bool { ["series", "tv"].contains(kind.lowercased()) }
    public var isFolder: Bool { kind.lowercased() == "folder" }
}

/// 同一部片在某个源里的条目（搜索结果的多来源）。
public struct ItemSource: Codable, Identifiable, Hashable, Sendable {
    public let itemId: String
    public let sourceId: String
    public let sourceName: String
    public var resolution: String?
    public var progress: Double = 0

    public var id: String { itemId }
}

/// 搜索时没有响应的源。
public struct SourceFailure: Codable, Hashable, Sendable {
    public let sourceId: String
    public let sourceName: String
    public let error: String
}

/// 聚合搜索结果：去重后的条目 + 失败的源。
public struct SearchResult: Codable, Sendable {
    public var items: [MediaItem]
    public var failed: [SourceFailure] = []

    public init(items: [MediaItem] = [], failed: [SourceFailure] = []) {
        self.items = items
        self.failed = failed
    }
}

public struct Paged<T: Codable & Sendable>: Codable, Sendable {
    public let items: [T]
    public let total: Int
    public let page: Int
    public let pageSize: Int
}

public struct Genre: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
}

public struct HttpHeader: Codable, Hashable, Sendable {
    public let name: String
    public let value: String
}

public struct ImageSource: Codable, Sendable {
    public let url: String
    public let headers: [HttpHeader]
    /// 服务器设的 HTTP 代理；空 = 直连。
    public let proxy: String?
}

public struct PlayRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String { itemId }
    public let itemId: String
    public let title: String
    public let sourceId: String
    public let seriesTitle: String?
    public let parentId: String?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let posterPath: String?
    public let positionSeconds: Int
    public let durationSeconds: Int
    public let lastPlayed: Int?

    public var progress: Double {
        durationSeconds <= 0 ? 0 : min(1, max(0, Double(positionSeconds) / Double(durationSeconds)))
    }
}

public struct Person: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let job: String?
    public let imagePath: String?
}

public struct MediaDetail: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: String
    public let originalTitle: String?
    public let overview: String?
    public let posterPath: String?
    public let backdropPath: String?
    public let logoPath: String?
    public let rating: Double?
    public let releaseDate: String?
    public let runtimeSeconds: Int?
    public let seasonCount: Int?
    public let localSeasonCount: Int?
    public let episodeCount: Int?
    public let localEpisodeCount: Int?
    public let status: String?
    public let resolution: String?
    public let audioType: String?
    public let colorRange: String?
    public let playItemId: String?
    public let singleChildId: String?
    public let isFavorite: Bool?
    public let isWatched: Bool?
    /// 外部库 id（Emby / Jellyfin 的 ProviderIds）：Trakt 精确匹配、详情页链接用。
    public let tmdbId: String?
    public let imdbId: String?
}

/// 播放源随带的轨道表（外挂字幕带下载地址）。
public struct SubtitleTrack: Codable, Hashable, Sendable {
    public let guid: String
    public let language: String?
    public let codec: String?
    public let format: String?
    public let isExternal: Bool
    public let isBitmap: Bool
    /// 外挂字幕的下载地址；内嵌字幕为 nil。请求头用 `PlaySource.headers`。
    public let url: String?
}

public struct PlaySource: Codable, Sendable {
    public let itemId: String
    public let title: String
    public let url: String
    public let headers: [HttpHeader]
    public let isDirect: Bool
    /// 原盘：界面要走挂载 / libbluray，而不是直接丢给 mpv。
    public let disc: Bool
    public let mediaGuid: String
    public let positionSeconds: Int
    public let durationSeconds: Int
    public let posterPath: String?
    public let resolution: String?
    public let colorRange: String?
    public let dolbyVision: Bool
    public let videoCodec: String?
    public let audioCodec: String?
    /// 服务器设的 HTTP 代理；空 = 直连。播放请求也走它。
    public let proxy: String?
    /// 播放源的轨道表；外挂字幕的 `url` 用来下载。
    public let subtitleStreams: [SubtitleTrack]?
}

public struct AudioInfo: Codable, Hashable, Sendable {
    public let title: String?
    public let language: String?
    public let codec: String?
    public let profile: String?
    public let layout: String?
    public let bitRate: Int64?
    public let channels: Int?
    public let sampleRate: Int?
    public let isDefault: Bool?
    public let isExternal: Bool?
}

public struct SubtitleInfo: Codable, Hashable, Sendable {
    public let title: String?
    public let language: String?
    public let codec: String?
    public let format: String?
    public let isDefault: Bool?
    public let isBitmap: Bool?
    public let isExternal: Bool?
}

public struct MediaInfo: Codable, Sendable {
    public let video: VideoInfo?
    public let audios: [AudioInfo]
    public let subtitles: [SubtitleInfo]
    /// 文件 / 目录路径（详情页「位置」）；本地源只有这一项，服务器可能不给。
    public let path: String?
}

public struct VideoInfo: Codable, Sendable {
    public let title: String?
    public let codec: String?
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let bitRate: Int64?
    public let colorRange: String?
    public let profile: String?
    public let level: Double?
    public let aspectRatio: String?
    public let interlaced: Bool?
    public let bitDepth: Int?
    public let pixelFormat: String?
    public let dolbyVision: Bool?

    /// 「4K」「1080p」这类从尺寸推出来的标签，标题缺失时兜底。
    public var resolutionLabel: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        if width >= 3600 { return "4K" }
        if width >= 2500 { return "1440p" }
        if width >= 1800 { return "1080p" }
        if width >= 1200 { return "720p" }
        return "\(width)x\(height)"
    }
}

/// 列表筛选（和 core 的 ListQuery 对齐）。
public struct ListQuery: Codable, Sendable {
    public var kinds: [String] = []
    public var genre: String?
    public var sort: String?
    public var descending: Bool = false

    public init(kinds: [String] = [], genre: String? = nil,
                sort: String? = nil, descending: Bool = false) {
        self.kinds = kinds
        self.genre = genre
        self.sort = sort
        self.descending = descending
    }
}
