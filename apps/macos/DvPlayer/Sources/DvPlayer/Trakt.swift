import Foundation
import DvCore

// MARK: - 凭据

/// Trakt 应用的 client id / secret。
///
/// 和弹幕凭据一样：打包时 `build.sh` 从 `~/.config/dvplayer/trakt.env` 把默认值
/// 写进 Info.plist，随包分发；设置页里填的值优先，方便用户换自己的应用。
///
/// 这个服务不需要每个用户各自申请：设备码流程里 client id 只是标明「哪个应用
/// 在请求」，token 是用户自己的。仓库和 settings.json 里都不放明文默认值。
enum TraktSettings {
    private static let lock = NSLock()
    private static var cache: (id: String, secret: String, at: Date)?

    static var clientId: String { credentials().id }
    static var clientSecret: String { credentials().secret }
    static var isConfigured: Bool { !clientId.isEmpty }

    /// 设置页改过凭据后调一下，别让 3 秒缓存继续用旧值。
    static func invalidate() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    static func credentials() -> (id: String, secret: String) {
        lock.lock()
        defer { lock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < 3 {
            return (cache.id, cache.secret)
        }
        let settings = AppSettings.load()
        let environment = ProcessInfo.processInfo.environment
        let id = trimmed(environment["DVPLAYER_TRAKT_CLIENT_ID"])
            ?? trimmed(settings.traktClientId)
            ?? plist("DVTraktClientId")
        let secret = trimmed(environment["DVPLAYER_TRAKT_CLIENT_SECRET"])
            ?? trimmed(settings.traktClientSecret)
            ?? plist("DVTraktClientSecret")
        cache = (id, secret, Date())
        return (id, secret)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func plist(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}

// MARK: - 模型

struct TraktToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var username: String?
}

/// 设备码：给用户看的 8 位码 + 轮询用的 device_code。
struct TraktDeviceCode: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: TimeInterval
    let interval: TimeInterval
}

/// Trakt 上匹配到的一条片子 / 一部剧。
struct TraktMatch: Codable, Hashable, Sendable {
    /// `movie` / `show`
    let kind: String
    let traktId: Int
    let slug: String?
    let title: String
    let year: Int?

    var webURL: URL? {
        guard let slug, !slug.isEmpty else { return nil }
        return URL(string: "https://trakt.tv/\(kind == "movie" ? "movies" : "shows")/\(slug)")
    }
}

enum TraktError: LocalizedError {
    case notConfigured
    case notLoggedIn
    case devicePending
    case deviceExpired
    case deviceDenied
    case http(Int, String)

    var errorDescription: String? {
        switch self {
            case .notConfigured:
                return "没有 Trakt 应用凭据（设置 → Trakt 里填 Client ID / Secret）"
            case .notLoggedIn:
                return "还没连接 Trakt 账号"
            case .devicePending:
                return "等待在网页上确认…"
            case .deviceExpired:
                return "设备码过期了，重新连接一次"
            case .deviceDenied:
                return "在网页上拒绝了授权"
            case .http(let code, let detail):
                return detail.isEmpty ? "Trakt 返回 \(code)" : "Trakt 返回 \(code)：\(detail)"
        }
    }
}

// MARK: - token 存储

enum TraktTokenStore {
    static var fileURL: URL {
        AppSettings.directory.appendingPathComponent("trakt.json")
    }

    static func load() -> TraktToken? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(TraktToken.self, from: data)
    }

