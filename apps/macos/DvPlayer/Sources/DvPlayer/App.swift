import SwiftUI
import DvCore

@main
struct DvPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ShellView()
                .environmentObject(AppState.shared)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 680)
                .task { await AppState.shared.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // 单窗口应用，不需要「新建窗口」。
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Cmd+Q / 注销：单窗口应用的普通窗口关闭回调不会走，
    /// 这里兜底停 mpv、卸 ISO 并清掉全屏时的 presentationOptions。
    func applicationWillTerminate(_ notification: Notification) {
        PlayerLauncher.shared.shutdownForTermination()
        NSApp.presentationOptions = []
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 上次异常退出可能留下挂载中的 ISO 临时目录。
        // hdiutil detach 可能要几秒：放后台，别让 App 启动第一帧卡住。
        DispatchQueue.global(qos: .utility).async {
            BluRayDisc.cleanupStaleMounts()
        }

        // 起窗就抢焦点，红绿灯才是彩色的（非活动窗口是灰点，深色侧栏上看不清）。
        // 窗口 chrome：没有标题栏，三个按钮浮在侧栏左上角。
        // 系统自带的红绿灯在「没有标题栏 + 内容满窗」时靠不住（非前台会淡成灰点），
        // 所以藏掉它们，由界面里的 WindowControls 画三个同样的圆点（见 ShellView）。
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.backgroundColor = NSColor(srgbRed: 0x14 / 255.0,
                                                 green: 0x14 / 255.0,
                                                 blue: 0x19 / 255.0,
                                                 alpha: 1)
                window.title = "DV Player"
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                // 无标题栏，整窗背景可拖（系统原生拖动，双击缩放）。
                // 搜索框是 AppKit 的 NSSearchField，整块会自己吃掉点击，
                // 不会被当成拖窗口——点放大镜 / 内边距也能直接输入。
                window.isMovableByWindowBackground = true

                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
            }

            NSApp.windows.first(where: { $0.contentView != nil })?.makeKeyAndOrderFront(nil)
        }

        // 自检：`DVPLAYER_WINDOWTEST=1` 依次点一下三个窗口按钮，验证
        // 关闭 / 最小化 / 缩放真的能用（远程时没法手动点）。
        if ProcessInfo.processInfo.environment["DVPLAYER_WINDOWTEST"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Self.runWindowTest()
            }
        }

        // 自检：`DVPLAYER_DISC=<iso>` 不经过媒体库，直接开原盘播放窗。
        // `DVPLAYER_DISC_TITLE=N` 选第 N 个标题（不给就弹标题框，远程没法点）。
        if let iso = ProcessInfo.processInfo.environment["DVPLAYER_DISC"], !iso.isEmpty {
            Task { @MainActor in
                let env = ProcessInfo.processInfo.environment
                let wanted = Int(env["DVPLAYER_DISC_TITLE"] ?? "")
                DiscUI.open(path: iso, autoTitle: wanted)

                // 挂载 + 读 mpls 要一两秒；等播放窗真的出来。
                var waited = 0
                while PlayerLauncher.shared.current == nil && waited < 60 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 1
                }

                let wait = Double(env["DVPLAYER_PLAY_SECONDS"] ?? "") ?? 6
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, wait) * 1_000_000_000))
                if let spec = env["DVPLAYER_PLAY_UI"] {
                    Self.runPlayerUI(spec)
                }
                if let path = env["DVPLAYER_PLAY_FRAME"] {
                    PlayerLauncher.shared.current?.mpv.screenshotWindow(to: path)
                }
                Self.logPlayerState()
                if let path = env["DVPLAYER_PLAY_SHOT"] {
                    PlayerLauncher.shared.current?.showChrome()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    Self.capture(to: path, window: PlayerLauncher.shared.window)
                }
                if env["DVPLAYER_EXIT"] == "1" { NSApp.terminate(nil) }
            }
        }

        // 自检：`DVPLAYER_FIND=<关键词>` 连上后搜一下，打印结果 id。
        // 远程验证播放 / 字幕时用它拿真实 itemId，不用手动翻页面。
        if let query = ProcessInfo.processInfo.environment["DVPLAYER_FIND"], !query.isEmpty {
            Task { @MainActor in
                await Self.waitForCore()
                do {
                    if let core = AppState.shared.core {
                        // `@fav` 扫收藏、`@scan` 扫各媒体库前 100 条（远程找带字幕的样片），
                        // 其它是普通搜索。
                        var items: [MediaItem]
                        if query == "@fav" {
                            items = try await core.favorites(pageSize: 100).items
                        } else if query == "@scan" {
                            items = []
                            for library in try await core.libraries() {
                                let page = try await core.items(library.id, pageSize: 100)
                                NSLog("[FindTest] library=\(library.title) "
                                      + "cat=\(library.category) n=\(page.items.count)")
                                items += page.items
                            }
                        } else {
                            items = try await core.search(query).items
                        }
                        for item in items {
                            let sources = item.sources.map { source in
                                "\(source.sourceName)#\(source.sourceId):\(source.itemId)"
                            }.joined(separator: " | ")
                            NSLog("[FindTest] \(item.id) | \(item.title) | \(item.kind) "
                                  + "| sources=\(item.sources.count) [\(sources)]")
                        }
                        NSLog("[FindTest] total=\(items.count) query=\(query)")

                        // 电影 / 单个视频顺手读一下媒体信息，标出带字幕的样片；
                        // 找到 5 条（或扫过 300 条）就停，别把整个库都请求一遍。
                        var scanned = 0
                        var found = 0
                        for item in items where (item.kind == "movie" || item.kind == "video")
                            && scanned < 300 && found < 5 {
                            scanned += 1
                            guard let info = try? await core.mediaInfo(item.id),
                                  !info.subtitles.isEmpty else { continue }
                            found += 1
                            NSLog("[FindTest] subs=\(info.subtitles.count) "
                                  + "audios=\(info.audios.count) | \(item.title) | \(item.id)")
                        }
                        NSLog("[FindTest] scanned=\(scanned) withSubs=\(found)")
                    }
                } catch {
                    NSLog("[FindTest] failed: \(error.localizedDescription)")
                }

                if ProcessInfo.processInfo.environment["DVPLAYER_EXIT"] == "1" {
                    NSApp.terminate(nil)
                }
            }
        }

        // 自检：`DVPLAYER_PLAY=<itemId>` 等核心连上后直接开播放窗。
        // 远程验证用：`DVPLAYER_PLAY_SHOT=<png>` 截播放窗，`DVPLAYER_PLAY_UI=` 拨浮层 / 切轨，
        // `DVPLAYER_PLAY_SECONDS=` 后打印位置，`DVPLAYER_EXIT=1` 收工退出。
        if let itemId = ProcessInfo.processInfo.environment["DVPLAYER_PLAY"], !itemId.isEmpty {
            Task { @MainActor in
                await Self.waitForCore()
                let env = ProcessInfo.processInfo.environment

                // `DVPLAYER_PLAY_RECORD=1`：模拟「继续观看」入口——从观看记录续播，
                // 选集由 `PlaylistLoader` 顺着记录自己找回来。
                if env["DVPLAYER_PLAY_RECORD"] == "1" {
                    // 记录是连上以后才拉的，比 core 晚到几秒。
                    for _ in 0..<240 {
                        if !AppState.shared.records.isEmpty { break }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }

                    if let record = AppState.shared.records.first {
                        PlayerLauncher.shared.play(record: record)
                        NSLog("[PlayTest] record \(record.itemId) parent=\(record.parentId ?? "-")")
                    } else {
                        NSLog("[PlayTest] 没有观看记录")
                    }

                    // `DVPLAYER_PLAY_OPENING_SHOT=<png>`：窗口刚弹出、视频还没出画时截一张，
                    // 确认打开阶段是不透明黑底，而不是透出桌面。
                    if let path = env["DVPLAYER_PLAY_OPENING_SHOT"] {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        Self.capture(to: path, window: PlayerLauncher.shared.window)
                    }

                    let wait = Double(env["DVPLAYER_PLAY_RECORD_WAIT"] ?? "") ?? 3
                    try? await Task.sleep(nanoseconds: UInt64(max(0.5, wait) * 1_000_000_000))
                    if let spec = env["DVPLAYER_PLAY_UI"] {
                        Self.runPlayerUI(spec)
                    }
                    if let path = env["DVPLAYER_PLAY_FRAME"] {
                        PlayerLauncher.shared.current?.mpv.screenshotWindow(to: path)
                    }
                    Self.logPlayerState()
                    if let path = env["DVPLAYER_PLAY_SHOT"] {
                        PlayerLauncher.shared.current?.showChrome()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        Self.capture(to: path, window: PlayerLauncher.shared.window)
                    }
                    if env["DVPLAYER_EXIT"] == "1" { NSApp.terminate(nil) }
                    return
                }

                // `DVPLAYER_PLAY_CONTAINER=<剧集 id>`：模拟详情页入口，先把这一季的集列出来，
                // 再带 playlist 打开（验证选集面板 / 自动接下一集）。
                var playlist: [PlayerEpisode] = []
                var seriesTitle: String?
                if let containerId = env["DVPLAYER_PLAY_CONTAINER"],
                   let core = AppState.shared.core {
                    if let detail = try? await core.detail(containerId) {
                        seriesTitle = MediaText.clean(detail.title)
                    }
                    if let page = try? await core.children(containerId, page: 1, pageSize: 100) {
                        playlist = PlayerEpisode.list(from: page.items, season: nil)
                    }
                    NSLog("[PlayTest] playlist=\(playlist.count) title=\(seriesTitle ?? "-") "
                          + "first=\(playlist.first?.id ?? "-") last=\(playlist.last?.id ?? "-")")
                }

                PlayerLauncher.shared.play(itemId: itemId,
                                          startSeconds: nil,
                                          playlist: playlist,
                                          seriesTitle: seriesTitle,
                                          hintTitle: seriesTitle)
                NSLog("[PlayTest] open \(itemId)")

                // `DVPLAYER_PLAY_RETRY=1`：等错误面板出来，点一次「重试」再记状态。
                if env["DVPLAYER_PLAY_RETRY"] == "1" {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    PlayerLauncher.shared.current?.retry()
                    NSLog("[PlayTest] retry sent")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    Self.logPlayerState()
                }

                if let path = env["DVPLAYER_PLAY_OPENING_SHOT"] {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    Self.capture(to: path, window: PlayerLauncher.shared.window)
                }


                if let text = env["DVPLAYER_PLAY_SEEK"], let seconds = Double(text) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    PlayerLauncher.shared.current?.seek(to: seconds)
                    NSLog("[PlayTest] seek \(seconds)")
                }

                if let path = env["DVPLAYER_PLAY_FRAME"] {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    PlayerLauncher.shared.current?.mpv.screenshotWindow(to: path)
                    NSLog("[PlayTest] frame \(path)")
                }

                if let spec = env["DVPLAYER_PLAY_UI"] {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    Self.runPlayerUI(spec)
                }

                if let text = env["DVPLAYER_PLAY_SECONDS"], let seconds = Double(text) {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                    Self.logPlayerState()
                }

                if let path = env["DVPLAYER_PLAY_SHOT"] {
                    let delay = Double(env["DVPLAYER_PLAY_SHOT_DELAY"] ?? "") ?? 6
                    try? await Task.sleep(nanoseconds: UInt64(max(0.2, delay) * 1_000_000_000))
                    PlayerLauncher.shared.current?.showChrome()
                    // 等 SwiftUI 把浮层真正画进图层，再截。
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    NSLog("[PlayTest] player window=\(PlayerLauncher.shared.window.map { "\($0.frame.width)x\($0.frame.height)" } ?? "-")")
                    Self.capture(to: path, window: PlayerLauncher.shared.window)
                    if env["DVPLAYER_EXIT"] == "1" { NSApp.terminate(nil) }
                    return
                }

                if env["DVPLAYER_EXIT"] == "1" {
                    Self.logPlayerState()
                    NSApp.terminate(nil)
                }
            }
        }

        // 自检：`DVPLAYER_CLICKTEST="x,y"`（左上角原点）在窗口上合成一次点击，
        // 看 firstResponder 有没有变成输入框——排查「搜索框点不进去」用。
        // 配了 `DVPLAYER_SCROLL=end` 时改成「滚到底再点」（坐标按滚动后的位置给），
        // 用来验证详情页底部的媒体信息卡能不能点。
        if let spec = ProcessInfo.processInfo.environment["DVPLAYER_CLICKTEST"],
           ProcessInfo.processInfo.environment["DVPLAYER_SCROLL"] != "end" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                Self.runClickTest(spec)
            }
        }

        // 截图巡检：`DVPLAYER_SHOT=/路径/xx.png` 打开后截一张壳自己（不需要屏幕录制权限），
        // 配上 `DVPLAYER_EXIT=1` 截完就退，方便脚本跑。
        let env = ProcessInfo.processInfo.environment
        guard let shot = env["DVPLAYER_SHOT"] else { return }

        let delay = Double(env["DVPLAYER_SHOT_DELAY"] ?? "") ?? 2.8

        Task { @MainActor in
            // 截图时先把自己拉到前台：窗口不在前台时系统会把红绿灯画成灰点，
            // 截出来看不出颜色。
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.contentView != nil })?.makeKeyAndOrderFront(nil)

            try? await Task.sleep(nanoseconds: UInt64(max(0.2, delay) * 1_000_000_000))

            // `DVPLAYER_SCROLL_Y=<像素>`：把长页面往下滚一段（选集行在页面中部）。
            if let dy = Double(env["DVPLAYER_SCROLL_Y"] ?? ""), dy != 0 {
                Self.scrollBy(CGFloat(dy))
                try? await Task.sleep(nanoseconds: 700_000_000)
            }

            // `DVPLAYER_SCROLL=end`：截长页面底部（详情页的媒体信息在那里）。
            if env["DVPLAYER_SCROLL"] == "end" {
                Self.scrollToEnd()
                try? await Task.sleep(nanoseconds: 900_000_000)

                if let spec = env["DVPLAYER_CLICKTEST"] {
                    Self.runClickTest(spec)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }

            Self.capture(to: shot)

            // 截图巡检：`DVPLAYER_SHOT_SHEET=1` 再截一张附着的 sheet
            // （选源框、确认框这类浮层不在主窗口的图层里）。
            if env["DVPLAYER_SHOT_SHEET"] == "1",
               let sheet = NSApp.windows.first(where: { $0.sheetParent != nil }) {
                let ext = (shot as NSString).pathExtension
                let base = (shot as NSString).deletingPathExtension
                let suffix = ext.isEmpty ? "-sheet" : "-sheet.\(ext)"
                Self.capture(to: base + suffix, window: sheet)

                // 留着 sheet 的话 NSApp.terminate 会被挡住，截完就收起来。
                sheet.sheetParent?.endSheet(sheet)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            if env["DVPLAYER_EXIT"] == "1" {
                NSApp.terminate(nil)
            }
        }
    }

    /// 等核心连上（媒体源的手动连接 / 自动连接都在 `AppState.start()` 里）。
    @MainActor
    static func waitForCore() async {
        for _ in 0..<120 {
            if AppState.shared.core != nil { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        NSLog("[PlayTest] core 一直没连上")
    }

    /// 播放页自检：`episodes` / `info` / `audio:N` / `subtitle:N`（-1 关闭）/ `pause` / `close`。
    @MainActor
    static func runPlayerUI(_ spec: String) {
        guard let session = PlayerLauncher.shared.current else {
            NSLog("[PlayTest] 没有播放窗")
            return
        }

        // 和 Windows 的 `--play-features` 一样，支持逗号分隔的多条。
        for item in spec.split(separator: ",") {
            applyPlayerUI(String(item), session: session)
        }
    }

    @MainActor
    private static func applyPlayerUI(_ spec: String, session: PlayerSession) {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
            case "episodes":
                session.togglePanel(.episodes)
            case "next":
                session.nextEpisode()
                NSLog("[PlayTest] next item=\(session.itemId)")
            case "prev":
                session.previousEpisode()
                NSLog("[PlayTest] prev item=\(session.itemId)")
            case "info":
                session.togglePanel(.info)
            case "pause":
                session.togglePause()
            case "speed":
                if let value = Double(parts.count > 1 ? parts[1] : ""), value > 0 {
                    session.setSpeed(value)
                }
                NSLog("[PlayTest] speed=\(session.speed)")
            case "mute":
                session.toggleMute()
                NSLog("[PlayTest] mute=\(session.muted)")
            case "close":
                session.requestClose()
            case "fullscreen":
                session.toggleFullscreen()
            case "audio":
                let index = Int(parts.count > 1 ? parts[1] : "") ?? 0
                if session.audioTracks.indices.contains(index) {
                    session.selectAudio(session.audioTracks[index].id)
                }
                NSLog("[PlayTest] audio=\(index) -> \(session.selectedAudioId) of \(session.audioTracks.count)")
            case "subtitle":
                let index = Int(parts.count > 1 ? parts[1] : "") ?? 0
                if index < 0 {
                    session.selectSubtitle(0)
                } else if session.subtitleTracks.indices.contains(index) {
                    session.selectSubtitle(session.subtitleTracks[index].id)
                }
                NSLog("[PlayTest] subtitle=\(index) -> \(session.selectedSubtitleId) of \(session.subtitleTracks.count)")
            case "audioout":
                NSLog("[PlayTest] audio devices=\(session.audioDevices.count) "
                      + "current=\(session.audioDevice.isEmpty ? "-" : session.audioDevice) "
                      + "passthrough=\(session.audioPassthrough) hdr=\(session.hdrPassthrough)")
                for device in session.audioDevices {
                    NSLog("[PlayTest] audio device \(device.name) | \(device.description)")
                }
            case "audiodevice":
                let index = Int(parts.count > 1 ? parts[1] : "") ?? 0
                if session.audioDevices.indices.contains(index) {
                    session.setAudioDevice(session.audioDevices[index].name)
                }
                NSLog("[PlayTest] audio device -> \(session.audioDevice) of \(session.audioDevices.count)")
            case "audiotoggle":
                session.toggleAudioPassthrough()
                session.toggleHdrPassthrough()
                NSLog("[PlayTest] audio toggle passthrough=\(session.audioPassthrough) "
                      + "hdr=\(session.hdrPassthrough) label=\(session.audioOutputLabel)")
            case "aspect":
                if let mode = PlayerAspect(rawValue: parts.count > 1 ? parts[1] : "fit") {
                    session.setAspect(mode)
                }
                NSLog("[PlayTest] aspect=\(session.aspect.rawValue)")
            case "sleep":
                if let minutes = Double(parts.count > 1 ? parts[1] : ""), minutes > 0 {
                    session.setSleep(minutes: minutes)
                } else {
                    session.cancelSleep()
                }
                NSLog("[PlayTest] sleep=\(session.sleepLabel ?? "-")")
            case "sleepepisode":
                session.setSleepEndOfEpisode()
                NSLog("[PlayTest] sleep=\(session.sleepLabel ?? "-")")
            case "nosleep":
                session.cancelSleep()
                NSLog("[PlayTest] sleep=\(session.sleepLabel ?? "-")")
            case "mark":
                switch parts.count > 1 ? parts[1] : "" {
                    case "intro": session.markIntroEnd()
                    case "outro": session.markOutroStart()
                    case "clear": session.clearMarkers()
                    default: break
                }
                NSLog("[PlayTest] markers intro=\(session.markers.introEnd.map { Int($0) } ?? -1) "
                      + "outro=\(session.markers.outroStart.map { Int($0) } ?? -1)")
            case "skipoutro":
                session.skipOutro()
                NSLog("[PlayTest] skipoutro pos=\(Int(session.position))")
            case "danmaku":
                let on = (parts.count > 1 ? parts[1] : "on") != "off"
                session.setDanmaku(enabled: on)
                NSLog("[PlayTest] danmaku=\(session.danmakuEnabled) status=\(session.danmakuStatus ?? "-")")
            case "danmakufile":
                // 自检 / 调试：直接挂一份本地 ASS，不联网。
                let path = parts.count > 1 ? parts[1] : ""
                session.mpv.addSecondarySubtitle(path)
                NSLog("[PlayTest] danmakufile=\(path)")
            case "subsearch":
                session.openSubtitleSearch()
                NSLog("[PlayTest] subsearch panel=\(session.panel)")
            case "subload":
                let index = Int(parts.count > 1 ? parts[1] : "") ?? 0
                if session.subtitleResults.indices.contains(index) {
                    session.applySubtitle(session.subtitleResults[index])
                }
                NSLog("[PlayTest] subload=\(index) of \(session.subtitleResults.count)")
            case "subauto":
                // 自检：搜索 → 等结果 → 下载并挂上第一条。
                session.openSubtitleSearch()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if let first = session.subtitleResults.first {
                        session.applySubtitle(first)
                    }
                    NSLog("[PlayTest] subauto results=\(session.subtitleResults.count)")
                }
            default:
                break
        }

        NSLog("[PlayTest] ui=\(spec) panel=\(session.panel) chrome=\(session.chromeVisible)")
    }

    @MainActor
    static func logPlayerState() {
        guard let session = PlayerLauncher.shared.current else {
            NSLog("[PlayTest] 没有播放窗")
            return
        }
        NSLog("[PlayTest] tracks \(session.trackSummary)")
        NSLog("[PlayTest] item=\(session.itemId) pos=\(Int(session.position)) dur=\(Int(session.duration)) "
              + "paused=\(session.paused) eof=\(session.eof) loading=\(session.loading) "
              + "audio=\(session.audioTracks.count)/aid=\(session.selectedAudioId) "
              + "subs=\(session.subtitleTracks.count)/sid=\(session.selectedSubtitleId) "
              + "playlist=\(session.playlist.count) fullscreen=\(session.isFullscreen) "
              + "aspect=\(session.aspect.rawValue) sleep=\(session.sleepLabel ?? "-") "
              + "intro=\(session.markers.introEnd.map { Int($0) } ?? -1) "
              + "outro=\(session.markers.outroStart.map { Int($0) } ?? -1) "
              + "skipoutro=\(session.showSkipOutro) "
              + "danmaku=\(session.danmakuEnabled)/\(session.danmakuStatus ?? "-") "
              + "subOnline=\(session.subtitleResults.count)/\(session.subtitleSearching) "
              + "subErr=\(session.subtitleError ?? "-") "
              + "error=\(session.error ?? "-")")
    }

    /// 合成一次鼠标点击 + 几个字符，验证控件真的能拿到焦点。
    @MainActor
    static func runClickTest(_ spec: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else {
            NSLog("[ClickTest] 找不到窗口")
            NSApp.terminate(nil)
            return
        }

        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else {
            NSLog("[ClickTest] 坐标格式应为 x,y")
            NSApp.terminate(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 参数按「左上角原点」给，AppKit 用的是左下角原点。
        let point = NSPoint(x: parts[0], y: view.bounds.height - parts[1])
        NSLog("[ClickTest] point=\(point) before=\(String(describing: window.firstResponder))")

        // 走 app 的事件队列：直接 sendEvent 会在「拖动窗口」这种追踪循环里卡住。
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            NSApp.postEvent(event, atStart: false)
            usleep(120_000)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSLog("[ClickTest] after=\(String(describing: window.firstResponder))")

            for char in Array("abc") {
                guard let key = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: String(char), charactersIgnoringModifiers: String(char),
                    isARepeat: false, keyCode: 0) else { continue }
                window.sendEvent(key)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let editor = window.firstResponder as? NSTextView
                NSLog("[ClickTest] text=\(String(describing: editor?.string))")
                NSApp.terminate(nil)
            }
        }
    }

    /// 依次点窗口左上角的三个圆点（关闭 / 最小化 / 缩放），把结果打到日志。
    @MainActor
    static func runWindowTest() {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.level == .normal && $0.contentView != nil
        }) else {
            NSLog("[WindowTest] 找不到窗口")
            NSApp.terminate(nil)
            return
        }

        window.makeKeyAndOrderFront(nil)

        /// 圆点在侧栏左上角：靠左 18、靠上 16，直径 12、间距 8 → 圆心 24 / 44 / 64，y 22。
        func click(_ x: CGFloat) {
            let point = NSPoint(x: x, y: window.frame.height - 22)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                window.sendEvent(event)
            }
        }

        Task { @MainActor in
            let start = window.frame
            NSLog("[WindowTest] 起始 frame=\(start) mini=\(window.isMiniaturized)")

            click(44)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            NSLog("[WindowTest] 点最小化 → mini=\(window.isMiniaturized)")

            if window.isMiniaturized {
                window.deminiaturize(nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            click(64)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NSLog("[WindowTest] 点缩放 → frame=\(window.frame)")

            if window.frame != start {
                click(64)
                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            click(24)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NSLog("[WindowTest] 点关闭 → visible=\(window.isVisible)")

            exit(0)
        }
    }

    /// 把主窗口里第一个纵向滚动视图滚到底，截图巡检长页面用。
    @MainActor
    /// 截图巡检：往下滚 `dy` 像素，用来截页面中段（详情页的选集行）。
    static func scrollBy(_ dy: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        guard let scroll = findScroll(in: window.contentView) else { return }
        let current = scroll.contentView.bounds.origin.y
        let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        let target = min(max(0, current + dy), maxY)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        reflectScroll(scroll)
    }

    private static func reflectScroll(_ scroll: NSScrollView) {
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func scrollToEnd() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        guard let scroll = findScroll(in: window.contentView) else { return }
        guard let document = scroll.documentView else { return }
        let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func findScroll(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView,
           let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            return scroll
        }
        for child in view.subviews {
            if let found = findScroll(in: child) { return found }
        }
        return nil
    }

    /// 把主窗口内容画成图片。走 CALayer 渲染，绕开屏幕录制权限。
    ///
    /// 注意：SwiftUI 的视图是 layer-backed，`cacheDisplay` / `dataWithPDF` 拿不到
    /// 内容（整块透明），必须让 layer 自己重新渲染一遍。渲染结果上下是反的，
    /// 翻一次再存。
    ///
    /// 路径以 `.jpg` / `.jpeg` 结尾就出 JPEG（按 1x 渲染，约 200KB）——
    /// 手机上看截图时 PNG（2x，2–5MB）经常加载不完。要原尺寸就设
    /// `DVPLAYER_SHOT_SCALE=2`。
    @MainActor
    static func capture(to path: String, window only: NSWindow? = nil) {
        guard let window = only ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else {
            NSLog("[DvPlayer] 截图失败：找不到窗口")
            return
        }

        let env = ProcessInfo.processInfo.environment

        // `DVPLAYER_SHOT_FRAME=1`：连标题栏一起截（红绿灯在这里），
        // 平时只截内容区，省得顶部多一条。
        let target: NSView = env["DVPLAYER_SHOT_FRAME"] == "1"
            ? (view.superview ?? view)
            : view

        let size = target.bounds.size
        NSLog("[Shot] win=\(window.title) num=\(window.windowNumber) size=\(Int(size.width))x\(Int(size.height))")
        guard size.width > 0, size.height > 0 else { return }

        let lowered = path.lowercased()
        let jpeg = lowered.hasSuffix(".jpg") || lowered.hasSuffix(".jpeg")
        let scale = Double(env["DVPLAYER_SHOT_SCALE"] ?? "") ?? (jpeg ? 1 : window.backingScaleFactor)

        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            return
        }
        canvas.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x19 / 255.0, alpha: 1)
            .setFill()
        NSBezierPath(rect: target.bounds).fill()

        let cg = context.cgContext
        cg.saveGState()
        // 内容视图的图层是「上下颠倒」的（SwiftUI 的 hosting 用 flipped 坐标），翻一次；
        // 整个窗口（含标题栏）不用翻。普通 NSView 容器（播放窗）本来就是正的。
        if target === view && view.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        target.layer?.render(in: cg)
        cg.restoreGState()

        // 弹层（popover / 菜单）是独立窗口，单独渲染会丢，顺手叠上去。
        let base = window.frame
        // 只叠真正的弹层（popover / 菜单）；普通窗口（主窗口、播放窗）互相独立，不能叠。
        for extra in NSApp.windows where extra !== window && extra.isVisible
            && extra.contentView != nil && (extra.level != .normal || extra is NSPanel) {
            let dx = extra.frame.minX - base.minX
            let dy = extra.frame.minY - base.minY
            cg.saveGState()
            cg.translateBy(x: dx, y: dy)
            // 弹层的内容视图是翻转坐标系，跟主窗口方向相反，再翻一次。
            if let content = extra.contentView, content.isFlipped {
                cg.translateBy(x: 0, y: content.bounds.height)
                cg.scaleBy(x: 1, y: -1)
            }
            extra.contentView?.layer?.render(in: cg)
            cg.restoreGState()
        }

        // 标题栏（红绿灯）是另一个子视图，layer.render 画不到它的按钮，
        // 用 cacheDisplay 单独画一份，再叠到内容顶部——截图才和窗口一致。
        if let bar = window.contentView?.superview?.subviews.first(where: {
            String(describing: type(of: $0)).contains("TitlebarContainer")
        }), let barRep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
            bar.cacheDisplay(in: bar.bounds, to: barRep)
            let barImage = NSImage(size: bar.bounds.size)
            barImage.addRepresentation(barRep)
            barImage.draw(in: NSRect(x: 0, y: size.height - bar.bounds.height,
                                     width: size.width, height: bar.bounds.height),
                          from: .zero, operation: .sourceOver, fraction: 1)
        }

        NSGraphicsContext.restoreGraphicsState()

        let data = jpeg
            ? canvas.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            : canvas.representation(using: .png, properties: [:])
        guard let data else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        NSLog("[DvPlayer] 截图：\(path)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
