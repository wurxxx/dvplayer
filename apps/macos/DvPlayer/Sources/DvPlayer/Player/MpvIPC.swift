import Foundation

/// mpv 的 JSON IPC 客户端（unix socket）。
///
/// 和 Windows 的 `Player/MpvIpc.cs` 是同一套协议：
/// - 一条连接既发命令又收事件；命令带 `request_id`，回复按 id 分发；
/// - 不带 id 的是事件：`property-change` / `end-file` / `file-loaded` / `log-message`。
///
/// 读线程把一行行 JSON 解析出来，再切回主线程回调。
final class MpvIPC: @unchecked Sendable {
    enum Reply {
        case success(Any?)
        case failure(String)
    }

    /// 事件回调（主线程）。
    var onEvent: ((_ name: String, _ data: Any?) -> Void)?
    /// 连接断了（主线程）。
    var onDisconnect: (() -> Void)?

    private var fd: Int32 = -1
    private var reading = false
    private var nextId = 1
    private var nextObserveId = 1
    private var buffer = Data()

    private let gate = NSLock()
    private var pending: [Int: (Reply) -> Void] = [:]

    /// 连到 mpv 的 `--input-ipc-server`。进程刚起来时 socket 可能还没建，重试到超时。
    func connect(path: String, timeout: TimeInterval = 6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let handle = socket(AF_UNIX, SOCK_STREAM, 0)
            if handle < 0 { return false }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                bytes.withUnsafeBufferPointer { src in
                    dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                        _ = memcpy($0, src.baseAddress!, bytes.count)
                    }
                }
            }

            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(handle, $0, size)
                }
            }

            if result == 0 {
                fd = handle
                reading = true
                let thread = Thread { [weak self] in self?.readLoop() }
                thread.name = "mpv-ipc"
                thread.start()
                return true
            }

            Darwin.close(handle)
            usleep(120_000)
        }

        return false
    }

    /// 发一条命令，例如 `command(["set_property", "pause", "yes"])`。
    func command(_ args: [Any], reply: ((Reply) -> Void)? = nil) {
        var payload: [String: Any] = ["command": args]

        if let reply {
            let id: Int = {
                gate.lock(); defer { gate.unlock() }
                let value = nextId
                nextId += 1
                pending[value] = reply
                return value
            }()
            payload["request_id"] = id
        }

        write(payload)
    }

    /// 订阅属性；mpv 会先推一次当前值。
    func observe(_ name: String) {
        gate.lock()
        let id = nextObserveId
        nextObserveId += 1
        gate.unlock()
        command(["observe_property", id, name])
    }

    func close() {
        reading = false
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: - 内部

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)

        gate.lock()
        let handle = fd
        gate.unlock()
        guard handle >= 0 else { return }

        line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(handle, raw.baseAddress!.advanced(by: offset),
                                           raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while reading {
            let count = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }

            if count <= 0 {
                break
            }

            buffer.append(contentsOf: chunk[0..<count])

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                handle(line: Data(line))
            }
        }

        reading = false

        gate.lock()
        let waiting = pending
        pending.removeAll()
        gate.unlock()
        for (_, reply) in waiting {
            reply(.failure("mpv 连接断开"))
        }

        DispatchQueue.main.async { [weak self] in
            self?.onDisconnect?()
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        // 命令回复：先按 request_id 找回调。
        if let id = object["request_id"] as? Int {
            gate.lock()
            let reply = pending.removeValue(forKey: id)
            gate.unlock()
            if let reply {
                let error = object["error"] as? String ?? "unknown"
                reply(error == "success" ? .success(object["data"]) : .failure(error))
            }
            return
        }

        guard let event = object["event"] as? String else { return }

        switch event {
            case "property-change":
                let name = object["name"] as? String ?? ""
                let data = object["data"]
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(name, data)
                }
            default:
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?("@" + event, object["data"])
                }
        }
    }
}
