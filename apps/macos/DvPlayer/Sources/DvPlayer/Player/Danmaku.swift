import Foundation
import CryptoKit

/// 一条弹幕（弹弹play 的 `<d p="…">` / v2 JSON 的 `{"p":…,"m":…}`）。
struct DanmakuComment {
    /// 出现时间（秒）。
    let time: Double
    /// 1–3 滚动，4 底部，5 顶部。
    let mode: Int
    let size: Int
    /// 0xRRGGBB。
    let color: Int
    let text: String
}

enum DanmakuError: LocalizedError {
    case notMatched
    /// 电影按片名去库里找剧场版，没找到对得上的条目。
    case noMovie
    /// 状态码 + 服务器给的 `X-Error-Message`（`Invalid AppId` 这类，没给就是空）。
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
            case .notMatched:
                return "弹弹play 没匹配到这一集"
            case .noMovie:
                return "弹弹play 库里没有这部片"
            case .http(let code, let detail):
                return detail.isEmpty
                    ? "弹弹play 返回 HTTP \(code)"
                    : "弹弹play 返回 HTTP \(code)（\(detail)）"
            case .empty:
                return "这一集没有弹幕"
        }
    }
}

/// 弹弹play 客户端（v2，AppId + 签名鉴权）。
///
/// 只做两件事：按「剧名 + 集号」找 episodeId，再取这一集的弹幕（JSON / XML 都认）。
/// 返回的弹幕最终写成 ASS，交给 mpv 当第二字幕显示（见 `DanmakuAss`）。
final class DanmakuService {
    static let shared = DanmakuService()

    private let base = ProcessInfo.processInfo.environment["DVPLAYER_DANDANPLAY_BASE"]
        ?? "https://api.dandanplay.net"
    private let session = URLSession(configuration: .ephemeral)