    static func save(_ token: TraktToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let directory = AppSettings.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        // token 等价于账号密码：只让当前用户读。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 客户端

/// Trakt v2 客户端：设备码登录、token 刷新、搜索匹配、scrobble、评分 / 收藏 / 待看。
///
/// 全部走 actor：token 刷新是单次的（refresh token 只能用一次），
/// 播放页和详情页同时请求时不能各刷各的。
actor TraktClient {
    static let shared = TraktClient()

    private let base = "https://api.trakt.tv"
    private let cacheTTL: TimeInterval = 300

    private var token: TraktToken?
    private var tokenLoaded = false
    private var refreshing: Task<TraktToken, Error>?

    /// 匹配缓存：`movie|片名|年份` → 条目。搜索结果落盘，重启后不用重搜。
    private var matches: [String: TraktMatch]?

    private var ratings: [String: Int] = [:]
    private var ratingsAt = Date.distantPast
    private var watchlist: Set<String> = []
    private var watchlistAt = Date.distantPast
    private var collection: Set<String> = []
    private var collectionAt = Date.distantPast

    // MARK: 状态

    func isLoggedIn() -> Bool {
        loadTokenIfNeeded()
        return token != nil
    }

    func currentUsername() -> String? {
        loadTokenIfNeeded()
        return token?.username
    }

    /// 登录成功后补一次用户名（设备码响应里没有）。
    func rememberUsername() async {
        guard var current = token else { return }
        if let name = try? await fetchUsername() {
            current.username = name
            token = current
            TraktTokenStore.save(current)
        }
    }

    // MARK: 设备码登录

    func startDeviceLogin() async throws -> TraktDeviceCode {
        let (clientId, _) = TraktSettings.credentials()
        guard !clientId.isEmpty else { throw TraktError.notConfigured }

        let data = try await send("POST", "/oauth/device/code",
                                  body: ["client_id": clientId], authorized: false)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = object["device_code"] as? String,
              let user = object["user_code"] as? String,
              let url = object["verification_url"] as? String else {
            throw TraktError.http(0, "设备码响应格式不对")
        }
        return TraktDeviceCode(
            deviceCode: device,
            userCode: user,
            verificationURL: url,
            expiresIn: (object["expires_in"] as? NSNumber)?.doubleValue ?? 600,
            interval: max(2, (object["interval"] as? NSNumber)?.doubleValue ?? 5))
    }

    /// 轮询一次：没授权时抛 `.devicePending`，UI 隔 `interval` 秒再来。
    func pollDeviceToken(_ device: TraktDeviceCode) async throws -> TraktToken {
        let (clientId, clientSecret) = TraktSettings.credentials()
        var body: [String: Any] = [
            "code": device.deviceCode,
            "client_id": clientId,
        ]
        if !clientSecret.isEmpty { body["client_secret"] = clientSecret }

        do {
            let data = try await send("POST", "/oauth/device/token",
                                      body: body, authorized: false)
            let fresh = try parseToken(data)
            token = fresh
            tokenLoaded = true
            TraktTokenStore.save(fresh)
            return fresh
        } catch TraktError.http(let code, _) where code == 400 {
            throw TraktError.devicePending
        } catch TraktError.http(let code, _) where code == 404 || code == 410 {
            throw TraktError.deviceExpired
        } catch TraktError.http(let code, _) where code == 418 {
            throw TraktError.deviceDenied
        }
    }

    func logOut() async {
        // 先试着让服务端作废 token；网络不通也照样清本地。
        if let current = token {
            _ = try? await send("POST", "/oauth/revoke",
                                body: ["token": current.accessToken,
                                       "client_id": TraktSettings.clientId,
                                       "client_secret": TraktSettings.clientSecret],
                                authorized: false)
        }
        token = nil
        tokenLoaded = true
        TraktTokenStore.clear()
        ratings = [:]
        watchlist = []
        collection = []
        ratingsAt = .distantPast
        watchlistAt = .distantPast
        collectionAt = .distantPast
    }

    // MARK: 匹配

    /// 在 Trakt 里找条目：先用库里的 TMDB / IMDb id 精确查，都没有（或查不到）
    /// 再按片名 + 年份搜。宁可没有也不挂错：片名去掉空白标点后必须完全一致，
    /// 年份都有时最多差 1 年（首映年 vs 文件年份）。
    func match(title: String, year: Int?, series: Bool,
               tmdbId: String? = nil, imdbId: String? = nil) async throws -> TraktMatch? {
        let kind = series ? "show" : "movie"
        loadMatchesIfNeeded()

        // id 优先：Emby / Jellyfin 刮削时记下的 id 不会和别的片子撞名。
        for (type, raw) in [("tmdb", tmdbId), ("imdb", imdbId)] {
            guard let value = raw?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty else { continue }
            let key = "\(kind)|\(type)|\(value)"
            if let cached = matches?[key] { return cached }
            if let found = try await findById(kind: kind, type: type, value: value) {
                matches?[key] = found
                saveMatches()
                return found
            }
        }

        let key = matchKey(title: title, year: year, series: series)
        if let cached = matches?[key] { return cached }

        let query = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "limit", value: "10"),
        ]
        // 不用 years 参数：Trakt 的年份有时和文件里的差一年，交给本地判断更稳。
        // 搜索是公开端点：没登录也能按标题找条目（scrobble 才需要 token）。
        let data = try await send("GET", series ? "/search/show" : "/search/movie",
                                  query: query, authorized: false)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let wanted = Self.normalized(title)
        var yearFallback: TraktMatch?

        for entry in list {
            let item = (entry[series ? "show" : "movie"] as? [String: Any]) ?? entry
            guard let ids = item["ids"] as? [String: Any],
                  let traktId = ids["trakt"] as? Int,
                  let name = item["title"] as? String else { continue }

            let itemYear = item["year"] as? Int
            let sameName = Self.normalized(name) == wanted
            let sameYear: Bool? = {
                guard let year, let itemYear else { return nil }
                return abs(itemYear - year) <= 1
            }()

            let found = TraktMatch(kind: series ? "show" : "movie",
                                   traktId: traktId,
                                   slug: ids["slug"] as? String,
                                   title: name,
                                   year: itemYear)

            if sameName {
                // 标题完全一致：年份差 1 年内直接认；本地没年份也认。
                if sameYear ?? true {
                    matches?[key] = found
                    saveMatches()
                    return found
                }
                continue
            }

            // 中文片名在 Trakt 里显示成原名（「千与千寻」→ Spirited Away，
            // 「进击的巨人」→ Attack on Titan）：标题对不上时只按年份认第一条，
            // 而且必须两边都有年份——没有年份的多结果无从判断，宁可不挂。
            if yearFallback == nil, sameYear == true {
                yearFallback = found
            }
        }

        if let yearFallback {
            matches?[key] = yearFallback
            saveMatches()
            return yearFallback
        }

        // 本地没有年份、搜索结果又只有一条：采用它（常见于刚上映的片子）。
        if year == nil, list.count == 1 {
            let item = (list[0][series ? "show" : "movie"] as? [String: Any]) ?? list[0]
            if let ids = item["ids"] as? [String: Any],
               let traktId = ids["trakt"] as? Int,
               let name = item["title"] as? String {
                let only = TraktMatch(kind: series ? "show" : "movie",
                                      traktId: traktId,
                                      slug: ids["slug"] as? String,
                                      title: name,
                                      year: item["year"] as? Int)
                matches?[key] = only
                saveMatches()
                return only
            }
        }

        return nil
    }

