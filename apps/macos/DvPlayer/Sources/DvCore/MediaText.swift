import Foundation

/// 标题、时长这些「到处都在用」的小工具，和 Windows 的 `Services/MediaText.cs` 对齐。
public enum MediaText {
    /// 「异能寻生机（76集） - SKIT」→「异能寻生机」。
    public static func clean(_ title: String?) -> String {
        guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "(未命名)"
        }

        var text = raw.replacingOccurrences(of: #"\s+-\s+[A-Za-z0-9@]+$"#,
                                            with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*[（(]\s*\d{1,4}\s*集\s*[)）]"#,
                                         with: "", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    /// 去掉视频扩展名。
    public static func trimExtension(_ title: String) -> String {
        guard let dot = title.lastIndex(of: ".") else { return title }
        return dot > title.startIndex && title.distance(from: dot, to: title.endIndex) <= 5
            ? String(title[title.startIndex..<dot])
            : title
    }

    /// 从文件名反推剧名：「某剧 - S01E03.mp4」→「某剧」。
    /// 未刮削的目录只有文件名，分组时把集号那截去掉才好归到一起。
    public static func seriesTitle(from title: String) -> String {
        var text = trimExtension(title)
        for pattern in [#"\s*[-—_·]\s*[Ss]\d{1,2}\s*[Ee]\d{1,4}.*$"#,
                        #"\s*[-—_·]\s*[Ee][Pp]?\s*\d{1,4}.*$"#,
                        #"\s*第\s*\d{1,4}\s*[集话].*$"#,
                        #"\s*\[\d{1,4}\]\s*$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let cleaned = clean(text)
        return cleaned.isEmpty ? clean(title) : cleaned
    }

    /// 标题看起来是「剧名 + 集号」这样的文件名。
    public static func looksLikeFileName(_ title: String) -> Bool {
        let patterns = [
            #"[Ss]\d{1,2}\s*[Ee]\d{1,4}"#,
            #"^[Ee][Pp]?\s*\d{1,4}$"#,
            #"^第\s*\d{1,4}\s*集$"#,
            #"^\[\d{1,4}\]"#,
        ]
        return patterns.contains { title.range(of: $0, options: .regularExpression) != nil }
    }

    /// 秒 → `H:MM:SS` / `M:SS`。
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// 集号角标：「S01E03」/「E03」，没有集号就不显示。
    public static func badge(season: Int?, episode: Int?) -> String? {
        guard let episode, episode > 0 else { return nil }
        if let season, season > 0 {
            return String(format: "S%02dE%02d", season, episode)
        }
        return String(format: "E%02d", episode)
    }

    /// 「1 小时 44 分钟」这种时长说明（卡片、列表用）。
    ///
    /// 列表不写 `1:44`——那是时间点，片长用中文更好读；
    /// 播放页的进度和剩余时间仍然走 `duration` 的时间码。
    public static func runtime(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = (seconds + 30) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest > 0 ? "\(hours) 小时 \(rest) 分钟" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }
}

extension MediaText {
    /// 类型的中文名。
    public static func kindLabel(_ kind: String) -> String {
        switch kind.lowercased() {
        case "movie": return "电影"
        case "series", "tv": return "剧集"
        case "season": return "季"
        case "episode": return "单集"
        case "folder": return "目录"
        case "video": return "视频"
        default: return kind
        }
    }

    /// 源类型的中文名。
    public static func sourceKindLabel(_ kind: String) -> String {
        switch kind.lowercased() {
        case "fnos": return "飞牛影视"
        case "emby": return "Emby"
        case "jellyfin": return "Jellyfin"
        case "plex": return "Plex"
        case "local": return "本地文件夹"
        case "smb", "cifs": return "SMB"
        case "nfs": return "NFS"
        case "webdav": return "WebDAV"
        case "directory": return "本地目录"
        default: return kind
        }
    }

    /// 比特率：「24.6 Mbps」。
    public static func bitRate(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        if value >= 1_000_000_000 {
            return String(format: "%.2f Gbps", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f kbps", Double(value) / 1_000)
        }
        return "\(value) bps"
    }

    /// 卡片副标题：「剧集 · 12 集 · 2 季」。
    public static func describe(_ item: MediaItem) -> String {
        var parts = [kindLabel(item.kind)]

        if let episodes = item.episodeCount ?? item.localEpisodeCount, episodes > 0 {
            parts.append("\(episodes) 集")
        } else if let runtime = MediaText.runtime(item.runtimeSeconds) {
            parts.append(runtime)
        }

        // 季数只对剧集本身有意义；单集也带着 5 季这种字段，别显示。
        if item.kind.lowercased() == "series" || item.kind.lowercased() == "tv",
           let seasons = item.seasonCount, seasons > 1 {
            parts.append("\(seasons) 季")
        }

        return parts.joined(separator: " · ")
    }
}
