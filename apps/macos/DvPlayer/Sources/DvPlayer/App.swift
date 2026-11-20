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
        DispatchQueue.main.async {
            NSApp.windows.first(where: { $0.contentView != nil })?.makeKeyAndOrderFront(nil)
        }

        // 窗口底色统一成页面底色，别让系统在标题栏 / 圆角处漏出浅色。
        DispatchQueue.main.async {
            for window in NSApp.windows {
            }
        }

        // 截图巡检：`DVPLAYER_SHOT=/路径/xx.png` 打开后截一张壳自己（不需要屏幕录制权限），
        // 配上 `DVPLAYER_EXIT=1` 截完就退，方便脚本跑。
        let env = ProcessInfo.processInfo.environment
        guard let shot = env["DVPLAYER_SHOT"] else { return }

        let delay = Double(env["DVPLAYER_SHOT_DELAY"] ?? "") ?? 2.8

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, delay) * 1_000_000_000))

            // `DVPLAYER_SCROLL=end`：截长页面底部（详情页的媒体信息在那里）。
            if env["DVPLAYER_SCROLL"] == "end" {
                Self.scrollToEnd()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }

            Self.capture(to: shot)
            if env["DVPLAYER_EXIT"] == "1" {
                NSApp.terminate(nil)
            }
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
