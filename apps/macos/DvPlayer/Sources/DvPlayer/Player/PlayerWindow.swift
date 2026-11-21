import AppKit
import SwiftUI
import DvCore

/// 拼播放页右侧的选集（和 Windows 的 `Views/Playlists.cs` 对齐）。
///
/// 详情页直接把自己那行集传进来；续播只有一条记录，要顺着记录把所在容器找回来，
/// 不然播放页只有一个孤零零的片子，没有上一集 / 下一集。
enum PlaylistLoader {
    struct Result {
        let episodes: [PlayerEpisode]
        let title: String?
    }

    private static let pageSize = 100

    static func load(core: Core, record: PlayRecord) async -> Result? {
        // 1) 记录的父条目能直接列出集。
        if let parentId = withSource(record.parentId, sourceId: record.sourceId),
           let result = await loadContainer(core, id: parentId, record: record) {
            return result
        }

        // 2) 飞牛的 parent_guid 不是可浏览的目录，按剧名把剧集找回来。
        if let series = record.seriesTitle, !series.trimmingCharacters(in: .whitespaces).isEmpty,
           let seriesId = await findSeries(core, title: series),
           let result = await loadContainer(core, id: seriesId, record: record) {
            return result
        }

        NSLog("[Play] no playlist item=\(record.itemId)")
        return nil
    }

    private static func loadContainer(_ core: Core,
                                      id: String,
                                      record: PlayRecord) async -> Result? {
        var items = await fetchAll(core, id)

        // 直接子项是「季」：再下一层才是集。
        if let first = items.first, first.isSeason {
            let season = items.first { record.seasonNumber != nil && $0.seasonNumber == record.seasonNumber }
                ?? items.first { ($0.seasonNumber ?? 0) > 0 }
                ?? first
            items = await fetchAll(core, season.id)
        }

        items = items.filter { !$0.id.isEmpty }

        guard items.count >= 2 else { return nil }

        let target = items.first { $0.id == record.itemId }
            ?? matchByTitle(items, record: record)
        guard let target else {
            NSLog("[Play] record \(record.itemId) not in \(id) first=\(items[0].id)")
            return nil
        }

        let season = target.seasonNumber ?? record.seasonNumber
        let episodes = PlayerEpisode.list(from: items, season: season)

        var title = record.seriesTitle
        if title?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            if let detail = try? await core.detail(id) {
                title = detail.title
            }
        }

        NSLog("[Play] playlist \(record.itemId) in \(id) episodes=\(episodes.count)")
        return Result(episodes: episodes, title: title)
    }

    private static func fetchAll(_ core: Core, _ id: String) async -> [MediaItem] {
        var all: [MediaItem] = []

        for page in 1...30 {
            guard let result = try? await core.children(id, page: page, pageSize: pageSize) else {
                NSLog("[Play] children failed id=\(id) page=\(page)")
                break
            }
            if result.items.isEmpty { break }
            all.append(contentsOf: result.items)
            if result.items.count < pageSize || (result.total > 0 && all.count >= result.total) {
                break
            }
        }

        return all
    }

    /// 记录里的 guid 是裸的，要补 `<sourceId>:` 前缀核心才认。
    private static func withSource(_ id: String?, sourceId: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        if id.contains(":") || sourceId == nil { return id }
        return "\(sourceId!):\(id)"
    }

    private static func matchByTitle(_ items: [MediaItem], record: PlayRecord) -> MediaItem? {
        let wanted = normalize(record.title)
        guard !wanted.isEmpty else { return nil }

        let named = items.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        return named.first { normalize($0.title) == wanted }
            ?? named.first { normalize($0.title).contains(wanted) }
            ?? named.first { wanted.contains(normalize($0.title)) }
    }

    private static func normalize(_ title: String) -> String {
        MediaText.trimExtension(MediaText.clean(title)).trimmingCharacters(in: .whitespaces)
    }

    private static func findSeries(_ core: Core, title: String) async -> String? {
        guard let result = try? await core.search(title) else { return nil }
        let wanted = title.trimmingCharacters(in: .whitespaces)
        let series = result.items.filter { ["series", "tv"].contains($0.kind.lowercased()) }
        return series.first { $0.title.trimmingCharacters(in: .whitespaces) == wanted }?.id
            ?? series.first?.id
    }
}

