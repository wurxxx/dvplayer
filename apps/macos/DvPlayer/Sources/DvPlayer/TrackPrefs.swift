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
        return text.contains("simplified") || text.contains("简") || text.contains("簡")
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
        "中文", "简体", "繁体", "簡體", "繁體", "简中", "繁中", "中字", "中英", "双语",
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

    /// 语言码 → 中文名（`chi` → 中文、`en` → 英语）。
    /// 空 / `und` / `unknown` 返回 nil，调用方当作「这条轨没说语言」。
    static func languageName(_ language: String?) -> String? {
        let raw = (language ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }

        let key = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        if ["und", "unknown", "undetermined", "mul", "zxx", "mis"].contains(key) {
            return nil
        }

        // 服务器已经给了中文名（`中文` / `简体中文`）就直接用。
        if hasCjk(raw) { return raw }

        if let name = languageNames.first(where: { $0.code == key })?.name {
            return name
        }

        // `zh-CN` / `en-US`：主标签能认出来就用主标签。
        let primary = key.split(separator: "-").first.map(String.init) ?? key
        if primary != key, let name = languageNames.first(where: { $0.code == primary })?.name {
            return name
        }

        // 英文写法的名字（VLC 或部分服务器会给 `Chinese` / `English`）。
        if let hint = languageHints.first(where: { key.contains($0.hint) }) {
            return hint.name
        }

        return raw
    }

    private static let languageNames: [(code: String, name: String)] = [
        ("zh", "中文"), ("chi", "中文"), ("zho", "中文"), ("cmn", "中文"), ("yue", "中文"),
        ("zh-cn", "中文"), ("zh-sg", "中文"), ("zh-tw", "中文"), ("zh-hk", "中文"),
        ("zh-hans", "中文"), ("zh-hant", "中文"),
        ("en", "英语"), ("eng", "英语"),
        ("ja", "日语"), ("jpn", "日语"),
        ("ko", "韩语"), ("kor", "韩语"),
        ("fr", "法语"), ("fre", "法语"), ("fra", "法语"),
        ("de", "德语"), ("ger", "德语"), ("deu", "德语"),
        ("es", "西班牙语"), ("spa", "西班牙语"),
        ("it", "意大利语"), ("ita", "意大利语"),
        ("ru", "俄语"), ("rus", "俄语"),
        ("pt", "葡萄牙语"), ("por", "葡萄牙语"),
        ("ar", "阿拉伯语"), ("ara", "阿拉伯语"),
        ("hi", "印地语"), ("hin", "印地语"),
        ("th", "泰语"), ("tha", "泰语"),
        ("vi", "越南语"), ("vie", "越南语"),
        ("id", "印尼语"), ("ind", "印尼语"),
        ("ms", "马来语"), ("msa", "马来语"), ("may", "马来语"),
        ("tr", "土耳其语"), ("tur", "土耳其语"),
        ("pl", "波兰语"), ("pol", "波兰语"),
        ("nl", "荷兰语"), ("dut", "荷兰语"), ("nld", "荷兰语"),
        ("sv", "瑞典语"), ("swe", "瑞典语"),
        ("da", "丹麦语"), ("dan", "丹麦语"),
        ("no", "挪威语"), ("nor", "挪威语"), ("nb", "挪威语"), ("nn", "挪威语"),
        ("fi", "芬兰语"), ("fin", "芬兰语"),
        ("cs", "捷克语"), ("cze", "捷克语"), ("ces", "捷克语"),
        ("el", "希腊语"), ("gre", "希腊语"), ("ell", "希腊语"),
        ("he", "希伯来语"), ("heb", "希伯来语"),
        ("hu", "匈牙利语"), ("hun", "匈牙利语"),
        ("uk", "乌克兰语"), ("ukr", "乌克兰语"),
        ("ro", "罗马尼亚语"), ("rum", "罗马尼亚语"), ("ron", "罗马尼亚语"),
        ("fa", "波斯语"), ("per", "波斯语"), ("fas", "波斯语"),
        ("slk", "斯洛伐克语"), ("slo", "斯洛伐克语"),
        ("slv", "斯洛文尼亚语"),
        ("hrv", "克罗地亚语"), ("scr", "克罗地亚语"),
        ("srp", "塞尔维亚语"), ("scc", "塞尔维亚语"),
        ("bos", "波斯尼亚语"),
        ("bul", "保加利亚语"),
        ("mkd", "马其顿语"), ("mac", "马其顿语"),
        ("lit", "立陶宛语"), ("lav", "拉脱维亚语"), ("est", "爱沙尼亚语"),
        ("isl", "冰岛语"), ("ice", "冰岛语"),
        ("cat", "加泰罗尼亚语"), ("eus", "巴斯克语"), ("baq", "巴斯克语"),
        ("glg", "加利西亚语"),
        ("sqi", "阿尔巴尼亚语"), ("alb", "阿尔巴尼亚语"),
        ("bel", "白俄罗斯语"), ("kaz", "哈萨克语"),
        ("fil", "菲律宾语"), ("tgl", "菲律宾语"),
        ("ben", "孟加拉语"), ("tam", "泰米尔语"), ("tel", "泰卢固语"),
        ("mar", "马拉地语"), ("guj", "古吉拉特语"), ("pan", "旁遮普语"),
        ("urd", "乌尔都语"),
    ]

    private static let languageHints: [(hint: String, name: String)] = [
        ("chinese", "中文"), ("mandarin", "中文"), ("cantonese", "中文"),
        ("english", "英语"), ("japanese", "日语"), ("korean", "韩语"),
        ("french", "法语"), ("german", "德语"), ("spanish", "西班牙语"),
        ("italian", "意大利语"), ("russian", "俄语"), ("portuguese", "葡萄牙语"),
        ("arabic", "阿拉伯语"), ("hindi", "印地语"), ("thai", "泰语"),
        ("vietnamese", "越南语"), ("indonesian", "印尼语"), ("malay", "马来语"),
        ("turkish", "土耳其语"), ("polish", "波兰语"), ("dutch", "荷兰语"),
        ("swedish", "瑞典语"), ("danish", "丹麦语"), ("norwegian", "挪威语"),
        ("finnish", "芬兰语"), ("czech", "捷克语"), ("greek", "希腊语"),
        ("hebrew", "希伯来语"), ("hungarian", "匈牙利语"), ("ukrainian", "乌克兰语"),
        ("romanian", "罗马尼亚语"), ("persian", "波斯语"),
        ("slovak", "斯洛伐克语"), ("slovenian", "斯洛文尼亚语"),
        ("croatian", "克罗地亚语"), ("serbian", "塞尔维亚语"),
        ("bosnian", "波斯尼亚语"), ("bulgarian", "保加利亚语"),
        ("macedonian", "马其顿语"), ("lithuanian", "立陶宛语"),
        ("latvian", "拉脱维亚语"), ("estonian", "爱沙尼亚语"),
        ("icelandic", "冰岛语"), ("catalan", "加泰罗尼亚语"),
        ("basque", "巴斯克语"), ("galician", "加利西亚语"),
        ("albanian", "阿尔巴尼亚语"), ("belarusian", "白俄罗斯语"),
        ("kazakh", "哈萨克语"), ("filipino", "菲律宾语"), ("tagalog", "菲律宾语"),
        ("bengali", "孟加拉语"), ("tamil", "泰米尔语"), ("telugu", "泰卢固语"),
        ("marathi", "马拉地语"), ("gujarati", "古吉拉特语"),
        ("punjabi", "旁遮普语"), ("urdu", "乌尔都语"),
    ]

    private static let codecTokens = [
        "hdmv", "pgs", "subtitle", "subtitles", "subrip", "vobsub", "dvd_subtitle",
        "dvdsub", "mov_text", "webvtt", "ttml", "dvb", "ssa", "ass", "srt", "text",
    ]

    /// 标题只是容器 / 编码标签（`HDMV PGS_SUBTITLE`、`subrip`）或纯序号（`1`、`2`）时，
    /// 当作没有标题。
    static func isCodecLabel(_ title: String?) -> Bool {
        var text = (title ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }

        for token in codecTokens {
            text = text.replacingOccurrences(of: token, with: " ")
        }

        return !text.contains { $0.isLetter }
    }

    /// 去掉没意义的标题；nil = 这条字幕没有标题。
    static func cleanTitle(_ title: String?) -> String? {
        let text = (title ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty || isCodecLabel(text) ? nil : text
    }

    /// 字幕菜单 / 按钮的文案：`语言 · 标题`，缺哪个跳哪个。
    ///
    /// 两个都没有时用序号兜底（`字幕 3`）；`ordinal` 为 0
    /// （按钮、媒体信息卡这类单条展示）时只写「字幕」。
    static func subtitleLabel(language: String?, title: String?, ordinal: Int = 0) -> String {
        var lang = languageName(language)
        var text = cleanTitle(title)

        // 简繁信息从标题里提出来，显示成「中文 · 简体」。
        if isSimplified(language, title) {
            lang = "中文"
            text = "简体"
        } else if isTraditional(language, title) {
            lang = "中文"
            text = "繁体"
        } else if lang == nil && isChinese(language, title) {
            lang = "中文"
        }

        // 标题里重复了语言名（`中文` / `English`）就别再拼一遍；
        // `English SDH` 这种带别的内容的保留。
        if let current = text, let language = lang,
           current == language
            || (!current.contains(" ") && languageName(current) == language) {
            text = nil
        }

        var parts: [String] = []
        if let language = lang { parts.append(language) }
        if let current = text { parts.append(current) }
        if parts.isEmpty {
            return ordinal > 0 ? "字幕 \(ordinal)" : "未命名"
        }
        return parts.joined(separator: " · ")
    }

    /// 一批字幕：重名的追加序号（`中文 1`、`中文 2`）。
    static func subtitleLabels(_ tracks: [(language: String?, title: String?)]) -> [String] {
        var labels = tracks.enumerated().map { index, track in
            subtitleLabel(language: track.language, title: track.title, ordinal: index + 1)
        }

        var counts: [String: Int] = [:]
        for label in labels { counts[label, default: 0] += 1 }

        var seen: [String: Int] = [:]
        for index in labels.indices where (counts[labels[index]] ?? 0) > 1 {
            seen[labels[index], default: 0] += 1
            labels[index] = "\(labels[index]) \(seen[labels[index]]!)"
        }

        return labels
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
