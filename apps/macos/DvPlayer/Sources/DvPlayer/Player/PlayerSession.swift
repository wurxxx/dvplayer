import AppKit
import Foundation
import SwiftUI
import DvCore

/// 播放页右侧「选集」里的一集（和 Windows 的 `PlayEpisode` 对齐）。
struct PlayerEpisode: Identifiable, Hashable {
    let id: String
    let badge: String
    let meta: String
    let posterPath: String?
    let title: String

    init(id: String, badge: String, meta: String, posterPath: String?, title: String) {
        self.id = id
        self.badge = badge
        self.meta = meta
        self.posterPath = posterPath
        self.title = title
    }

    init(item: MediaItem, number: Int, season: Int?) {
        let badge = season.map { String(format: "S%02dE%02d", $0, number) }
            ?? String(format: "E%02d", number)
        let runtime = MediaText.runtime(item.runtimeSeconds)
        let meta = [item.resolution, runtime]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        self.init(id: item.id,
                  badge: badge,
                  meta: meta,
                  posterPath: item.posterPath,
                  title: MediaText.clean(item.title))
    }

    /// 把一个容器的子项排成播放列表：集号升序，服务器漏号时用未被占用的最小号补。
    /// 规则和详情页的 `makeRows` 一致，两边显示同一个号。
    static func list(from items: [MediaItem], season: Int?) -> [PlayerEpisode] {
        var numbered: [(item: MediaItem, number: Int)] = []
        var missing: [MediaItem] = []
        var used = Set<Int>()

        for item in items {
            if let number = item.episodeNumber, number > 0, !used.contains(number) {
                used.insert(number)
                numbered.append((item, number))
            } else {
                missing.append(item)
            }
        }

        if !missing.isEmpty {
            var taken = used
            let upper = max(taken.max() ?? 0, items.count)
            var candidate = 1
            for item in missing {
                while taken.contains(candidate) && candidate <= upper { candidate += 1 }
                numbered.append((item, candidate))
                taken.insert(candidate)
                candidate += 1
            }
        }

        return numbered
            .sorted { $0.number < $1.number }
            .map { PlayerEpisode(item: $0.item, number: $0.number, season: season) }
    }
}

/// 原盘 / 本地文件的播放源：不经过媒体库核心，URL 是本地文件或一份 EDL。
struct LocalPlayback {
    let itemId: String
    let title: String
    let url: String
    let duration: Double
    /// 媒体库里的本地条目（ISO 从媒体库点开时），进度回写到核心而不是本地 JSON。
    var coreItemId: String?
    /// 起播点：本地源已经在核心那边存了续播点。
    var startSeconds: Double?
}

/// 一张挂载中的原盘：播放器右侧「标题」面板靠它切标题。
///
/// 和 Windows 一样，条目 id 是 `iso:<盘名>:mpls<N>`；每个标题一份
/// 本地进度（从媒体库点开时回写到核心的 ISO 条目）。切标题不用卸载盘，
/// 重新 `prepare` 一份 EDL 再重启 mpv 即可。
struct DiscPlayback {
    let disc: BluRaySession
    /// 从媒体库点开时核心给的片名；直接打开 ISO 时没有。
    let hintTitle: String?
    let coreItemId: String?

    var displayName: String {
        if let hint = hintTitle, !hint.isEmpty {
            return hint
        }
        return disc.discName
    }

    private var isoName: String {
        URL(fileURLWithPath: disc.isoPath).deletingPathExtension().lastPathComponent
    }

    func itemId(for title: BluRayTitle) -> String {
        "iso:\(isoName):mpls\(title.id)"
    }

    func title(for itemId: String) -> BluRayTitle? {
        disc.titles.first { self.itemId(for: $0) == itemId }
    }

    /// 为一个标题生成播放源（EDL 写到临时目录）。
    func local(_ title: BluRayTitle, start: Double?) -> LocalPlayback? {
        guard let url = disc.prepare(title) else { return nil }
        return LocalPlayback(itemId: itemId(for: title),
                             title: "\(displayName) · 标题 \(title.number)",
                             url: url.path,
                             duration: title.duration,
                             coreItemId: coreItemId,
                             startSeconds: start)
    }

    /// 右侧面板里的标题：正片在前（长的先），花絮按标题号。
    func playlist() -> [PlayerEpisode] {
        let features = disc.titles
            .filter(disc.isFeature)
            .sorted { $0.duration > $1.duration }
        let extras = disc.titles
            .filter { !disc.isFeature($0) }
            .sorted { $0.number < $1.number }

        return (features + extras).map { title in
            PlayerEpisode(id: itemId(for: title),
                          badge: "标题 \(title.number)",
                          meta: "\(disc.isFeature(title) ? "正片" : "花絮")"
                              + " · \(title.durationLabel)",
                          posterPath: nil,
                          title: "\(displayName) · 标题 \(title.number)")
        }
    }
}

/// 播放页音轨 / 字幕菜单的一项。id 是 mpv 的轨道 id（选轨直接用它）。
struct PlayerTrack: Identifiable, Hashable {
    let id: Int64
    let name: String
    let detail: String
    let language: String?
    let title: String?
    let isDefault: Bool
}

/// 画面比例。`fill` 是裁切填满（panscan），`stretch` 不保持宽高比。
enum PlayerAspect: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch
    case ratio16x9
    case ratio4x3

    var id: String { rawValue }

    var label: String {
        switch self {
            case .fit: return "适应窗口"
            case .fill: return "填充窗口（裁切）"
            case .stretch: return "拉伸铺满"
            case .ratio16x9: return "强制 16:9"
            case .ratio4x3: return "强制 4:3"
        }
    }

    var keepAspect: Bool { self != .stretch }

    var panscan: Double { self == .fill ? 1 : 0 }

    var aspectOverride: String {
        switch self {
            case .ratio16x9: return "16:9"
            case .ratio4x3: return "4:3"
            default: return "no"
        }
    }
}

/// 播放页的状态：mpv 视图 + 控制条 / 选集要用的所有值。
///
/// 回调都从 `MpvEngine` 的主线程回调进来，所以这里不切队列。
@MainActor
final class PlayerSession: ObservableObject {

    enum Panel {
        case none
        case episodes
        case info
        case subtitles
    }

    // —— mpv（子进程 + IPC，视频在 mpv 自己的窗口里） ——
    private(set) var mpv: MpvEngine!
    /// 起 mpv 时用的 frame：进程退出后重试要按同一个形状重开。
    private let engineFrame: NSRect
    /// 上次打开失败的参数：错误面板「重试」照原样再跑一次。
    private var retryItemId: String?
    private var retryStartSeconds: Double?

    // —— 正在播的 ——
    @Published private(set) var itemId: String
    @Published private(set) var source: PlaySource?
    @Published private(set) var mediaInfo: MediaInfo?
    @Published private(set) var title: String
    @Published private(set) var seriesTitle: String?
    @Published private(set) var playlist: [PlayerEpisode]
    @Published private(set) var hintTitle: String

    // —— 状态 ——
    @Published var loading = true
    /// mpv 在等缓存（`paused-for-cache`）：出画后在播放窗中间显示一个小状态。
    @Published private(set) var buffering = false
    @Published var error: String?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var speed: Double = 1
    @Published var volume: Double = 100
    @Published var muted = false
    @Published var eof = false

    /// 播放期间不让系统熄屏 / 休眠（暂停时释放，让系统按用户设置正常熄屏）。
    private let sleepBlocker = SleepBlocker()

    // —— 音频输出 / 直通 / HDR ——
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var audioDevice: String = ""
    @Published private(set) var audioPassthrough = false
    @Published private(set) var hdrPassthrough = false
    /// HDR → SDR 亮度参考（nits）；0 = 自动（100 nit）。
    @Published private(set) var hdrPeakNits = 0

    // —— 轨道 ——
    @Published private(set) var audioTracks: [PlayerTrack] = []
    @Published private(set) var subtitleTracks: [PlayerTrack] = []
    @Published private(set) var selectedAudioId: Int64 = 0
    @Published private(set) var selectedSubtitleId: Int64 = 0

    // —— 浮层 ——
    @Published var chromeVisible = true

