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

/// Dolby Vision P7 的增强层类型：`elType` 是 "fel" / "mel"。
public struct DoviProbe: Decodable, Sendable {
    public let profile: Int
    public let elType: String
    public let disableResidual: Bool
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

    /// 并行建连多个源：核心给每个源开一个线程登录，全部完成后按入参顺序返回。
    public func addMany(_ configs: [SourceConfig]) async throws -> [SourceConnection] {
        let json = String(data: try JSONEncoder().encode(configs), encoding: .utf8) ?? "[]"
        return try await perform { hub in
            json.withCString { dv_hub_add_many(hub, $0) }
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

    public func search(_ keyword: String) async throws -> SearchResult {
        try await perform { hub in keyword.withCString { dv_hub_search(hub, $0) } }
    }

    // MARK: - 详情 / 播放

    public func detail(_ itemId: String) async throws -> MediaDetail {
        try await perform { hub in itemId.withCString { dv_hub_detail(hub, $0) } }
    }

    /// 详情页「资源」：同一部片在各源的条目（第一项是该片的最佳来源）。
    public func itemSources(_ itemId: String) async throws -> [ItemSource] {
        try await perform { hub in itemId.withCString { dv_hub_item_sources(hub, $0) } }
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

    /// 播放结束 / 关窗：Emby 要 Stopped 才会把位置写进 UserData。
    public func reportStopped(_ itemId: String, position: Int, duration: Int) async throws {
        try await performVoid { hub in
            itemId.withCString {
                dv_hub_report_stopped(hub, $0, Int64(position), Int64(duration))
            }
        }
    }

    /// 退出前的最后一次上报：**同步**等它发完。
    ///
    /// `NSApp.terminate` / 关窗会直接结束进程，异步 `Task` 常常还没跑到
    /// 网络请求就被带走了（服务器位置停在旧值）。核心队列是一条独立的
    /// 串行队列，主线程在这里等最多 `timeout` 秒，不会有死锁。
    @discardableResult
    public func reportBlocking(
        _ itemId: String, position: Int, duration: Int, stopped: Bool,
        timeout: TimeInterval = 2) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            defer { done.signal() }
            guard let hub = self?.hub else { return }
            let pointer = itemId.withCString { id in
                stopped
                    ? dv_hub_report_stopped(hub, id, Int64(position), Int64(duration))
                    : dv_hub_report_progress(hub, id, Int64(position), Int64(duration))
            }
            if let pointer {
                dv_string_free(pointer)
            }
        }

        return done.wait(timeout: .now() + timeout) == .success
    }

    @discardableResult
    public func reportStoppedBlocking(
        _ itemId: String, position: Int, duration: Int, timeout: TimeInterval = 2) -> Bool {
        reportBlocking(itemId, position: position, duration: duration,
                       stopped: true, timeout: timeout)
    }

    /// 判定 Dolby Vision P7 是 FEL 还是 MEL：只读码流前缀，找到 RPU 就返回。
    ///
    /// 这个不需要 hub（url 已经带齐鉴权），单独走核心队列，省得给
    /// `dv_hub_probe_dovi` 再造一个句柄。
    public func probeDovi(
        url: String, headers: [HttpHeader], proxy: String?) async throws -> DoviProbe {
        let headersJson = (try? JSONEncoder().encode(headers))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let pointer = url.withCString { urlPointer in
                    headersJson.withCString { headersPointer in
                        (proxy ?? "").withCString { proxyPointer in
                            dv_probe_dovi(urlPointer, headersPointer, proxyPointer)
                        }
                    }
                }

                guard let pointer else {
                    continuation.resume(throwing: ApiError("核心返回了空指针"))
                    return
                }

                let text = String(cString: pointer)
                dv_string_free(pointer)
                do {
                    continuation.resume(returning:
                        try Self.decodeEnvelope(DoviProbe.self, from: text))
                } catch {
                    continuation.resume(throwing: error)
                }
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
            NSLog("[DvCore] 解码 \(T.self) 失败：\(error)")
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
