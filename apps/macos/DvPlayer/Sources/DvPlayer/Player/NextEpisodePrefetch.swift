import Foundation
import DvCore

/// 下一集预加载：本集快播完时提前把下一集的播放地址取好，再读一小段数据
/// 把连接和服务器会话热起来；真正切集时直接吃缓存，省掉一次取地址的往返
/// 和首包的等待。
///
/// 只预热、不预解码：切集仍走原来的 `loadfile` 流程，预热失败或不命中
/// 也只是退回普通切集，不影响播放。开关在设置 → 播放 →「预加载下一集」。
@MainActor
final class NextEpisodePrefetch {
    static let shared = NextEpisodePrefetch()

    /// 剩余多少秒开始预取。
    static let leadSeconds: Double = 90
    /// 缓存多久算过期：直链里的签名 / 会话可能失效，太旧就别用。
    private static let ttl: TimeInterval = 10 * 60
    /// 同一集失败后多久内不再重试，避免反复打服务器。
    private static let failureBackoff: TimeInterval = 30
    /// 预热读多少字节就断开：够让服务端把会话和文件头准备好。
    private static let warmBytes = 512 * 1024

    private struct Entry {
        let source: PlaySource
        let at: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private var failedAt: [String: Date] = [:]

    /// 取缓存（取走即删）：命中说明这一集已经在后台取好地址了。
    func take(_ itemId: String) -> PlaySource? {
        guard let entry = cache.removeValue(forKey: itemId) else { return nil }
        guard Date().timeIntervalSince(entry.at) < Self.ttl else { return nil }
        return entry.source
    }

    /// 后台预取。同一集只跑一份；失败 30 秒内不再试。
    /// 返回是否真的发起了这次预取（已经在缓存 / 在途 / 退避中返回 false）。
    @discardableResult
    func prefetch(_ itemId: String, core: Core) -> Bool {
        guard cache[itemId] == nil, !inFlight.contains(itemId) else { return false }
        if let at = failedAt[itemId], Date().timeIntervalSince(at) < Self.failureBackoff {
            return false
        }

        inFlight.insert(itemId)
        Task { [weak self] in
            let started = Date()
            do {
                let source = try await core.playSource(itemId)
                let read = await Self.warm(source)
                guard let self else { return }
                self.inFlight.remove(itemId)
                guard read >= 0 else {
                    self.failedAt[itemId] = Date()
                    NSLog("[Prefetch] warm fail item=\(itemId)")
                    return
                }
                self.cache[itemId] = Entry(source: source, at: Date())
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                NSLog("[Prefetch] ready item=\(itemId) bytes=\(read) " +
                      "dur=\(source.durationSeconds) ms=\(ms)")
            } catch {
                guard let self else { return }
                self.inFlight.remove(itemId)
                self.failedAt[itemId] = Date()
                NSLog("[Prefetch] fail item=\(itemId) \(error.localizedDescription)")
            }
        }
        return true
    }

    /// 关窗时清掉：地址和服务器会话都别留着。
    func clear() {
        cache.removeAll()
        failedAt.removeAll()
    }

    /// 读一小段数据把连接 / 服务端会话热起来。返回读到的字节数；
    /// 不需要预热（本地文件 / 原盘）返回 0，失败返回 -1。
    private static func warm(_ source: PlaySource) async -> Int {
        guard !source.disc,
              let url = URL(string: source.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return 0
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // 只要开头一段：服务端支持 Range 就精确；不支持我们读够就断。
        request.setValue("bytes=0-\(warmBytes - 1)", forHTTPHeaderField: "Range")
        for header in source.headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        if let proxy = proxyDictionary(source.proxy) {
            config.connectionProxyDictionary = proxy
        }

        let probe = WarmProbe(cap: warmBytes)
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return await probe.run(request, session: session)
    }

    /// 服务器设了 HTTP 代理时，预热请求也要走它，否则连不上。
    private static func proxyDictionary(_ raw: String?) -> [AnyHashable: Any]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              let host = url.host,
              url.scheme?.lowercased() == "http" else {
            return nil
        }
        let port = url.port ?? 8080
        return [
            "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
        ]
    }
}

/// 只读前 N 字节就取消的探针：服务端忽略 Range 时也不会把整部片下载下来。
private final class WarmProbe: NSObject, URLSessionDataDelegate {
    private let cap: Int
    private var received = 0
    private var statusOK = true
    private var finished = false
    private var continuation: CheckedContinuation<Int, Never>?

    init(cap: Int) {
        self.cap = cap
    }

    func run(_ request: URLRequest, session: URLSession) async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            statusOK = false
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        received += data.count
        if received >= cap {
            // 读够了：主动断开，别把整部片拉下来。
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        if statusOK, received > 0 {
            continuation?.resume(returning: min(received, cap))
        } else if statusOK, error == nil {
            continuation?.resume(returning: 0)
        } else {
            continuation?.resume(returning: -1)
        }
        continuation = nil
    }
}