/// 打开播放窗口的唯一入口：单个播放窗、先出窗再解析地址。
@MainActor
final class PlayerLauncher {
    static let shared = PlayerLauncher()

    private var controller: PlayerWindowController?

    private init() {}

    var isOpen: Bool { controller != nil }

    /// 自检用：当前播放窗（没有就 nil）。
    var window: NSWindow? { controller?.window }

    /// 自检用：当前播放会话。
    var current: PlayerSession? { controller?.session }

    func play(itemId: String,
              startSeconds: Double?,
              playlist: [PlayerEpisode] = [],
              seriesTitle: String? = nil,
              hintTitle: String? = nil) {
        // 本地文件夹源里的 ISO：条目在媒体库里，但播放要先挂载原盘。
        if isLocalItem(itemId) {
            Task { @MainActor in
                guard let core = AppState.shared.core else {
                    self.startSession(itemId: itemId, startSeconds: startSeconds,
                                      playlist: playlist, seriesTitle: seriesTitle,
                                      hintTitle: hintTitle)
                    return
                }
                let source = try? await core.playSource(itemId)
                if let source, source.disc {
                    // 自检时用 `DVPLAYER_DISC_TITLE` 指定标题，远程没法点选择框。
                    let wanted = Int(ProcessInfo.processInfo.environment["DVPLAYER_DISC_TITLE"] ?? "")
                    DiscUI.open(path: source.url, autoTitle: wanted,
                                coreItemId: source.itemId,
                                hintTitle: source.title,
                                start: source.positionSeconds > 0
                                    ? Double(source.positionSeconds) : nil)
                } else {
                    self.startSession(itemId: itemId, startSeconds: startSeconds,
                                      playlist: playlist, seriesTitle: seriesTitle,
                                      hintTitle: hintTitle)
                }
            }
            return
        }

        startSession(itemId: itemId, startSeconds: startSeconds,
                     playlist: playlist, seriesTitle: seriesTitle,
                     hintTitle: hintTitle)
    }

    /// 条目 id 的源是不是文件夹源（本地文件夹，或挂载成目录的 SMB / NFS / WebDAV）。
    /// 这两类走同一套本地续播 / 原盘流程。
    private func isLocalItem(_ itemId: String) -> Bool {
        guard let sourceId = itemId.split(separator: ":", maxSplits: 1).first.map(String.init),
              !sourceId.isEmpty,
              let kind = AppState.shared.settings.sources
                .first(where: { $0.id == sourceId })?.kind else {
            return false
        }
        return kind == "local" || MountSources.isMount(kind)
    }

