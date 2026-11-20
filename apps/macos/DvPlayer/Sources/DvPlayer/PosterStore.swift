import AppKit
import CryptoKit
import DvCore

/// 海报加载：内存 → 磁盘 → 核心取地址再下载。
///
/// 图片接口要带鉴权头，`AsyncImage` 用不了，所以自己下载并按路径缓存。
/// 同一个路径并发请求只会真正下载一次。
actor PosterStore {
    static let shared = PosterStore()

    private var memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("DvPlayer/posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    func image(path: String?, core: Core?) async -> NSImage? {
        guard let path, !path.isEmpty else { return nil }

        if let cached = memory.object(forKey: path as NSString) {
            return cached
        }

        if let task = inflight[path] {
            return await task.value
        }

        let task = Task<NSImage?, Never> { [directory] in
            if let disk = NSImage(contentsOf: directory.appendingPathComponent(Self.fileName(path))) {
                return disk
            }

            guard let core else { return nil }
            do {
                let source = try await core.imageSource(path)
                guard var request = URL(string: source.url).map({ URLRequest(url: $0) }) else {
                    return nil
                }
                for header in source.headers {
                    request.setValue(header.value, forHTTPHeaderField: header.name)
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
                      let image = NSImage(data: data) else {
                    return nil
                }
                try? data.write(to: directory.appendingPathComponent(Self.fileName(path)))
                return image
            } catch {
                NSLog("[DvPlayer] 海报加载失败 \(path)：\(error.localizedDescription)")
                return nil
            }
        }

        inflight[path] = task
        let image = await task.value
        inflight[path] = nil
        if let image {
            memory.setObject(image, forKey: path as NSString)
        }
        return image
    }

    private static func fileName(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }
}
