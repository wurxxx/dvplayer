import Foundation
import DvCoreC

/// 共享核心（Rust）的 Swift 绑定。
///
/// 核心是阻塞式的（内部用 reqwest 跑同步请求），所以所有调用都丢到一条
/// 串行队列上：既不挡主线程，也保证同一个 hub 句柄不会被并发访问。
/// core 的统一返回：`{ok, data, error}`。
private struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}

/// 没有 data 的返回。
private struct EnvelopeNoData: Decodable {
    let ok: Bool
    let error: String?
}

public final class Core: @unchecked Sendable {
    private var hub: DVHub?
    private let queue = DispatchQueue(label: "com.dvplayer.core", qos: .userInitiated)

    /// 加载到的核心版本号；DLL 缺失时是 "unavailable: ..."。
    public static let version: String = {
        guard let pointer = dv_version() else { return "unknown" }
        let text = String(cString: pointer)
        dv_string_free(pointer)
        return (try? decodeEnvelope(String.self, from: text)) ?? "unknown"
    }()

    public init?() {
        hub = dv_hub_new()
        if hub == nil {
            return nil
        }
    }

    deinit {
        if let hub {
            dv_hub_free(hub)
        }
    }

    // MARK: - 源

    public func add(_ config: SourceConfig) async throws -> SourceInfo {
        let json = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? ""
        return try await perform { hub in
            json.withCString { dv_hub_add(hub, $0) }
        }
    }

    public func sources() async throws -> [SourceInfo] {
        try await perform { hub in dv_hub_sources(hub) }
    }

    // MARK: - 浏览

    public func libraries() async throws -> [MediaLibrary] {
        try await perform { hub in dv_hub_libraries(hub) }
    }

    public func items(_ libraryId: String, page: Int = 1, pageSize: Int = 60,
                      query: ListQuery? = nil) async throws -> Paged<MediaItem> {
        let filter = queryJSON(query)
        return try await perform { hub in
            libraryId.withCString { lib in
                filter.withCString { q in
                    dv_hub_items(hub, lib, Int32(page), Int32(pageSize), q)
                }
            }
        }
    }

    public func children(_ parentId: String, page: Int = 1, pageSize: Int = 200,
                         query: ListQuery? = nil) async throws -> Paged<MediaItem> {
        let filter = queryJSON(query)
        return try await perform { hub in
            parentId.withCString { parent in
                filter.withCString { q in
                    dv_hub_children(hub, parent, Int32(page), Int32(pageSize), q)
                }
            }
        }
    }

    public func genres(_ scopeId: String) async throws -> [Genre] {
        try await perform { hub in scopeId.withCString { dv_hub_genres(hub, $0) } }
    }

    public func search(_ keyword: String) async throws -> [MediaItem] {
        try await perform { hub in keyword.withCString { dv_hub_search(hub, $0) } }
    }

    // MARK: - 详情 / 播放

    public func detail(_ itemId: String) async throws -> MediaDetail {
        try await perform { hub in itemId.withCString { dv_hub_detail(hub, $0) } }
    }

    public func people(_ itemId: String) async throws -> [Person] {
        try await perform { hub in itemId.withCString { dv_hub_people(hub, $0) } }
    }

    public func personWorks(_ personId: String) async throws -> [MediaItem] {
        try await perform { hub in personId.withCString { dv_hub_person_works(hub, $0) } }
    }

    public func mediaInfo(_ itemId: String) async throws -> MediaInfo {
        try await perform { hub in itemId.withCString { dv_hub_media_info(hub, $0) } }
    }

    public func playSource(_ itemId: String) async throws -> PlaySource {
        try await perform { hub in itemId.withCString { dv_hub_play_source(hub, $0) } }
    }

    public func imageSource(_ posterPath: String) async throws -> ImageSource {
        try await perform { hub in posterPath.withCString { dv_hub_image_source(hub, $0) } }
    }

    // MARK: - 记录 / 收藏

    public func records() async throws -> [PlayRecord] {
        try await perform { hub in dv_hub_records(hub) }
    }

    public func reportProgress(_ itemId: String, position: Int, duration: Int) async throws {
        try await performVoid { hub in
            itemId.withCString {
                dv_hub_report_progress(hub, $0, Int64(position), Int64(duration))
            }
        }
    }

    public func setFavorite(_ itemId: String, favorite: Bool) async throws {
        try await performVoid { hub in
            itemId.withCString { dv_hub_set_favorite(hub, $0, favorite ? 1 : 0) }
        }
    }

    public func setWatched(_ itemId: String, watched: Bool) async throws {
        try await performVoid { hub in
            itemId.withCString { dv_hub_set_watched(hub, $0, watched ? 1 : 0) }
        }
    }

    public func removeRecord(_ itemId: String) async throws {
        try await performVoid { hub in
            itemId.withCString { dv_hub_remove_record(hub, $0) }
        }
    }

    public func favorites(page: Int = 1, pageSize: Int = 60) async throws -> Paged<MediaItem> {
        try await perform { hub in dv_hub_favorites(hub, Int32(page), Int32(pageSize)) }
    }

    // MARK: - FFI 细节

    private func json(_ query: ListQuery?) -> String {
        guard let query, let data = try? JSONEncoder().encode(query) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func queryJSON(_ query: ListQuery?) -> String { json(query) }

    /// 在核心的串行队列上跑一次调用，并把返回的 JSON 解成强类型。
    private func perform<T: Decodable>(_ body: @escaping (DVHub) -> UnsafeMutablePointer<CChar>?)
        async throws -> T {
        let text = try await raw(body)
        return try Self.decodeEnvelope(T.self, from: text)
    }

    /// 只关心 ok / error 的调用（收藏、标记看过这些没有 data）。
    private func performVoid(_ body: @escaping (DVHub) -> UnsafeMutablePointer<CChar>?)
        async throws {
        let text = try await raw(body)
        let envelope = try Self.decodeEnvelope(EnvelopeNoData.self, from: text)
        guard envelope.ok else {
            throw ApiError(envelope.error ?? "未知错误")
        }
    }

    /// 只取字符串，不解码（报错也要先拿到文本）。
    private func raw(_ body: @escaping (DVHub) -> UnsafeMutablePointer<CChar>?)
        async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let hub = self.hub else {
                    continuation.resume(throwing: ApiError("共享核心未初始化"))
                    return
                }

                guard let pointer = body(hub) else {
                    continuation.resume(throwing: ApiError("核心返回了空指针"))
                    return
                }

                let text = String(cString: pointer)
                dv_string_free(pointer)
                continuation.resume(returning: text)
            }
        }
    }

    private static func decodeEnvelope<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: Data(text.utf8))
        } catch {
            throw ApiError("核心返回的不是合法 JSON：\(text.prefix(120))")
        }

        guard envelope.ok else {
            throw ApiError(envelope.error ?? "未知错误")
        }

        guard let data = envelope.data else {
            throw ApiError("核心没有返回数据")
        }

        return data
    }
}
