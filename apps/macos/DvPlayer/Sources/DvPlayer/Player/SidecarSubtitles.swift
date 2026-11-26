import Foundation

/// 视频同目录的一张外挂字幕。
struct SidecarSubtitle: Hashable {
    let path: String
    /// ISO 代码（`zh-Hans` / `en`…）；认不出就是 nil。
    let language: String?
    /// 「简体」「繁体」「强制」这类补充，菜单里拼在语言后面。
    let title: String?
}

/// 找视频旁边的字幕文件，交给 mpv 一起加载。
///
/// 只按文件名配对，不读字幕内容：
/// - 位置：视频所在目录（不递归）；
/// - 扩展名：`srt` / `ass` / `ssa` / `vtt` / `sup` / `idx`；
/// - 名字：去掉分隔符后，两边互为前缀（`Movie.2024.srt` 配得上
///   `Movie.2024.1080p.mkv`），多出来的部分全是数字的不算，
///   免得 `E01.srt` 挂到 `E010.mkv` 上；
/// - 语言：从字幕名里多出来的词认（`chs` / `zh-Hans` / `简中` / `eng`…）。
enum SidecarSubtitles {
    static let extensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sup", "idx"]

    static func find(for videoPath: String) -> [SidecarSubtitle] {
        // 网络地址没有「目录」可翻；原盘的 EDL 在临时目录，也不会命中。
        guard !videoPath.contains("://") else { return [] }
        let video = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: video.path) else { return [] }

        let dir = video.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        let videoStem = video.deletingPathExtension().lastPathComponent

        return files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .filter { matches(video: videoStem,
                             subtitle: $0.deletingPathExtension().lastPathComponent) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            .map { url in
                let subStem = url.deletingPathExtension().lastPathComponent
                let extra = extraTokens(video: videoStem, subtitle: subStem)
                let meta = describe(extra)
                return SidecarSubtitle(path: url.path, language: meta.language,
                                       title: meta.title)
            }
    }

    /// 两边去掉分隔符后比较：相等，或互为前缀（前缀后不能紧跟数字）。
    static func matches(video: String, subtitle: String) -> Bool {
        let target = normalize(video)
        let candidate = normalize(subtitle)
        guard !target.isEmpty, !candidate.isEmpty else { return false }
        if target == candidate { return true }
        if candidate.hasPrefix(target) {
            return !remainderIsDigits(candidate, after: target.count)
        }
        if target.hasPrefix(candidate) {
            return !remainderIsDigits(target, after: candidate.count)
        }
        return false
    }

    /// 去掉空格 / `.` `_` `-` / 括号，只留字母、数字和汉字，统一小写。
    static func normalize(_ stem: String) -> String {
        let keep = stem.lowercased().filter { ch in
            ch.isLetter || ch.isNumber
        }
        return keep
    }

    /// 多出来的部分全是数字（`E01` → `E010`）：当作不同条目，不配对。
    /// 带字母的（`Movie.2024` → `Movie.2024.1080p`）正常配对。
    private static func remainderIsDigits(_ text: String, after count: Int) -> Bool {
        let rest = text.dropFirst(count)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }

    // MARK: - 语言

    /// 字幕名里比视频名多出来的词（`Movie.2024.chs.srt` → `["chs"]`）。
    private static func extraTokens(video: String, subtitle: String) -> [String] {
        let videoTokens = Set(tokens(video))
        return tokens(subtitle).filter { !videoTokens.contains($0) }
    }

    private static func tokens(_ stem: String) -> [String] {
        stem.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " ._-[](){}·+&,"))
            .filter { !$0.isEmpty }
    }

    private static func describe(_ extra: [String]) -> (language: String?, title: String?) {
        let words = Set(extra)
        var language: String?
        var title: String?

        // 具体到简繁的先认，最后才是笼统的 `zh`。整词比较，避免
        // `french` 里的 `en` 被当成英语。
        if !words.isDisjoint(with: ["hans", "zhcn", "zhsg", "cn", "chs", "sc", "simplified",
                                    "简体", "简中", "简", "简体中文"]) {
            language = "zh-Hans"
            title = "简体"
        } else if !words.isDisjoint(with: ["hant", "zhtw", "zhhk", "cht", "tc", "traditional",
                                           "繁体", "繁中", "繁", "繁體", "繁体中文"]) {
            language = "zh-Hant"
            title = "繁体"
        } else if !words.isDisjoint(with: ["zh", "chi", "zho", "cmn", "yue", "chinese",
                                           "mandarin", "cantonese", "中文", "中字"]) {
            language = "zh"
        } else if !words.isDisjoint(with: ["eng", "en", "english", "英语", "英文"]) {
            language = "en"
        } else if !words.isDisjoint(with: ["jpn", "ja", "japanese", "日语", "日本語", "日文"]) {
            language = "ja"
        } else if !words.isDisjoint(with: ["kor", "ko", "korean", "韩语", "한국어", "韩文"]) {
            language = "ko"
        } else if !words.isDisjoint(with: ["fre", "fra", "fr", "french", "法语"]) {
            language = "fr"
        } else if !words.isDisjoint(with: ["ger", "deu", "de", "german", "德语"]) {
            language = "de"
        } else if !words.isDisjoint(with: ["spa", "es", "spanish", "西班牙语"]) {
            language = "es"
        } else if !words.isDisjoint(with: ["ita", "it", "italian", "意大利语"]) {
            language = "it"
        } else if !words.isDisjoint(with: ["rus", "ru", "russian", "俄语"]) {
            language = "ru"
        } else if !words.isDisjoint(with: ["por", "pt", "portuguese", "葡萄牙语"]) {
            language = "pt"
        } else if !words.isDisjoint(with: ["tha", "th", "thai", "泰语"]) {
            language = "th"
        } else if !words.isDisjoint(with: ["vie", "vi", "vietnamese", "越南语"]) {
            language = "vi"
        }

        // 附加说明：强制 / SDH / CC / 双语。
        var extras: [String] = []
        if title != nil { extras.append(title!) }
        if !words.isDisjoint(with: ["forced", "强制"]) { extras.append("强制") }
        if words.contains("sdh") { extras.append("SDH") }
        if words.contains("cc") { extras.append("CC") }
        if !words.isDisjoint(with: ["双语", "中英", "bilingual"]) { extras.append("双语") }
        title = extras.isEmpty ? nil : extras.joined(separator: " · ")

        return (language, title)
    }
}
