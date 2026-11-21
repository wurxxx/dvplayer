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
        let runtime = item.runtimeSeconds.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" }
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
    }

    // —— mpv（子进程 + IPC，视频在 mpv 自己的窗口里） ——
    private(set) var mpv: MpvEngine!

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
    @Published var error: String?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var paused = false
    @Published var speed: Double = 1
    @Published var volume: Double = 100
    @Published var muted = false
    @Published var eof = false

    // —— 轨道 ——
    @Published private(set) var audioTracks: [PlayerTrack] = []
    @Published private(set) var subtitleTracks: [PlayerTrack] = []
    @Published private(set) var selectedAudioId: Int64 = 0
    @Published private(set) var selectedSubtitleId: Int64 = 0

    // —— 浮层 ——
    @Published var chromeVisible = true
    @Published var panel: Panel = .none
    @Published var toast: String?
    @Published var isFullscreen = false
    /// 全屏切换那一拍不要跟着窗口 frame 同步（否则 mpv 会被中间态拽一下）。
    var isFullscreenSwitching = false
    @Published var isScrubbing = false
    @Published var seekPosition: Double = 0

    // —— 画面比例 / 定时关闭 / 片头片尾 ——
    @Published private(set) var aspect: PlayerAspect
    @Published private(set) var sleepDeadline: Date?
    /// 定时关闭选的是「本集结束后」。
    @Published private(set) var sleepEndOfEpisode = false
    @Published private(set) var markers = SkipMarker()
    /// 进度进了片尾区间，浮出「跳过片尾」。
    @Published var showSkipOutro = false

    // —— 由窗口控制器接上的动作 ——
    var onClose: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?

    private var initialStart: Double?
    private var loadToken = 0
    private var tracksApplied = false
    private var isStopped = false
    private var launchStart: Double = 0
    private var launchAt = Date()
    private var lastReportAt = Date.distantPast
    private var hideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var reportTimer: Timer?
    private var aboutToClose = false

    private static let resumeThreshold = 5.0
    private static let reportEvery: TimeInterval = 10

    init?(itemId: String,
          startSeconds: Double?,
          playlist: [PlayerEpisode] = [],
          seriesTitle: String? = nil,
          hintTitle: String? = nil,
          frame: NSRect) {
        self.itemId = itemId
        self.initialStart = startSeconds
        self.playlist = playlist
        self.seriesTitle = Self.cleanSeries(seriesTitle)
        self.hintTitle = hintTitle ?? ""
        self.title = hintTitle ?? "正在播放"
        self.aspect = PlayerAspect(rawValue: AppSettings.load().videoAspect ?? "") ?? .fit
        self.markers = SkipMarkerStore.marker(for: Self.cleanSeries(seriesTitle) ?? itemId)

        guard let engine = MpvEngine(frame: frame, startSeconds: startSeconds) else {
            return nil
        }
        mpv = engine

        engine.onPosition = { [weak self] position, duration in
            self?.handlePosition(position, duration)
        }
        engine.onPause = { [weak self] paused in
            guard let self else { return }
            self.paused = paused
        }
        engine.onLoaded = { [weak self] duration in
            guard let self else { return }
            self.loading = false
            if duration > 1 {
                self.duration = duration
            }
            NSLog("[Play] loaded \(self.itemId) duration=\(Int(self.duration))s")
            self.applyAspect()
            self.applyTrackPrefsIfNeeded()
            self.skipIntroIfNeeded()
        }
        engine.onEOF = { [weak self] in
            self?.handleEOF()
        }
        engine.onTracks = { [weak self] audio, subs, aid, sid in
            self?.handleTracks(audio, subs, aid, sid)
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
        await begin(itemId: itemId, startSeconds: initialStart)
    }

    private func begin(itemId: String, startSeconds: Double?) async {
        guard let core = AppState.shared.core else {
            error = "未连接媒体源。"
            loading = false
            return
        }

        loadToken += 1
        let token = loadToken
        loading = true
        error = nil
        eof = false
        position = 0
        seekPosition = 0
        tracksApplied = false
        audioTracks = []
        subtitleTracks = []
        selectedAudioId = 0
        selectedSubtitleId = 0
        mediaInfo = nil
        panel = .none
        showSkipOutro = false
        markers = SkipMarkerStore.marker(for: markerKey)

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
            // 从起播开始计时：否则第一个位置回调用「很久没报过」立刻上报一次，
            // 这时 duration 还没下来，会把记录写成 0。
            lastReportAt = Date()

            let headers: [String: String] = Dictionary(
                source.headers.map { ($0.name, $0.value) },
                uniquingKeysWith: { _, last in last })
            NSLog("[Play] load \(itemId) from=\(String(format: "%.1f", start)) dur=\(source.durationSeconds)")
            mpv.loadURL(source.url, headers: headers, start: start)
            startReporting()

            Task { await loadMediaInfo(itemId: itemId) }
        } catch {
            guard token == loadToken, !isStopped else { return }
            loading = false
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
        Task { await begin(itemId: itemId, startSeconds: 0) }
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
    }

    // MARK: - mpv 回调

    private func handlePosition(_ position: Double, _ duration: Double) {
        if duration > 1 {
            self.duration = duration
        }
        guard !isScrubbing else { return }
        self.position = position
        seekPosition = position

        // 有的流不给 file-loaded，拿到位置也说明已经出画了。
        if loading && position > 0.05 {
            loading = false
        }

        if Date().timeIntervalSince(lastReportAt) >= Self.reportEvery, position > 0 {
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

    private func handleEOF() {
        eof = true

        // 续播点正好是片尾：mpv 一加载就 EOF，这不是「播完」，从头来一遍。
        let instant = Date().timeIntervalSince(launchAt) < 3
        if instant, launchStart > 0, duration > 0, launchStart >= duration - 2,
           let source {
            NSLog("[Play] eof at resume point -> restart")
            eof = false
            position = 0
            launchStart = 0
            launchAt = Date()
            let headers: [String: String] = Dictionary(
                source.headers.map { ($0.name, $0.value) },
                uniquingKeysWith: { _, last in last })
            mpv.loadURL(source.url, headers: headers, start: 0)
            return
        }

        report(duration > 0 ? duration : Double(source?.durationSeconds ?? 0))

        if sleepEndOfEpisode {
            sleepEndOfEpisode = false
            NSLog("[Play] sleep at end of episode -> close")
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

        subtitleTracks = subtitles.map { raw in
            let language = raw.language.isEmpty ? nil : raw.language
            let title = raw.title.isEmpty ? nil : raw.title
            let name = TrackPrefs.subtitleName(language: language,
                                               title: title,
                                               codec: raw.codec.isEmpty ? nil : raw.codec)
            let detail = [language, raw.isExternal ? "外部" : nil]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return PlayerTrack(id: raw.id, name: name, detail: detail,
                               language: language, title: title, isDefault: raw.isDefault)
        }

        // mpv 自己开了默认轨（比如第一条字幕）时，勾要跟着它。
        selectedAudioId = aid
        selectedSubtitleId = sid

        if hadTracks {
            NSLog("[Play] tracks audio=\(audioTracks.count) subs=\(subtitleTracks.count) aid=\(aid) sid=\(sid)")
        }
        applyTrackPrefsIfNeeded()
    }

    // MARK: - 音轨 / 字幕

    /// 只在第一次拿到轨道时套用详情页的选择；之后用户自己改。
    /// 详情页没读媒体信息就起播（续播、切集）时，退到 mpv 轨上的中文判断。
    private func applyTrackPrefsIfNeeded() {
        guard !tracksApplied, !(audioTracks.isEmpty && subtitleTracks.isEmpty) else { return }
        tracksApplied = true

        if let index = TrackPrefs.audio(itemId), audioTracks.indices.contains(index) {
            selectAudio(audioTracks[index].id, remember: false)
        }

        if let pref = TrackPrefs.subtitle(itemId) {
            if pref == TrackPrefs.subtitleOff {
                selectSubtitle(0, remember: false)
            } else if subtitleTracks.indices.contains(pref) {
                selectSubtitle(subtitleTracks[pref].id, remember: false)
            }
            return
        }

        if let info = mediaInfo, !info.subtitles.isEmpty {
            let index = TrackPrefs.resolveSubtitle(itemId, info.subtitles)
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
            toast("已经是第一集")
            return
        }
        switchTo(itemId: playlist[index - 1].id)
    }

    func nextEpisode() {
        guard let index = playlist.firstIndex(where: { $0.id == itemId }),
              index + 1 < playlist.count else {
            toast("已经是最后一集")
            return
        }
        switchTo(itemId: playlist[index + 1].id)
    }

    func toggleFullscreen() {
        onToggleFullscreen?()
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
        chromeVisible = true
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

    func setAspect(_ mode: PlayerAspect) {
        aspect = mode
        applyAspect()
        var settings = AppSettings.load()
        settings.videoAspect = mode.rawValue
        settings.save()
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
        NSLog("[Play] skip intro -> \(Int(intro)) start=\(Int(launchStart))")
        toast("已跳过片头")
    }

    func skipOutro() {
        showSkipOutro = false
        let target = max(0, duration - 0.4)
        seek(to: target)
        toast("跳过片尾")
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
        // 播到结尾时 mpv 会把 time-pos 复位，别拿这个值覆盖刚写好的「已看完」。
        if !eof {
            report(position)
        }
        onClose?()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        hideTask?.cancel()
        toastTask?.cancel()
        reportTimer?.invalidate()
        reportTimer = nil

        if !eof {
            report(max(position, 0))
        }

        mpv.onPosition = nil
        mpv.onPause = nil
        mpv.onLoaded = nil
        mpv.onEOF = nil
        mpv.onTracks = nil
        mpv.onSpeed = nil
        mpv.onVolume = nil
        mpv.onError = nil
        mpv.shutdown()
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
        if Date().timeIntervalSince(lastReportAt) >= Self.reportEvery {
            lastReportAt = Date()
            report(position)
        }
    }

    private func report(_ seconds: Double) {
        guard seconds > 0, let core = AppState.shared.core else { return }
        let item = itemId
        let total = Int(duration > 0 ? duration : Double(source?.durationSeconds ?? 0))
        // 时长还没解析出来时不写记录：服务器会把它当成 0 秒的片子。
        guard total > 0 else { return }
        let value = Int(seconds)
        NSLog("[Play] report \(item) pos=\(value) dur=\(total)")
        Task {
            try? await core.reportProgress(item, position: value, duration: total)
        }
    }

    // MARK: - 媒体信息

    private func loadMediaInfo(itemId: String) async {
        guard let core = AppState.shared.core else { return }
        do {
            let info = try await core.mediaInfo(itemId)
            guard itemId == self.itemId, !isStopped else { return }
            mediaInfo = info
            NSLog("[Play] media info video=\(info.video != nil) audios=\(info.audios.count) " +
                  "subs=\(info.subtitles.count)")
            applyTrackPrefsIfNeeded()
        } catch {
            NSLog("[Play] media info failed \(itemId): \(error.localizedDescription)")
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

    // MARK: - 规格标签

    /// 底部的规格标签：HW / 编码 / HDR / 2160p / 帧率 / 码率。
    var chips: [String] {
        var chips: [String] = []
        let video = mediaInfo?.video

        chips.append("HW")

        if let codec = video?.codec, !codec.isEmpty {
            chips.append(codec)
        } else if let codec = source?.videoCodec, !codec.isEmpty {
            chips.append(codec.uppercased())
        }

        if let range = video?.colorRange ?? source?.colorRange, !range.isEmpty {
            chips.append(range)
        }

        if source?.dolbyVision == true || video?.dolbyVision == true {
            chips.append("DV")
        }

        if let label = video?.resolutionLabel, !label.isEmpty {
            chips.append(label)
        } else if let resolution = source?.resolution, !resolution.isEmpty {
            chips.append(resolution)
        }

        if let fps = video?.frameRate, fps > 0 {
            chips.append("\(Int(fps.rounded()))FPS")
        }

        if let rate = video?.bitRate, rate > 0 {
            chips.append(String(format: "%.1fmbps", Double(rate) / 1_000_000))
        }

        if aspect != .fit {
            chips.append(aspect.label)
        }

        if let sleep = sleepLabel {
            chips.append("定时 \(sleep)")
        }

        return chips
    }
}