    private func startSession(itemId: String,
                              startSeconds: Double?,
                              playlist: [PlayerEpisode],
                              seriesTitle: String?,
                              hintTitle: String?) {
        if let existing = controller {
            if existing.session.itemId == itemId, existing.session.error == nil {
                existing.showWindow(nil)
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            // 换一部片：关掉旧的（会回写进度），再开新的。
            existing.close()
            controller = nil
        }

        let frame = PlayerWindowController.preferredFrame()
        guard let session = PlayerSession(itemId: itemId,
                                          startSeconds: startSeconds,
                                          playlist: playlist,
                                          seriesTitle: seriesTitle,
                                          hintTitle: hintTitle,
                                          frame: frame) else {
            AppState.shared.showToast("播放器启动失败，检查 mpv 是否随包带上了")
            return
        }

        let window = PlayerWindowController(session: session, frame: frame) { [weak self] in
            self?.controller = nil
        }
        session.onClose = { [weak window] in window?.closePlayer() }

        controller = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        Task { await session.start() }
    }

    /// 从观看记录续播：先播记录本身，选集后台补。
    func play(record: PlayRecord) {
        play(itemId: record.itemId,
             startSeconds: nil,
             seriesTitle: record.seriesTitle,
             hintTitle: recordHint(record))

        guard let core = AppState.shared.core else { return }
        Task {
            guard let loaded = await PlaylistLoader.load(core: core, record: record) else { return }
            guard let session = self.controller?.session, session.itemId == record.itemId else { return }
            session.setPlaylist(loaded.episodes, seriesTitle: loaded.title)
        }
    }

    /// 播蓝光原盘：视频是挂载 ISO 里的 m2ts（EDL 拼接），关窗时卸载。
    func playDisc(_ disc: BluRaySession,
                  title: BluRayTitle,
                  coreItemId: String? = nil,
                  hintTitle: String? = nil,
                  start: Double? = nil) {
        if let existing = controller {
            existing.close()
            controller = nil
        }

        guard let url = disc.prepare(title) else {
            AppState.shared.showToast("读不到这个标题的视频片段")
            disc.detach()
            return
        }

        let name = URL(fileURLWithPath: disc.isoPath)
            .deletingPathExtension()
            .lastPathComponent
        let itemId = coreItemId ?? "iso:\(name):mpls\(title.id)"
        let titleText = hintTitle.map { "\($0) · 标题 \(title.number)" }
            ?? "\(disc.discName) · 标题 \(title.number)"
        let local = LocalPlayback(itemId: itemId,
                                  title: titleText,
                                  url: url.path,
                                  duration: title.duration,
                                  coreItemId: coreItemId,
                                  startSeconds: start)
        let frame = PlayerWindowController.preferredFrame()

        guard let session = PlayerSession(itemId: itemId,
                                          startSeconds: nil,
                                          playlist: [],
                                          seriesTitle: nil,
                                          hintTitle: local.title,
                                          frame: frame,
                                          local: local) else {
            disc.detach()
            AppState.shared.showToast("播放器启动失败，检查 mpv 是否随包带上了")
            return
        }

        let window = PlayerWindowController(session: session, frame: frame) { [weak self] in
            self?.controller = nil
            disc.detach()
        }
        session.onClose = { [weak window] in window?.closePlayer() }

        controller = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        Task { await session.start() }
    }

    func close() {
        controller?.close()
        controller = nil
    }

    private func recordHint(_ record: PlayRecord) -> String {
        let series = MediaText.clean(record.seriesTitle)
        if !series.isEmpty, series != "(未命名)" {
            if let season = record.seasonNumber, let episode = record.episodeNumber {
                return String(format: "%@  S%02dE%02d", series, season, episode)
            }
            return series
        }
        let title = MediaText.clean(record.title)
        return title == "(未命名)" ? "" : title
    }
}

// MARK: - 窗口

/// 播放窗是「浮层」：视频由 mpv 自己的窗口画，这个窗口透明地盖在它上面。
///
/// 为什么分两个窗口：macOS 上拿 Dolby Vision 必须走 gpu-next，而 gpu-next
/// 只有 mpv 自己的窗口（cocoa-cb + Vulkan）能用，render API 够不到。
/// 代价就是位置 / 大小 / 全屏都要自己跟 mpv 同步（`syncGeometry`）。
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let session: PlayerSession
    private let onClosed: () -> Void

    private var keyMonitor: Any?
    private var wheelMonitor: Any?
    private var lastWheelAt = Date.distantPast
    private var syncTask: DispatchWorkItem?
    private var savedFrame: NSRect?
    private var zoomSavedFrame: NSRect?
    private var closeRequested = false
    /// 上一次按视频比例调过的宽高比，避免同一部视频反复改窗口。
    private var fittedAspect: Double = 0