    /// 上一次重置「控制条 3 秒后隐藏」的时间，见 showChrome()。
    private var lastChromePoke = Date.distantPast
    @Published var panel: Panel = .none
    @Published var toast: String?
    @Published var isFullscreen = false
    /// 窗口置顶（播放页的图钉）：置顶后切到别的 App 也盖在上面。
    @Published var isAlwaysOnTop = false
    /// 窗口控制器接这个：把播放窗的 level 在 .normal / .floating 之间切。
    var onToggleAlwaysOnTop: (() -> Void)?
    /// 全屏切换那一拍不要跟着窗口 frame 同步（否则 mpv 会被中间态拽一下）。
    var isFullscreenSwitching = false
    @Published var isScrubbing = false
    @Published var seekPosition: Double = 0
    /// demuxer 缓存到的位置（秒）；进度条画「已缓冲」那一段。
    @Published private(set) var bufferedPosition: Double = 0
    /// 缓存 / 下载速度（字节每秒）。右上角显示，0.05 MB/s 以下不显示。
    @Published private(set) var cacheSpeed: Double = 0

    // —— 画面比例 / 定时关闭 / 片头片尾 ——
    @Published private(set) var aspect: PlayerAspect
    /// 当前视频的显示宽高比（0 = 还不知道）。
    private(set) var videoAspect: Double = 0
    /// 实际输出的动态范围：DV profile（0 = 不是 DV）与传递函数。
    @Published private(set) var dvProfile: Int = 0
    /// P7 的增强层类型："fel" / "mel"；还没探到就是 nil（只标 DV P7）。
    @Published private(set) var dvElType: String?
    @Published private(set) var outputTransfer: String = ""
    /// mpv 解出来的画面参数；原盘没有服务端媒体信息，chips 靠它们。
    @Published private(set) var videoWidth: Int = 0
    @Published private(set) var videoHeight: Int = 0
    @Published private(set) var videoFps: Double = 0
    @Published private(set) var videoBitrate: Double = 0
    @Published private(set) var videoCodecName: String = ""
    /// 窗口控制器接这个：适应窗口时按视频形状改窗口。
    var onVideoAspect: ((Double) -> Void)?
    @Published private(set) var sleepDeadline: Date?
    /// 定时关闭选的是「本集结束后」。
    @Published private(set) var sleepEndOfEpisode = false
    @Published private(set) var markers = SkipMarker()
    /// 进度进了片尾区间，浮出「跳过片尾」。
    @Published var showSkipOutro = false

    // —— 弹幕 ——
    @Published private(set) var danmakuEnabled: Bool
    @Published private(set) var danmakuStatus: String?
    private var danmakuTask: Task<Void, Never>?
    private var danmakuNoticeShown = false

    // —— 在线字幕 ——
    @Published private(set) var subtitleResults: [SubtitleResult] = []
    @Published private(set) var subtitleSearching = false
    @Published private(set) var subtitleError: String?

    // —— 由窗口控制器接上的动作 ——
    var onClose: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?

    private var localSource: LocalPlayback?
    /// 原盘：切标题时重新生成 EDL，不卸载盘。
    private let discSource: DiscPlayback?
    private var initialStart: Double?
    private var loadToken = 0
    /// 音轨 / 字幕各自套用一次：字幕轨常比音轨晚到，不能共用标记。
    private var audioPrefsApplied = false
    private var subtitlePrefsApplied = false
    /// 媒体信息请求已结束（成功与否），字幕自动选择不用再等它。
    private var mediaInfoLoaded = false
    private var isStopped = false
    private var launchStart: Double = 0
    private var launchAt = Date()
    /// 首帧判定基准：起播点；片头跳过后改到跳到的位置。
    private var loadingFloor: Double = 0
    /// 巡检用：假装首帧一直没来（`DVPLAYER_OPENING_HOLD=1`），验证慢网络遮罩。
    private static let openingHold =
        ProcessInfo.processInfo.environment["DVPLAYER_OPENING_HOLD"] == "1"
    /// 巡检用：出画后强制显示「正在缓冲…」状态（`DVPLAYER_BUFFERING_HOLD=1`）。
    private static let bufferingHold =
        ProcessInfo.processInfo.environment["DVPLAYER_BUFFERING_HOLD"] == "1"
    /// 每集的 RPU 探测只做一次（mpv 会反复推 video-params）。
    private var doviProbeStarted = false
    /// 按条目缓存 FEL / MEL：切回来不再重复读码流。
    private static var doviCache: [String: String] = [:]
    private var lastReportAt = Date.distantPast
    /// 上一次上报的秒数：暂停时周期上报跳过没变的位置。
    private var lastReportedPosition: Double = -1
    private var hideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var reportTimer: Timer?
    private var aboutToClose = false
    /// 加载超时计时（见 startLoadTimeout）。
    private var loadTimeoutTask: Task<Void, Never>?
    /// 这次加载是不是被 30 秒超时判过：首帧晚到时要把那条错误收掉。
    private var loadTimedOut = false

    private static let resumeThreshold = 5.0
    private static let reportEvery: TimeInterval = 10

    init?(itemId: String,
          startSeconds: Double?,
          playlist: [PlayerEpisode] = [],
          seriesTitle: String? = nil,
          hintTitle: String? = nil,
          frame: NSRect,
          local: LocalPlayback? = nil,
          disc: DiscPlayback? = nil) {
        let effectiveId = local?.itemId ?? itemId
        self.itemId = effectiveId
        self.localSource = local
        self.discSource = disc
        self.initialStart = startSeconds
        self.playlist = playlist
        self.seriesTitle = Self.cleanSeries(seriesTitle)
        self.hintTitle = hintTitle ?? ""
        self.title = local?.title ?? hintTitle ?? "正在播放"
        let settings = AppSettings.load()
        self.aspect = PlayerAspect(rawValue: settings.videoAspect ?? "") ?? .fit
        self.danmakuEnabled = settings.danmakuEnabled ?? false
        self.audioPassthrough = settings.audioPassthrough ?? false
        self.hdrPassthrough = settings.hdrPassthrough ?? false
        self.hdrPeakNits = max(0, settings.hdrPeakNits ?? 0)
        self.audioDevice = settings.audioDevice ?? ""
        // 置顶状态跨会话保留：上次开着，下次开播放窗还是置顶。
        self.isAlwaysOnTop = settings.alwaysOnTop ?? false
        self.markers = SkipMarkerStore.marker(for: Self.cleanSeries(seriesTitle) ?? effectiveId)

        guard let engine = MpvEngine(frame: frame,
                                     startSeconds: local == nil ? startSeconds : nil) else {
            return nil
        }
        engineFrame = frame
        mpv = engine
        wire(engine)
    }

    /// 把回调和 mpv 实例接上。进程退出后重试会换一个新实例，所以单独拿出来。
    private func wire(_ engine: MpvEngine) {
        engine.onPosition = { [weak self] position, duration in
            self?.handlePosition(position, duration)
        }
        engine.onPause = { [weak self] paused in
            guard let self else { return }
            self.paused = paused
            self.refreshSleepBlocker()
        }
        engine.onBuffering = { [weak self] value in
            self?.buffering = value
        }
        engine.onLoaded = { [weak self] duration in
            guard let self else { return }
            // 这里只代表文件头拿到了，不代表已经出了第一帧（慢网络下还会继续缓冲）。
            // 黑底等 `video-frame-info` 或 handlePosition 确认真的出画再收。
            if duration > 1 {
                self.duration = duration
            }
            NSLog("[Play] loaded \(self.itemId) duration=\(Int(self.duration))s")
            self.syncAudioConfig()
            self.applyAspect()
            self.applyTrackPrefsIfNeeded()
            self.skipIntroIfNeeded()
            self.loadDanmakuIfNeeded()
        }
        engine.onFirstFrame = { [weak self, weak engine] in
            // 换集时旧进程可能还有一帧在路上：只认当前这个 mpv。
            guard let self, let engine, self.mpv === engine,
                  !Self.openingHold else { return }
            self.finishLoading("first-frame")
            // 真正出画了才算在播：这时按当前 paused / eof 决定是否阻止熄屏。
            // 不在这里补一次的话，起播时 paused 可能还是上一集的值。
            self.refreshSleepBlocker()
        }
        engine.onEOF = { [weak self] in
            self?.handleEOF()
        }
        engine.onTracks = { [weak self] audio, subs, aid, sid in
            self?.handleTracks(audio, subs, aid, sid)
        }
        engine.onVideoAspect = { [weak self] aspect in
            guard let self else { return }
            self.videoAspect = aspect
            self.onVideoAspect?(aspect)
        }
        engine.onVideoRange = { [weak self] profile, transfer in
            guard let self else { return }
            self.dvProfile = profile
            self.outputTransfer = transfer
            self.probeDolbyVisionIfNeeded()
        }
        engine.onVideoStats = { [weak self] width, height, fps, bitrate, codec in
            guard let self else { return }
            self.videoWidth = width
            self.videoHeight = height
            self.videoFps = fps
            self.videoBitrate = bitrate
            self.videoCodecName = codec
        }
        engine.onAudioConfig = { [weak self] in
            self?.syncAudioConfig(verbose: false)
        }
        // 观察的回调可能先于这一行到达，也可能晚到；先搬一次已有的值。
        syncAudioConfig(verbose: false)
        engine.onCacheTime = { [weak self] cache in
            guard let self else { return }
            // 刚 seek 回来缓存位置可能还落在进度后面，至少画到已观看那。
            self.bufferedPosition = max(cache, self.position)
        }
        engine.onCacheSpeed = { [weak self] bytesPerSecond in
            self?.cacheSpeed = bytesPerSecond
        }
        engine.onSpeed = { [weak self] speed in
            self?.speed = speed
        }
        engine.onVolume = { [weak self] volume, muted in
            guard let self else { return }
            self.volume = volume
            self.muted = muted
        }
        engine.onError = { [weak self] message in
            guard let self else { return }
            self.loading = false
            self.error = message
            NSLog("[Play] error \(self.itemId): \(message)")
        }
    }

