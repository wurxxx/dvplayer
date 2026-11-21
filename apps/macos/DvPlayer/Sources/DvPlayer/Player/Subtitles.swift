import Foundation

/// 一条在线字幕搜索结果（OpenSubtitles）。
struct SubtitleResult: Identifiable, Hashable {
    let id: Int
    let language: String
    let release: String
    let fileName: String
    let movieName: String
    let downloads: Int
    let ratings: Double
    let hearingImpaired: Bool

    var languageLabel: String {
        switch language.lowercased() {
            case "zh-cn", "chi", "zho": return "简体中文"
            case "zh-tw": return "繁体中文"
            case "en": return "英文"
            case "ja": return "日文"
            case "ko": return "韩文"
            default: return language
        }
    }

    var detail: String {
        var parts: [String] = [languageLabel]
        if !release.isEmpty { parts.append(release) }
        if downloads > 0 { parts.append("\(downloads) 次下载") }
        if hearingImpaired { parts.append("听障") }
        return parts.joined(separator: " · ")
    }
}

enum SubtitleError: LocalizedError {
    case missingApiKey
    case http(Int, String)
    case noResults
    case badResponse

    var errorDescription: String? {
        switch self {
            case .missingApiKey:
                return "字幕搜索需要先在「设置」里填 OpenSubtitles API Key"
            case .http(let code, let message):
                return message.isEmpty ? "OpenSubtitles 返回 HTTP \(code)"
                                       : "OpenSubtitles：\(message)"
            case .noResults:
                return "没搜到字幕"
            case .badResponse:
                return "OpenSubtitles 返回的数据看不懂"
        }
    }
}

/// OpenSubtitles REST API v1：搜索 → 取下载链接 → 存成本地字幕文件。
///
/// 只需要 API Key；如果配置了用户名 / 密码，下载前会先换一个 token
/// （OpenSubtitles 对下载接口有登录要求，免费账号即可）。
final class OpenSubtitlesService {
    static let shared = OpenSubtitlesService()

    private let base = ProcessInfo.processInfo.environment["DVPLAYER_OPENSUBTITLES_BASE"]
        ?? "https://api.opensubtitles.com/api/v1"
    private let session = URLSession(configuration: .ephemeral)

    private var token: String?
    private var tokenAt = Date.distantPast

    private func headers(apiKey: String) -> [String: String] {
        var headers = [
            "Api-Key": apiKey,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "DVPlayer v1.0",
        ]
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    private func loginIfNeeded(apiKey: String, username: String?, password: String?) async {
        guard let username, !username.isEmpty,
              let password, !password.isEmpty else { return }
        if token != nil, Date().timeIntervalSince(tokenAt) < 20 * 3600 { return }

        var request = URLRequest(url: URL(string: base + "/login")!)
        request.httpMethod = "POST"
        for (key, value) in headers(apiKey: apiKey).filter({ $0.key != "Authorization" }) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = root["token"] as? String, !value.isEmpty else {
                NSLog("[Subtitles] 登录 OpenSubtitles 失败")
                return
            }
            token = value
            tokenAt = Date()
            NSLog("[Subtitles] 已登录 OpenSubtitles")
        } catch {
            NSLog("[Subtitles] 登录失败：\(error.localizedDescription)")
        }
    }

    /// 剧集按「标题 + 季 + 集」搜，电影只按标题。
    func search(title: String,
                season: Int?,
                episode: Int?,
                apiKey: String,
                username: String?,
                password: String?,
                languages: String = "zh-cn,zh-tw,en") async throws -> [SubtitleResult] {
        guard !apiKey.isEmpty else { throw SubtitleError.missingApiKey }

        var components = URLComponents(string: base + "/subtitles")!
        var items = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "languages", value: languages),
        ]
        if let season, let episode {
            items.append(URLQueryItem(name: "type", value: "episode"))
            items.append(URLQueryItem(name: "season_number", value: String(season)))
            items.append(URLQueryItem(name: "episode_number", value: String(episode)))
        } else {
            items.append(URLQueryItem(name: "type", value: "movie"))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        for (key, value) in headers(apiKey: apiKey) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw SubtitleError.http(http?.statusCode ?? 0,
                                     Self.message(from: data))
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            throw SubtitleError.badResponse
        }

        let results: [SubtitleResult] = rows.compactMap { row in
            guard let attributes = row["attributes"] as? [String: Any],
                  let files = attributes["files"] as? [[String: Any]],
                  let file = files.first,
                  let fileId = file["file_id"] as? Int else { return nil }

            let ratings = (attributes["ratings"] as? NSNumber)?.doubleValue ?? 0
            return SubtitleResult(
                id: fileId,
                language: attributes["language"] as? String ?? "",
                release: attributes["release"] as? String ?? "",
                fileName: file["file_name"] as? String ?? "",
                movieName: attributes["movie_name"] as? String ?? "",
                downloads: (attributes["download_count"] as? NSNumber)?.intValue ?? 0,
                ratings: ratings,
                hearingImpaired: (attributes["hearing_impaired"] as? Bool) ?? false)
        }

        if results.isEmpty { throw SubtitleError.noResults }
        await loginIfNeeded(apiKey: apiKey, username: username, password: password)
        NSLog("[Subtitles] \(results.count) results for \(title) S\(season ?? 0)E\(episode ?? 0)")
        return results
    }

    /// 取临时下载链接，再把字幕文件存到缓存目录。
    func download(_ result: SubtitleResult,
                  apiKey: String,
                  username: String?,
                  password: String?) async throws -> URL {
        await loginIfNeeded(apiKey: apiKey, username: username, password: password)

        var request = URLRequest(url: URL(string: base + "/downloads")!)
        request.httpMethod = "POST"
        for (key, value) in headers(apiKey: apiKey) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["file_id": result.id])

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = root["link"] as? String,
              let url = URL(string: link) else {
            throw SubtitleError.http(http?.statusCode ?? 0, Self.message(from: data))
        }

        let (payload, downloadResponse) = try await session.data(from: url)
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw SubtitleError.badResponse
        }

        let folder = cacheFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (root["file_name"] as? String) ?? result.fileName
        let path = folder.appendingPathComponent(sanitize(name))
        try payload.write(to: path, options: .atomic)
        NSLog("[Subtitles] downloaded \(path.lastPathComponent) (\(payload.count) bytes)")
        return path
    }

    var cacheFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DvPlayer/subtitles", isDirectory: true)
    }

    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(cleaned)
    }

    private static func message(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return (root["message"] as? String) ?? ""
    }
}
