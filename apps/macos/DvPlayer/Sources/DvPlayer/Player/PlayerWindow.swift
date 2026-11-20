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
        guard let items = try? await core.search(title) else { return nil }
        let wanted = title.trimmingCharacters(in: .whitespaces)
        let series = items.filter { ["series", "tv"].contains($0.kind.lowercased()) }
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

        let session = PlayerSession(itemId: itemId,
                                    startSeconds: startSeconds,
                                    playlist: playlist,
                                    seriesTitle: seriesTitle,
                                    hintTitle: hintTitle)
        let window = PlayerWindowController(session: session) { [weak self] in
            self?.controller = nil
        }
        session.onClose = { [weak window] in window?.closePlayer() }

        controller = window
        window.showWindow(nil)
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

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let session: PlayerSession
    private let onClosed: () -> Void

    private var keyMonitor: Any?
    private var wheelMonitor: Any?
    private var lastWheelAt = Date.distantPast
    private var fullscreenObservers: [NSObjectProtocol] = []
    private var closeRequested = false

    init(session: PlayerSession, onClosed: @escaping () -> Void) {
        self.session = session
        self.onClosed = onClosed

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "DV Player"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.minSize = NSSize(width: 720, height: 405)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()

        // 和主窗口一样自绘三个按钮，系统红绿灯藏掉。
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
        window.delegate = self

        // 播放页里的「全屏」按钮 / 双击画面 / 键盘 F 都走这里。
        session.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }

        buildContentView()
        installKeyMonitor()
        installWheelMonitor()
        observeFullscreen()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContentView() {
        guard let window else { return }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let video = session.mpv
        video.frame = container.bounds
        video.autoresizingMask = [.width, .height]
        container.addSubview(video)

        let root = PlayerView(
            session: session,
            actions: PlayerActions(
                close: { [weak self] in self?.closePlayer() },
                minimize: { [weak self] in self?.window?.miniaturize(nil) },
                zoom: { [weak self] in self?.window?.zoom(nil) },
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
    }

    func closePlayer() {
        guard !closeRequested else { return }
        closeRequested = true
        window?.close()
    }

    func toggleFullscreen() {
        guard let window else { return }
        // 全屏要求窗口是 key（自检跑在后台时它不是）。
        if !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
        }
        window.toggleFullScreen(nil)
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

    // MARK: 全屏

    private func observeFullscreen() {
        guard let window else { return }
        let center = NotificationCenter.default
        fullscreenObservers.append(center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { [weak self] _ in
                self?.session.isFullscreen = true
            })
        fullscreenObservers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window, queue: .main) { [weak self] _ in
                self?.session.isFullscreen = false
            })
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
        for observer in fullscreenObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        fullscreenObservers.removeAll()

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
