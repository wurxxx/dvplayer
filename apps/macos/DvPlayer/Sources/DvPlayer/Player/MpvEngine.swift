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

/// 播放引擎：进程内 libmpv（gpu-next render backend），视频画进我们自己的
/// `MpvVideoView`。
///
/// 和 Windows 的 libmpv 嵌入同构：视频和控件在**同一个窗口**里，
/// 所以拖动 / 缩放天然同步，不需要 `geometry` 在两个窗口之间追。
///
/// 用 gpu-next render backend（2026-11-22 之后的 mpv）才有正确的 Dolby Vision
/// 整形；legacy `gpu` 会把 IPT 当 YCbCr 解，P5 画面发紫（实测）。
///
/// 回调都在主线程，对外接口没变，`PlayerSession` 不用改。
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

    /// 播放窗当前是否「置顶」（App 活跃时窗口层级更高）。
    private var ontop = true

    /// 引擎还活着吗：错误面板「重试」用它决定要不要换个新实例。
    var isAlive: Bool { !shuttingDown && client.handle != nil }
    /// 渲染上下文也建好了：没建好之前不能复用这个实例。
    var isReady: Bool { ready && !shuttingDown }

    private let client = MpvClient()
    /// 视频画布：由 PlayerWindow 塞进窗口，mpv 直接画在这里。
    private(set) var videoView: MpvVideoView?

    /// mpv 报上来的累计掉帧数（`decoder-frame-drop-count` + `vo-drop-frame-count`）。
    /// 拖动自检用它判断渲染有没有被窗口移动拖慢。
    private(set) var droppedFrames = 0

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
        "decoder-frame-drop-count", "vo-drop-frame-count",
    ]

    init?(frame: NSRect, startSeconds: Double?) {
        // 单窗口：视频画布由这里建，PlayerWindow 把它塞到控件下面。
        let view = MpvVideoView(client: client)
        videoView = view

        // 选项直接对应旧的命令行参数。和子进程时代相比去掉的：
        // `--input-ipc-server`（进程内了）、`--geometry` / `--screen` / `--ontop` /
        // `--no-border` / `--macos-app-activation-policy` / `--focus-on`
        // （不再有独立窗口）、`--gpu-api=vulkan` / `--gpu-context=macvk`
        // （render API 跑在 OpenGL 上）。
        var options: [String: String] = [
            "config": "no",
            // 先起核心，文件稍后用命令送进来。
            "idle": "yes",
            // render API 必须指定 libmpv 这个 VO，否则 mpv 会自己开窗。
            "vo": "libmpv",
            "terminal": "no",
            "input-default-bindings": "no",
            "input-vo-keyboard": "no",
            "keep-open": "yes",
            "hwdec": "auto-safe",
            "msg-level": "all=info,vo/gpu-next=warn",
            // 出问题看这个文件：.app 里没有终端。
            "log-file": NSTemporaryDirectory() + "dvplayer-mpv.log",
        ]

        // 音频输出 / 直通 / HDR 跟着设置走：换集不重建 mpv，也一直是用户选的。
        let settings = AppSettings.load()
        if settings.audioPassthrough ?? false {
            options["audio-spdif"] = "ac3,eac3,dts,dts-hd,truehd"
        }
        if settings.hdrPassthrough ?? false {
            options["target-colorspace-hint"] = "yes"
        }
        if let device = settings.audioDevice, !device.isEmpty {
            options["audio-device"] = device
        }

        // 缓冲大小跟着设置走：默认 512MB，蓝光原盘可以调到 2G / 4G。
        // 网络流才需要预读，本地文件给多了只是白占内存。
        var bufferMb = min(max(settings.bufferSizeMb ?? 512, 128), 8192)
        // 自检用：无桌面环境验证三层进度条时，把缓冲压小才看得到「未观看」那一段。
        if let forced = Int(ProcessInfo.processInfo.environment["DVPLAYER_BUFFER_MB"] ?? ""),
           forced > 0 {
            bufferMb = forced
        }
        options["cache"] = "yes"
        options["demuxer-max-bytes"] = "\(bufferMb)MiB"
        options["demuxer-max-back-bytes"] = "\(max(64, bufferMb / 2))MiB"

        // `start` 只在第一次 loadfile 时生效，放在这里；
        // 切集时再用 `set_property start` 逐次设置。
        if let startSeconds, startSeconds > 1 {
            options["start"] = String(format: "%.3f", startSeconds)
        }

        client.onEvent = { [weak self] name, data in
            self?.handle(event: name, data: data)
        }
        client.onDisconnect = { [weak self] in
            guard let self, !self.shuttingDown else { return }
            // mpv 核心没了：这个实例不能再复用。
            self.ready = false
            NSLog("[Play] mpv 核心已销毁")
            self.onError?("播放器已退出")
        }

        guard client.start(options: options) else {
            NSLog("[Play] libmpv 初始化失败")
            return nil
        }

        NSLog("[Play] libmpv 已启动")

        // 渲染上下文由视图在第一次 draw 时建（必须在 GL 上下文 current 的线程上）。
        // mpv 要等它有渲染上下文才肯初始化视频链路，所以 `ready` 在之后才置位，
        // 期间来的 loadfile 先存着。
        view.onRenderReady = { [weak self] in
            self?.finishConnect()
        }
        view.onFirstDraw = { [weak self] in
            self?.releaseFirstFrameWait()
        }
    }

    /// 渲染上下文就绪之后的收尾。
    private func finishConnect() {
        guard !shuttingDown else { return }
        guard !ready else { return }

        for name in Self.observed {
            client.observe(name)
        }
        client.command(["set_property", "secondary-sub-visibility", "yes"])
        ready = true

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
        client.command(["set_property", "http-header-fields", fields])

        // 服务器的代理设置：设了就一直用，切集换成新源时会重新设。
        client.command(["set_property", "http-proxy", Self.normalizeProxy(proxy)])

        // 起播先停在第一帧：音频约 0.4 秒就出声，而首帧要 1 秒左右，
        // 直接播会「声音先出来、画面晚约 1 秒」。
        client.command(["set_property", "pause", "yes"])

        // `start` 是 option：先设再 loadfile，比给 loadfile 传 options 稳
        // （mpv 的 loadfile options 在 IPC 里要传数组，逗号串会被当成非法值）。
        let startValue = (startOverride ?? 0) > 1
            ? String(format: "%.3f", startOverride ?? 0)
            : "none"
        client.command(["set_property", "start", startValue])

        NSLog("[Play] mpv load \(Self.redacted(url).prefix(72))… start=\(startValue)")
        client.command(["loadfile", url, "replace"])
        waitFirstFrame()
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
        client.command(["set_property", "pause", "no"])
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
        client.command(["set_property", "pause", "no"])
    }

    func pause() {
        cancelFirstFrameWait()
        client.command(["set_property", "pause", "yes"])
    }

    func togglePause() {
        cancelFirstFrameWait()
        client.command(["set_property", "pause", paused ? "no" : "yes"])
    }

    func seek(to seconds: Double) {
        let value = max(0, seconds)
        client.command(["seek", String(format: "%.3f", value), "absolute"])
        lastPositionEmit = 0
    }

    func setVolumePercent(_ percent: Double) {
        client.command(["set_property", "volume", String(format: "%.1f", min(100, max(0, percent)))])
    }

    func setMuted(_ muted: Bool) {
        client.command(["set_property", "mute", muted ? "yes" : "no"])
    }

    func setSpeed(_ speed: Double) {
        client.command(["set_property", "speed", String(format: "%.3f", speed)])
    }

    // MARK: - 音频输出 / 直通 / HDR

    /// 换音频输出设备（mpv 的 `audio-device` 名字，`auto` 是系统默认）。
    func setAudioDevice(_ name: String) {
        client.command(["set_property", "audio-device", name])
        audioDevice = name

        var settings = AppSettings.load()
        settings.audioDevice = name
        settings.save()
        onAudioConfig?()
    }

    /// 音频直通：交给功放解 AC3 / EAC3 / DTS / TrueHD。
    func setAudioPassthrough(_ enabled: Bool) {
        client.command(["set_property", "audio-spdif",
                     enabled ? "ac3,eac3,dts,dts-hd,truehd" : ""])
        audioPassthrough = enabled

        var settings = AppSettings.load()
        settings.audioPassthrough = enabled
        settings.save()
        onAudioConfig?()
    }

    /// HDR 直通：`target-colorspace-hint`，系统开了 HDR 才真的进 PQ。
    func setHdrPassthrough(_ enabled: Bool) {
        client.command(["set_property", "target-colorspace-hint", enabled ? "yes" : "no"])
        hdrPassthrough = enabled

        var settings = AppSettings.load()
        settings.hdrPassthrough = enabled
        settings.save()
        onAudioConfig?()
    }

    func selectAudio(_ trackId: Int64) {
        client.command(["set_property", "aid", trackId > 0 ? String(trackId) : "no"])
    }

    func selectSubtitle(_ trackId: Int64) {
        client.command(["set_property", "sid", trackId > 0 ? String(trackId) : "no"])
    }

    /// 弹幕：`sub-add` 之后用 `secondary-sid` 让它和用户选的字幕同时显示。
    /// `sub-add` 在 JSON IPC 里不返回轨道 id，所以加完再查一次 `track-list`，
    /// 按 `external-filename` 找到刚加的那条。
    func addSecondarySubtitle(_ path: String) {
        let primary = subtitleId
        let generation = loadGeneration
        secondarySubtitlePath = path
        client.command(["sub-add", path, "auto"])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, generation == self.loadGeneration else { return }
            self.bindSecondarySubtitle(path: path, primary: primary)
        }
    }

    private func bindSecondarySubtitle(path: String, primary: Int64) {
        client.command(["get_property", "track-list"]) { [weak self] reply in
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
                self.client.command(["set_property", "secondary-sid", String(id)])
                // 加弹幕时如果没有主字幕，mpv 会把它选成主字幕：退回 secondary。
                if primary == 0 {
                    self.client.command(["set_property", "sid", "no"])
                }
                NSLog("[Danmaku] secondary sub id=\(id) primary=\(primary)")
            }
        }
    }

    func clearSecondarySubtitle() {
        client.command(["set_property", "secondary-sid", "no"])
    }

    /// 在线下载的字幕：直接加进来并选上（主字幕）。
    func addPrimarySubtitle(_ path: String) {
        client.command(["sub-add", path, "select"])
        NSLog("[Play] sub-add primary \(path)")
    }

    /// 画面比例：`keepaspect` 控制是否保持宽高比，`panscan=1` 是裁切填满，
    /// `video-aspect-override` 强制一个比例（`no` 表示不覆盖）。
    /// `video-aspect-override` 是逐文件的，换集后要重新套一次。
    func setAspect(keepAspect: Bool, panscan: Double, aspectOverride: String) {
        client.command(["set_property", "keepaspect", keepAspect ? "yes" : "no"])
        client.command(["set_property", "panscan", String(format: "%.2f", panscan)])
        client.command(["set_property", "video-aspect-override", aspectOverride])
    }

    /// mpv 自己截一帧（解码输出，不含后处理）。
    func screenshot(to path: String) {
        screenshotWindow(to: path)
    }

    /// 截图：从我们自己的 GL framebuffer 读一帧。
    ///
    /// 不能用 mpv 的 `screenshot-to-file`：render API 下它会**静默回退到软件路径**，
    /// 截出来的是解码帧直接转 RGB、不含 DV reshape（实测发紫）。
    func screenshotWindow(to path: String) {
        guard let videoView else {
            NSLog("[Play] 截图失败：没有视频画布")
            return
        }
        if !videoView.snapshot(to: path) {
            NSLog("[Play] 截图失败：framebuffer 读取失败")
        }
    }

    /// 播放窗置顶开关：单窗口之后就是普通的窗口层级，交给 `NSWindow`。
    ///
    /// 保留这个方法是因为 `PlayerSession` / `PlayerWindow` 在 App 激活 / 失活时
    /// 会调它；现在只需要把窗口层级提上去 / 放下来，不再有第二个进程的窗口。
    func setOnTop(_ on: Bool) {
        guard on != ontop else { return }
        ontop = on
    }

    func toggleMuteIPC() {
        client.command(["set_property", "mute", muted ? "no" : "yes"])
    }

    /// 关闭 mpv：先销毁渲染上下文（要在 GL 线程），再销毁核心。
    ///
    /// `mpv_terminate_destroy` 会等 mpv 的线程收尾，可能几十毫秒到几百毫秒；
    /// 放到后台线程做，主线程只负责把窗口关掉。
    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        cancelFirstFrameWait()

        let client = self.client
        let view = videoView
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // 渲染上下文必须在 GL 上下文 current 的线程销毁。
                view?.shutdownRenderContext()
                client.close()
                continuation.resume()
            }
        }
    }

    /// 退出 App 时的同步收尾。
    ///
    /// `applicationWillTerminate` 返回后进程就没了，MainActor 上排队的 `shutdown()`
    /// 不会再执行。进程内的 mpv 会跟着进程一起消失，这里只需要在有限时间内
    /// 把渲染上下文和核心收干净，别让退出卡住。
    func shutdownNow() {
        guard !shuttingDown else { return }
        shuttingDown = true
        cancelFirstFrameWait()

        let client = self.client
        let view = videoView
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            view?.shutdownRenderContext()
            client.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.6)
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
            case "decoder-frame-drop-count":
                droppedFrames = Int(doubleValue(data) ?? 0)
            case "vo-drop-frame-count":
                droppedFrames += Int(doubleValue(data) ?? 0)
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

    /// 日志里不能出现签名 / token：去掉 query 和 userinfo。
    private static func redacted(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.query = nil
        components.user = nil
        components.password = nil
        return components.string ?? url
    }
}
