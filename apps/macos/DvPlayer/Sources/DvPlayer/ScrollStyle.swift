import SwiftUI
import AppKit

/// 页面滚动的度量：内容高度 / 滚动偏移由 SwiftUI 侧量出来，右侧自绘的条读它。
///
/// 不用 `NSScrollView.documentView`：SwiftUI 的 `ScrollView` 里那个 view 的高度
/// 并不是内容真实高度（实测 1224×38，而网格实际有一千多高），系统滚动条
/// 因此也从不出现——这也是「滚动条一直看不见」的真正原因。
@MainActor
final class ScrollMetrics: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var contentHeight: CGFloat = 0
    @Published private(set) var viewportHeight: CGFloat = 0

    weak var scrollView: NSScrollView?

    var scrollable: Bool { contentHeight > viewportHeight + 1 }

    /// 0 = 顶部，1 = 底部。
    var fraction: CGFloat {
        let maxOffset = max(contentHeight - viewportHeight, 1)
        return min(max(offset / maxOffset, 0), 1)
    }

    func update(offset: CGFloat, content: CGFloat, viewport: CGFloat) {
        if abs(offset - self.offset) > 0.5 { self.offset = offset }
        if abs(content - contentHeight) > 0.5 { contentHeight = content }
        if abs(viewport - viewportHeight) > 0.5 { viewportHeight = viewport }
    }

    /// 点 / 拖右侧滚动条：直接滚到对应比例。
    func scroll(toFraction value: CGFloat) {
        guard let scroll = scrollView else { return }
        let clip = scroll.contentView
        let maxOffset = max(contentHeight - viewportHeight, 0)
        let target = min(max(value, 0), 1) * maxOffset
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scroll.reflectScrolledClipView(clip)
    }
}

/// 页面滚动样式：系统 `ScrollView` 的 `NSScrollView` 会自己画一层底色
/// （深色主题下也是一块浅色），滚动条按设计隐藏。
struct ScrollStyler: NSViewRepresentable {
    var metrics: ScrollMetrics?

    func makeNSView(context: Context) -> NSView {
        let probe = ScrollStyleProbe(frame: .zero)
        probe.metrics = metrics
        probe.scheduleConfigure()
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let probe = view as? ScrollStyleProbe else { return }
        probe.metrics = metrics
        probe.scheduleConfigure()
    }
}

/// 探针：向上找到包住内容的 `NSScrollView` 改样式，并把它的引用交给 `metrics`
/// （拖滚动条时要直接改它的 `contentView` 位置）。
///
/// 只在 `makeNSView` 里改一次不可靠（那时 NSScrollView 还没套上来），
/// 但也不能在 `layout()` 里无条件改——写属性会再触发一次布局，
/// 变成死循环，页面就画不出来。所以：只在值真的不同时才写。
private final class ScrollStyleProbe: NSView {
    weak var metrics: ScrollMetrics?

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
                // 系统滚动条一律藏掉；要显示时由右侧自绘的那条画。
                if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
                if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
                if scroll.verticalScrollElasticity != .allowed {
                    scroll.verticalScrollElasticity = .allowed
                }
                if scroll.horizontalScrollElasticity != .none {
                    scroll.horizontalScrollElasticity = .none
                }
                metrics?.scrollView = scroll
                break
            }
            node = current.superview
        }
    }
}

extension View {
    /// 透明底 + 隐藏系统滚动条（`metrics` 有值时右侧自绘一条）。
    func pageScrollBackground(metrics: ScrollMetrics? = nil) -> some View {
        background(ScrollStyler(metrics: metrics))
    }
}

/// SwiftUI 侧量出来的滚动信息：内容从视口顶滚走了多少、内容总高。
private struct PageScrollReport: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
}

private struct PageScrollMetricsKey: PreferenceKey {
    static let defaultValue = PageScrollReport()
    static func reduce(value: inout PageScrollReport, nextValue: () -> PageScrollReport) {
        let next = nextValue()
        if next.content > 0 { value = next }
    }
}

/// 页面级滚动容器：原生 `ScrollView` + 透明底 + 自绘滚动条。
struct PageScroll<Content: View>: View {
    var showsScroller = false
    @ViewBuilder var content: Content

    // 用 @State 而不是 @StateObject：滚动只该让右侧那条重算，
    // 不能让整页（ScrollView + 内容）跟着每次偏移变化重建。
    @State private var metrics = ScrollMetrics()

    private let space = "dv-page-scroll"

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                content
                    .background {
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: PageScrollMetricsKey.self,
                                value: PageScrollReport(
                                    offset: -inner.frame(in: .named(space)).minY,
                                    content: inner.size.height
                                )
                            )
                        }
                    }
                    .pageScrollBackground(metrics: showsScroller ? metrics : nil)
            }
            .coordinateSpace(name: space)
            .onPreferenceChange(PageScrollMetricsKey.self) { report in
                metrics.update(offset: report.offset,
                               content: report.content,
                               viewport: outer.size.height)
            }
        }
        .overlay(alignment: .trailing) {
            if showsScroller {
                PageScroller(metrics: metrics)
                    .padding(.trailing, 3)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// 右侧细滚动条：圆角滑块，可点可拖。内容一屏放得下就不显示。
private struct PageScroller: View {
    @ObservedObject var metrics: ScrollMetrics
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        if metrics.scrollable {
            GeometryReader { geo in
                let height = geo.size.height
                let ratio = metrics.viewportHeight / max(metrics.contentHeight, 1)
                let thumb = max(30, min(height, height * ratio))
                let travel = max(height - thumb, 1)
                let y = travel * metrics.fraction

                ZStack(alignment: .top) {
                    // 整条滚动槽都是命中区域：点空白处也直接跳过去。
                    // 以前手势挂在滑块上，`location.y` 只有 0..thumb，
                    // 点/拖滑块会被算成「顶部」，页面直接跳回开头。
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    dragging = true
                                    // 槽内坐标减去半个滑块：让滑块中心跟手。
                                    let fraction = (value.location.y - thumb / 2) / travel
                                    metrics.scroll(toFraction: fraction)
                                }
                                .onEnded { _ in dragging = false }
                        )

                    Capsule()
                        .fill(Color.white.opacity(dragging ? 0.46 : (hovering ? 0.34 : 0.22)))
                        .frame(width: 6, height: thumb)
                        .offset(y: y)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 1)
                        .allowsHitTesting(false)
                }
                .onHover { hovering = $0 }
            }
            .frame(width: 10)
            .animation(.easeOut(duration: 0.12), value: metrics.offset)
        }
    }
}