    // MARK: - 起播 / 切集

    func start() async {
        if let localSource {
            await beginLocal(localSource)
            return
        }

        await begin(itemId: itemId, startSeconds: initialStart)
    }

    /// 本地播放：不取核心播放源、不拉媒体信息，续播点读本地文件。
    private func beginLocal(_ local: LocalPlayback) async {
        // 点开本地文件后、真正开始前窗口可能已经关了。
        guard !isStopped else { return }
        loadToken += 1
        let token = loadToken
        loading = true
        buffering = false
        error = nil
        loadTimedOut = false
        eof = false
        position = 0
        seekPosition = 0
        audioPrefsApplied = false
        subtitlePrefsApplied = false
        mediaInfoLoaded = false
        audioTracks = []
        subtitleTracks = []
        // 上一集的在线字幕搜索结果不能带到这一集。
        subtitleResults = []
        subtitleError = nil
        subtitleSearching = false
        selectedAudioId = 0
        selectedSubtitleId = 0
        mediaInfo = nil
        panel = .none
        showSkipOutro = false
        videoAspect = 0
        dvProfile = 0
        dvElType = nil
        doviProbeStarted = false
        outputTransfer = ""
        videoWidth = 0
        videoHeight = 0
        videoFps = 0
        videoBitrate = 0
        videoCodecName = ""
        bufferedPosition = 0
        markers = SkipMarkerStore.marker(for: markerKey)
        danmakuTask?.cancel()
        danmakuStatus = nil

        source = nil
        localSource = local
        itemId = local.itemId
        title = local.title
        duration = local.duration

        let start = local.startSeconds ?? LocalProgressStore.get(local.itemId)
        launchStart = start
        launchAt = Date()
        loadingFloor = start
        lastReportAt = Date()
        lastReportedPosition = -1

        NSLog("[Play] local load \(local.itemId) from=\(String(format: "%.1f", start)) " +
              "dur=\(Int(local.duration))")
        mpv.loadURL(local.url, headers: [:], start: start)
        startReporting()
        startLoadTimeout(token: token)
    }

    private func begin(itemId: String, startSeconds: Double?) async {
        // 错误面板的「重试」按这次参数再来一遍。
        retryItemId = itemId
        retryStartSeconds = startSeconds

        guard let core = AppState.shared.core else {
            error = "未连接媒体源。"
            loading = false
            return
        }

        loadToken += 1
        let token = loadToken
        // 先不要置 loading：旧文件的 position 回调还在来（切集复用同一个 mpv），
        // 那些回调会走 finishLoading 把黑底收掉，新文件还没开始加载就露出旧画面。
        buffering = false
        error = nil
        loadTimedOut = false
        eof = false
        position = 0
        seekPosition = 0
        audioPrefsApplied = false
        subtitlePrefsApplied = false
        mediaInfoLoaded = false
        audioTracks = []
        subtitleTracks = []
        // 上一集的在线字幕搜索结果不能带到这一集。
        subtitleResults = []
        subtitleError = nil
        subtitleSearching = false
        selectedAudioId = 0
        selectedSubtitleId = 0
        mediaInfo = nil
        panel = .none
        showSkipOutro = false
        videoAspect = 0
        dvProfile = 0
        dvElType = nil
        doviProbeStarted = false
        outputTransfer = ""
        videoWidth = 0
        videoHeight = 0
        videoFps = 0
        videoBitrate = 0
        videoCodecName = ""
        bufferedPosition = 0
        markers = SkipMarkerStore.marker(for: markerKey)
        danmakuTask?.cancel()
        danmakuStatus = nil

        NSLog("[Play] open \(itemId) playlist=\(playlist.count) start=\(startSeconds.map { String($0) } ?? "resume")")

        do {
            let source = try await core.playSource(itemId)
            guard token == loadToken, !isStopped else { return }

            self.itemId = itemId
            self.source = source
            duration = Double(source.durationSeconds)
            title = displayTitle(source, itemId: itemId)

            var start = startSeconds ?? resumePoint(for: source)
            if startSeconds == nil, source.durationSeconds > 0,
               start >= Double(source.durationSeconds) - 1 {
                // 记录停在片尾：从头放，别一加载就 EOF。
                start = 0
            }
            launchStart = start
            launchAt = Date()
            loadingFloor = start
            // 从起播开始计时：否则第一个位置回调用「很久没报过」立刻上报一次，
            // 这时 duration 还没下来，会把记录写成 0。
            lastReportAt = Date()
        lastReportedPosition = -1

            let headers: [String: String] = Dictionary(
                source.headers.map { ($0.name, $0.value) },
                uniquingKeysWith: { _, last in last })
            NSLog("[Play] load \(itemId) from=\(String(format: "%.1f", start)) dur=\(source.durationSeconds)")
            // 拿到地址、真正要 loadfile 了才盖上黑底。
            loading = true
            mpv.loadURL(source.url, headers: headers, start: start, proxy: source.proxy)
            startReporting()
            startLoadTimeout(token: token)

            Task { await loadMediaInfo(itemId: itemId) }
        } catch {
            guard token == loadToken, !isStopped else { return }
            loading = false
            loadTimeoutTask?.cancel()
            loadTimeoutTask = nil
            self.error = error.localizedDescription
            NSLog("[Play] source failed \(itemId): \(error.localizedDescription)")
        }
    }

    /// 续播点小于 5 秒就从头发；开关和 Windows 的「继续播放」一致。
    private func resumePoint(for source: PlaySource) -> Double {
        let enabled = AppSettings.load().resumePlayback
        return enabled && Double(source.positionSeconds) >= Self.resumeThreshold
            ? Double(source.positionSeconds)
            : 0
    }

    func switchTo(itemId: String) {
        guard itemId != self.itemId || error != nil else { return }

        // 媒体库源：切走前把当前集的进度记下并发 stopped，
        // 否则这一集的「看到哪」停在切集前最后一次周期上报的位置。
        if discSource == nil, !eof, position > 0 {
            report(position, stopped: true)
        }

        // 原盘：同一个窗口换标题，重新生成 EDL 再重启 mpv，不查核心。
        if let discSource {
            guard let title = discSource.title(for: itemId) else {
                toast("找不到这个标题")
                return
            }

            // 切走前把当前标题的进度记下，切回来还能续。
            report(position)
            // 侧栏直开的原盘读本地进度；媒体库条目只有一个续播点，切标题从头来。
            let start: Double? = discSource.coreItemId == nil ? nil : 0
            guard let local = discSource.local(title, start: start) else {
                toast("读不到这个标题的视频片段")
                return
            }

            NSLog("[Play] disc switch \(itemId) title=\(title.number) mpls=\(title.id)")
            Task { await beginLocal(local) }
            return
        }

        Task { await begin(itemId: itemId, startSeconds: 0) }
    }

    /// 右边面板这一趟列的是原盘标题还是剧集。
    var isDisc: Bool { discSource != nil }

