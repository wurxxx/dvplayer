import AppKit
import Foundation
import DvCore

/// mpv 自己开的窗口里的一条轨（音频 / 字幕）。
struct RawTrack {
    let id: Int64
    let type: String
    let title: String
    let language: String
    let codec: String
    let isDefault: Bool
    let isExternal: Bool
    /// 外挂文件路径（mpv 的 `external-filename`）；弹幕 ASS 靠它排除出字幕菜单。
    let externalFilename: String?
}

/// mpv `audio-device-list` 里的一条输出设备。
struct AudioDeviceInfo: Identifiable, Equatable {
    let name: String
    let description: String
    var id: String { name }

    /// 菜单上显示的名字：没有描述就用 mpv 的设备名。
    var label: String { description.isEmpty ? name : description }
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
    /// mpv 在等缓存（`paused-for-cache`），播放中卡顿时显示一个小状态。
    var onBuffering: ((Bool) -> Void)?
    var onLoaded: ((Double) -> Void)?
    /// VO 真正显示出第一帧（mpv 的 `video-frame-info` 出现）。
    var onFirstFrame: (() -> Void)?
    var onEOF: (() -> Void)?
    var onTracks: (([RawTrack], [RawTrack], Int64, Int64) -> Void)?
    var onSpeed: ((Double) -> Void)?
    var onVolume: ((Double, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    /// demuxer 缓存到的位置（秒），进度条画「已缓冲」那一段用。
    var onCacheTime: ((Double) -> Void)?
    /// 实际输出的动态范围：DV profile（0 = 不是 DV）+ 传递函数（pq / hlg / bt.1886）。
    var onVideoRange: ((Int, String) -> Void)?
    /// mpv 解出来的画面参数（宽、高、帧率、比特率、编码）；原盘没有服务端媒体信息。
    var onVideoStats: ((Int, Int, Double, Double, String) -> Void)?
    /// 视频显示宽高比（已含旋转 / 变形）；「适应窗口」用它把窗口改成同样的形状。
    var onVideoAspect: ((Double) -> Void)?
    /// 音频输出相关状态变了（设备列表 / 当前设备 / 直通开关）。
    var onAudioConfig: (() -> Void)?

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

    /// 视频窗口当前是否置顶（启动参数带 `--ontop`，所以默认 true）。
    private var ontop = true

    /// mpv 子进程还活着吗：错误面板「重试」用它决定要不要换个新进程。
    var isAlive: Bool { !shuttingDown && process.isRunning }
    /// IPC 也还连着：`isAlive` 为真但控制通道已断的间隙里不能复用这个实例。
    var isReady: Bool { ready && !shuttingDown }

    private let process = Process()
    private let ipc = MpvIPC()
    private let socketPath: String

    private var audioTracks: [RawTrack] = []
    private var subtitleTracks: [RawTrack] = []
    private var audioId: Int64 = 0
    private var subtitleId: Int64 = 0
    private var pendingLoad: (url: String, headers: [String: String], start: Double, proxy: String?)?
    /// 当前挂着的弹幕 ASS 路径：从字幕菜单里排除。
    private var secondarySubtitlePath: String?
    /// 每次 loadfile +1：切集时把上一集还没绑完的弹幕回调丢掉。
    private var loadGeneration = 0
    private var ready = false
    private var shuttingDown = false
    private var lastPositionEmit: TimeInterval = 0
    private var eofSent = false
    private var dvProfile = 0
    private var transferName = ""
    private var videoWidth = 0
    private var videoHeight = 0
    private var videoFps = 0.0
    private var videoBitrate = 0.0
    private var videoCodecName = ""
    private var startOverride: Double?
    /// 无头自检（`--vo=null`）没有真实出画，别等首帧。
    private static let pauseUntilFirstFrame =
        ProcessInfo.processInfo.environment["DVPLAYER_NO_VO"] != "1"
    /// 起播先停在第一帧，等 VO 真的出画再 unpause（声音就不会抢跑）。
    private var waitingFirstFrame = false
    /// loadfile 后这段时间内 VO 还会重画上一集的帧，不能当成新首帧。
    private var firstFrameNotBefore = Date.distantPast
    /// 这一轮已经把 `onFirstFrame` 报出去了（`video-frame-info` 每秒会变很多次）。
    private var firstFrameSent = false
    private var firstFrameTimeout: DispatchWorkItem?
    /// mpv 报上来的音频输出设备；`audio-device-list` 一有就填。
    private(set) var audioDevices: [AudioDeviceInfo] = []
    private(set) var audioDevice: String = ""
    private(set) var audioPassthrough = false
    private(set) var hdrPassthrough = false

    private static let observed = [
        "time-pos", "duration", "pause", "eof-reached", "speed", "volume", "mute",
        "track-list", "aid", "sid", "video-params/aspect", "demuxer-cache-time",
        "current-tracks/video", "video-params", "vo-configured", "video-frame-info",
        "paused-for-cache",
        "width", "height", "estimated-vf-fps", "video-bitrate",
        "audio-device-list", "audio-device", "audio-spdif", "target-colorspace-hint",
    ]

    init?(frame: NSRect, startSeconds: Double?) {
        guard let executable = Self.mpvExecutable() else {
            NSLog("[Play] 找不到 mpv 可执行文件")
            return nil
        }

        socketPath = NSTemporaryDirectory() + "dvplayer-\(getpid())-\(Int.random(in: 1000...9999)).sock"
        try? FileManager.default.removeItem(atPath: socketPath)

        // mpv 的 geometry 用左上原点；屏幕索引单独给，副屏负坐标才不会错位。
        let geometry = Self.geometry(for: frame)

        var args = [
            "--no-config",
            "--idle=yes",          // 先起进程，文件稍后用 IPC 的 loadfile 送进来
            "--vo=gpu-next",
            "--gpu-api=vulkan",
            "--gpu-context=macvk",
            "--hwdec=auto-safe",
            "--no-border",
            "--screen=\(geometry.screen)",
            "--no-input-default-bindings",
            "--input-vo-keyboard=no",
            "--keep-open=yes",
            "--no-terminal",
            "--focus-on=never",     // 窗口焦点归浮层，mpv 不抢
            // 播放器是浮层里的画面，不该再占一个 Dock 图标 / Cmd-Tab 条目：
            // 默认 regular 会多出一个「mpv」，看起来像开了两个 App。
            "--macos-app-activation-policy=accessory",
            // 库窗口和 mpv 窗口都是普通层级（0），而 accessory 的 mpv 不再被激活，
            // 窗口会永远压在库窗口下面——视频区透出的是库页面。提到 floating（3）
            // 才能盖住库窗口；播放浮层再高一级（4）盖住控制条。切到别的 App 时
            // 由 `setOnTop(false)` 放下来，行为和 Windows 的普通播放窗一致。
            "--ontop",
            "--title=DV Player",
            "--geometry=\(geometry.value)",
            "--input-ipc-server=\(socketPath)",
            "--msg-level=all=info,vo/gpu-next=warn",
            // 出问题看这个文件：mpv 是子进程，stderr 在 .app 里看不到。
            "--log-file=\(NSTemporaryDirectory())dvplayer-mpv.log",
        ]
        // 音频输出 / 直通 / HDR 跟着设置走：换集重启 mpv 也一直是用户选的。
        let settings = AppSettings.load()
        if settings.audioPassthrough ?? false {
            args.append("--audio-spdif=ac3,eac3,dts,dts-hd,truehd")
        }
        if settings.hdrPassthrough ?? false {
            args.append("--target-colorspace-hint=yes")
        }
        if let device = settings.audioDevice, !device.isEmpty {
            args.append("--audio-device=\(device)")
        }

        // 缓冲大小跟着设置走：默认 512MB，蓝光原盘可以调到 2G / 4G。
        // 网络流才需要预读，本地文件给多了只是白占内存。
        var bufferMb = min(max(settings.bufferSizeMb ?? 512, 128), 8192)
        // 自检用：无桌面环境验证三层进度条时，把缓冲压小才看得到「未观看」那一段。
        if let forced = Int(ProcessInfo.processInfo.environment["DVPLAYER_BUFFER_MB"] ?? ""),
           forced > 0 {
            bufferMb = forced
        }
        args.append("--cache=yes")
        args.append("--demuxer-max-bytes=\(bufferMb)MiB")
        args.append("--demuxer-max-back-bytes=\(max(64, bufferMb / 2))MiB")

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

        videoFrame = frame

        // IPC 连接放后台：mpv 建 socket 要时间，最坏重试 6 秒。
        // 在主线程同步等，打开播放窗会先卡住这么久。
        let ipc = self.ipc
        let path = self.socketPath
        Task.detached {
            let connected = ipc.connect(path: path)
            await MainActor.run { [weak self] in
                self?.finishConnect(connected: connected)
            }
        }
    }

    /// IPC 连上（或失败）之后的收尾。后台连接完成时回到主线程执行。
    private func finishConnect(connected: Bool) {
        guard !shuttingDown else {
            // 连接期间窗已经关了：socket 收掉，别再挂回调。
            ipc.close()
            return
        }

        guard connected else {
            NSLog("[Play] mpv IPC 连不上")
            process.terminate()
            onError?("播放器启动失败：控制通道没连上")
            return
        }

        ipc.onEvent = { [weak self] name, data in
            self?.handle(event: name, data: data)
        }
        ipc.onDisconnect = { [weak self] in
            guard let self, !self.shuttingDown else { return }
            // 控制通道断了但进程可能还没退出：这个实例不能再复用（写命令会落在死 fd 上）。
            self.ready = false
            NSLog("[Play] mpv 退出 code=\(self.process.terminationStatus)")
            self.onError?("播放器已退出")
        }

        for name in Self.observed {
            ipc.observe(name)
        }
        ipc.command(["set_property", "secondary-sub-visibility", "yes"])
        ready = true

        // IPC 连上之前调用过 setOnTop 的话，这里补发一次。
        applyOnTop()

        // 起进程时窗口还没摆好（PlayerWindow 的 buildContentView 早于 IPC 连上）：
        // 那一次 syncGeometry 被 `guard ready` 挡掉，这里补一次，否则 mpv 停在
        // 启动参数里的 geometry 上，和浮层错开几十点。
        if videoFrame != .zero {
            syncGeometry(to: videoFrame)
        }

        if let pendingLoad {
            self.pendingLoad = nil
            loadURL(pendingLoad.url, headers: pendingLoad.headers,
                    start: pendingLoad.start, proxy: pendingLoad.proxy)
        }
    }

    // MARK: - 播放控制

    func loadURL(_ url: String, headers: [String: String], start: Double, proxy: String? = nil) {
        guard !shuttingDown else { return }
        guard ready else {
            pendingLoad = (url, headers, start, proxy)
            return
        }

        pendingLoad = nil
        loadGeneration += 1
        isLoaded = false
        eofSent = false
        dvProfile = 0
        transferName = ""
        videoWidth = 0
        videoHeight = 0
        videoFps = 0
        videoBitrate = 0
        videoCodecName = ""
        emitVideoStats()
        eofReached = false
        position = 0
        duration = 0          // 上一集的时长别留在 loaded 里
        audioTracks = []
        subtitleTracks = []
        audioId = 0
        subtitleId = 0
        startOverride = start > 1 ? start : 0
        lastPositionEmit = 0
        firstFrameSent = false

        // 请求头：每集可能不一样（飞牛带 token）。
        let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        ipc.command(["set_property", "http-header-fields", fields])

        // 服务器的代理设置：设了就一直用，切集换成新源时会重新设。
        ipc.command(["set_property", "http-proxy", Self.normalizeProxy(proxy)])

        // 起播先停在第一帧：音频约 0.4 秒就出声，而首帧要 1 秒左右，
        // 直接播会「声音先出来、画面晚约 1 秒」。
        ipc.command(["set_property", "pause", Self.pauseUntilFirstFrame ? "yes" : "no"])

        // `start` 是 option：先设再 loadfile，比给 loadfile 传 options 稳
        // （mpv 的 loadfile options 在 IPC 里要传数组，逗号串会被当成非法值）。
        let startValue = (startOverride ?? 0) > 1
            ? String(format: "%.3f", startOverride ?? 0)
            : "none"
        ipc.command(["set_property", "start", startValue])
        ipc.command(["set_property", "pause", Self.pauseUntilFirstFrame ? "yes" : "no"])

        NSLog("[Play] mpv load \(Self.redacted(url).prefix(72))… start=\(startValue)")
        ipc.command(["loadfile", url, "replace"])
        if Self.pauseUntilFirstFrame {
            waitFirstFrame()
        }
    }

    // MARK: - 首帧闸门

    /// 起播先暂停，VO 就绪（`vo-configured`）再放开；超时兜底不让黑屏卡死。
    private func waitFirstFrame() {
        firstFrameTimeout?.cancel()
        waitingFirstFrame = true
        firstFrameNotBefore = Date().addingTimeInterval(0.09)
        let generation = loadGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.waitingFirstFrame,
                  self.loadGeneration == generation else { return }
            NSLog("[Play] 等首帧超时，直接开始播放")
            self.releaseFirstFrameWait()
        }
        firstFrameTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    /// 放开起播暂停：声音和画面从这里一起开始。
    private func releaseFirstFrameWait() {
        guard waitingFirstFrame else { return }
        waitingFirstFrame = false
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
        NSLog("[Play] 首帧放开 pause")
        ipc.command(["set_property", "pause", "no"])
    }

    /// 用户自己按了播放 / 暂停：别再让首帧回调改状态。
    private func cancelFirstFrameWait() {
        guard waitingFirstFrame else { return }
        waitingFirstFrame = false
        firstFrameTimeout?.cancel()
        firstFrameTimeout = nil
    }

    /// 代理地址允许只写 `127.0.0.1:7890`；空表示直连（mpv 要的是空串）。
    private static func normalizeProxy(_ proxy: String?) -> String {
        guard var value = proxy?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return ""
        }
        if !value.contains("://") {
            value = "http://" + value
        }
        return value
    }

    func play() {
        cancelFirstFrameWait()
        ipc.command(["set_property", "pause", "no"])
    }

    func pause() {
        cancelFirstFrameWait()
        ipc.command(["set_property", "pause", "yes"])
    }

    func togglePause() {
        cancelFirstFrameWait()
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

    // MARK: - 音频输出 / 直通 / HDR

    /// 换音频输出设备（mpv 的 `audio-device` 名字，`auto` 是系统默认）。
    func setAudioDevice(_ name: String) {
        ipc.command(["set_property", "audio-device", name])
        audioDevice = name

        var settings = AppSettings.load()
        settings.audioDevice = name
        settings.save()
        onAudioConfig?()
    }

    /// 音频直通：交给功放解 AC3 / EAC3 / DTS / TrueHD。
    func setAudioPassthrough(_ enabled: Bool) {
        ipc.command(["set_property", "audio-spdif",
                     enabled ? "ac3,eac3,dts,dts-hd,truehd" : ""])
        audioPassthrough = enabled

        var settings = AppSettings.load()
        settings.audioPassthrough = enabled
        settings.save()
        onAudioConfig?()
    }

    /// HDR 直通：`target-colorspace-hint`，系统开了 HDR 才真的进 PQ。
    func setHdrPassthrough(_ enabled: Bool) {
        ipc.command(["set_property", "target-colorspace-hint", enabled ? "yes" : "no"])
        hdrPassthrough = enabled

        var settings = AppSettings.load()
        settings.hdrPassthrough = enabled
        settings.save()
        onAudioConfig?()
    }

    func selectAudio(_ trackId: Int64) {
        ipc.command(["set_property", "aid", trackId > 0 ? String(trackId) : "no"])
    }

    func selectSubtitle(_ trackId: Int64) {
        ipc.command(["set_property", "sid", trackId > 0 ? String(trackId) : "no"])
    }

    /// 弹幕：`sub-add` 之后用 `secondary-sid` 让它和用户选的字幕同时显示。
    /// `sub-add` 在 JSON IPC 里不返回轨道 id，所以加完再查一次 `track-list`，
    /// 按 `external-filename` 找到刚加的那条。
    func addSecondarySubtitle(_ path: String) {
        let primary = subtitleId
        let generation = loadGeneration
        secondarySubtitlePath = path
        ipc.command(["sub-add", path, "auto"])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, generation == self.loadGeneration else { return }
            self.bindSecondarySubtitle(path: path, primary: primary)
        }
    }

    private func bindSecondarySubtitle(path: String, primary: Int64) {
        ipc.command(["get_property", "track-list"]) { [weak self] reply in
            guard let self, case .success(let value) = reply,
                  let list = value as? [[String: Any]] else { return }

            let match = list.first { item in
                guard (item["type"] as? String) == "sub" else { return false }
                return (item["external-filename"] as? String) == path
            }
            guard let id = (match?["id"] as? NSNumber)?.int64Value, id > 0 else {
                NSLog("[Danmaku] 没找到刚加的弹幕轨道 \(path)")
                return
            }

            DispatchQueue.main.async {
                self.ipc.command(["set_property", "secondary-sid", String(id)])
                // 加弹幕时如果没有主字幕，mpv 会把它选成主字幕：退回 secondary。
                if primary == 0 {
                    self.ipc.command(["set_property", "sid", "no"])
                }
                NSLog("[Danmaku] secondary sub id=\(id) primary=\(primary)")
            }
        }
    }

    func clearSecondarySubtitle() {
        ipc.command(["set_property", "secondary-sid", "no"])
    }

    /// 在线下载的字幕：直接加进来并选上（主字幕）。
    func addPrimarySubtitle(_ path: String) {
        ipc.command(["sub-add", path, "select"])
        NSLog("[Play] sub-add primary \(path)")
    }

    /// 画面比例：`keepaspect` 控制是否保持宽高比，`panscan=1` 是裁切填满，
    /// `video-aspect-override` 强制一个比例（`no` 表示不覆盖）。
    /// `video-aspect-override` 是逐文件的，换集后要重新套一次。
    func setAspect(keepAspect: Bool, panscan: Double, aspectOverride: String) {
        ipc.command(["set_property", "keepaspect", keepAspect ? "yes" : "no"])
        ipc.command(["set_property", "panscan", String(format: "%.2f", panscan)])
        ipc.command(["set_property", "video-aspect-override", aspectOverride])
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

    /// 视频窗口置顶开关。
    ///
    /// mpv 是独立进程，它的窗口和库窗口同属普通层级（0）；accessory 策略下 mpv
    /// 不再被激活，窗口就一直压在库窗口下面，视频区看着是透明的。`--ontop` 把
    /// 它提到 floating（3），库窗口就盖不住它了。
    ///
    /// 切到别的 App 时放下来（`ontop=no`），播放窗像 Windows 的普通窗口一样
    /// 被别的 App 盖住；回到我们 App 再提上去。运行时改 `ontop` 实测有效。
    func setOnTop(_ on: Bool) {
        guard on != ontop else { return }
        ontop = on
        applyOnTop()
    }

    /// IPC 没连上时先记下意愿，连上后补发（窗口是后创建的，不会漏）。
    private func applyOnTop() {
        guard ready, !shuttingDown else { return }
        ipc.command(["set_property", "ontop", ontop ? "yes" : "no"])
    }

    /// 把 mpv 窗口挪到浮层窗口的位置。坐标系要换成主屏左上原点。
    func syncGeometry(to frame: NSRect) {
        guard ready, !shuttingDown else { return }
        guard frame.width > 1, frame.height > 1 else { return }
        videoFrame = frame

        // 先选屏幕再给相对坐标：副屏在主屏左侧时，绝对坐标是负数，
        // mpv 的 geometry 会把负号当成「从右边算」，窗口就跑错屏了。
        let geometry = Self.geometry(for: frame)
        // `geometry` 只在窗口创建时生效；运行时改必须先把 force-window-position 打开，
        // 否则命令返回 success 但窗口纹丝不动（实测：拖动浮层后画面停在原地）。
        ipc.command(["set_property", "force-window-position", "yes"])
        ipc.command(["set_property", "screen", geometry.screen])
        ipc.command(["set_property", "geometry", geometry.value])
        if geometry.value != lastAppliedGeometry {
            lastAppliedGeometry = geometry.value
            NSLog("[Play] sync geometry=\(geometry.value) screen=\(geometry.screen) " +
                  "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) " +
                  "\(Int(frame.width))x\(Int(frame.height))")
        }
    }

    /// 上一次真正发给 mpv 的 geometry，只在变化时打日志。
    private var lastAppliedGeometry = ""

    func toggleMuteIPC() {
        ipc.command(["set_property", "mute", muted ? "no" : "yes"])
    }

    /// 关闭 mpv：发 quit，最多等 2 秒，不退就杀。
    ///
    /// 用 `await` 等而不是主线程 `usleep` 轮询：关窗 / Cmd+Q 都是在主线程调的，
    /// 同步轮询会把界面卡住最多 2 秒。
    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        cancelFirstFrameWait()
        ipc.command(["quit"])
        ipc.close()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// 退出 App 时的同步收尾。
    ///
    /// `applicationWillTerminate` 返回后进程就没了，MainActor 上排队的 `shutdown()`
    /// 不会再执行 —— 原来 Cmd+Q 会把 mpv 留成孤儿进程继续播放。
    /// 这里最多等 400ms，宁可在退出时多站一会儿，也别留下后台 mpv。
    func shutdownNow() {
        guard !shuttingDown else { return }
        shuttingDown = true
        cancelFirstFrameWait()
        ipc.command(["quit"])
        ipc.close()

        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
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
            case "video-params/aspect":
                guard let value = data as? Double, value > 0 else { return }
                onVideoAspect?(value)
            case "demuxer-cache-time":
                guard let value = data as? Double else { return }
                onCacheTime?(value)
            case "current-tracks/video":
                let map = data as? [String: Any]
                let profile = (map?["dolby-vision-profile"] as? Int)
                    ?? Int((map?["dolby-vision-profile"] as? Double) ?? 0)
                dvProfile = profile
                videoCodecName = map?["codec"] as? String ?? ""
                emitVideoStats()
                onVideoRange?(dvProfile, transferName)
            case "width":
                videoWidth = intValue(data) ?? 0
                emitVideoStats()
            case "height":
                videoHeight = intValue(data) ?? 0
                emitVideoStats()
            case "estimated-vf-fps":
                videoFps = doubleValue(data) ?? 0
                emitVideoStats()
            case "video-bitrate":
                videoBitrate = doubleValue(data) ?? 0
                emitVideoStats()
            case "vo-configured":
                // 暂停状态下 mpv 也会把 VO 配好，但不会给第一帧；VO 一就绪就放开，
                // 声音和画面从这一秒一起开始（实测相差不到 10ms）。
                guard (data as? Bool) == true else { return }
                releaseFirstFrameWait()
            case "video-frame-info":
                // 只有 VO 真正拿到一帧后这个属性才存在；音频通常比它先出。
                guard data is [String: Any], isLoaded else { return }
                if waitingFirstFrame {
                    // 切集时 VO 已经配好了，mpv 会先把上一集的最后一帧重画一次。
                    guard Date() >= firstFrameNotBefore else { return }
                    releaseFirstFrameWait()
                }
                guard !firstFrameSent else { return }
                firstFrameSent = true
                onFirstFrame?()
            case "video-params":
                // mpv 把传递函数放在 gamma 里（pq / hlg / bt.1886），没有 transfer 字段。
                if let map = data as? [String: Any] {
                    if let gamma = map["gamma"] as? String {
                        transferName = gamma
                    } else if let transfer = map["transfer"] as? String {
                        transferName = transfer
                    }
                }
                onVideoRange?(dvProfile, transferName)
            case "audio-device-list":
                guard let list = data as? [[String: Any]] else { return }
                audioDevices = list.compactMap { item in
                    guard let name = item["name"] as? String, !name.isEmpty else { return nil }
                    return AudioDeviceInfo(name: name,
                                           description: item["description"] as? String ?? "")
                }
                onAudioConfig?()
            case "audio-device":
                audioDevice = data as? String ?? ""
                onAudioConfig?()
            case "audio-spdif":
                audioPassthrough = !((data as? String) ?? "").isEmpty
                onAudioConfig?()
            case "target-colorspace-hint":
                hdrPassthrough = (data as? Bool) ?? ((data as? Int) == 1)
                onAudioConfig?()
            case "pause":
                let value = (data as? Bool) ?? ((data as? Int) == 1)
                paused = value
                onPause?(value)
            case "paused-for-cache":
                let value = (data as? Bool) ?? ((data as? Int) == 1)
                onBuffering?(value)
            case "eof-reached":
                let value = (data as? Bool) ?? ((data as? Int) == 1)
                eofReached = value
                if value, !eofSent {
                    eofSent = true
                    onEOF?()
                } else if !value {
                    // 拖回片尾之前：再播完一次要重新触发 onEOF（以前只会触发一次）。
                    eofSent = false
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

            // 弹幕 ASS 只走 secondary-sid，不进字幕菜单。
            if let filename = item["external-filename"] as? String,
               filename.contains("DVPlayer-danmaku") || filename == secondarySubtitlePath {
                continue
            }

            let track = RawTrack(
                id: (item["id"] as? NSNumber)?.int64Value ?? 0,
                type: type,
                title: item["title"] as? String ?? "",
                language: item["lang"] as? String ?? "",
                codec: item["codec"] as? String ?? "",
                isDefault: (item["default"] as? Bool) ?? false,
                isExternal: (item["external"] as? Bool) ?? false,
                externalFilename: item["external-filename"] as? String)

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

    private func emitVideoStats() {
        onVideoStats?(videoWidth, videoHeight, videoFps, videoBitrate, videoCodecName)
    }

    private func intValue(_ data: Any?) -> Int? {
        if let value = data as? Int { return value }
        if let value = data as? Double { return Int(value) }
        if let value = data as? NSNumber { return value.intValue }
        return nil
    }

    private func doubleValue(_ data: Any?) -> Double? {
        if let value = data as? Double { return value }
        if let value = data as? Int { return Double(value) }
        if let value = data as? NSNumber { return value.doubleValue }
        return nil
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

    /// 日志里不能出现签名 / token：去掉 query 和 userinfo。
    private static func redacted(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.query = nil
        components.user = nil
        components.password = nil
        return components.string ?? url
    }

    /// AppKit 的窗口 frame（左下原点，单位是点）→ mpv 的 `--screen` + `--geometry`。
    ///
    /// 两个坑，都是实测出来的（1080p@2x 屏）：
    /// - **geometry 的单位是像素，不是点**：传 `1280x720` 得到的是 640x360 点的窗口，
    ///   正好是浮层的一半，画面缩在左上角。要按屏幕的 backingScaleFactor 乘回去。
    /// - **y 的原点是菜单栏下方**，不是屏幕顶：传 `+200+200` 实际落在 y=130 点，
    ///   比 AppKit 算出来的低 30 点。这里把菜单栏高度补进去。
    /// mpv 的 geometry 只接受正偏移（负号是「从右边算」），所以先选屏幕再算相对坐标，
    /// 副屏在主屏左边时不会被夹到主屏。
    private static func geometry(for frame: NSRect) -> (screen: Int, value: String) {
        let screens = NSScreen.screens
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let index = screens.firstIndex { $0.frame.contains(center) } ?? 0
        let screen = screens.indices.contains(index) ? screens[index] : NSScreen.main
        let screenFrame = screen?.frame ?? .zero
        let scale = screen?.backingScaleFactor ?? 1
        // 菜单栏高度：visibleFrame 顶端与 frame 顶端之差。
        let menuBar = max(0, screenFrame.maxY - (screen?.visibleFrame.maxY ?? screenFrame.maxY))

        let x = max(0, Int(((frame.origin.x - screenFrame.minX) * scale).rounded()))
        let y = max(0, Int(((screenFrame.maxY - frame.maxY - menuBar) * scale).rounded()))
        let width = Int((frame.width * scale).rounded())
        let height = Int((frame.height * scale).rounded())
        return (index, "\(width)x\(height)+\(x)+\(y)")
    }
}