    /// 新播放窗的初始位置：居中，最多 1280×720，四周留点边。
    static func preferredFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let width = min(1280, max(720, visible.width - 96))
        let height = min(720, max(405, visible.height - 96))
        return NSRect(x: visible.midX - width / 2,
                      y: visible.midY - height / 2,
                      width: width,
                      height: height)
    }

    init(session: PlayerSession, frame: NSRect, onClosed: @escaping () -> Void) {
        self.session = session
        self.onClosed = onClosed

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "DV Player"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // 竖屏短剧要能缩成竖窗口，最小尺寸不能按 16:9 卡死。
        window.minSize = NSSize(width: 380, height: 380)
        window.center()

        // 透明浮层：底下的 mpv 窗口透出来。
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false

        // 比普通窗口高一级，才盖得住 mpv 自己的窗口（另一个进程）。
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)

        // 和主窗口一样自绘三个按钮，系统红绿灯藏掉。
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
        window.delegate = self

        // 播放页里的「全屏」按钮 / 双击画面 / 键盘 F 都走这里。
        session.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }
        session.onVideoAspect = { [weak self] aspect in self?.fitWindowToVideo(aspect) }

        buildContentView()
        installKeyMonitor()
        installWheelMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContentView() {
        guard let window else { return }

        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let root = PlayerView(
            session: session,
            actions: PlayerActions(
                close: { [weak self] in self?.closePlayer() },
                minimize: { [weak self] in self?.window?.miniaturize(nil) },
                zoom: { [weak self] in self?.zoom() },
                toggleFullscreen: { [weak self] in self?.toggleFullscreen() },
                dragWindow: { [weak self] event in self?.window?.performDrag(with: event) }))
            .environmentObject(AppState.shared)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        container.addSubview(hosting)

        window.contentView = container
        window.initialFirstResponder = hosting
        window.makeFirstResponder(hosting)

        // mpv 先把窗口摆好，浮层再盖上去。
        syncGeometry(force: true)
    }

    /// 浮层显示 / 移动 / 缩放 → 告诉 mpv 挪窗口。高频拖动按 40ms 合并。
    private func syncGeometry(force: Bool = false) {
        if force {
            syncTask?.cancel()
            applyGeometry()
            return
        }

        syncTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.applyGeometry() }
        syncTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: task)
    }

    private func applyGeometry() {
        guard let window, !session.isFullscreenSwitching else { return }
        session.mpv?.syncGeometry(to: window.frame)
    }

    /// 适应窗口 = 窗口跟着视频的宽高比走（竖屏短剧就是竖窗口），
    /// 画面正好铺满客户区，不留左右 / 上下黑边。填充 / 拉伸 / 强制比例不动窗口。
    private func fitWindowToVideo(_ aspect: Double) {
        guard aspect > 0.05, aspect <= 20 else { return }
        guard session.aspect == .fit, !session.isFullscreen, let window else { return }

        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        // 最大化（铺满工作区）时别抢尺寸。
        if window.frame == visible { return }
        if abs(aspect - fittedAspect) < 0.001 { return }
        fittedAspect = aspect

        var height = min(max(window.frame.height, 380), visible.height * 0.85)
        var width = height * aspect

        if width > visible.width * 0.95 {
            width = visible.width * 0.95
            height = width / aspect
        }

        // 竖屏窗口太窄控制条会挤成一团。
        let minWidth = 380.0
        if width < minWidth {
            width = minWidth
            height = width / aspect
        }

        if height > visible.height * 0.95 {
            height = visible.height * 0.95
            width = height * aspect
        }

        // 以当前窗口中心为中心缩放，再夹进屏幕可见区域。
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var frame = NSRect(x: center.x - width / 2, y: center.y - height / 2,
                           width: width, height: height)
        frame.origin.x = min(max(frame.origin.x, visible.minX),
                             max(visible.minX, visible.maxX - width))
        frame.origin.y = min(max(frame.origin.y, visible.minY),
                             max(visible.minY, visible.maxY - height))

        window.setFrame(frame, display: true, animate: false)
        syncGeometry(force: true)
        NSLog("[Play] fit window aspect=%.3f %.0fx%.0f", aspect, width, height)
    }

    func closePlayer() {
        guard !closeRequested else { return }
        closeRequested = true
        window?.close()
    }

    /// 缩放按钮：按屏幕可见区域的最大化（不是系统全屏，全屏另有一套）。
    func zoom() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if window.frame == screen.visibleFrame {
            window.setFrame(zoomSavedFrame ?? Self.preferredFrame(), display: true)
            fittedAspect = 0
            fitWindowToVideo(session.videoAspect)
        } else {
            zoomSavedFrame = window.frame
            window.setFrame(screen.visibleFrame, display: true)
        }
        syncGeometry(force: true)
    }

    /// 假全屏：视频是另一个进程的窗口，进不了同一个 fullscreen space。
    /// 所以把两个窗口都铺满屏幕，并临时隐藏菜单栏 / Dock。
    func toggleFullscreen() {
        guard let window else { return }

        session.isFullscreenSwitching = true
        defer { session.isFullscreenSwitching = false }

        if let saved = savedFrame, session.isFullscreen {
            savedFrame = nil
            NSApp.presentationOptions = []
            window.setFrame(saved, display: true, animate: false)
            session.isFullscreen = false
            fittedAspect = 0
            fitWindowToVideo(session.videoAspect)
        } else {
            savedFrame = window.frame
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            let screen = window.screen ?? NSScreen.main
            window.setFrame(screen?.frame ?? window.frame, display: true, animate: false)
            session.isFullscreen = true
        }

        window.makeKeyAndOrderFront(nil)
        syncGeometry(force: true)
    }

    // MARK: 键盘

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// 画面上滚轮调音量，和 Windows 的 `OnSurfaceWheel` 一样（±2，向上加）。
    /// 触控板会连着来几十个小事件，按时间节流，别一下拉满。
    private func installWheelMonitor() {
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard abs(event.scrollingDeltaY) > 0.5 else { return nil }
            guard Date().timeIntervalSince(self.lastWheelAt) > 0.08 else { return nil }
            self.lastWheelAt = Date()
            self.session.setVolume(self.session.volume + (event.scrollingDeltaY > 0 ? 2 : -2))
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // 面板 / 菜单打开时，方向键归系统。
        let key = event.keyCode
        let shift = event.modifierFlags.contains(.shift)

        switch key {
            case 49: // space
                session.togglePause()
                return true
            case 123: // ←
                session.skip(shift ? -30 : -10)
                return true
            case 124: // →
                session.skip(shift ? 30 : 10)
                return true
            case 126: // ↑
                session.setVolume(session.volume + 5)
                return true
            case 125: // ↓
                session.setVolume(session.volume - 5)
                return true
            case 46: // m
                session.toggleMute()
                return true
            case 3: // f
                session.toggleFullscreen()
                return true
            case 36, 76: // return / enter
                session.toggleFullscreen()
                return true
            case 116: // page up
                session.previousEpisode()
                return true
            case 121: // page down
                session.nextEpisode()
                return true
            case 53: // esc
                if session.panel != .none {
                    session.panel = .none
                } else if session.isFullscreen {
                    session.toggleFullscreen()
                } else {
                    closePlayer()
                }
                return true
            default:
                return false
        }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        syncGeometry()
    }

    func windowDidResize(_ notification: Notification) {
        syncGeometry()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        syncGeometry(force: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        syncGeometry(force: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
        syncTask?.cancel()

        if savedFrame != nil {
            NSApp.presentationOptions = []
        }

        session.stop()
        onClosed()
    }
}

/// 播放页 overlay 用到的窗口动作。
struct PlayerActions {
    let close: () -> Void
    let minimize: () -> Void
    let zoom: () -> Void
    let toggleFullscreen: () -> Void
    /// 顶栏那块无标题栏区域：拖动移窗（`window.performDrag`）。
    let dragWindow: (NSEvent) -> Void
}
