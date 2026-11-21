import Foundation

/// 原盘 / 本地文件的续播点。媒体库的进度由核心回写，本地盘核心不知道，
/// 所以单独存一份：~/Library/Application Support/DvPlayer/local-progress.json。
enum LocalProgressStore {
    private struct Entry: Codable {
        var position: Double
        var duration: Double
        var updatedAt: Int
    }

    private static let lock = NSLock()
    private static var cache: [String: Entry]?

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("DvPlayer/local-progress.json")
    }

    /// 续播点；停在片尾、或者不到 5 秒的，返回 0 从头播。
    static func get(_ key: String) -> Double {
        guard !key.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }

        guard let entry = load()[key] else { return 0 }
        if entry.position < 5 || (entry.duration > 0 && entry.position >= entry.duration - 1) {
            return 0
        }
        return entry.position
    }

    static func save(_ key: String, position: Double, duration: Double) {
        guard !key.isEmpty, position > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        entries[key] = Entry(position: position,
                             duration: max(0, duration),
                             updatedAt: Int(Date().timeIntervalSince1970))
        persist(entries)
    }

    static func clear(_ key: String) {
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var entries = load()
        if entries.removeValue(forKey: key) != nil {
            persist(entries)
        }
    }

    private static func load() -> [String: Entry] {
        if let cache { return cache }

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            cache = [:]
            return cache!
        }

        cache = decoded
        return decoded
    }

    private static func persist(_ entries: [String: Entry]) {
        cache = entries

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Play] local progress save failed: \(error.localizedDescription)")
        }
    }
}
