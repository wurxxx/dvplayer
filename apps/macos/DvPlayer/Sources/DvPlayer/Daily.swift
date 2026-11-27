import AppKit
import Foundation
import SwiftUI
import DvCore

// MARK: - 模型

/// 每日推荐里的一条：来自 TMDB 或豆瓣的热门条目。
struct DailyItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var year: Int?
    /// movie / tv
    var kind: String
    var rating: Double?
    var poster: String?
    var overview: String?
    /// 只有 TMDB 条目有，订阅时优先用它。
    var tmdbId: Int?
    /// TMDB / 豆瓣
    var trend: String
    /// 豆瓣条目页，点「来源」时打开。
    var link: String?

    /// 匹配到的媒体源条目 id（有就直接进详情）。
    var matchedItemId: String?
    var matchedTitle: String?
    /// 已经推到 MoviePilot。
    var subscribed: Bool?

    var isSeries: Bool { kind.lowercased() == "tv" }

    /// 去重用：标题归一化 + 电影 / 剧集。
    var matchKey: String {
        Self.normalize(title) + (isSeries ? "#tv" : "#movie")
    }

    /// 归一化：去括号内容、季数、空白、标点。
    ///
    /// 各服务器的标题有的带「（2026）」「第 2 季」「：」全半角混用，
    /// 不归一化的话同一个片会对不上。
    static func normalize(_ text: String) -> String {
        var value = text.lowercased()
        value = value.replacingOccurrences(
            of: "[\\(（\\[【].*?[\\)）\\]】]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: "第[0-9一二三四五六七八九十]+[季部]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(
            of: "[\\s\\p{P}\\p{S}]+", with: "", options: .regularExpression)
        return value
    }
}

/// 一天一份，缓存到 `daily.json`。
struct DailyFeed: Codable, Sendable {
    var date: String
    var fetchedAt: Date
    var items: [DailyItem]
    var tmdbError: String?
    var doubanError: String?
}

enum DailyError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 推荐条目的资料。媒体源里没有的条目点开时，用豆瓣 / TMDB 的数据撑起
/// 一个和媒体详情页同结构的页面：先看清楚，再决定要不要订阅。
struct DailyDetailInfo: Sendable, Equatable {
    var title: String
    var originalTitle: String?
    var year: Int?
    var isSeries: Bool
    var rating: Double?
    var ratingCount: Int?
    var genres: [String] = []
    var countries: [String] = []
    /// 「166 分钟」「45 分钟/集」。
    var runtime: String?
    /// 剧集总集数。
    var episodes: Int?
    var overview: String?
    var directors: [String] = []
    var cast: [String] = []
    var poster: String?
    var backdrop: String?
    var doubanURL: String?
    var tmdbURL: String?
    var imdbURL: String?
}

// MARK: - 抓取

enum DailyAPI {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

    // MARK: TMDB

