import Foundation
import DvCore

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

    /// 详情页与播放器共用的「当前字幕」：
    /// 手动选过听手动，否则简体 → 繁体 → 任意中文 → 服务器默认 → 关闭。
    static func resolveSubtitle(_ itemId: String, _ subtitles: [SubtitleInfo]) -> Int {
        if let saved = subtitle(itemId) {
            return saved
        }

        guard !subtitles.isEmpty else { return subtitleOff }

        var simplified = -1
        var traditional = -1
        var chinese = -1
        var byDefault = -1

        for (index, item) in subtitles.enumerated() {
            if byDefault < 0 && item.isDefault == true {
                byDefault = index
            }
            if chinese < 0 && isChinese(item.language, item.title) {
                chinese = index
            }
            if simplified < 0 && isSimplified(item.language, item.title) {
                simplified = index
            }
            if traditional < 0 && isTraditional(item.language, item.title) {
                traditional = index
            }
        }

        return simplified >= 0 ? simplified
            : traditional >= 0 ? traditional
            : chinese >= 0 ? chinese
            : byDefault >= 0 ? byDefault
            : subtitleOff
    }

    /// 字幕菜单里的名字：中文轨映射成中文名，别露出 `Simplified Chinese`。
    static func subtitleName(language: String?, title: String?, codec: String? = nil) -> String {
        let title = (title ?? "").trimmingCharacters(in: .whitespaces)

        if isSimplified(language, title) { return "简体中文" }
        if isTraditional(language, title) { return "繁体中文" }

        if isChinese(language, title) {
            return hasCjk(title) ? title : "中文"
        }

        let lang = (language ?? "").trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty { return lang }

        let codec = (codec ?? "").trimmingCharacters(in: .whitespaces)
        return codec.isEmpty ? "默认" : codec
    }

    /// 音轨菜单里的名字：中文轨统一叫「中文」，别把 `chi` 露出来。
    static func audioName(language: String?, title: String?, codec: String? = nil) -> String {
        let title = (title ?? "").trimmingCharacters(in: .whitespaces)

        if isChinese(language, title) {
            return hasCjk(title) ? title : "中文"
        }

        let lang = (language ?? "").trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty { return lang }
        if !title.isEmpty { return title }

        let codec = (codec ?? "").trimmingCharacters(in: .whitespaces)
        return codec.isEmpty ? "默认" : codec
    }

    private static func hasCjk(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func setAudio(_ itemId: String, _ index: Int?) {
        let current = map[itemId] ?? (unset, unset)
        map[itemId] = (index ?? unset, current.subtitle)
    }

    static func setSubtitle(_ itemId: String, _ index: Int?) {
        let current = map[itemId] ?? (unset, unset)
        map[itemId] = (current.audio, index ?? unset)
    }
}
