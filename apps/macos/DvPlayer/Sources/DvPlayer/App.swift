import SwiftUI

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

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
            if env["DVPLAYER_EXIT"] == "1" {
                NSApp.terminate(nil)
            }
        }
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
    static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
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
        // 内容视图的图层是「上下颠倒」的，翻一次；整个窗口（含标题栏）不用翻。
        if target === view {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        target.layer?.render(in: cg)
        cg.restoreGState()

        // 弹层（popover / 菜单）是独立窗口，单独渲染会丢，顺手叠上去。
        let base = window.frame
        for extra in NSApp.windows where extra !== window && extra.isVisible && extra.contentView != nil {
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
