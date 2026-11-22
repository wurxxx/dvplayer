import Foundation
import DvCore

/// 详情页的短期缓存。
///
/// 飞牛的 `/item/list` 在同一台机器上实测 0.5–3 秒（服务端波动，
/// 和 page_size 不完全成正比）。同一部片来回进时不该每次都等，
/// 这里缓存「详情 + 演职人员 + 季 + 当前季的集」两分钟。
///
/// 只放在内存里；收藏 / 标记看过之后会主动 `drop`，避免状态过期。
@MainActor
final class DetailCache {
    static let shared = DetailCache()

    struct Snapshot {
        let detail: MediaDetail
        let people: [Person]
        let seasons: [MediaItem]
        let seasonId: String?
        let episodes: [EpisodeRow]
        /// 这一季服务器说有多少集；首屏可能只拿了一页。
        let total: Int
        let at: Date
    }

    private var items: [String: Snapshot] = [:]
    private let ttl: TimeInterval = 120
    /// 内存里最多留多少部片的详情：来回翻也不会一直涨。
    private let limit = 20

    func get(_ id: String) -> Snapshot? {
        guard let snapshot = items[id] else { return nil }
        guard Date().timeIntervalSince(snapshot.at) < ttl else {
            // 过期项顺手删掉；否则逛过的每一部片都留在内存里，永不释放。
            items[id] = nil
            return nil
        }
        return snapshot
    }

    func put(_ id: String, _ snapshot: Snapshot) {
        let now = Date()
        // 先清过期项，再按最旧淘汰，把总数压回上限。
        items = items.filter { now.timeIntervalSince($0.value.at) < ttl }
        items[id] = snapshot

        while items.count > limit {
            guard let oldest = items.min(by: { $0.value.at < $1.value.at })?.key else {
                break
            }
            items[oldest] = nil
        }
    }

    func drop(_ id: String) {
        items[id] = nil
    }
}
