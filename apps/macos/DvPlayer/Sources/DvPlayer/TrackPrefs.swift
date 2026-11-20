import Foundation

/// 详情页选的音轨 / 字幕，播放页照这份应用（和 Windows 的 `TrackPrefs` 对齐）。
///
/// 下标对应 `MediaInfo` 里的顺序（音频 `audios`、字幕 `subtitles`），
/// 和文件里的轨序一致，播放器再用 mpv 的 `aid` / `sid` 选轨。
/// 只在内存里记：一次运行内切集、退出播放器再进来还认这份选择。
@MainActor
enum TrackPrefs {
    /// 没选过（按服务器的默认轨）。
    private static let unset = -2

    /// 字幕「关闭」。
    static let subtitleOff = -1

    private static var map: [String: (audio: Int, subtitle: Int)] = [:]

    /// 选中的音频下标；nil = 用默认轨。
    static func audio(_ itemId: String) -> Int? {
        guard let value = map[itemId], value.audio != unset else { return nil }
        return value.audio
    }

    /// 选中的字幕下标；nil = 默认，`subtitleOff` = 关闭。
    static func subtitle(_ itemId: String) -> Int? {
        guard let value = map[itemId], value.subtitle != unset else { return nil }
        return value.subtitle
    }

    /// 语言 / 标题看起来是中文轨（`zh`、`chi`、`简中`、`中英` 这些都算）。
    static func isChinese(_ language: String?, _ title: String?) -> Bool {
        let lang = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if lang == "中文" { return true }

        if !lang.isEmpty,
           ["zh", "chi", "zho", "chs", "cht", "cmn", "yue"].contains(where: { lang.hasPrefix($0) }) {
            return true
        }

        let text = (title ?? "").lowercased()
        guard !text.isEmpty else { return false }
        return ChineseHints.contains(where: { text.contains($0) })
    }

    /// 简体字幕：`Simplified Chinese` / `简` / `chs` / `zh-CN` 都算。
    static func isSimplified(_ language: String?, _ title: String?) -> Bool {
        let text = (title ?? "").lowercased()
        let lang = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return text.contains("simplified") || text.contains("简")
            || lang.contains("hans")
            || ["chs", "cn", "zh-cn", "zh-hans"].contains(lang)
    }

    /// 繁体字幕：`Traditional Chinese` / `繁` / `cht` / `zh-TW` 都算。
    static func isTraditional(_ language: String?, _ title: String?) -> Bool {
        let text = (title ?? "").lowercased()
        let lang = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return text.contains("traditional") || text.contains("繁")
            || lang.contains("hant")
            || ["cht", "zh-tw", "zh-hk", "zh-hant"].contains(lang)
    }

    private static let ChineseHints = [
        "中文", "简体", "繁体", "简中", "繁中", "中字", "中英", "双语",
        "chinese", "mandarin", "cantonese", "chs", "cht",
    ]

    static func setAudio(_ itemId: String, _ index: Int?) {
        let current = map[itemId] ?? (unset, unset)
        map[itemId] = (index ?? unset, current.subtitle)
    }

    static func setSubtitle(_ itemId: String, _ index: Int?) {
        let current = map[itemId] ?? (unset, unset)
        map[itemId] = (current.audio, index ?? unset)
    }
}