    /// `/search/tmdb/{id}?type=show` 这类 id 查询。返回结构和标题搜索一样，
    /// 取第一条（id 是唯一的，不会有一堆候选）。
    private func findById(kind: String, type: String, value: String) async throws -> TraktMatch? {
        let data = try await send("GET", "/search/\(type)/\(value)",
                                  query: [URLQueryItem(name: "type", value: kind)],
                                  authorized: false)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = list.first else { return nil }
        let item = (entry[kind] as? [String: Any]) ?? entry
        guard let ids = item["ids"] as? [String: Any],
              let traktId = ids["trakt"] as? Int,
              let name = item["title"] as? String else { return nil }
        return TraktMatch(kind: kind,
                          traktId: traktId,
                          slug: ids["slug"] as? String,
                          title: name,
                          year: item["year"] as? Int)
    }

    // MARK: 评分 / 收藏 / 待看

    func rating(kind: String, traktId: Int) async throws -> Int? {
        let map = try await ratingMap()
        return map["\(kind):\(traktId)"]
    }

    func setRating(_ value: Int?, kind: String, traktId: Int) async throws {
        var entry: [String: Any] = ["ids": ["trakt": traktId]]
        if let value { entry["rating"] = value }
        let path = value == nil ? "/sync/ratings/remove" : "/sync/ratings"
        _ = try await send("POST", path, body: [kind == "movie" ? "movies" : "shows": [entry]])
        ratingsAt = .distantPast
    }

