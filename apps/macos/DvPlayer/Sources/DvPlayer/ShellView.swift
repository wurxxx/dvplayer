import Combine
import SwiftUI
import DvCore

/// 侧栏 + 内容区。侧栏结构和 Windows 一致：品牌、导航、服务器列表、连接状态；
/// 「媒体库」不单独做菜单——点某个服务器就是它的首页。
struct ShellView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: Theme.sidebarWidth)
                .background(Theme.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.line).frame(width: 1)
                }

            ZStack(alignment: .bottom) {
                Theme.bg
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        // 确认卡片盖住整窗（含侧栏），和 Windows 的模态确认框一致。
        .overlay {
            if let request = state.confirm {
                ConfirmDialogView(request: request,
                                  onCancel: { state.confirm = nil },
                                  onConfirm: {
                                      state.confirm = nil
                                      request.action()
                                  })
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceHover, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    .padding(.bottom, 26)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toast)
        .animation(.easeOut(duration: 0.16), value: state.confirm?.id)
    }

    @ViewBuilder
    private var content: some View {
        switch state.page {
        case .home(let sourceId):
            LibrariesPage(sourceId: sourceId)
        case .sources:
            SourcesPage()
        case .records:
            RecordsPage()
        case .search:
            SearchPage()
        case .settings:
            SettingsPage()
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 没有标题栏，三个窗口按钮自己画（系统红绿灯在这种窗型下会淡掉）。
            WindowControls()
                .padding(.leading, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

            brand
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            nav
                .padding(.horizontal, 10)

            if !state.connections.isEmpty {
                Text("服务器")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .padding(.leading, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 6)

                serverNav
                    .padding(.horizontal, 10)
            }

            Spacer(minLength: 12)
            status
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.accent)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: 0x1A1200))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("DV Player")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("媒体库")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private var nav: some View {
        VStack(spacing: 2) {
            SidebarItem(icon: "server.rack", title: "服务器",
                        selected: state.page == .sources) {
                state.page = .sources
            }

            SidebarItem(icon: "clock.arrow.circlepath", title: "记录",
                        selected: state.page == .records) {
                state.page = .records
            }

            SidebarItem(icon: "magnifyingglass", title: "搜索",
                        selected: state.page == .search) {
                state.page = .search
            }

            SidebarItem(icon: "gearshape", title: "设置",
                        selected: state.page == .settings) {
                state.page = .settings
            }
        }
    }

    private var serverNav: some View {
        VStack(spacing: 2) {
            ForEach(state.connections) { connection in
                SidebarItem(
                    icon: "rectangle.stack",
                    title: connection.name,
                    selected: state.page == .home(connection.id),
                    dot: connection.ok ? Theme.success : Theme.danger,
                    size: 13.5
                ) {
                    state.openSource(connection.id)
                }
            }
        }
    }

    /// 左下角只留版本；连没连上看服务器列表前面的状态点。
    private var status: some View {
        Text("版本 \(state.coreVersion)")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
    }
}

private struct SidebarItem: View {
    let icon: String
    let title: String
    let selected: Bool
    var dot: Color?
    var size: CGFloat = 14
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                        .frame(width: 16)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13.5))
                        .frame(width: 16)
                }

                Text(title)
                    .font(.system(size: size))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.text : Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .fill(selected ? Color.white.opacity(0.07)
                                   : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 侧栏左上角的三个窗口按钮（关闭 / 最小化 / 最大化）。
///
/// macOS 26 里 `.hiddenTitleBar` + 内容满窗的系统红绿灯在窗口不在前台时
/// 会淡成灰点，深色侧栏上基本看不见，所以藏掉系统按钮，自己画一组同样的圆点：
/// 始终有颜色，鼠标移上去浮出符号，行为和系统一致。
struct WindowControls: View {
    @State private var hovering = false
    @State private var active = true

    var body: some View {
        HStack(spacing: 8) {
            dot(color: 0xFF5F57, glyph: "xmark") { window?.performClose(nil) }
            dot(color: 0xFEBC2E, glyph: "minus") { window?.performMiniaturize(nil) }
            dot(color: 0x28C840, glyph: "plus") { window?.performZoom(nil) }
        }
        .onHover { hovering = $0 }
        // 窗口不在前台时和系统红绿灯一样变灰，别一直红黄绿地亮着。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            active = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            active = false
        }
    }

    private var window: NSWindow? {
        NSApp.windows.first {
            $0.isVisible && $0.level == .normal && $0.contentView != nil
        }
    }

    private func dot(color: UInt32, glyph: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: active ? color : 0x4A4A52))
                .frame(width: 12, height: 12)
                .overlay {
                    if hovering && active {
                        Image(systemName: glyph)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.6))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(glyph == "xmark" ? "关闭" : (glyph == "minus" ? "最小化" : "缩放"))
    }
}
