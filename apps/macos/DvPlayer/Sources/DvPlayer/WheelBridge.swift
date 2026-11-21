import AppKit
import SwiftUI

/// 横向行里的滚轮桥：鼠标停在横向行上滚「纵向」滚轮时，把事件交给页面的
/// 纵向滚动。
///
/// AppKit 的 `NSScrollView` 会把落在自己身上的滚轮事件吃掉——横向行不用
/// 纵向滚动，但事件也不会再传给外层页面，结果就是鼠标一停在海报行上，
/// 整页就滚不动了（Windows 那版就有这个毛病）。这里在事件到达横向行之前
/// 先拦下来，纵向的转给外层的页面滚动，横向的照旧。
struct RowWheelBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        RowWheelView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

final class RowWheelView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else {
            installMonitor()
        }
    }

    deinit {
        removeMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window else { return event }

            // 只处理指针确实在这一行上的事件。
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }

            // 横向手势（触控板左右滑）留给横向行自己。
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }

            // 找外层能纵向滚的那个（横向行自己的 document 不够高，会被跳过）。
            guard let page = self.verticalScrollAncestor else { return event }
            page.scrollWheel(with: event)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private var verticalScrollAncestor: NSScrollView? {
        var node: NSView? = superview
        while let current = node {
            if let scroll = current as? NSScrollView,
               let document = scroll.documentView,
               document.bounds.height > scroll.contentView.bounds.height + 1 {
                return scroll
            }
            node = current.superview
        }
        return nil
    }
}

/// 横向行「滚到第 N 项」：SwiftUI 的 `scrollTo` 在单元格刚插入时不可靠，
/// 这里直接找到行自己的 NSScrollView 设横向偏移（选集快捷段 / 1-30、31-60 用）。
struct RowJumpBridge: NSViewRepresentable {
    var targetX: CGFloat
    var token: Int

    func makeNSView(context: Context) -> NSView {
        RowJumpView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? RowJumpView)?.apply(targetX: targetX, token: token)
    }
}

final class RowJumpView: NSView {
    private var lastToken = Int.min

    func apply(targetX: CGFloat, token: Int) {
        guard token != lastToken else { return }
        lastToken = token
        guard token > 0 else { return }

        // 等这一轮布局落定，卡片进 HStack 后再算偏移。
        DispatchQueue.main.async { [weak self] in
            self?.scroll(to: targetX)
        }
    }

    private func scroll(to targetX: CGFloat) {
        guard let scroll = rowScroll, let document = scroll.documentView else {
            NSLog("[RowJump] no row scroll targetX=%.0f", targetX)
            return
        }

        let maxX = max(0, document.bounds.width - scroll.contentView.bounds.width)
        let x = min(max(0, targetX), maxX)
        scroll.contentView.scroll(to: NSPoint(x: x, y: scroll.contentView.bounds.origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 背景视图和这一行的 `NSScrollView` 在同一个 SwiftUI 容器里，
    /// 按兄弟节点找，比顺着 superview 往上碰运气稳。
    private var rowScroll: NSScrollView? {
        var node: NSView? = superview
        while let current = node {
            if String(describing: type(of: current)).contains("PlatformGroupContainer") {
                for sibling in current.subviews {
                    if let scroll = Self.firstHorizontalScroll(in: sibling) {
                        return scroll
                    }
                }
            }
            node = current.superview
        }

        // 兜底：上一级能横向滚的那个。
        return horizontalScrollAncestor
    }

    private static func firstHorizontalScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           let document = scroll.documentView,
           document.bounds.width > scroll.contentView.bounds.width + 1 {
            return scroll
        }

        for child in view.subviews {
            if let found = firstHorizontalScroll(in: child) {
                return found
            }
        }

        return nil
    }

    private var horizontalScrollAncestor: NSScrollView? {
        var node: NSView? = superview
        while let current = node {
            if let scroll = current as? NSScrollView,
               let document = scroll.documentView,
               document.bounds.width > scroll.contentView.bounds.width + 1 {
                return scroll
            }
            node = current.superview
        }
        return nil
    }
}