    func isInWatchlist(kind: String, traktId: Int) async throws -> Bool {
        let set = try await watchlistSet()
        return set.contains("\(kind):\(traktId)")
    }

    func setWatchlist(_ on: Bool, kind: String, traktId: Int) async throws {
        let noun = kind == "movie" ? "movies" : "shows"
        let path = on ? "/sync/watchlist" : "/sync/watchlist/remove"
        _ = try await send("POST", path, body: [noun: [["ids": ["trakt": traktId]]]])
        watchlistAt = .distantPast
    }

    func isInCollection(kind: String, traktId: Int) async throws -> Bool {
        let set = try await collectionSet()
        return set.contains("\(kind):\(traktId)")
    }

    func setCollection(_ on: Bool, kind: String, traktId: Int) async throws {
        let noun = kind == "movie" ? "movies" : "shows"
        let path = on ? "/sync/collection" : "/sync/collection/remove"
        _ = try await send("POST", path, body: [noun: [["ids": ["trakt": traktId]]]])
        collectionAt = .distantPast
    }

    // MARK: scrobble

    /// `action` = start / pause / stop。progress 是 0–100 的百分比。
    func scrobble(_ action: String, match: TraktMatch,
                  season: Int?, episode: Int?, progress: Double) async throws {
        var body: [String: Any] = [:]
        if match.kind == "movie" {
            body["movie"] = ["ids": ["trakt": match.traktId]]
        } else {
            body["show"] = ["ids": ["trakt": match.traktId]]
            body["episode"] = ["season": season ?? 1, "number": episode ?? 1]
        }
        body["progress"] = min(100, max(0.1, progress))
        _ = try await send("POST", "/scrobble/\(action)", body: body)
    }

    // MARK: - 请求

