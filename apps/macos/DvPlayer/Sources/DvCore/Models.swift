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

    public init(id: String = UUID().uuidString, name: String, kind: String = "fnos",
                base: String, username: String = "", password: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.base = base
        self.username = username
        self.password = password
    }
}

public struct SourceInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
}

/// 一个源连没连上。设置页和侧栏都用它。
public struct SourceConnection: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let ok: Bool
    public let error: String?

    public init(id: String, name: String, kind: String, ok: Bool, error: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ok = ok
        self.error = error
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

    public var isSeason: Bool { kind.lowercased() == "season" }
    public var isSeries: Bool { ["series", "tv"].contains(kind.lowercased()) }
    public var isFolder: Bool { kind.lowercased() == "folder" }
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
}

public struct PlaySource: Codable, Sendable {
    public let itemId: String
    public let title: String
    public let url: String
    public let headers: [HttpHeader]
    public let mediaGuid: String
    public let positionSeconds: Int
    public let durationSeconds: Int
    public let posterPath: String?
    public let resolution: String?
    public let colorRange: String?
    public let dolbyVision: Bool
    public let videoCodec: String?
    public let audioCodec: String?
}

public struct AudioInfo: Codable, Hashable, Sendable {
    public let title: String?
    public let language: String?
    public let codec: String?
    public let channels: Int?
    public let isDefault: Bool?
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
    public let bitDepth: Int?
    public let pixelFormat: String?
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