    static func tmdb(apiKey: String, proxy: String?) async throws -> [DailyItem] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/trending/all/day")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "zh-CN"),
        ]
        // TMDB 走外网，超时给短一点：不通时别让豆瓣的数据跟着等 25 秒。
        let root = try await json(components.url!, timeout: 10, proxy: proxy)
        guard let object = root as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            throw DailyError.message("TMDB 返回格式不对")
        }

        return results.compactMap { result in
            let mediaType = result["media_type"] as? String ?? ""
            guard mediaType == "movie" || mediaType == "tv" else { return nil }

            let title = firstString(result, ["title", "name", "original_title", "original_name"])
            guard !title.isEmpty, let id = (result["id"] as? NSNumber)?.intValue else { return nil }

            let date = firstString(result, ["release_date", "first_air_date"])
            let year = Int(date.prefix(4))
            let posterPath = result["poster_path"] as? String
            return DailyItem(
                id: "tmdb:\(mediaType):\(id)",
                title: title,
                year: year,
                kind: mediaType,
                rating: (result["vote_average"] as? NSNumber)?.doubleValue,
                poster: posterPath.map { "https://image.tmdb.org/t/p/w500\($0)" },
                overview: result["overview"] as? String,
                tmdbId: id,
                trend: "TMDB",
                link: nil,
                matchedItemId: nil,
                matchedTitle: nil,
                subscribed: nil)
        }
    }

    // MARK: 豆瓣

    /// 豆瓣没有公开 API，但移动端的 `/j/search_subjects` 一直能返回热门列表。
    /// 必须带桌面 UA + Referer，否则会被判成爬虫（418）。
    static func douban(type: String) async throws -> [DailyItem] {
        var components = URLComponents(string: "https://movie.douban.com/j/search_subjects")!
        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "tag", value: "热门"),
            URLQueryItem(name: "page_limit", value: "30"),
            URLQueryItem(name: "page_start", value: "0"),
        ]
        let root = try await json(components.url!, referer: "https://movie.douban.com/")
        guard let object = root as? [String: Any],
              let subjects = object["subjects"] as? [[String: Any]] else {
            throw DailyError.message("豆瓣返回格式不对")
        }

        return subjects.compactMap { subject in
            guard let doubanId = subject["id"] as? String, !doubanId.isEmpty else { return nil }
            let title = (subject["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }

            // 剧集接口的 `episodes_info` 是「更新至16集」，非空基本就是剧。
            let episodes = subject["episodes_info"] as? String ?? ""
            let isTv = type == "tv" || !episodes.isEmpty
            let rate = Double(subject["rate"] as? String ?? "")
            return DailyItem(
                id: "douban:\(isTv ? "tv" : "movie"):\(doubanId)",
                title: title,
                year: nil,
                kind: isTv ? "tv" : "movie",
                rating: rate,
                poster: subject["cover"] as? String,
                overview: nil,
                tmdbId: nil,
                trend: "豆瓣",
                link: subject["url"] as? String,
                matchedItemId: nil,
                matchedTitle: nil,
                subscribed: nil)
        }
    }

    // MARK: 条目详情

    /// 拉一条推荐条目的资料。豆瓣走 rexxar 接口，TMDB 走详情接口；
    /// 拿不到时至少把列表里已有的信息填上，页面不会空着。
    static func detail(for item: DailyItem, settings: AppSettings) async throws -> DailyDetailInfo {
        if item.id.hasPrefix("douban:") {
            return try await doubanDetail(item)
        }

        let key = settings.tmdbApiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return baseInfo(item) }
        return try await tmdbDetail(item, apiKey: key, proxy: settings.tmdbProxy)
    }

    /// 列表里已有的信息：详情接口失败时兜底。
    static func baseInfo(_ item: DailyItem) -> DailyDetailInfo {
        DailyDetailInfo(
            title: item.title,
            year: item.year,
            isSeries: item.isSeries,
            rating: item.rating,
            overview: item.overview,
            poster: item.poster,
            doubanURL: item.id.hasPrefix("douban:") ? item.link : nil,
            tmdbURL: item.tmdbId.map {
                "https://www.themoviedb.org/\(item.isSeries ? "tv" : "movie")/\($0)"
            })
    }

    /// 豆瓣移动端条目接口。没公开文档，但一直能返回完整资料。
    /// 和列表接口一样必须带桌面 UA + Referer。
    private static func doubanDetail(_ item: DailyItem) async throws -> DailyDetailInfo {
        let parts = item.id.split(separator: ":").map(String.init)
        guard parts.count == 3, let id = parts.last else {
            throw DailyError.message("豆瓣条目 id 不对")
        }
        let type = item.isSeries ? "tv" : "movie"
        var components = URLComponents(
            string: "https://m.douban.com/rexxar/api/v2/\(type)/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "ck", value: ""),
            URLQueryItem(name: "for_mobile", value: "1"),
        ]

        let root = try await json(components.url!,
                                  referer: "https://m.douban.com/", timeout: 12)
        guard let object = root as? [String: Any] else {
            throw DailyError.message("豆瓣返回格式不对")
        }

        var info = baseInfo(item)
        info.title = firstString(object, ["title"], fallback: item.title)
        info.originalTitle = firstString(object, ["original_title"], fallback: "")
        if let raw = object["year"] as? String ?? (object["year"] as? NSNumber)?.stringValue,
           let year = Int(raw.prefix(4)) {
            info.year = year
        }
        // 剧集接口里 `is_tv` 才是准的：列表接口有时会把剧当电影。
        if let isTv = object["is_tv"] as? Bool {
            info.isSeries = isTv
        }
        info.overview = firstString(object, ["intro"], fallback: info.overview ?? "")
        if let rating = object["rating"] as? [String: Any] {
            let value = (rating["value"] as? NSNumber)?.doubleValue ?? 0
            info.rating = value > 0 ? value : info.rating
            info.ratingCount = (rating["count"] as? NSNumber)?.intValue
        }
        info.genres = strings(object["genres"])
        info.countries = strings(object["countries"])
        info.runtime = strings(object["durations"]).joined(separator: " / ")
        if info.runtime?.isEmpty == true { info.runtime = nil }
        let episodes = (object["episodes_count"] as? NSNumber)?.intValue ?? 0
        info.episodes = episodes > 0 ? episodes : nil
        info.cast = names(object["actors"])
        info.directors = names(object["directors"])
        info.poster = firstString(object, ["cover_url"], fallback: info.poster ?? "")
        if info.poster?.isEmpty == true { info.poster = item.poster }
        info.doubanURL = firstString(object, ["url"], fallback: item.link ?? "")
        if info.doubanURL?.isEmpty == true { info.doubanURL = nil }
        return info
    }

    /// TMDB 详情：制片国家是英文名，够用；演职人员按片方排序取前几位。
    private static func tmdbDetail(_ item: DailyItem, apiKey: String, proxy: String?)
        async throws -> DailyDetailInfo {
        guard let tmdbId = item.tmdbId else { return baseInfo(item) }
        let media = item.isSeries ? "tv" : "movie"
        var components = URLComponents(
            string: "https://api.themoviedb.org/3/\(media)/\(tmdbId)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "append_to_response", value: "credits,external_ids"),
        ]

        let root = try await json(components.url!, timeout: 12, proxy: proxy)
        guard let object = root as? [String: Any] else {
            throw DailyError.message("TMDB 返回格式不对")
        }

        var info = baseInfo(item)
        info.title = firstString(object, ["title", "name"], fallback: item.title)
        info.originalTitle = firstString(object, ["original_title", "original_name"],
                                         fallback: "")
        let date = firstString(object, ["release_date", "first_air_date"], fallback: "")
        if let year = Int(date.prefix(4)) { info.year = year }
        info.overview = firstString(object, ["overview"], fallback: info.overview ?? "")
        if let vote = (object["vote_average"] as? NSNumber)?.doubleValue, vote > 0 {
            info.rating = vote
        }
        info.ratingCount = (object["vote_count"] as? NSNumber)?.intValue
        info.genres = names(object["genres"])
        info.countries = names(object["production_countries"])

        let movieRuntime = (object["runtime"] as? NSNumber)?.intValue ?? 0
        let episodeRuntime = ((object["episode_run_time"] as? [Any])?
            .compactMap { ($0 as? NSNumber)?.intValue } ?? []).first ?? 0
        let episodes = (object["number_of_episodes"] as? NSNumber)?.intValue ?? 0
        if info.isSeries {
            if episodeRuntime > 0 { info.runtime = "\(episodeRuntime) 分钟/集" }
            info.episodes = episodes > 0 ? episodes : nil
        } else if movieRuntime > 0 {
            info.runtime = "\(movieRuntime) 分钟"
        }

        if let credits = object["credits"] as? [String: Any] {
            info.cast = Array(names(credits["cast"]).prefix(10))
            let directors = (credits["crew"] as? [[String: Any]] ?? []).filter {
                ($0["job"] as? String) == "Director"
            }
            info.directors = Array(names(directors).prefix(4))
        }
        if let external = object["external_ids"] as? [String: Any],
           let imdb = external["imdb_id"] as? String, !imdb.isEmpty {
            info.imdbURL = "https://www.imdb.com/title/\(imdb)/"
        }
        if let path = object["poster_path"] as? String, !path.isEmpty {
            info.poster = "https://image.tmdb.org/t/p/w500\(path)"
        }
        if let path = object["backdrop_path"] as? String, !path.isEmpty {
            info.backdrop = "https://image.tmdb.org/t/p/w1280\(path)"
        }
        return info
    }

    private static func strings(_ raw: Any?) -> [String] {
        switch raw {
        case let list as [String]:
            return list.filter { !$0.isEmpty }
        case let list as [Any]:
            return list.compactMap { $0 as? String }.filter { !$0.isEmpty }
        case let text as String:
            return text.isEmpty ? [] : [text]
        default:
            return []
        }
    }

    /// `[{"name": "…"}]` 这种结构里的名字。
    private static func names(_ raw: Any?) -> [String] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: MoviePilot

    /// 推一条订阅。返回服务器的提示文本（成功 / 已在订阅里都算成功）。
    static func subscribe(_ item: DailyItem, base rawBase: String, token rawToken: String) async throws -> String {
        var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !token.isEmpty else {
            throw DailyError.message("先在设置里填 MoviePilot 地址和 API Token")
        }
        if !base.lowercased().hasPrefix("http") {
            base = "https://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }

        guard var components = URLComponents(string: base + "/api/v1/subscribe/") else {
            throw DailyError.message("MoviePilot 地址不对：\(base)")
        }
        // MoviePilot 的 v1 接口只认 `?apikey=`（API Token）。
        // 不要同时带 `Authorization: Bearer`：那会被当成登录令牌校验，反而 403。
        components.queryItems = [URLQueryItem(name: "apikey", value: token)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "name": item.title,
            "type": item.isSeries ? "电视剧" : "电影",
            "season": 0,
        ]
        if let year = item.year { body["year"] = String(year) }
        if let tmdbId = item.tmdbId { body["tmdbid"] = tmdbId }
        // 豆瓣条目带上豆瓣 id：没填 TMDB Key 时 MoviePilot 也能按豆瓣识别。
        if item.id.hasPrefix("douban:"),
           let doubanId = item.id.split(separator: ":").last.map(String.init) {
            body["doubanid"] = doubanId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await directSession.data(for: request)
        let http = response as? HTTPURLResponse
        let text = String(data: data, encoding: .utf8) ?? ""
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let serverMessage = (object?["message"] as? String)
            ?? (object?["detail"] as? String)
            ?? ""

        guard let http else { throw DailyError.message("MoviePilot 没有响应") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DailyError.message("MoviePilot 认证失败，检查 API Token")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DailyError.message("MoviePilot HTTP \(http.statusCode) \(serverMessage.isEmpty ? String(text.prefix(120)) : serverMessage)")
        }
        if let success = object?["success"] as? Bool, !success {
            var message = serverMessage.isEmpty ? "MoviePilot 拒绝了这次订阅" : serverMessage
            if item.tmdbId == nil, message.contains("未识别") {
                message += "（豆瓣条目没有 TMDB id；填上 TMDB API Key 后用 TMDB 的条目订阅）"
            }
            throw DailyError.message(message)
        }
        return serverMessage
    }

    /// 连通性自检：只发一个只读请求，确认地址和 Token 能过认证。
    /// 不同 MoviePilot 版本的返回码不完全一致，所以 404 也当作「能连上」，
    /// 真正的订阅结果以推荐页里点一次为准。
    static func checkPilot(base rawBase: String, token rawToken: String) async throws -> String {
        var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !token.isEmpty else {
            throw DailyError.message("先填地址和 API Token")
        }
        if !base.lowercased().hasPrefix("http") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }

        guard var components = URLComponents(string: base + "/api/v1/subscribe/") else {
            throw DailyError.message("地址格式不对：\(base)")
        }
        components.queryItems = [URLQueryItem(name: "apikey", value: token)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DailyError.message("MoviePilot 没有响应")
        }
        switch http.statusCode {
        case 200..<300:
            return "连接正常，API Token 有效"
        case 401, 403:
            throw DailyError.message("认证失败：检查 API Token")
        case 404:
            return "地址能连上（订阅接口未找到，可能是很老的版本）"
        default:
            throw DailyError.message("HTTP \(http.statusCode)")
        }
    }

    // MARK: 公共

    private static func json(_ url: URL, referer: String? = nil, timeout: TimeInterval = 25,
                            proxy: String? = nil) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await session(proxy: proxy).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DailyError.message("没有响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw DailyError.message("HTTP \(http.statusCode) \(text)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// MoviePilot 一般在内网：固定直连，不跟随系统代理。
    private static let directSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    /// TMDB 专用会话：填了代理就按代理走，留空跟随系统。
    ///
    /// URLSession 不能按请求换代理，只能换一个 `URLSessionConfiguration`。
    /// 这里不缓存会话：一次抓取只有一次 API 请求，海报另走自己的会话。
    static func session(proxy: String?) -> URLSession {
        guard let proxy = parseProxy(proxy) else { return .shared }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        var dict: [AnyHashable: Any] = [:]
        if proxy.socks {
            dict["SOCKSEnable"] = 1
            dict["SOCKSProxy"] = proxy.host
            dict["SOCKSPort"] = proxy.port
        } else {
            dict["HTTPEnable"] = 1
            dict["HTTPProxy"] = proxy.host
            dict["HTTPPort"] = proxy.port
            dict["HTTPSEnable"] = 1
            dict["HTTPSProxy"] = proxy.host
            dict["HTTPSPort"] = proxy.port
        }
        config.connectionProxyDictionary = dict
        return URLSession(configuration: config)
    }

    /// 接受 `127.0.0.1:7897` / `http://host:port` / `socks5://host:port`。
    private static func parseProxy(_ raw: String?) -> (host: String, port: Int, socks: Bool)? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        var socks = false
        if let range = value.range(of: "://") {
            let scheme = value[value.startIndex..<range.lowerBound].lowercased()
            socks = scheme.hasPrefix("socks")
            value = String(value[range.upperBound...])
        }

        let parts = value.split(separator: ":")
        guard let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count > 1 ? Int(parts[1]) ?? 7897 : 7897
        return (String(host), port, socks)
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func firstString(_ object: [String: Any], _ keys: [String],
                                   fallback: String) -> String {
        let value = firstString(object, keys)
        return value.isEmpty ? fallback : value
    }
}

// MARK: - 状态

/// 详情按条目缓存：来回进出详情页不用反复请求。
///
/// 进程内内存缓存，不落盘：豆瓣 / TMDB 的资料会变，重启后重新取一次。
actor DailyDetailCache {
    static let shared = DailyDetailCache()

    private var items: [String: DailyDetailInfo] = [:]

    func value(for id: String) -> DailyDetailInfo? { items[id] }

    func save(_ info: DailyDetailInfo, for id: String) { items[id] = info }
}

/// 每日推荐：抓取 → 缓存 → 匹配媒体源 → 订阅 MoviePilot。
///
/// 抓取和匹配都在后台，页面只读 `feed`。缓存按天，打开 app 时当天已经有了
/// 就直接用，不再打 TMDB / 豆瓣。
@MainActor
final class DailyStore: ObservableObject {
    static let shared = DailyStore()

    @Published private(set) var feed: DailyFeed?
    @Published private(set) var loading = false
    @Published private(set) var matching = false
    @Published private(set) var subscribing: Set<String> = []
    @Published private(set) var error: String?

    private var fetchTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    /// 已经完整匹配过一轮的数据签名：切回页面不重复搜同一批条目。
    private var completedMatchSignature = ""
    /// 抓取还没结束时传进来的核心：等结果落地后用它与媒体源匹配。
    private var pendingCore: Core?
    /// 抓取世代号：强制刷新时旧请求晚到的结果不能覆盖新的。
    private var fetchVersion = 0

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var today: String { Self.dayFormatter.string(from: Date()) }
    var items: [DailyItem] { feed?.items ?? [] }
    var movies: [DailyItem] { items.filter { !$0.isSeries } }
    var series: [DailyItem] { items.filter { $0.isSeries } }
    var fetchedAt: Date? { feed?.fetchedAt }
    var tmdbError: String? { feed?.tmdbError }

    private static var cacheURL: URL {
        AppSettings.directory.appendingPathComponent("daily.json")
    }

    init() {
        feed = Self.loadCache()
    }

    // MARK: 刷新

    func refreshIfNeeded(core: Core?, settings: AppSettings) {
        // 抓取进行中（启动时先抓、连上源后再来一次）：记下核心，抓完后匹配。
        if loading {
            if let core { pendingCore = core }
            return
        }
        if let feed, feed.date == today, !feed.items.isEmpty {
            // 今天的已经在缓存里：只补没匹配上的（上次可能源还没连上）。
            let signature = feed.items.map(\.id).joined(separator: ",")
            if core != nil, signature != completedMatchSignature {
                matchAll(core: core)
            }
            return
        }
        refresh(core: core, settings: settings, force: false)
    }

    func refresh(core: Core?, settings: AppSettings, force: Bool) {
        guard !loading else { return }
        if !force, let feed, feed.date == today, !feed.items.isEmpty { return }

        let apiKey = settings.tmdbApiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        loading = true
        error = nil
        fetchTask?.cancel()
        fetchVersion += 1
        let version = fetchVersion

        fetchTask = Task { [weak self] in
            guard let self else { return }

            async let tmdbResult = Self.loadTMDB(apiKey, proxy: settings.tmdbProxy)
            async let doubanResult = Self.loadDouban()
            let tmdb = await tmdbResult
            let douban = await doubanResult

            // 重新抓取时保留上次的匹配 / 订阅状态：同一条片不用再匹配一遍，
            // 已订阅的也不会因为刷新变成「可订阅」。
            var previous: [String: DailyItem] = [:]
            for old in self.feed?.items ?? [] {
                previous[old.matchKey] = old
            }

            var merged: [DailyItem] = []
            var seen = Set<String>()
            for var item in tmdb.items + douban.items {
                guard seen.insert(item.matchKey).inserted else { continue }
                if let old = previous[item.matchKey] {
                    item.matchedItemId = old.matchedItemId
                    item.matchedTitle = old.matchedTitle
                    item.subscribed = old.subscribed
                }
                merged.append(item)
            }

            guard version == self.fetchVersion else { return }

            let feed = DailyFeed(
                date: self.today,
                fetchedAt: Date(),
                items: merged,
                tmdbError: tmdb.error,
                doubanError: douban.error)
            self.feed = feed
            self.loading = false

            if merged.isEmpty {
                self.error = tmdb.error ?? douban.error ?? "没有取到热门资源"
            } else if apiKey.isEmpty {
                self.error = nil
            } else if let error = tmdb.error, douban.items.isEmpty {
                self.error = error
            }

            if let core { self.pendingCore = core }
            self.saveCache()
            self.completedMatchSignature = ""
            let target = self.pendingCore
            self.pendingCore = nil
            self.matchAll(core: target)
        }
    }

    private static func loadTMDB(_ apiKey: String, proxy: String?)
        async -> (items: [DailyItem], error: String?) {
        guard !apiKey.isEmpty else { return ([], nil) }
        do {
            return (try await DailyAPI.tmdb(apiKey: apiKey, proxy: proxy), nil)
        } catch {
            return ([], "TMDB：\(error.localizedDescription)")
        }
    }

    private static func loadDouban() async -> (items: [DailyItem], error: String?) {
        // 电影和剧集分开抓：一页失败不应该把另一页也丢掉。
        async let movies = DailyAPI.douban(type: "movie")
        async let series = DailyAPI.douban(type: "tv")

        var items: [DailyItem] = []
        var errors: [String] = []
        do {
            items += try await movies
        } catch {
            errors.append("电影 \(error.localizedDescription)")
        }
        do {
            items += try await series
        } catch {
            errors.append("剧集 \(error.localizedDescription)")
        }
        return (items, errors.isEmpty ? nil : "豆瓣：" + errors.joined(separator: "；"))
    }

    // MARK: 匹配媒体源

    private func matchAll(core: Core?) {
        guard let core, let feed else { return }
        let signature = feed.items.map(\.id).joined(separator: ",")
        if signature == completedMatchSignature { return }

        matchTask?.cancel()
        matching = true

        matchTask = Task { [weak self] in
            guard let self else { return }
            var current = self.feed?.items ?? []
            for index in current.indices {
                if Task.isCancelled { break }
                if current[index].matchedItemId != nil || current[index].subscribed == true { continue }
                if let matched = try? await Self.match(current[index], core: core) {
                    current[index].matchedItemId = matched.id
                    current[index].matchedTitle = matched.title
                    // 逐条发布，页面上海报一个个亮起来，不用等全部匹配完。
                    self.applyItems(current)
                }
            }
            self.matching = false
            self.completedMatchSignature = signature
            self.saveCache()
        }
    }

    private static func match(_ item: DailyItem, core: Core) async throws -> MediaItem? {
        let result = try await core.search(item.title)
        let key = DailyItem.normalize(item.title)
        guard !key.isEmpty else { return nil }

        let wantsSeries = item.isSeries
        let pool = result.items.filter { candidate in
            let kind = candidate.kind.lowercased()
            if wantsSeries {
                return kind == "series" || kind == "tv" || kind == "folder"
            }
            return kind == "movie" || kind == "folder"
        }

        let exact = pool.filter { DailyItem.normalize($0.title) == key }
        if let year = item.year {
            if let hit = exact.first(where: { candidate in
                guard let other = candidate.year else { return false }
                return abs(other - year) <= 1
            }) {
                return hit
            }
        }
        if let hit = exact.first { return hit }

        return pool.first { candidate in
            let other = DailyItem.normalize(candidate.title)
            return !other.isEmpty && (other.contains(key) || key.contains(other))
        }
    }

    // MARK: 订阅

    func subscribe(_ item: DailyItem, settings: AppSettings) async -> String {
        guard !subscribing.contains(item.id) else { return "" }
        guard let base = settings.moviePilotUrl, let token = settings.moviePilotToken,
              !base.trimmingCharacters(in: .whitespaces).isEmpty,
              !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "先在设置里填 MoviePilot 地址和 API Token"
        }

        subscribing.insert(item.id)
        defer { subscribing.remove(item.id) }

        do {
            let message = try await DailyAPI.subscribe(item, base: base, token: token)
            markSubscribed(item.id)
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "已推送到 MoviePilot" : "MoviePilot：\(trimmed)"
        } catch {
            return "订阅失败：\(error.localizedDescription)"
        }
    }

    private func markSubscribed(_ id: String) {
        guard var feed else { return }
        guard let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
        feed.items[index].subscribed = true
        self.feed = feed
        saveCache()
    }

    private func applyItems(_ items: [DailyItem]) {
        guard var feed else { return }
        feed.items = items
        self.feed = feed
    }

    // MARK: 详情

    /// 媒体源里没有的条目点开后要的资料。成功 / 失败都返回可展示的内容。
    func detail(for item: DailyItem, settings: AppSettings)
        async -> (info: DailyDetailInfo, error: String?) {
        if let cached = await DailyDetailCache.shared.value(for: item.id) {
            return (cached, nil)
        }
        do {
            let info = try await DailyAPI.detail(for: item, settings: settings)
            await DailyDetailCache.shared.save(info, for: item.id)
            return (info, nil)
        } catch {
            return (DailyAPI.baseInfo(item), error.localizedDescription)
        }
    }

    /// 同一条推荐的最新状态（比如详情页里订阅成功后回到列表）。
    func item(id: String) -> DailyItem? {
        items.first { $0.id == id }
    }

    // MARK: 缓存

    private func saveCache() {
        guard let feed else { return }
        do {
            try FileManager.default.createDirectory(
                at: AppSettings.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(feed).write(to: Self.cacheURL, options: .atomic)
        } catch {
            NSLog("[DvPlayer] 每日推荐缓存写入失败：\(error.localizedDescription)")
        }
    }

    private static func loadCache() -> DailyFeed? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(DailyFeed.self, from: data)
    }
}