    private func send(_ method: String, _ path: String,
                      query: [URLQueryItem] = [], body: Any? = nil,
                      authorized: Bool = true, retryAuth: Bool = true) async throws -> Data {
        let (clientId, _) = TraktSettings.credentials()
        guard !clientId.isEmpty else { throw TraktError.notConfigured }

        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw TraktError.http(0, "URL 拼不起来") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("DVPlayer/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if authorized {
            let current = try await validToken()
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TraktError.http(0, "没有响应")
        }

        // access token 过期 / 被吊销：强制刷新后重试一次。
        if http.statusCode == 401, authorized, retryAuth {
            _ = try await validToken(force: true)
            return try await send(method, path, query: query, body: body,
                                  authorized: authorized, retryAuth: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TraktError.http(http.statusCode, String(text.prefix(180)))
        }
        return data
    }

    private func loadTokenIfNeeded() {
        guard !tokenLoaded else { return }
        tokenLoaded = true
        token = TraktTokenStore.load()
    }

    private func validToken(force: Bool = false) async throws -> TraktToken {
        loadTokenIfNeeded()
        guard let current = token else { throw TraktError.notLoggedIn }
        if !force, current.expiresAt > Date().addingTimeInterval(3600) {
            return current
        }
        if let refreshing {
            return try await refreshing.value
        }

        let task = Task { try await self.refresh(current.refreshToken) }
        refreshing = task
        do {
            let fresh = try await task.value
            token = fresh
            refreshing = nil
            TraktTokenStore.save(fresh)
            return fresh
        } catch {
            refreshing = nil
            throw error
        }
    }

    private func refresh(_ refreshToken: String) async throws -> TraktToken {
        let (clientId, clientSecret) = TraktSettings.credentials()
        var body: [String: Any] = [
            "refresh_token": refreshToken,
            "client_id": clientId,
            "grant_type": "refresh_token",
            // 设备码应用没有 redirect uri，Trakt 要求这个固定值。
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
        ]
        if !clientSecret.isEmpty { body["client_secret"] = clientSecret }

        let data = try await send("POST", "/oauth/token", body: body, authorized: false)
        var fresh = try parseToken(data)
        fresh.username = token?.username
        return fresh
    }

    private func parseToken(_ data: Data) throws -> TraktToken {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String,
              let refresh = object["refresh_token"] as? String else {
            throw TraktError.http(0, "token 响应格式不对")
        }
        let expires = (object["expires_in"] as? NSNumber)?.doubleValue ?? 7 * 24 * 3600
        let created = (object["created_at"] as? NSNumber)?.doubleValue
            ?? Date().timeIntervalSince1970
        return TraktToken(accessToken: access,
                          refreshToken: refresh,
                          expiresAt: Date(timeIntervalSince1970: created + expires),
                          username: token?.username)
    }

    private func fetchUsername() async throws -> String? {
        let data = try await send("GET", "/users/settings")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = object["user"] as? [String: Any] else { return nil }
        return user["username"] as? String
    }

    // MARK: - 全量缓存

    private func ratingMap() async throws -> [String: Int] {
        if Date().timeIntervalSince(ratingsAt) < cacheTTL { return ratings }
        var map: [String: Int] = [:]
        for (kind, path) in [("movie", "/sync/ratings/movies"),
                             ("show", "/sync/ratings/shows")] {
            let data = try await send("GET", path)
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }
            for entry in list {
                guard let rating = entry["rating"] as? Int,
                      let item = entry[kind] as? [String: Any],
                      let ids = item["ids"] as? [String: Any],
                      let id = ids["trakt"] as? Int else { continue }
                map["\(kind):\(id)"] = rating
            }
        }
        ratings = map
        ratingsAt = Date()
        return map
    }

    private func watchlistSet() async throws -> Set<String> {
        if Date().timeIntervalSince(watchlistAt) < cacheTTL { return watchlist }
        let set = try await idSet(paths: [("movie", "/sync/watchlist/movies"),
                                          ("show", "/sync/watchlist/shows")])
        watchlist = set
        watchlistAt = Date()
        return set
    }

    private func collectionSet() async throws -> Set<String> {
        if Date().timeIntervalSince(collectionAt) < cacheTTL { return collection }
        let set = try await idSet(paths: [("movie", "/sync/collection/movies"),
                                          ("show", "/sync/collection/shows")])
        collection = set
        collectionAt = Date()
        return set
    }

    private func idSet(paths: [(String, String)]) async throws -> Set<String> {
        var set = Set<String>()
        for (kind, path) in paths {
            let data = try await send("GET", path)
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }
            for entry in list {
                guard let item = entry[kind] as? [String: Any],
                      let ids = item["ids"] as? [String: Any],
                      let id = ids["trakt"] as? Int else { continue }
                set.insert("\(kind):\(id)")
            }
        }
        return set
    }

    // MARK: - 匹配缓存

    private var matchesURL: URL {
        AppSettings.directory.appendingPathComponent("trakt-matches.json")
    }

    private func loadMatchesIfNeeded() {
        guard matches == nil else { return }
        if let data = try? Data(contentsOf: matchesURL),
           let map = try? JSONDecoder().decode([String: TraktMatch].self, from: data) {
            matches = map
        } else {
            matches = [:]
        }
    }

    private func saveMatches() {
        guard let matches,
              let data = try? JSONEncoder().encode(matches) else { return }
        try? FileManager.default.createDirectory(at: AppSettings.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: matchesURL, options: .atomic)
    }

    private func matchKey(title: String, year: Int?, series: Bool) -> String {
        "\(series ? "show" : "movie")|\(Self.normalized(title))|\(year ?? 0)"
    }

    /// 片名比对：去掉空白和标点，全半角 / 大小写差异不影响。
    static func normalized(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
