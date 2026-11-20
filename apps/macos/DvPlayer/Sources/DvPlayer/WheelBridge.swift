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