    /// 错误面板的「重试」：地址没取到就重新取；播放器进程退出就换个新进程。
    func retry() {
        guard !isStopped else { return }
        let id = retryItemId ?? itemId
        let start = retryStartSeconds
        NSLog("[Play] retry item=\(id) start=\(start.map { String($0) } ?? "resume") " +
              "mpvAlive=\(mpv.isAlive)")

        error = nil

        // mpv 子进程已经退出，或 IPC 已经断了：这个实例不能再复用，换个新实例再试。
        if !mpv.isAlive || !mpv.isReady {
            let dead = mpv
            Task { await dead?.shutdown() }
            guard let engine = MpvEngine(frame: engineFrame, startSeconds: nil) else {
                loading = false
                error = "播放器启动失败"
                return
            }
            mpv = engine
            wire(engine)
        }

        // 本地文件 / 原盘不走核心取地址，照原来的入口再来一次。
        if let localSource {
            Task { await beginLocal(localSource) }
            return
        }

        Task { await begin(itemId: id, startSeconds: start) }
    }

    func playEpisode(_ episode: PlayerEpisode) {
        switchTo(itemId: episode.id)
    }

    func setPlaylist(_ episodes: [PlayerEpisode], seriesTitle: String?) {
        playlist = episodes
        if let cleaned = Self.cleanSeries(seriesTitle) {
            self.seriesTitle = cleaned
        }
        // 剧名可能晚到（续播后台补选集），到了再按剧名取一次标记。
        markers = SkipMarkerStore.marker(for: markerKey)
        if let source {
            title = displayTitle(source, itemId: itemId)
        }
        NSLog("[Play] playlist attached item=\(itemId) n=\(episodes.count) title=\(self.seriesTitle ?? "-")")

        // 续播是先用记录里的剧名起播、选集后到：弹幕要等集号才查得准，
        // 前面那次可能已经按「电影」查过了，这里补一次。
        if danmakuEnabled, danmakuStatus == nil {
            loadDanmakuIfNeeded()
        }
    }

    // MARK: - mpv 回调

    private func handlePosition(_ position: Double, _ duration: Double) {
        if duration > 1 {
            self.duration = duration
        }

        // 播完以后用户又把进度拖回片尾之前：这一集重新算「正在看」。
        // 不重置的话，关窗时 eof 分支会按片长上报，把刚拖回去的进度改成「已看完」。
        if eof, duration > 1, position < duration - 2 {
            eof = false
        }

        guard !isScrubbing else { return }
        self.position = position
        seekPosition = position

        // 兜底：有些 VO 不报 video-frame-info（比如无头），就等播放位置真的往前走。
        // 慢网络下 mpv 会先报续播点（或者 0），但一帧都还没出来，这时不能收黑底。
        if loading, !Self.openingHold, position > loadingFloor + 0.5 {
            finishLoading("position")
        }

        if Date().timeIntervalSince(lastReportAt) >= Self.reportEvery, position > 0,
           abs(position - lastReportedPosition) >= 1 {
            lastReportAt = Date()
            report(position)
        }

        // 片尾区间到了就浮「跳过片尾」，退回去再收起来。
        if let outro = markers.outroStart, outro > 1, duration > 0 {
            let inOutro = position >= outro && position < duration - 1
            if inOutro != showSkipOutro {
                showSkipOutro = inOutro
            }
        }
    }

    /// 首帧到了：收掉不透明黑底。`video-frame-info` 先到就用它，位置兜底。
    private func finishLoading(_ reason: String) {
        // 超时之后首帧才到（慢 NAS / 大文件）：视频已经在放了，别让界面停在错误面板。
        if loadTimedOut {
            loadTimedOut = false
            if error != nil {
                error = nil
            }
        }

        guard loading else { return }
        loading = false
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        NSLog("[Play] loading finish reason=\(reason) pos=\(String(format: "%.1f", position)) " +
              "floor=\(String(format: "%.1f", loadingFloor))")
        if Self.bufferingHold {
            buffering = true
        }
    }

