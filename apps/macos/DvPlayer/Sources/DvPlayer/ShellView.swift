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
            brand
                .padding(.horizontal, 18)
                .padding(.top, 42)
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

    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.connections.contains(where: \.ok) ? Theme.success : Theme.faint)
                    .frame(width: 6, height: 6)
                Text(state.sourceSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            Text(state.connections.isEmpty ? "在「服务器」里添加" : "版本 \(state.coreVersion)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .padding(.leading, 14)
        }
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
