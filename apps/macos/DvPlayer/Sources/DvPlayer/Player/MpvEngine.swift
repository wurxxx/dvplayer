import AppKit
import Foundation

/// mpv 自己开的窗口里的一条轨（音频 / 字幕）。
struct RawTrack {
    let id: Int64
    let type: String
    let title: String
    let language: String
    let codec: String
    let isDefault: Bool
    let isExternal: Bool
}

/// 播放引擎：拉起 `mpv` 子进程（gpu-next + Vulkan），通过 JSON IPC 控制。
///
/// 和 Windows 的 `MpvProcess` 同一个思路：视频由 mpv 自己开窗，
/// 我们的 SwiftUI 浮层是另一个窗口，靠 `geometry` 跟着走。
/// 这样能用到 gpu-next 的 Dolby Vision 整形（render API 拿不到）。
///
/// 回调都在主线程，接口和旧的 render API 封装一致，`PlayerSession` 只换了实现。
@MainActor
final class MpvEngine {

    // —— 回调（主线程） ——
    var onPosition: ((Double, Double) -> Void)?
    var onPause: ((Bool) -> Void)?
    var onLoaded: ((Double) -> Void)?
    var onEOF: (() -> Void)?
    var onTracks: (([RawTrack], [RawTrack], Int64, Int64) -> Void)?
    var onSpeed: ((Double) -> Void)?
    var onVolume: ((Double, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    // —— 状态 ——
    private(set) var isLoaded = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    private(set) var speed: Double = 1
    private(set) var volume: Double = 100
    private(set) var muted = false
    private(set) var eofReached = false

    /// mpv 窗口的 frame（屏幕坐标，左上原点），浮层照这个摆。
    private(set) var videoFrame: NSRect = .zero

    private let process = Process()
    private let ipc = MpvIPC()
    private let socketPath: String

    private var audioTracks: [RawTrack] = []
    private var subtitleTracks: [RawTrack] = []
    private var audioId: Int64 = 0
    private var subtitleId: Int64 = 0
    private var pendingLoad: (url: String, headers: [String: String], start: Double)?
    private var ready = false
    private var shuttingDown = false
    private var lastPositionEmit: TimeInterval = 0
    private var eofSent = false
    private var startOverride: Double?

    private static let observed = [
        "time-pos", "duration", "pause", "eof-reached", "speed", "volume", "mute",
        "track-list", "aid", "sid",
    ]

    init?(frame: NSRect, startSeconds: Double?) {
        guard let executable = Self.mpvExecutable() else {
            NSLog("[Play] 找不到 mpv 可执行文件")
            return nil
        }

        socketPath = NSTemporaryDirectory() + "dvplayer-\(getpid())-\(Int.random(in: 1000...9999)).sock"
        try? FileManager.default.removeItem(atPath: socketPath)

        // mpv 的 geometry 用左上原点（主屏）。
        let geometry = Self.geometryString(for: frame)

        var args = [
            "--no-config",
            "--idle=yes",          // 先起进程，文件稍后用 IPC 的 loadfile 送进来
            "--vo=gpu-next",
            "--gpu-api=vulkan",
            "--gpu-context=macvk",
            "--hwdec=auto-safe",
            "--no-border",
            "--no-input-default-bindings",
            "--input-vo-keyboard=no",
            "--keep-open=yes",
            "--no-terminal",
            "--focus-on=never",     // 窗口焦点归浮层，mpv 不抢
            "--title=DV Player",
            "--geometry=\(geometry)",
            "--input-ipc-server=\(socketPath)",
            "--msg-level=all=info,vo/gpu-next=warn",
            // 出问题看这个文件：mpv 是子进程，stderr 在 .app 里看不到。
            "--log-file=\(NSTemporaryDirectory())dvplayer-mpv.log",
        ]
        // 自检用：锁屏 / 无图形会话时 Vulkan 拿不到 swapchain，`--vo=null` 只跑解码和 IPC。
        if ProcessInfo.processInfo.environment["DVPLAYER_NO_VO"] == "1" {
            args.append("--vo=null")
        }

        // `--start` 只在第一次 loadfile 时生效，放在这里；
        // 切集时再用 `set_property start` 逐次设置。
        if let startSeconds, startSeconds > 1 {
            args.append("--start=\(String(format: "%.3f", startSeconds))")
        }

        process.executableURL = executable
        process.arguments = args
        process.environment = Self.environment()

        do {
            try process.run()
        } catch {
            NSLog("[Play] mpv 启动失败：\(error.localizedDescription)")
            return nil
        }

        NSLog("[Play] mpv pid=\(process.processIdentifier) geometry=\(geometry) args=\(args.joined(separator: " "))")

        guard ipc.connect(path: socketPath) else {
            NSLog("[Play] mpv IPC 连不上")
            process.terminate()
            return nil
        }

        ipc.onEvent = { [weak self] name, data in
            self?.handle(event: name, data: data)
        }
        ipc.onDisconnect = { [weak self] in
            guard let self, !self.shuttingDown else { return }
            NSLog("[Play] mpv 退出 code=\(self.process.terminationStatus)")
            self.onError?("播放器已退出")
        }

        for name in Self.observed {
            ipc.observe(name)
        }
        ready = true
        videoFrame = frame

        if let pendingLoad {
            self.pendingLoad = nil
            loadURL(pendingLoad.url, headers: pendingLoad.headers, start: pendingLoad.start)
        }
    }

    // MARK: - 播放控制

    func loadURL(_ url: String, headers: [String: String], start: Double) {
        guard !shuttingDown else { return }
        guard ready else {
            pendingLoad = (url, headers, start)
            return
        }

        pendingLoad = nil
        isLoaded = false
        eofSent = false
        eofReached = false
        position = 0
        duration = 0          // 上一集的时长别留在 loaded 里
        audioTracks = []
        subtitleTracks = []
        audioId = 0
        subtitleId = 0
        startOverride = start > 1 ? start : 0
        lastPositionEmit = 0

        // 请求头：每集可能不一样（飞牛带 token）。
        let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        ipc.command(["set_property", "http-header-fields", fields])
        ipc.command(["set_property", "pause", "no"])

        // `start` 是 option：先设再 loadfile，比给 loadfile 传 options 稳
        // （mpv 的 loadfile options 在 IPC 里要传数组，逗号串会被当成非法值）。
        let startValue = (startOverride ?? 0) > 1
            ? String(format: "%.3f", startOverride ?? 0)
            : "none"
        ipc.command(["set_property", "start", startValue])
        ipc.command(["set_property", "pause", "no"])

        NSLog("[Play] mpv load \(url.prefix(72))… start=\(startValue)")
        ipc.command(["loadfile", url, "replace"])
    }

    func play() {
        ipc.command(["set_property", "pause", "no"])
    }

    func pause() {
        ipc.command(["set_property", "pause", "yes"])
    }

    func togglePause() {
        ipc.command(["set_property", "pause", paused ? "no" : "yes"])
    }

    func seek(to seconds: Double) {
        let value = max(0, seconds)
        ipc.command(["seek", String(format: "%.3f", value), "absolute"])
        lastPositionEmit = 0
    }

    func setVolumePercent(_ percent: Double) {
        ipc.command(["set_property", "volume", String(format: "%.1f", min(100, max(0, percent)))])
    }

    func setMuted(_ muted: Bool) {
        ipc.command(["set_property", "mute", muted ? "yes" : "no"])
    }

    func setSpeed(_ speed: Double) {
        ipc.command(["set_property", "speed", String(format: "%.3f", speed)])
    }

    func selectAudio(_ trackId: Int64) {
        ipc.command(["set_property", "aid", trackId > 0 ? String(trackId) : "no"])
    }

    func selectSubtitle(_ trackId: Int64) {
        ipc.command(["set_property", "sid", trackId > 0 ? String(trackId) : "no"])
    }

    /// mpv 自己截一帧（解码输出，不含后处理）。
    func screenshot(to path: String) {
        takeScreenshot(path, kind: "video")
    }

    /// 从窗口抓一帧：包含 gpu-next 的 DV 整形 / tone map，验颜色用这个。
    func screenshotWindow(to path: String) {
        takeScreenshot(path, kind: "window")
    }

    private func takeScreenshot(_ path: String, kind: String) {
        ipc.command(["screenshot-to-file", path, kind]) { reply in
            if case .failure(let error) = reply {
                NSLog("[Play] 截图失败：\(error)")
            }
        }
    }

    /// 把 mpv 窗口挪到浮层窗口的位置。坐标系要换成主屏左上原点。
    func syncGeometry(to frame: NSRect) {
        guard ready, !shuttingDown else { return }
        guard frame.width > 1, frame.height > 1 else { return }
        videoFrame = frame
        ipc.command(["set_property", "geometry", Self.geometryString(for: frame)])
    }

    func toggleMuteIPC() {
        ipc.command(["set_property", "mute", muted ? "no" : "yes"])
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        ipc.command(["quit"])
        ipc.close()

        // 给它一点时间自己退；不退就杀掉。
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - 属性事件

    private func handle(event name: String, data: Any?) {
        guard !shuttingDown else { return }

        switch name {
            case "time-pos":
                guard let value = data as? Double else { return }
                position = value
                let now = Date().timeIntervalSince1970
                if now - lastPositionEmit >= 0.15 {
                    lastPositionEmit = now
                    onPosition?(value, duration)
                }
            case "duration":
                guard let value = data as? Double else { return }
                duration = value
                onPosition?(position, value)
            case "pause":
                let value = (data as? Bool) ?? ((data as? Int) == 1)
                paused = value
                onPause?(value)
            case "eof-reached":
                let value = (data as? Bool) ?? ((data as? Int) == 1)
                eofReached = value
                if value, !eofSent {
                    eofSent = true
                    onEOF?()
                }
            case "speed":
                guard let value = data as? Double else { return }
                speed = value
                onSpeed?(value)
            case "volume":
                guard let value = data as? Double else { return }
                volume = value
                onVolume?(value, muted)
            case "mute":
                let value = (data as? Bool) ?? ((data as? Int) == 1)
                muted = value
                onVolume?(volume, value)
            case "track-list":
                parseTracks(data)
            case "aid":
                audioId = parseTrackId(data)
                emitTracks()
            case "sid":
                subtitleId = parseTrackId(data)
                emitTracks()
            case "@file-loaded":
                isLoaded = true
                eofSent = false
                onLoaded?(duration)
            case "@end-file":
                if let info = data as? [String: Any],
                   let reason = info["reason"] as? String, reason == "error",
                   let message = info["file_error"] as? String, !message.isEmpty {
                    onError?("播放失败：\(message)")
                }
            case "@log-message":
                if let info = data as? [String: Any],
                   let text = info["text"] as? String {
                    onLog?(text)
                }
            default:
                break
        }
    }

    private func parseTracks(_ data: Any?) {
        guard let list = data as? [[String: Any]] else { return }

        var audio: [RawTrack] = []
        var subtitles: [RawTrack] = []

        for item in list {
            let type = item["type"] as? String ?? ""
            guard type == "audio" || type == "sub" else { continue }

            let track = RawTrack(
                id: (item["id"] as? NSNumber)?.int64Value ?? 0,
                type: type,
                title: item["title"] as? String ?? "",
                language: item["lang"] as? String ?? "",
                codec: item["codec"] as? String ?? "",
                isDefault: (item["default"] as? Bool) ?? false,
                isExternal: (item["external"] as? Bool) ?? false)

            if type == "audio" {
                audio.append(track)
            } else {
                subtitles.append(track)
            }
        }

        audioTracks = audio
        subtitleTracks = subtitles
        emitTracks()
    }

    private func parseTrackId(_ data: Any?) -> Int64 {
        if let text = data as? String {
            return text == "no" || text == "auto" ? 0 : (Int64(text) ?? 0)
        }
        if let number = data as? NSNumber { return number.int64Value }
        return 0
    }

    private func emitTracks() {
        onTracks?(audioTracks, subtitleTracks, audioId, subtitleId)
    }

    // MARK: - 进程

    /// .app 里在 `Contents/Frameworks/mpv`；开发时回落到仓库的 `prefix-vk/bin/mpv`。
    private static func mpvExecutable() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/mpv")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        // swift run / 直接跑二进制时，从可执行文件往上找仓库根。
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = directory else { break }
            let candidate = current.appendingPathComponent("prefix-vk/bin/mpv")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory = current.deletingLastPathComponent()
        }

        return nil
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        let candidates = [
            frameworks.appendingPathComponent("MoltenVK_icd.json"),
            frameworks.appendingPathComponent("vulkan/icd.d/MoltenVK_icd.json"),
        ]
        if let icd = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            env["VK_ICD_FILENAMES"] = icd.path
        }

        return env
    }

    /// AppKit 的窗口 frame（左下原点）→ mpv 的 geometry（左上原点，主屏坐标）。
    private static func geometryString(for frame: NSRect) -> String {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let screenFrame = screen?.frame ?? .zero
        let x = Int(frame.origin.x.rounded())
        let y = Int((screenFrame.maxY - frame.maxY).rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        return "\(width)x\(height)+\(max(0, x))+\(max(0, y))"
    }
}
