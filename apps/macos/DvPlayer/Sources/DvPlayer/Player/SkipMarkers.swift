import Foundation
import DvCore

/// 一部剧的片头 / 片尾标记（手动标记，按剧记忆）。
///
/// 时间都是**绝对秒数**：`introEnd` 是片头结束（从这往后正常看），
/// `outroStart` 是片尾开始（到这提示「跳过片尾」）。
struct SkipMarker: Codable, Equatable {
    var introEnd: Double?
    var outroStart: Double?

    var isEmpty: Bool { introEnd == nil && outroStart == nil }
}

/// 标记的本地存储：`~/Library/Application Support/DvPlayer/skip-markers.json`。
///
/// 键是剧名（`PlayerSession.seriesTitle`），电影用条目 id。和 Windows 端同一套
/// 「按剧记忆」的思路，将来搬进共享核心时这个文件格式可以直接照抄。
enum SkipMarkerStore {
    static var fileURL: URL {
        AppSettings.directory.appendingPathComponent("skip-markers.json")
    }

    static func load() -> [String: SkipMarker] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SkipMarker].self, from: data)) ?? [:]
    }

    static func marker(for key: String) -> SkipMarker {
        load()[key] ?? SkipMarker()
    }

    static func save(_ marker: SkipMarker, for key: String) {
        var all = load()
        if marker.isEmpty {
            all.removeValue(forKey: key)
        } else {
            all[key] = marker
        }

        do {
            try FileManager.default.createDirectory(at: AppSettings.directory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Play] 写入片头片尾标记失败：\(error.localizedDescription)")
        }
    }
}