    /// 鉴权三件套：`X-AppId` / `X-Timestamp` / `X-Signature`。
    /// 签名 = Base64(SHA256(AppId + Timestamp + Path + AppSecret))。
    private func headers(path: String, appId: String, appSecret: String) -> [String: String] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let raw = appId + timestamp + path + appSecret
        let digest = SHA256.hash(data: Data(raw.utf8))
        let signature = Data(digest).base64EncodedString()
        return [
            "X-AppId": appId,
            "X-Timestamp": timestamp,
            "X-Signature": signature,
            "Accept": "application/json",
            "User-Agent": "DVPlayer/1.0",
        ]
    }

    /// 找这一集的 episodeId（先按集号匹配标题，再按顺序兜底）。
    func episodeId(anime: String, episode: Int,
                   appId: String, appSecret: String) async throws -> Int {
        let animes = try await search(anime: anime, episode: episode,
                                      appId: appId, appSecret: appSecret)

        for animeItem in animes {
            guard let episodes = animeItem["episodes"] as? [[String: Any]], !episodes.isEmpty else {
                continue
            }

            // 优先标题里带「第 N 话 / 集」的。
            for item in episodes {
                let title = item["episodeTitle"] as? String ?? ""
                if Self.matchesEpisode(title, episode) {
                    if let id = item["episodeId"] as? Int { return id }
                }
            }

            if episodes.indices.contains(episode - 1),
               let id = episodes[episode - 1]["episodeId"] as? Int {
                return id
            }

            if let id = episodes.first?["episodeId"] as? Int {
                return id
            }
        }

        throw DanmakuError.notMatched
    }

    /// 电影（剧场版）没有集号：按片名搜一次，只认 `type == "movie"` 且片名对得上的条目。
    ///
    /// 结果里常有同名 TV 动画（搜「进击的巨人」会带出「进击的巨人 剧场版」），
    /// 挂错弹幕比没有更糟，所以片名不是完全对得上就放弃。
    func movieEpisodeId(title: String, appId: String, appSecret: String) async throws -> Int? {
        let animes = try await search(anime: title, episode: 1,
                                      appId: appId, appSecret: appSecret)
        let wanted = Self.normalized(title)

        for animeItem in animes where (animeItem["type"] as? String) == "movie" {
            let name = Self.normalized(animeItem["animeTitle"] as? String ?? "")
            guard name == wanted else { continue }
            if let episodes = animeItem["episodes"] as? [[String: Any]],
               let id = episodes.first?["episodeId"] as? Int {
                return id
            }
        }

        return nil
    }

    /// 片名比对：去掉空白和标点再比，全半角 / 空格差异不影响。
    private static func normalized(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func search(anime: String, episode: Int,
                        appId: String, appSecret: String) async throws -> [[String: Any]] {
        var components = URLComponents(string: base + "/api/v2/search/episodes")!
        components.queryItems = [
            URLQueryItem(name: "anime", value: anime),
            URLQueryItem(name: "episode", value: String(episode)),
        ]

        let path = "/api/v2/search/episodes"
        var request = URLRequest(url: components.url!)
        for (key, value) in headers(path: path, appId: appId, appSecret: appSecret) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanmakuError.notMatched }
        guard http.statusCode == 200 else {
            throw DanmakuError.http(http.statusCode,
                                    http.value(forHTTPHeaderField: "X-Error-Message") ?? "")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let animes = root["animes"] as? [[String: Any]] else {
            throw DanmakuError.notMatched
        }

        return animes
    }

    /// 标题里是不是这一集：「第1」不能命中「第10」，数字后面还是数字就不算。
    /// 也兼容「第 1 集」这种中间带空格的写法。
    private static func matchesEpisode(_ title: String, _ episode: Int) -> Bool {
        let number = String(episode)
        for prefix in ["第", "第 "] {
            let needle = prefix + number
            var searchRange = title.startIndex..<title.endIndex
            while let range = title.range(of: needle, range: searchRange) {
                if range.upperBound == title.endIndex ||
                    !title[range.upperBound].isNumber {
                    return true
                }
                searchRange = range.upperBound..<title.endIndex
            }
        }
        return false
    }

    /// 取一集的弹幕并解析。
    func comments(episodeId: Int,
                  appId: String, appSecret: String) async throws -> [DanmakuComment] {
        let path = "/api/v2/comment/\(episodeId)"
        var components = URLComponents(string: base + path)!
        components.queryItems = [
            URLQueryItem(name: "withRelated", value: "true"),
            URLQueryItem(name: "chConvert", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        for (key, value) in headers(path: path, appId: appId, appSecret: appSecret) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanmakuError.empty }
        guard http.statusCode == 200 else {
            throw DanmakuError.http(http.statusCode,
                                    http.value(forHTTPHeaderField: "X-Error-Message") ?? "")
        }

        let comments = DanmakuParser.parse(data)
        guard !comments.isEmpty else { throw DanmakuError.empty }
        return comments
    }
}

/// 弹幕体解析。
///
/// 弹弹play v2 的 `/api/v2/comment` 现在只回 JSON
/// （`{"count":N,"comments":[{"p":"time,mode,color,uid","m":"text"}]}`），
/// 老版本回 XML（`<i><d p="time,mode,size,color,…">text</d>`）。两种都认。
///
/// 之前只认 XML，接口换成 JSON 之后解析出 0 条，表现是「这一集没有弹幕」。
enum DanmakuParser {
    static func parse(_ data: Data) -> [DanmakuComment] {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = root["comments"] as? [[String: Any]] {
            let comments = list.compactMap(comment(from:))
            if !comments.isEmpty { return comments }
        }

        // 老接口 / 缓存里可能还是 XML。
        return DanmakuXML.parse(data)
    }

    /// v2 的 `p` 只有 4 段（时间,模式,颜色,用户），没有字号。
    private static func comment(from item: [String: Any]) -> DanmakuComment? {
        guard let raw = item["p"] as? String,
              let text = (item["m"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 4,
              let time = Double(fields[0]),
              let mode = Int(fields[1]) else { return nil }

        // XML 是 8 段（时间,模式,字号,颜色,…），JSON 是 4 段（时间,模式,颜色,用户）。
        var size = 0
        var color = 0
        if fields.count >= 8 {
            guard let xmlSize = Int(fields[2]), let xmlColor = Int(fields[3]) else { return nil }
            size = xmlSize
            color = xmlColor
        } else {
            guard let jsonColor = Int(fields[2]) else { return nil }
            color = jsonColor
        }

        return DanmakuComment(time: time, mode: mode, size: size, color: color, text: text)
    }
}

/// 弹幕 XML (`<i><d p="time,mode,size,color,…">text</d>`) 解析。
enum DanmakuXML {
    static func parse(_ data: Data) -> [DanmakuComment] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.comments
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var comments: [DanmakuComment] = []
        private var currentAttributes: String?
        private var currentText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            guard elementName == "d" else { return }
            currentAttributes = attributeDict["p"]
            currentText = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard currentAttributes != nil else { return }
            currentText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard elementName == "d", let raw = currentAttributes else { return }
            currentAttributes = nil

            let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let time = Double(fields[0]),
                  let mode = Int(fields[1]),
                  let size = Int(fields[2]),
                  let color = Int(fields[3]) else { return }

            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            comments.append(DanmakuComment(time: time, mode: mode, size: size,
                                           color: color, text: text))
        }
    }
}

/// 弹幕 → ASS。滚动 / 顶部 / 底部三种，按行错开，避免同一秒叠在一起。
enum DanmakuAss {
    static let width = 1920.0
    static let height = 1080.0
    private static let fontName = "PingFang SC"

    /// 写进缓存目录，返回文件路径。同一个 episodeId 第二次直接用缓存。
    static func write(comments: [DanmakuComment], episodeId: Int) -> URL? {
        let folder = cacheFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("DVPlayer-danmaku-\(episodeId).ass")

        let text = build(comments)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("[Danmaku] 写 ASS 失败：\(error.localizedDescription)")
            return nil
        }
    }

    static var cacheFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DvPlayer/danmaku", isDirectory: true)
    }

    static func build(_ comments: [DanmakuComment]) -> String {
        var lines: [String] = [
            "[Script Info]",
            "ScriptType: v4.00+",
            "PlayResX: \(Int(width))",
            "PlayResY: \(Int(height))",
            "WrapStyle: 2",
            "ScaledBorderAndShadow: yes",
            "",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: DM,\(fontName),48,&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,7,0,0,0,1",
            "",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
        ]

        let sorted = comments.sorted { $0.time < $1.time }.prefix(3000)
        let lineHeight = 62.0
        let laneCount = max(1, Int((height - 120) / lineHeight))
        var scrollFree = [Double](repeating: 0, count: laneCount)
        var topFree = [Double](repeating: 0, count: laneCount / 2)
        var bottomFree = [Double](repeating: 0, count: laneCount / 2)

        for comment in sorted {
            let text = sanitize(comment.text)
            guard !text.isEmpty else { continue }

            let size = comment.size > 0 ? min(64, max(28, comment.size * 2)) : 48
            let color = assColor(comment.color)
            let start = max(0, comment.time)

            switch comment.mode {
                case 4, 5:
                    // 顶部 / 底部：固定 4 秒，占一行。
                    let isTop = comment.mode == 5
                    var free = isTop ? topFree : bottomFree
                    let lane = free.firstIndex { $0 <= start } ?? 0
                    let y = 40 + Double(lane) * lineHeight
                    free[lane] = start + 4
                    if isTop { topFree = free } else { bottomFree = free }

                    let position = isTop
                        ? "{\\an8\\pos(\(Int(width / 2)),\(Int(y)))}"
                        : "{\\an2\\pos(\(Int(width / 2)),\(Int(height - y)))}"
                    lines.append(dialogue(start: start, end: start + 4,
                                          text: position + text,
                                          size: size, color: color))

                default:
                    // 滚动：9 秒从右到左；估算文字宽度，排队等前面的让出位置。
                    let textWidth = Double(text.count) * Double(size) * 0.95
                    let duration = 9.0
                    let lane = scrollFree.firstIndex { $0 <= start } ?? 0
                    let y = 30 + Double(lane) * lineHeight
                    scrollFree[lane] = start + duration * 0.45

                    let x1 = width
                    let x2 = -textWidth
                    let effect = "{\\move(\(Int(x1)),\(Int(y)),\(Int(x2)),\(Int(y)))}"
                    lines.append(dialogue(start: start, end: start + duration,
                                          text: effect + text,
                                          size: size, color: color))
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func dialogue(start: Double, end: Double, text: String,
                                 size: Int, color: String) -> String {
        "Dialogue: 0,\(timestamp(start)),\(timestamp(end)),DM,,0,0,0,,"
            + "{\\fs\(size)\\c\(color)}" + text
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = Int(total) % 3600 / 60
        let secs = total - Double(Int(total))
        return String(format: "%d:%02d:%05.2f", hours, minutes, Double(Int(total) % 60) + secs)
    }

    /// ASS 颜色是 `&HAABBGGRR`。
    private static func assColor(_ rgb: Int) -> String {
        let r = (rgb >> 16) & 0xFF
        let g = (rgb >> 8) & 0xFF
        let b = rgb & 0xFF
        return String(format: "&H00%02X%02X%02X&", b, g, r)
    }

    /// ASS 的 `{}` 是样式指令，`\` 是转义符；弹幕文本里全换成全角 / 空格。
    private static func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "{", with: "｛")
            .replacingOccurrences(of: "}", with: "｝")
            .replacingOccurrences(of: "\\", with: "／")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
