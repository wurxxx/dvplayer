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

        // 窗口底色统一成页面底色，别让系统在标题栏 / 圆角处漏出浅色。
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.backgroundColor = NSColor(srgbRed: 0x14 / 255.0,
                                                 green: 0x14 / 255.0,
                                                 blue: 0x19 / 255.0,
                                                 alpha: 1)
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
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

        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let env = ProcessInfo.processInfo.environment
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
        NSBezierPath(rect: view.bounds).fill()

        let cg = context.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        view.layer?.render(in: cg)
        cg.restoreGState()

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