    /// 加载超时：网络慢或文件读不出来时，别让黑底一直转。
    /// 以前 `file_error` 文案为空时没有任何兜底，界面就永远停在加载中。
    private func startLoadTimeout(token: Int, seconds: UInt64 = 30) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard token == self.loadToken, self.loading, !self.isStopped else { return }
            self.loading = false
            self.loadTimedOut = true
            self.error = "加载超时：媒体源没有响应，或这个文件读不出来。"
            NSLog("[Play] load timeout item=\(self.itemId)")
        }
    }

    private func handleEOF() {
        eof = true
        // 播完了，别再拦着系统熄屏。
        refreshSleepBlocker()

        // 续播点正好是片尾：mpv 一加载就 EOF，这不是「播完」，从头来一遍。
        let instant = Date().timeIntervalSince(launchAt) < 3
        if instant, launchStart > 0, duration > 0, launchStart >= duration - 2 {
            let url = source?.url ?? localSource?.url
            let headers: [String: String] = Dictionary(
                (source?.headers ?? []).map { ($0.name, $0.value) },
                uniquingKeysWith: { _, last in last })
            if let url {
                NSLog("[Play] eof at resume point -> restart")
                eof = false
                position = 0
                launchStart = 0
                launchAt = Date()
                mpv.loadURL(url, headers: headers, start: 0)
                return
            }
        }

        report(duration > 0 ? duration : Double(source?.durationSeconds ?? 0))

        if sleepEndOfEpisode {
            sleepEndOfEpisode = false
            NSLog("[Play] sleep at end of episode -> close")
            requestClose()
            return
        }

        // 原盘的标题是正片 / 花絮，不是剧集：播完这一段就收工，
        // 不自动跳到下一个标题。想换标题在右侧面板里点。
        if discSource != nil {
            NSLog("[Play] eof disc \(itemId) -> close (titles=\(playlist.count))")
            requestClose()
            return
        }

        let index = playlist.firstIndex { $0.id == itemId }
        if let index, index + 1 < playlist.count {
            let next = playlist[index + 1]
            NSLog("[Play] eof \(itemId) -> next \(next.id)")
            switchTo(itemId: next.id)
            return
        }

        NSLog("[Play] eof \(itemId) -> close (playlist=\(playlist.count))")
        requestClose()
    }

    private func handleTracks(_ audio: [RawTrack],
                              _ subtitles: [RawTrack],
                              _ aid: Int64,
                              _ sid: Int64) {
        let hadTracks = !self.audioTracks.isEmpty || !self.subtitleTracks.isEmpty

        audioTracks = audio.map { raw in
            let language = raw.language.isEmpty ? nil : raw.language
            let title = raw.title.isEmpty ? nil : raw.title
            let name = TrackPrefs.audioName(language: language,
                                            title: title,
                                            codec: raw.codec.isEmpty ? nil : raw.codec)
            let detail = [language, raw.codec.isEmpty ? nil : raw.codec,
                          raw.isExternal ? "外部" : nil]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return PlayerTrack(id: raw.id, name: name, detail: detail,
                               language: language, title: title, isDefault: raw.isDefault)
        }

        // 字幕菜单只写「语言 · 标题」，没有标题的轨（`HDMV PGS_SUBTITLE`）不再露编码，
        // 重名的追加序号。
        let subtitleLabels = TrackPrefs.subtitleLabels(subtitles.map { raw in
            (language: raw.language.isEmpty ? nil : raw.language,
             title: raw.title.isEmpty ? nil : raw.title)
        })

        subtitleTracks = subtitles.enumerated().map { index, raw in
            let language = raw.language.isEmpty ? nil : raw.language
            let title = raw.title.isEmpty ? nil : raw.title
            let name = subtitleLabels[index]
            // 名字里已经有语言 / 标题了，这里只补「外部」。
            let detail = raw.isExternal ? "外部" : ""
            return PlayerTrack(id: raw.id, name: name, detail: detail,
                               language: language, title: title, isDefault: raw.isDefault)
        }

        // 服务器的媒体信息可能比 `track-list` 晚到；到了以后按轨序把语言补回来。
        refreshSubtitleLabels()

        // mpv 自己开了默认轨（比如第一条字幕）时，勾要跟着它。
        selectedAudioId = aid
        selectedSubtitleId = sid

        if hadTracks {
            NSLog("[Play] tracks audio=\(audioTracks.count) subs=\(subtitleTracks.count) aid=\(aid) sid=\(sid)")
        }
        applyTrackPrefsIfNeeded()
    }

    // MARK: - 音轨 / 字幕

    /// mpv 对原盘 / remux 常常只给容器标题（`HDMV PGS_SUBTITLE`）、语言为空；
    /// 服务器的媒体信息里如果有 ffprobe 读到的语言，按轨序补回来（只补缺的）。
    private func refreshSubtitleLabels() {
        guard !subtitleTracks.isEmpty else { return }
        let server = mediaInfo?.subtitles ?? []

        let labels = TrackPrefs.subtitleLabels(subtitleTracks.enumerated().map { index, track in
            var language = track.language
            var title = track.title
            if server.indices.contains(index) {
                if TrackPrefs.languageName(language) == nil {
                    language = server[index].language
                }
                if TrackPrefs.isCodecLabel(title) {
                    title = server[index].title
                }
            }
            return (language: language, title: title)
        })

        subtitleTracks = subtitleTracks.enumerated().map { index, track in
            PlayerTrack(id: track.id,
                        name: labels.indices.contains(index) ? labels[index] : track.name,
                        detail: track.detail,
                        language: track.language,
                        title: track.title,
                        isDefault: track.isDefault)
        }

        if !server.isEmpty {
            NSLog("[Play] subtitle labels server=\(server.count) -> "
                  + labels.joined(separator: ","))
        }
    }

    /// 音轨 / 字幕各自只套用一次；每次轨道或媒体信息更新都试一下。
    /// 详情页没读媒体信息就起播（续播、切集）时，退到 mpv 轨上的中文判断。
    private func applyTrackPrefsIfNeeded() {
        if !audioPrefsApplied, !audioTracks.isEmpty {
            audioPrefsApplied = true
            if let index = TrackPrefs.audio(itemId), audioTracks.indices.contains(index) {
                selectAudio(audioTracks[index].id, remember: false)
            }
        }

        if subtitlePrefsApplied {
            return
        }

        // 明确选了「关闭」：不依赖字幕轨，直接关。
        let saved = TrackPrefs.subtitle(itemId)
        if saved == TrackPrefs.subtitleOff {
            subtitlePrefsApplied = true
            selectSubtitle(0, remember: false)
            return
        }

        // 字幕轨还没出现（外挂字幕 / 原盘字幕索引慢）：等下一次轨道清单。
        guard !subtitleTracks.isEmpty else { return }

        // 没手动选时，自动选择要读服务器的字幕表；媒体信息还在路上就先等，
        // 否则会把「已套用」标记掉，等表到了也不再选。
        // 本地文件没有服务器媒体信息，别一直等它。
        if saved == nil, mediaInfo == nil, !mediaInfoLoaded, localSource == nil {
            return
        }

        subtitlePrefsApplied = true

        if let pref = saved {
            if subtitleTracks.indices.contains(pref) {
                selectSubtitle(subtitleTracks[pref].id, remember: false)
            }
            return
        }

        // 原盘 remux 的 mpv 轨常常没有语言 / 标题（只有 HDMV PGS_SUBTITLE），
        // 按 mpv 的 lang 猜不到中文，必须借服务器字幕表（和详情页同一套规则）。
        if let info = mediaInfo, !info.subtitles.isEmpty {
            let index = TrackPrefs.resolveSubtitle(itemId, info.subtitles)
            NSLog("[Play] subtitle resolve index=\(index) server=\(info.subtitles.count) "
                  + "mpv=\(subtitleTracks.count)")
            if index == TrackPrefs.subtitleOff {
                selectSubtitle(0, remember: false)
            } else if subtitleTracks.indices.contains(index) {
                selectSubtitle(subtitleTracks[index].id, remember: false)
            }
            return
        }

        if let chinese = subtitleTracks.first(where: {
            TrackPrefs.isChinese($0.language, $0.title)
        }) {
            NSLog("[Play] subtitle auto zh id=\(chinese.id) lang=\(chinese.language ?? "-")")
            selectSubtitle(chinese.id, remember: false)
        }
    }

    /// 自检用：当前选的音轨 / 字幕（`subs` 是 mpv 轨的清单）。
    var trackSummary: String {
        let audio = audioTracks.first { $0.id == selectedAudioId }
        let subtitle = subtitleTracks.first { $0.id == selectedSubtitleId }
        return "aid=\(selectedAudioId)(\(audio?.name ?? "-")) "
            + "sid=\(selectedSubtitleId)(\(subtitle?.name ?? "-")) "
            + "avail=\(subtitleTracks.map { "\($0.id):\($0.name)" }.joined(separator: ","))"
    }

    func selectAudio(_ trackId: Int64) {
        selectAudio(trackId, remember: true)
    }

    // MARK: - 音频输出 / 直通 / HDR

    /// 当前音频输出的短标签（「更多」菜单和 toast 用）。
    var audioOutputLabel: String {
        let device = audioDevices.first { $0.name == audioDevice }
        var label = device?.label
            ?? (audioDevice.isEmpty || audioDevice == "auto" ? "系统默认" : audioDevice)
        if audioPassthrough { label += " · 直通" }
        if hdrPassthrough { label += " · HDR" }
        return label
    }

    func setAudioDevice(_ name: String) {
        mpv.setAudioDevice(name)
        audioDevice = name
        syncAudioConfig()
        toast("音频输出：\(audioOutputLabel)")
        showChrome()
    }

    func toggleAudioPassthrough() {
        let enabled = !audioPassthrough
        mpv.setAudioPassthrough(enabled)
        audioPassthrough = enabled
        syncAudioConfig()
        toast(enabled ? "音频直通：开" : "音频直通：关")
        showChrome()
    }

    func toggleHdrPassthrough() {
        let enabled = !hdrPassthrough
        mpv.setHdrPassthrough(enabled)
        hdrPassthrough = enabled
        syncAudioConfig()
        toast(enabled ? "HDR 直通：开（系统要开 HDR）" : "HDR 直通：关")
        showChrome()
    }

    /// 「HDR 亮度参考」：0 = 自动（100 nit）。播放中改立即生效。
    func setHdrPeakNits(_ nits: Int) {
        mpv.setHdrPeakNits(nits)
        hdrPeakNits = mpv.hdrPeakNits
        toast(hdrPeakNits <= 0 ? "HDR 亮度参考：自动（100 nit）"
                               : "HDR 亮度参考：\(hdrPeakNits) nit")
        showChrome()
    }

    /// 菜单里的短标签。
    var hdrPeakLabel: String {
        hdrPeakNits <= 0 ? "自动" : "\(hdrPeakNits) nit"
    }

    /// 把 mpv 的值搬回这里（mpv 可能拒绝 / 归一化某个参数）。
    private func syncAudioConfig(verbose: Bool = true) {
        audioDevices = mpv.audioDevices
        audioDevice = mpv.audioDevice
        audioPassthrough = mpv.audioPassthrough
        hdrPassthrough = mpv.hdrPassthrough
        guard verbose else { return }
        NSLog("[Play] audio device=\(audioDevice.isEmpty ? "-" : audioDevice) " +
              "passthrough=\(audioPassthrough) hdr=\(hdrPassthrough) " +
              "devices=\(audioDevices.count)")
    }

    private func selectAudio(_ trackId: Int64, remember: Bool) {
        selectedAudioId = trackId
        mpv.selectAudio(trackId)
        if remember {
            let index = audioTracks.firstIndex { $0.id == trackId }
            TrackPrefs.setAudio(itemId, index)
        }
        NSLog("[Play] select audio \(trackId) -> \(trackSummary)")
        showChrome()
    }

    func selectSubtitle(_ trackId: Int64) {
        selectSubtitle(trackId, remember: true)
    }

    private func selectSubtitle(_ trackId: Int64, remember: Bool) {
        selectedSubtitleId = trackId
        mpv.selectSubtitle(trackId)
        if remember {
            if trackId == 0 {
                TrackPrefs.setSubtitle(itemId, TrackPrefs.subtitleOff)
            } else {
                TrackPrefs.setSubtitle(itemId, subtitleTracks.firstIndex { $0.id == trackId })
            }
        }
        NSLog("[Play] select subtitle \(trackId) -> \(trackSummary)")
        showChrome()
    }

    // MARK: - 控制

    func togglePause() {
        mpv.togglePause()
        showChrome()
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        position = target
        seekPosition = target

        // 播完之后拖回片尾之前：重新算「正在看」（暂停时拖回不一定有时长事件）。
        if eof, duration <= 0 || target < duration - 2 {
            eof = false
        }

        // 跳过去以后原来那段缓存没用了，等 demuxer 重新填。
        bufferedPosition = target
        mpv.seek(to: target)
        showChrome()
    }

    func skip(_ delta: Double) {
        seek(to: position + delta)
        toast("\(delta > 0 ? "快进" : "后退") \(Int(abs(delta))) 秒")
    }

    func setVolume(_ percent: Double) {
        let value = min(100, max(0, percent))
        volume = value
        mpv.setVolumePercent(value)
        mpv.setMuted(false)
        showChrome()
    }

    func toggleMute() {
        mpv.setMuted(!muted)
        showChrome()
    }

    func setSpeed(_ speed: Double) {
        self.speed = speed
        mpv.setSpeed(speed)
        toast("速度 " + (speed == speed.rounded() ? String(Int(speed)) : String(format: "%.2g", speed)) + "×")
    }

    func previousEpisode() {
        guard let index = playlist.firstIndex(where: { $0.id == itemId }), index > 0 else {
            toast(isDisc ? "已经是第一个标题" : "已经是第一集")
            return
        }
        switchTo(itemId: playlist[index - 1].id)
    }

    func nextEpisode() {
        guard let index = playlist.firstIndex(where: { $0.id == itemId }),
              index + 1 < playlist.count else {
            toast(isDisc ? "已经是最后一个标题" : "已经是最后一集")
            return
        }
        switchTo(itemId: playlist[index + 1].id)
    }

    func toggleFullscreen() {
        onToggleFullscreen?()
        showChrome()
    }

    /// 窗口置顶开关（播放页的图钉按钮）。
    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        onToggleAlwaysOnTop?()
        // 跨会话保留：写进设置，下次开播放窗按上次的状态起。
        var settings = AppSettings.load()
        settings.alwaysOnTop = isAlwaysOnTop
        settings.save()
        showChrome()
    }

    func screenshot() {
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DVPlayer", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = title.replacingOccurrences(of: "/", with: "_")
        let stamp = Int(Date().timeIntervalSince1970)
        let path = folder.appendingPathComponent("\(name)_\(stamp).png").path
        mpv.screenshot(to: path)
        toast("截图已保存")
        NSLog("[Play] screenshot \(path)")
    }

    // MARK: - 浮层 / 面板

    func showChrome() {
        // @Published 不判等：鼠标每动一下就赋值会让整个播放页 body 重算。
        if !chromeVisible {
            chromeVisible = true
        }

        // 连续移动每秒几十次：每次都 cancel + 新建 3 秒计时太浪费，
        // 半秒内只重置一次，语义仍是「最后一次移动后 3 秒隐藏」。
        let now = Date()
        if hideTask != nil, now.timeIntervalSince(lastChromePoke) < 0.5 {
            return
        }
        lastChromePoke = now

        hideTask?.cancel()
        guard panel == .none, !isScrubbing else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.panel == .none, !self.isScrubbing else { return }
            self.chromeVisible = false
        }
    }

    func togglePanel(_ next: Panel) {
        panel = panel == next ? .none : next
        showChrome()
    }

    func setScrubbing(_ scrubbing: Bool) {
        isScrubbing = scrubbing
        if !scrubbing {
            seek(to: seekPosition)
        } else {
            showChrome()
        }
    }

    func toast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - 画面比例 / 定时关闭 / 片头片尾

    /// 标记按剧记；电影没有剧名，就用条目 id（等于只对这部片生效）。
    var markerKey: String { seriesTitle ?? itemId }

    private func applyAspect() {
        mpv.setAspect(keepAspect: aspect.keepAspect,
                      panscan: aspect.panscan,
                      aspectOverride: aspect.aspectOverride)
        NSLog("[Play] aspect \(aspect.rawValue) keep=\(aspect.keepAspect ? "yes" : "no") "
              + "panscan=\(String(format: "%.2f", aspect.panscan)) override=\(aspect.aspectOverride)")
    }

    /// 视频窗口置顶：我们 App 活跃时盖住库窗口，切到别的 App 时让位。
    func setOnTop(_ on: Bool) {
        mpv?.setOnTop(on)
    }

    func setAspect(_ mode: PlayerAspect) {
        aspect = mode
        applyAspect()
        var settings = AppSettings.load()
        settings.videoAspect = mode.rawValue
        settings.save()

        if mode == .fit {
            onVideoAspect?(videoAspect)
        }

        toast(mode.label)
        showChrome()
    }

    /// 定时关闭：到点先提示一下再关窗，进度照常回写。
    func setSleep(minutes: Double) {
        sleepEndOfEpisode = false
        sleepDeadline = Date().addingTimeInterval(max(1, minutes * 60))
        let seconds = max(1, Int((minutes * 60).rounded()))
        NSLog("[Play] sleep set \(seconds)s")
        toast(seconds >= 60 ? "\(seconds / 60) 分钟后关闭" : "\(seconds) 秒后关闭")
        showChrome()
    }

    func setSleepEndOfEpisode() {
        sleepDeadline = nil
        sleepEndOfEpisode = true
        NSLog("[Play] sleep set end-of-episode")
        toast("本集结束后关闭")
        showChrome()
    }

    func cancelSleep() {
        sleepDeadline = nil
        sleepEndOfEpisode = false
        NSLog("[Play] sleep cancelled")
        toast("已取消定时关闭")
        showChrome()
    }

    /// 菜单里显示的剩余时间；没设定时就是 nil。
    var sleepLabel: String? {
        if sleepEndOfEpisode { return "本集结束后" }
        guard let deadline = sleepDeadline else { return nil }
        let remaining = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    private func checkSleep() {
        guard let deadline = sleepDeadline, Date() >= deadline else { return }
        sleepDeadline = nil
        NSLog("[Play] sleep fired pos=\(Int(position))")
        toast("定时关闭")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.requestClose()
        }
    }

    func markIntroEnd() {
        guard position > 1 else {
            toast("先播一会儿再标记")
            return
        }
        markers.introEnd = position
        SkipMarkerStore.save(markers, for: markerKey)
        NSLog("[Play] mark intro end \(Int(position)) key=\(markerKey)")
        toast("片头结束：\(clock(position))")
        showChrome()
    }

    func clearIntro() {
        markers.introEnd = nil
        SkipMarkerStore.save(markers, for: markerKey)
        NSLog("[Play] clear intro key=\(markerKey)")
        toast("已清除片头标记")
        showChrome()
    }

    func markOutroStart() {
        guard position > 1 else {
            toast("先播一会儿再标记")
            return
        }
        markers.outroStart = position
        SkipMarkerStore.save(markers, for: markerKey)
        NSLog("[Play] mark outro start \(Int(position)) key=\(markerKey)")
        toast("片尾开始：\(clock(position))")
        showChrome()
    }

    func clearOutro() {
        markers.outroStart = nil
        SkipMarkerStore.save(markers, for: markerKey)
        NSLog("[Play] clear outro key=\(markerKey)")
        toast("已清除片尾标记")
        showChrome()
    }

    func clearMarkers() {
        markers = SkipMarker()
        SkipMarkerStore.save(markers, for: markerKey)
        NSLog("[Play] clear markers key=\(markerKey)")
        toast("已清除本剧标记")
        showChrome()
    }

    /// 起播 / 切集时从片头位置进来才跳；续播点已经在片头后面就不动。
    private func skipIntroIfNeeded() {
        guard let intro = markers.introEnd, intro > 1 else { return }
        let total = duration > 1 ? duration : Double(source?.durationSeconds ?? 0)
        guard total <= 0 || intro < total - 1 else { return }
        guard launchStart < intro - 0.5 else { return }

        mpv.seek(to: intro)
        position = intro
        seekPosition = intro
        // 片头跳过算一次大跳转，首帧判定从跳到的位置重新算。
        loadingFloor = intro
        NSLog("[Play] skip intro -> \(Int(intro)) start=\(Int(launchStart))")
        toast("已跳过片头")
    }

    func skipOutro() {
        showSkipOutro = false
        let target = max(0, duration - 0.4)
        seek(to: target)
        toast("跳过片尾")
    }

    // MARK: - 在线字幕

    /// 季号从选集角标（`S01E02`）里取；电影没有季。
    private var seasonNumber: Int? {
        guard let episode = playlist.first(where: { $0.id == itemId }) else { return nil }
        let badge = episode.badge
        guard badge.hasPrefix("S"), let e = badge.firstIndex(of: "E") else { return nil }
        let digits = badge[badge.index(after: badge.startIndex)..<e]
        return Int(digits)
    }

    func openSubtitleSearch() {
        panel = .subtitles
        showChrome()
        searchSubtitles()
    }

    func searchSubtitles() {
        guard !subtitleSearching else { return }

        let settings = AppSettings.load()
        let apiKey = settings.openSubtitlesApiKey ?? ""
        guard !apiKey.isEmpty else {
            subtitleResults = []
            subtitleError = SubtitleError.missingApiKey.localizedDescription
            NSLog("[Subtitles] 未配置 openSubtitlesApiKey")
            return
        }

        subtitleSearching = true
        subtitleError = nil
        subtitleResults = []

        let query = seriesTitle ?? title
        let season = seasonNumber
        let episode = episodeNumber
        let languages = settings.subtitleLanguages ?? "zh-cn,zh-tw,en"
        NSLog("[Subtitles] search \(query) S\(season ?? 0)E\(episode ?? 0)")

        // 搜索要几秒：切了集之后回来的是上一集的字幕，不能挂到新集上。
        let item = itemId

        Task { [weak self] in
            do {
                let results = try await OpenSubtitlesService.shared.search(
                    title: query,
                    season: season,
                    episode: episode,
                    apiKey: apiKey,
                    username: settings.openSubtitlesUsername,
                    password: settings.openSubtitlesPassword,
                    languages: languages)
                guard let self else { return }
                guard !self.isStopped, self.itemId == item else {
                    NSLog("[Subtitles] stale results for \(item), dropped")
                    return
                }
                self.subtitleResults = results
                self.subtitleSearching = false
                NSLog("[Subtitles] results=\(results.count)")
            } catch {
                guard let self else { return }
                guard !self.isStopped, self.itemId == item else { return }
                self.subtitleError = error.localizedDescription
                self.subtitleSearching = false
                NSLog("[Subtitles] search failed: \(error.localizedDescription)")
            }
        }
    }

    func applySubtitle(_ result: SubtitleResult) {
        let settings = AppSettings.load()
        guard let apiKey = settings.openSubtitlesApiKey, !apiKey.isEmpty else {
            subtitleError = SubtitleError.missingApiKey.localizedDescription
            return
        }

        toast("正在下载字幕…")
        let item = itemId

        Task { [weak self] in
            do {
                let url = try await OpenSubtitlesService.shared.download(
                    result,
                    apiKey: apiKey,
                    username: settings.openSubtitlesUsername,
                    password: settings.openSubtitlesPassword)

                // 下载要几秒：切了集就装到新集上了，必须以发请求时的条目为准。
                guard let self, !self.isStopped, self.itemId == item else { return }
                self.mpv.addPrimarySubtitle(url.path)
                self.toast("字幕已加载：\(result.languageLabel)")
                NSLog("[Subtitles] applied \(result.languageLabel) \(url.lastPathComponent)")
            } catch {
                guard let self, self.itemId == item else { return }
                self.subtitleError = error.localizedDescription
                NSLog("[Subtitles] download failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 弹幕

    /// 选集里这一集的集号（`E02` / `S01E02` 取末尾数字）。
    private var episodeNumber: Int? {
        guard let episode = playlist.first(where: { $0.id == itemId }) else { return nil }
        let digits = String(episode.badge.reversed().prefix { $0.isNumber }.reversed())
        return Int(digits)
    }

    func setDanmaku(enabled: Bool) {
        danmakuEnabled = enabled
        var settings = AppSettings.load()
        settings.danmakuEnabled = enabled
        settings.save()

        if enabled {
            NSLog("[Danmaku] enabled")
            if !DanmakuCredential.isConfigured {
                toast("这个构建没有内置弹幕凭据")
            }
            loadDanmakuIfNeeded()
        } else {
            NSLog("[Danmaku] disabled")
            danmakuTask?.cancel()
            danmakuStatus = nil
            mpv.clearSecondarySubtitle()
        }
        toast(enabled ? "弹幕：开" : "弹幕：关")
        showChrome()
    }

    /// 按「剧名 + 集号」去弹弹play 找弹幕，写成 ASS 交给 mpv 当第二字幕。
    /// 打包时没注入凭据（开发版）就安静跳过，日志里留一行，不打扰观看。
    private func loadDanmakuIfNeeded() {
        danmakuTask?.cancel()
        guard danmakuEnabled else { return }
        guard let series = seriesTitle else {
            NSLog("[Danmaku] 没有剧名，跳过")
            return
        }
        let episode = episodeNumber
        if episode == nil {
            // 电影 / 没有 SxxExx 的条目：按片名去库里找剧场版。
            NSLog("[Danmaku] 没有集号，按剧场版查找 series=\(series)")
        }

        let appId = DanmakuCredential.appId
        let secret = DanmakuCredential.appSecret
        guard !appId.isEmpty, !secret.isEmpty else {
            NSLog("[Danmaku] 这个构建没有内置弹幕凭据")
            return
        }

        let item = itemId
        danmakuTask = Task { [weak self] in
            do {
                let episodeId: Int
                if let episode {
                    episodeId = try await DanmakuService.shared.episodeId(
                        anime: series, episode: episode, appId: appId, appSecret: secret)
                } else {
                    // 电影：按片名找剧场版；库里没有就报「没有这部片」。
                    guard let movie = try await DanmakuService.shared.movieEpisodeId(
                        title: series, appId: appId, appSecret: secret) else {
                        throw DanmakuError.noMovie
                    }
                    episodeId = movie
                }
                try Task.checkCancellation()
                let comments = try await DanmakuService.shared.comments(
                    episodeId: episodeId, appId: appId, appSecret: secret)
                try Task.checkCancellation()

                guard let self, self.itemId == item else { return }
                if let url = DanmakuAss.write(comments: comments, episodeId: episodeId) {
                    self.mpv.addSecondarySubtitle(url.path)
                    self.danmakuStatus = "弹幕 \(comments.count)"
                    NSLog("[Danmaku] loaded \(comments.count) item=\(item) episodeId=\(episodeId)")
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("[Danmaku] \(error.localizedDescription) item=\(item)")
                guard let self, self.itemId == item, !self.danmakuNoticeShown else { return }
                self.danmakuNoticeShown = true
                self.toast(error.localizedDescription)
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 收尾

    func requestClose() {
        guard !aboutToClose else { return }
        aboutToClose = true

        // 播到结尾时 mpv 会把 time-pos 复位：用片长上报，别拿复位后的 0
        // 覆盖刚写好的「已看完」。eof 时也要补一次 stopped，
        // 否则 Emby 那边只收到进度、没收到停止，UserData 不落盘。
        if eof {
            report(duration, stopped: true)
        } else {
            // 关窗不等网络：主线程同步等会让窗口看起来像卡住。
            // Cmd+Q 那条路才需要 flush（见 stop(flush:)）。
            report(position, stopped: true)
        }

        onClose?()
    }

    /// 按当前状态决定要不要阻止熄屏 / 休眠。
    ///
    /// 只在**真正在播**时持有断言：
    /// - 还在加载（`loading`）→ 不持有，还没出画；
    /// - 暂停 → 释放，让系统按用户设置正常熄屏（暂停了还亮着屏幕很怪）；
    /// - 播完（eof）→ 释放，已经没有内容了；
    /// - 关窗 / stop → 释放。
    ///
    /// 判据里用 `loading` 而不是只看 `paused`：起播时 mpv 是先暂停再放开
    /// （等首帧），`paused` 在那个瞬间还是初始的 true，只看它会导致
    /// 「建断言 → 立刻释放 → 再建」的抖动。`loading` 在首帧到达时变 false，
    /// 语义正好是「已经开始出画了」。
    private func refreshSleepBlocker() {
        if !isStopped && !loading && !paused && !eof {
            sleepBlocker.start()
        } else {
            sleepBlocker.stop()
        }
    }

    /// <param name="flush">
    /// 退出 App 时同步等最后一次上报；普通关窗不用等，免得界面卡住。
    /// </param>
    func stop(flush: Bool = false) {
        guard !isStopped else { return }
        isStopped = true

        // 关窗就恢复系统熄屏 / 睡眠，别让断言跟着进程活到退出。
        sleepBlocker.stop()
        danmakuTask?.cancel()
        danmakuTask = nil
        hideTask?.cancel()
        toastTask?.cancel()
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        reportTimer?.invalidate()
        reportTimer = nil

        if eof {
            // 播完关窗：位置按片长算，并补 stopped（见 requestClose 的说明）。
            report(duration, stopped: true, wait: flush)
        } else {
            report(max(position, 0), stopped: true, wait: flush)
        }

        mpv.onPosition = nil
        mpv.onPause = nil
        mpv.onLoaded = nil
        mpv.onEOF = nil
        mpv.onTracks = nil
        mpv.onSpeed = nil
        mpv.onVolume = nil
        mpv.onError = nil

        // 关闭 mpv 要等它退出（最多 2 秒）；放进 Task，别卡住关窗主线程。
        // 但退出 App（Cmd+Q / 注销）时没有 run loop 再跑这个 Task：必须同步收尾，
        // 否则 applicationWillTerminate 一返回，mpv 就成了继续播放的孤儿进程。
        if let engine = mpv {
            if flush {
                engine.shutdownNow()
            } else {
                Task { await engine.shutdown() }
            }
        }
    }

    private func startReporting() {
        guard reportTimer == nil else { return }
        reportTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard !isStopped else { return }
        // 定时关闭和位置无关：暂停着也要到点关。
        checkSleep()
        guard position > 0 else { return }
        guard Date().timeIntervalSince(lastReportAt) >= Self.reportEvery else { return }

        // 暂停时位置不动：别每 10 秒把同一个点重复上报一遍。
        // 拖动 / 恢复播放后位置变了，下一次 tick 会补上。
        guard abs(position - lastReportedPosition) >= 1 else { return }

        lastReportAt = Date()
        report(position)
    }

    /// <param name="wait">关窗 / 退出时同步等这次上报，异步 Task 会被进程退出带走。</param>
    private func report(_ seconds: Double, stopped: Bool = false, wait: Bool = false) {
        guard seconds > 0 else { return }
        let item = itemId
        let total = Int(duration > 0
            ? duration
            : Double(source?.durationSeconds ?? Int(localSource?.duration ?? 0)))
        // 时长还没解析出来时不写记录：服务器会把它当成 0 秒的片子。
        guard total > 0 else { return }
        let value = Int(seconds)
        lastReportedPosition = seconds

        // 从媒体库点开的本地原盘：条目在核心里，进度回写核心。
        if let coreItemId = localSource?.coreItemId {
            guard let core = AppState.shared.core else { return }
            NSLog("[Play] report local \(coreItemId) pos=\(value) dur=\(total) wait=\(wait)")
            if wait {
                core.reportBlocking(coreItemId, position: value, duration: total,
                                    stopped: stopped)
            } else {
                Task {
                    if stopped {
                        try? await core.reportStopped(coreItemId, position: value, duration: total)
                    } else {
                        try? await core.reportProgress(coreItemId, position: value, duration: total)
                    }
                }
            }
            return
        }

        // 侧栏直接打开的原盘：核心不认识，续播点写本地文件。
        if localSource != nil {
            if value >= total - 1 {
                LocalProgressStore.clear(item)
            } else {
                LocalProgressStore.save(item, position: Double(value), duration: Double(total))
            }
            return
        }

        guard let core = AppState.shared.core else { return }
        NSLog("[Play] report \(item) pos=\(value) dur=\(total) stopped=\(stopped) wait=\(wait)")
        if wait {
            // 关窗 / 退出：同步等上报做完，否则进程先退出就丢了。
            core.reportBlocking(item, position: value, duration: total, stopped: stopped)
            return
        }
        Task {
            if stopped {
                try? await core.reportStopped(item, position: value, duration: total)
            } else {
                try? await core.reportProgress(item, position: value, duration: total)
            }
        }
    }

    // MARK: - 媒体信息

    private func loadMediaInfo(itemId: String) async {
        guard let core = AppState.shared.core else { return }
        do {
            let info = try await core.mediaInfo(itemId)
            guard itemId == self.itemId, !isStopped else { return }
            mediaInfo = info
            mediaInfoLoaded = true
            NSLog("[Play] media info video=\(info.video != nil) audios=\(info.audios.count) " +
                  "subs=\(info.subtitles.count)")
            refreshSubtitleLabels()
            applyTrackPrefsIfNeeded()
        } catch {
            guard itemId == self.itemId, !isStopped else { return }
            // 媒体信息读不到也要放行字幕选择，别一直等它。
            mediaInfoLoaded = true
            NSLog("[Play] media info failed \(itemId): \(error.localizedDescription)")
            applyTrackPrefsIfNeeded()
        }
    }

    // MARK: - 标题

    /// 记录里的剧名常带「（70集） - SKIT」这种尾巴。
    static func cleanSeries(_ title: String?) -> String? {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let cleaned = MediaText.clean(title)
        return cleaned == "(未命名)" ? nil : cleaned
    }

    private func displayTitle(_ source: PlaySource, itemId: String) -> String {
        let episode = playlist.first { $0.id == itemId }

        if let seriesTitle, !seriesTitle.isEmpty, let episode {
            return "\(seriesTitle)  \(episode.badge)"
        }

        let clean = MediaText.clean(MediaText.trimExtension(source.title))
        if !clean.isEmpty, !clean.contains("未命名"), !clean.contains("未知") {
            return clean
        }

        if let episode {
            return episode.title.isEmpty ? episode.badge : episode.title
        }

        return hintTitle.isEmpty ? "正在播放" : hintTitle
    }

    // MARK: - Dolby Vision FEL / MEL

    /// mpv 只给 P7 主层；增强层是 FEL 还是 MEL 要读 RPU。
    /// 异步做，失败就算了（徽标退回「DV P7」）。
    private func probeDolbyVisionIfNeeded() {
        guard dvProfile == 7, !doviProbeStarted else { return }

        // 原盘的 url 是 bd://，没有可直接读的码流；空地址也探不了。
        // 本地文件没有 `source`（`beginLocal` 里置 nil），但 `localSource.url`
        // 就是磁盘路径，可以直接读前缀。
        let url: String
        let headers: [HttpHeader]
        let proxy: String?
        if let source, !source.disc, !source.url.isEmpty {
            url = source.url
            headers = source.headers
            proxy = source.proxy
        } else if discSource == nil, let local = localSource, !local.url.isEmpty {
            url = local.url
            headers = []
            proxy = nil
        } else {
            return
        }

        doviProbeStarted = true
        let item = itemId

        if let cached = Self.doviCache[item] {
            dvElType = cached
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let probe = try await Core.probeDovi(url: url, headers: headers, proxy: proxy)
                guard self.itemId == item, self.dvProfile == 7 else { return }
                self.dvElType = probe.elType
                Self.doviCache[item] = probe.elType
                NSLog("[Play] dovi probe \(item) profile=\(probe.profile) " +
                      "el=\(probe.elType.uppercased())")
            } catch {
                NSLog("[Play] dovi probe \(item) skipped: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 规格标签

    /// 底部的规格标签：HW / 编码 / HDR / 2160p / 帧率 / 码率。
    /// 实际输出：DV P5/P7/P8 → HDR10（PQ）→ HLG → SDR。
    private var outputRange: String? {
        if dvProfile > 0 {
            if dvProfile == 7, let el = dvElType {
                return "DV P7 (\(el.uppercased()))"
            }
            return "DV P\(dvProfile)"
        }

        switch outputTransfer {
            case "pq": return "HDR10"
            case "hlg": return "HLG"
            case "bt.1886", "srgb", "bt.709": return "SDR"
            case "": return nil
            default: return "SDR"
        }
    }

    var chips: [String] {
        var chips: [String] = []
        let video = mediaInfo?.video

        chips.append("HW")

        if let codec = video?.codec, !codec.isEmpty {
            chips.append(codec)
        } else if !videoCodecName.isEmpty {
            chips.append(videoCodecName.uppercased())
        } else if let codec = source?.videoCodec, !codec.isEmpty {
            chips.append(codec.uppercased())
        }

        // 动态范围用 mpv 的实际输出（DV 源 tone map 后不一定是 DV），
        // 还没回报时退回服务端刮削的值。
        if let range = outputRange ?? video?.colorRange ?? source?.colorRange,
           !range.isEmpty {
            chips.append(range)
        }

        if let label = video?.resolutionLabel, !label.isEmpty {
            chips.append(label)
        } else if videoHeight > 0 {
            chips.append("\(videoHeight)p")
        } else if let resolution = source?.resolution, !resolution.isEmpty {
            chips.append(resolution)
        }

        if let fps = video?.frameRate, fps > 0 {
            chips.append("\(Int(fps.rounded()))FPS")
        } else if videoFps > 0 {
            chips.append("\(Int(videoFps.rounded()))FPS")
        }

        if let rate = video?.bitRate, rate > 0 {
            chips.append(String(format: "%.1fmbps", Double(rate) / 1_000_000))
        } else if videoBitrate > 0 {
            chips.append(String(format: "%.1fmbps", videoBitrate / 1_000_000))
        }

        if aspect != .fit {
            chips.append(aspect.label)
        }

        if let sleep = sleepLabel {
            chips.append("定时 \(sleep)")
        }

        if danmakuEnabled {
            chips.append(danmakuStatus ?? "弹幕")
        }

        return chips
    }
}
