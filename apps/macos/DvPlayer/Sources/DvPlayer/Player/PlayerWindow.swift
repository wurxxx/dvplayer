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
        let wanted = normalize(title)
        guard !wanted.isEmpty else { return nil }

        let series = result.items.filter { ["series", "tv"].contains($0.kind.lowercased()) }

        // 先精确匹配；再退一步用归一化后的包含关系。
        // 都没有就返回 nil——以前会退回「搜到的第一部剧」，
        // 记录标题对不上时会把播放列表接到另一部剧上。
        if let exact = series.first(where: { normalize($0.title) == wanted }) {
            return exact.id
        }

        for item in series {
            let name = normalize(item.title)
            if !name.isEmpty && (name.contains(wanted) || wanted.contains(name)) {
                return item.id
            }
        }

        return nil
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
              seriesYear: Int? = nil,
              seriesTmdbId: String? = nil,
              seriesImdbId: String? = nil,
              hintTitle: String? = nil) {
        // 本地文件夹源里的 ISO：条目在媒体库里，但播放要先挂载原盘。
        if isLocalItem(itemId) {
            Task { @MainActor in
                guard let core = AppState.shared.core else {
                    self.startSession(itemId: itemId, startSeconds: startSeconds,
                                      playlist: playlist, seriesTitle: seriesTitle,
                                      seriesYear: seriesYear,
                                      seriesTmdbId: seriesTmdbId,
                                      seriesImdbId: seriesImdbId,
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
                                      seriesYear: seriesYear,
                                      seriesTmdbId: seriesTmdbId,
                                      seriesImdbId: seriesImdbId,
                                      hintTitle: hintTitle)
                }
            }
            return
        }

        startSession(itemId: itemId, startSeconds: startSeconds,
                     playlist: playlist, seriesTitle: seriesTitle,
                     seriesYear: seriesYear,
                     seriesTmdbId: seriesTmdbId,
                     seriesImdbId: seriesImdbId,
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
                              seriesYear: Int?,
                              seriesTmdbId: String?,
                              seriesImdbId: String?,
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
                                          seriesYear: seriesYear,
                                          seriesTmdbId: seriesTmdbId,
                                          seriesImdbId: seriesImdbId,
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
        // 淡入：浮层是透明窗口，硬出现像一块悬空的控制条。
        window.window?.alphaValue = 0
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.window?.animator().alphaValue = 1
        }
        Task { await session.start() }
    }

    /// 自检：直接播一个本地文件，不经过媒体库 / 原盘挂载。
    ///
    /// 验证 Dolby Vision 色彩必须走这条：`samples/p5.mkv` 是 Profile 5，
    /// legacy `gpu` 渲染会发紫，gpu-next 才正常。
    func playLocalFile(_ path: String, startSeconds: Double? = nil) {
        if let existing = controller {
            existing.close()
            controller = nil
        }

        let frame = PlayerWindowController.preferredFrame()
        let local = LocalPlayback(itemId: "local:" + (path as NSString).lastPathComponent,
                                  title: (path as NSString).lastPathComponent,
                                  url: path,
                                  duration: 0,
                                  startSeconds: startSeconds)
        guard let session = PlayerSession(itemId: local.itemId,
                                          startSeconds: startSeconds,
                                          playlist: [],
                                          seriesTitle: nil,
                                          hintTitle: local.title,
                                          frame: frame,
                                          local: local) else {
            AppState.shared.showToast("播放器启动失败")
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
    /// 默认标题之外，同盘的其它标题作为右侧「标题」面板随播放器一起打开。
    /// 打开原盘的盘内菜单：`bd://` + `--disc-menu`，菜单由 mpv 自己画。
    /// 点按钮后 mpv 自己切标题，这里不用再重启播放器。
    func playDiscMenu(_ disc: DiscPlayback) {
        if let existing = controller {
            existing.close()
            controller = nil
        }

        let local = disc.menu()
        let playlist = disc.disc.titles.count > 1 ? disc.playlist() : []
        let frame = PlayerWindowController.preferredFrame()

        guard let session = PlayerSession(itemId: local.itemId,
                                          startSeconds: nil,
                                          playlist: playlist,
                                          seriesTitle: nil,
                                          hintTitle: local.title,
                                          frame: frame,
                                          local: local,
                                          disc: disc) else {
            disc.disc.detach()
            AppState.shared.showToast("播放器启动失败，检查 mpv 是否随包带上了")
            return
        }

        NSLog("[Play] disc menu open \(local.itemId) titles=\(playlist.count)")

        let window = PlayerWindowController(session: session, frame: frame) { [weak self] in
            self?.controller = nil
            disc.disc.detach()
        }
        session.onClose = { [weak window] in window?.closePlayer() }

        controller = window
        window.window?.alphaValue = 0
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.window?.animator().alphaValue = 1
        }
        Task { await session.start() }
    }

    /// 播 DVD 镜像：主 VTS 的 VOB 拼成一份 EDL，当普通视频播。
    ///
    /// 没有盘内菜单 / 标题 / 章节——mac 的 libmpv 是 LGPL 构建，mpv 的 DVD
    /// 导航要 GPL 的 libdvdnav（`-Ddvdnav` 在非 GPL 构建里直接报错）。
    func playDvd(_ dvd: DvdSession,
                 coreItemId: String?,
                 hintTitle: String?,
                 start: Double?) {
        if let existing = controller {
            existing.close()
            controller = nil
        }

        guard let edl = dvd.prepare() else {
            dvd.detach()
            AppState.shared.showToast("读不到这张 DVD 的视频片段")
            return
        }

        let name = URL(fileURLWithPath: dvd.isoPath).deletingPathExtension().lastPathComponent
        let display = (hintTitle?.isEmpty == false ? hintTitle! : dvd.discName)
        let local = LocalPlayback(itemId: "iso:\(name):dvd",
                                  title: display,
                                  url: edl.path,
                                  duration: dvd.duration,
                                  coreItemId: coreItemId,
                                  startSeconds: start,
                                  discMenuIso: nil)
        let frame = PlayerWindowController.preferredFrame()

        guard let session = PlayerSession(itemId: local.itemId,
                                          startSeconds: start,
                                          playlist: [],
                                          seriesTitle: nil,
                                          hintTitle: display,
                                          frame: frame,
                                          local: local,
                                          disc: nil) else {
            dvd.detach()
            AppState.shared.showToast("播放器启动失败，检查 mpv 是否随包带上了")
            return
        }

        NSLog("[Play] dvd open \(local.itemId) vob=\(dvd.clips.count) "
              + "dur=\(Int(dvd.duration)) resume=\(Int(start ?? 0))")

        let window = PlayerWindowController(session: session, frame: frame) { [weak self] in
            self?.controller = nil
            dvd.detach()
        }
        session.onClose = { [weak window] in window?.closePlayer() }

        controller = window
        window.window?.alphaValue = 0
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.window?.animator().alphaValue = 1
        }
        Task { await session.start() }
    }

    func playDisc(_ disc: DiscPlayback, title: BluRayTitle, start: Double? = nil) {
        if let existing = controller {
            existing.close()
            controller = nil
        }

        guard let local = disc.local(title, start: start) else {
            AppState.shared.showToast("读不到这个标题的视频片段")
            disc.disc.detach()
            return
        }

        let playlist = disc.disc.titles.count > 1 ? disc.playlist() : []
        let frame = PlayerWindowController.preferredFrame()

        guard let session = PlayerSession(itemId: local.itemId,
                                          startSeconds: nil,
                                          playlist: playlist,
                                          seriesTitle: nil,
                                          hintTitle: local.title,
                                          frame: frame,
                                          local: local,
                                          disc: disc) else {
            disc.disc.detach()
            AppState.shared.showToast("播放器启动失败，检查 mpv 是否随包带上了")
            return
        }

        NSLog("[Play] disc open \(local.itemId) title=\(title.number) " +
              "mpls=\(title.id) resume=\(Int(local.startSeconds ?? 0)) " +
              "titles=\(playlist.count)")

        let window = PlayerWindowController(session: session, frame: frame) { [weak self] in
            self?.controller = nil
            disc.disc.detach()
        }
        session.onClose = { [weak window] in window?.closePlayer() }

        controller = window
        window.window?.alphaValue = 0
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.window?.animator().alphaValue = 1
        }
        Task { await session.start() }
    }

    func close() {
        controller?.close()
        controller = nil
    }

    /// Cmd+Q / 注销的兜底：这两条路不会走 `windowWillClose`，
    /// 不在这里收尾，mpv 子进程、ISO 挂载、presentationOptions 都会留在系统里。
    func shutdownForTermination() {
        controller?.session.stop(flush: true)
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

/// 播放窗：视频和控件在**同一个窗口**里。
///
/// 和 Windows 的 `PlayWindow` 同构——mpv 通过 render API 把画面画进
/// `MpvVideoView`（窗口最底层），SwiftUI 控制条是它上面的兄弟视图。
/// 所以拖动 / 缩放 / 全屏都只是移动这一个窗口，画面天然跟得上，
/// 不需要 `geometry`、不需要把拖拽交给第二个进程、也不需要改窗口层级。
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let session: PlayerSession
    private let onClosed: () -> Void

    private var keyMonitor: Any?
    private var wheelMonitor: Any?
    private var lastWheelAt = Date.distantPast
    private var savedFrame: NSRect?
    private var zoomSavedFrame: NSRect?
    private var closeRequested = false
    /// 上一次按视频比例调过的宽高比，避免同一部视频反复改窗口。
    private var fittedAspect: Double = 0
    /// 视频画布（窗口最底层）。
    private var videoView: MpvVideoView?

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

        // 不透明：视频铺满客户区，没出画时是黑底（和 Windows 一样）。
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        // 普通层级：和 Windows 的普通播放窗一致，切到别的 App 会被盖住；
        // 上次开过「置顶」的话，按存下来的状态起。
        window.level = session.isAlwaysOnTop ? .floating : .normal
        // 让 CA 自己管 layer，视频层和控制条才能稳定合成。
        window.contentView?.wantsLayer = true

        // 和主窗口一样自绘三个按钮，系统红绿灯藏掉。
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
        window.delegate = self

        // 播放页里的「全屏」按钮 / 双击画面 / 键盘 F 都走这里。
        session.onToggleFullscreen = { [weak self] in self?.toggleFullscreen() }
        session.onToggleAlwaysOnTop = { [weak self] in self?.applyWindowLevel() }
        session.onVideoAspect = { [weak self] aspect in self?.fitWindowToVideo(aspect) }

        buildContentView()
        installKeyMonitor()
        installWheelMonitor()
        NSLog("[Play] window level=\(window.level.rawValue) alwaysOnTop=\(session.isAlwaysOnTop)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 单窗口布局：视频画布在最底层，SwiftUI 控制条盖在它上面。
    ///
    /// 视频层和控件层都跟着容器自动伸缩，所以窗口拖动 / 缩放 / 全屏期间
    /// 两者永远同步——这正是 Windows 里视频和控件同一个窗口的效果。
    private func buildContentView() {
        guard let window, let video = session.mpv?.videoView else {
            NSLog("[Play] 没有视频画布，播放窗无法建立")
            return
        }
        videoView = video

        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        video.frame = container.bounds
        video.autoresizingMask = [.width, .height]
        container.addSubview(video)

        let root = PlayerView(
            session: session,
            actions: PlayerActions(
                close: { [weak self] in self?.closePlayer() },
                minimize: { [weak self] in self?.window?.miniaturize(nil) },
                zoom: { [weak self] in self?.zoom() },
                toggleFullscreen: { [weak self] in self?.toggleFullscreen() },
                beginDrag: { [weak self] in self?.beginDrag() }))
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
    }

    /// 假全屏：视频是另一个进程的窗口，进不了同一个 fullscreen space。
    /// 所以把两个窗口都铺满屏幕，并临时隐藏菜单栏 / Dock。
    func toggleFullscreen() {
        guard let window else { return }

        session.isFullscreenSwitching = true

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

        // 先把「正在切全屏」清掉再同步：applyGeometry 会因这个标志直接返回，
        // 否则进出全屏后 mpv 的子窗口停在旧尺寸上。
        session.isFullscreenSwitching = false
    }

    // MARK: 窗口层级

    /// 置顶：`.floating` 会盖在普通窗口上，切到别的 App 也留在前面。
    /// 全屏时不用改（系统自己的空间已经独占一屏）。
    private func applyWindowLevel() {
        guard let window else { return }
        window.level = session.isAlwaysOnTop ? .floating : .normal
        NSLog("[Play] alwaysOnTop=\(session.isAlwaysOnTop) level=\(window.level.rawValue)")
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
            // 面板打开时滚轮归面板（选集 / 字幕列表要能滚），不要拿来调音量。
            guard self.session.panel == .none else { return event }
            guard abs(event.scrollingDeltaY) > 0.5 else { return nil }
            guard Date().timeIntervalSince(self.lastWheelAt) > 0.08 else { return nil }
            self.lastWheelAt = Date()
            self.session.setVolume(self.session.volume + (event.scrollingDeltaY > 0 ? 2 : -2))
            return nil
        }
    }

    // MARK: 拖动

    /// 拖动窗口。视频就在这个窗口里，所以直接让窗口服务器做原生拖动：
    /// 和 Windows 一样，画面和控制条一起走，没有第二个进程要追。
    ///
    /// 用 `performDrag(with:)` 而不是 `setFrameOrigin` 循环：前者把移动交给
    /// 窗口服务器，和系统标题栏拖动同一条路径，鼠标多快都不会掉队。
    func beginDrag() {
        guard let window, !session.isFullscreen else { return }
        guard let event = window.currentEvent else { return }
        window.performDrag(with: event)
    }

    /// 我们 App 活跃时把播放窗提到库窗口之上，切到别的 App 就落回普通层级
    /// （和 Windows 的普通播放窗一致）。全屏时不改层级，免得把系统全屏搞乱。
    private func applyActivation(_ active: Bool) {
        guard !session.isFullscreen else { return }
        window?.level = active
            ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
            : .normal
        session.setOnTop(active)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let key = event.keyCode

        // 面板 / 菜单打开时，键盘归面板；Esc 仍用来关面板。
        if session.panel != .none {
            if key == 53 {
                session.panel = .none
                return true
            }
            return false
        }

        // Cmd / Ctrl / Option 组合是系统菜单、输入法、辅助功能在用，别抢。
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }

        // 焦点在输入框 / 音量滑块上时，空格和方向键归控件
        // （以前 Space 一律暂停，滑块调不动，按钮也按不了）。
        if Self.isTextOrSlider(window?.firstResponder) {
            return false
        }

        // 盘内菜单在显示：方向键 / 回车归 libbluray 的按钮导航。
        if session.discMenuActive, forwardDiscMenuKey(key) {
            return true
        }

        let shift = flags.contains(.shift)

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
                if session.isFullscreen {
                    session.toggleFullscreen()
                } else {
                    closePlayer()
                }
                return true
            default:
                return false
        }
    }

    /// 把方向键 / 回车交给盘内菜单（mpv 的 `discnav`）。
    /// 返回 true 表示这次按键已经被菜单吃掉。
    private func forwardDiscMenuKey(_ key: UInt16) -> Bool {
        let action: String?
        switch key {
            case 126: action = "up"
            case 125: action = "down"
            case 123: action = "left"
            case 124: action = "right"
            case 36, 76: action = "select"
            case 53: action = "prev"
            default: action = nil
        }

        guard let action else { return false }
        session.mpv.discNav(action)
        return true
    }

    /// 焦点是不是在能自己用空格 / 方向键的控件上。
    private static func isTextOrSlider(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField || responder is NSSlider
    }

    // MARK: NSWindowDelegate

    /// 窗口尺寸变化时视频层要重画（`CAOpenGLLayer` 的 bounds 变了）。
    func windowDidResize(_ notification: Notification) {
        videoView?.scheduleRender()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        videoView?.scheduleRender()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        videoView?.scheduleRender()
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
    /// 顶栏那块无标题栏区域：拖动移窗。视频在 mpv 自己的窗口里，
    /// 靠 IPC 挪会慢一拍，所以改成把这次拖拽交给 mpv 原生拖动。
    let beginDrag: () -> Void
}
