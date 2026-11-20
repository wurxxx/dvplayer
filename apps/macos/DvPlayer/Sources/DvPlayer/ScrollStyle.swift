import SwiftUI
import AppKit

/// 页面滚动样式：系统 `ScrollView` 的 `NSScrollView` 会自己画一层底色
/// （深色主题下也是一块浅色），而且滚动条按设计要隐藏。
///
/// 放在滚动内容的最外层，向上找到包住它的 `NSScrollView` 改掉。这里不用
/// 自己造滚动视图：SwiftUI 的测量、弹性、滚动位置都还是原生的。
struct ScrollStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = ScrollStyleProbe(frame: .zero)
        probe.scheduleConfigure()
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ScrollStyleProbe)?.scheduleConfigure()
    }
}

/// 探针：向上找到包住内容的 `NSScrollView` 改样式。
///
/// 只在 `makeNSView` 里改一次不可靠（那时 NSScrollView 还没套上来），
/// 但也不能在 `layout()` 里无条件改——写属性会再触发一次布局，
/// 变成死循环，页面就画不出来。所以：只在值真的不同时才写。
private final class ScrollStyleProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfigure()
    }

    /// 视图层级是异步搭起来的，隔两拍再压一次就稳了。
    func scheduleConfigure() {
        configure()
        DispatchQueue.main.async { [weak self] in self?.configure() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.configure() }
    }

    func configure() {
        var node: NSView? = superview
        while let current = node {
            if let scroll = current as? NSScrollView {
                if scroll.drawsBackground { scroll.drawsBackground = false }
                if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
                if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
                if scroll.verticalScrollElasticity != .allowed {
                    scroll.verticalScrollElasticity = .allowed
                }
                if scroll.horizontalScrollElasticity != .none {
                    scroll.horizontalScrollElasticity = .none
                }
                break
            }
            node = current.superview
        }
    }
}

extension View {
    /// 透明底 + 隐藏滚动条。
    func pageScrollBackground() -> some View {
        background(ScrollStyler())
    }
}

/// 页面级滚动容器：原生 `ScrollView` + 透明底 / 隐藏滚动条。
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content.pageScrollBackground()
        }
    }
}