// MARK: - 海报

/// 推荐海报：TMDB / 豆瓣都是公开 URL，但豆瓣要带 Referer，`AsyncImage` 用不了。
actor DailyImageCache {
    static let shared = DailyImageCache()

    private let memory = NSCache<NSString, NSImage>()

    init() {
        memory.countLimit = 80
    }

    func image(_ raw: String?, proxy: String?) async -> NSImage? {
        guard let raw, let url = URL(string: raw) else { return nil }
        if let cached = memory.object(forKey: raw as NSString) { return cached }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(DailyAPI.userAgent, forHTTPHeaderField: "User-Agent")
        if url.host?.contains("douban") == true {
            request.setValue("https://movie.douban.com/", forHTTPHeaderField: "Referer")
        }

        let session = url.host?.contains("tmdb") == true
            ? DailyAPI.session(proxy: proxy)
            : .shared
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = NSImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: raw as NSString)
        return image
    }
}

struct DailyPoster: View {
    @EnvironmentObject private var state: AppState

    let url: String?
    let title: String
    @State private var image: NSImage?

    private var proxy: String { state.settings.tmdbProxy ?? "" }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.gradient(for: url ?? title)
                Text(Palette.initial(for: title))
                    .font(.system(size: max(18, min(geo.size.width, geo.size.height) * 0.3),
                                  weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .task(id: (url ?? "") + "|" + proxy) {
            let loaded = await DailyImageCache.shared.image(url, proxy: proxy)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}
