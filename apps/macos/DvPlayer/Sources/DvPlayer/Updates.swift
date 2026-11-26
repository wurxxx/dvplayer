import Foundation

/// 项目主页与发布页：设置页「关于」里点得开，更新检查也读这里的 Releases。
enum ProjectInfo {
    static let repo = "wurxxx/dvplayer"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!
    static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
}

/// 启动时查到的可用更新：侧栏左下角据此提示。
struct AvailableUpdate {
    let version: String
    let url: URL
}

/// 更新检查：问 GitHub 最新 Release，和当前版本比。
///
/// 结果在进程内缓存 10 分钟：设置页来回切不重复打接口（未登录的 GitHub API
/// 每小时只有 60 次）。手动点「重新检查」走 `force` 绕过缓存。
actor UpdateChecker {
    enum Result {
        case upToDate(current: String)
        case available(version: String, url: URL)
        case noRelease
        case failed(String)
    }

    static let shared = UpdateChecker()

    private var cached: (at: Date, version: String, result: Result)?
    private let cacheTTL: TimeInterval = 10 * 60

    func check(currentVersion: String, force: Bool = false) async -> Result {
        if !force, let cached,
           cached.version == currentVersion,
           Date().timeIntervalSince(cached.at) < cacheTTL {
            return cached.result
        }

        let result = await fetch(currentVersion: currentVersion)
        switch result {
        case .upToDate, .available:
            cached = (Date(), currentVersion, result)
        case .noRelease, .failed:
            break
        }
        return result
    }

    private func fetch(currentVersion: String) async -> Result {
        var request = URLRequest(url: ProjectInfo.latestReleaseAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DVPlayer/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("网络响应异常")
            }
            // 仓库还没有发布过 Release：不是错误，只是没得更新。
            if http.statusCode == 404 {
                return .noRelease
            }
            guard http.statusCode == 200 else {
                return .failed("GitHub 返回 HTTP \(http.statusCode)")
            }

            struct Release: Decodable {
                let tag_name: String
                let html_url: String
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = Self.normalize(release.tag_name)
            guard !version.isEmpty else {
                return .failed("发布信息不完整")
            }
            let url = URL(string: release.html_url) ?? ProjectInfo.releasesURL

            return Self.isNewer(version, than: currentVersion)
                ? .available(version: version, url: url)
                : .upToDate(current: Self.normalize(currentVersion))
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failed("网络不可用")
        } catch {
            return .failed("检查失败：\(error.localizedDescription)")
        }
    }

    /// `v0.1.5` / `0.1.5-beta` / `0.1.5+abc` → `0.1.5`。
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        if let cut = value.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            value = String(value[..<cut])
        }
        return value
    }

    /// 按数字段比较（0.1.10 > 0.1.9）；缺的段当 0。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = normalize(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let right = normalize(current).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b {
                return a > b
            }
        }
        return false
    }
}
