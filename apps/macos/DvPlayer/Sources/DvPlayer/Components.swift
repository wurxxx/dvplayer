import SwiftUI
import AppKit
import DvCore

// MARK: - 占位色

/// 没有海报时的占位：按标题散出一个偏暗的渐变，比一块纯灰好看些。
enum Palette {
    private static let gradients: [(UInt32, UInt32)] = [
        (0x2A2340, 0x171226), (0x1F2A3A, 0x121A25), (0x33241C, 0x1C1310),
        (0x22302A, 0x111A16), (0x2E2433, 0x181120), (0x1E2A33, 0x101A20),
    ]

    static func gradient(for seed: String) -> LinearGradient {
        var hash: UInt32 = 2166136261
        for byte in seed.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        let pair = gradients[Int(hash % UInt32(gradients.count))]
        return LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func initial(for title: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.first else { return "?" }
        return String(first)
    }
}

// MARK: - 海报

/// 一张海报。异步加载，失败就留在渐变占位上。
struct PosterImage: View {
    @EnvironmentObject private var state: AppState

    let path: String?
    var title: String = ""
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.gradient(for: path ?? title)

                Text(Palette.initial(for: title))
                    .font(.system(size: max(18, min(geo.size.width, geo.size.height) * 0.3),
                                  weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .task(id: path) {
            let loaded = await PosterStore.shared.image(path: path, core: state.core)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

/// 网格里的海报卡：2:3 海报 + 标题 + 副标题。
struct PosterCard: View {
    @EnvironmentObject private var state: AppState

    let item: MediaItem
    var width: CGFloat
    var onTap: () -> Void

    private var badge: String? {
        guard state.settings.showResolution,
              let resolution = item.resolution, !resolution.isEmpty else { return nil }
        return resolution
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                ZStack(alignment: .topTrailing) {
                    PosterImage(path: item.posterPath, title: item.title)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.35),
                                        in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                    }
                }
                .frame(width: width, height: (width * 1.5).rounded())
                .overlay(alignment: .bottom) {
                    // 看完的（进度满）不再画一条满格横线，那看着像描边。
                    if item.progress > 0.01 && item.progress < 0.995 {
                        ProgressBar(value: item.progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 9)

            Text(MediaText.describe(item))
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 「继续观看」横卡：16:9 缩略图 + 进度条 + 剩余时间。
struct ContinueCard: View {
    let record: PlayRecord
    var onTap: () -> Void

    private var remaining: String {
        let left = record.durationSeconds - record.positionSeconds
        return left > 0 ? "剩 \(MediaText.duration(Double(left)))" : "已看完"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                ZStack(alignment: .bottomTrailing) {
                    PosterImage(path: record.posterPath,
                                title: record.seriesTitle ?? record.title)

                    Text(remaining)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .frame(width: 248, height: 140)
                .overlay(alignment: .bottom) {
                    ProgressBar(value: record.progress, height: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(record.seriesTitle ?? record.title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.top, 9)

            Text(recordSub)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(width: 248, alignment: .leading)
    }

    private var recordSub: String {
        if let badge = MediaText.badge(season: record.seasonNumber,
                                       episode: record.episodeNumber) {
            return "\(record.seriesTitle ?? "剧集") · \(badge)"
        }
        return MediaText.clean(record.title)
    }
}

/// 「我的媒体」卡片：420×220，横向拼 1–3 张海报。
struct LibraryCard: View {
    let library: MediaLibrary
    let arts: [String?]
    var onTap: () -> Void

    private var columns: Int { max(1, min(3, arts.count)) }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    if arts.isEmpty {
                        Palette.gradient(for: library.id)
                    } else {
                        ForEach(Array(arts.enumerated()), id: \.offset) { _, art in
                            PosterImage(path: art, title: library.title)
                        }
                    }
                }

                LinearGradient(colors: [.clear, Color.black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 96)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)

                Text(library.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 13)
            }
            .frame(width: 420, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 小零件

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.white.opacity(0.18)
                Theme.accent
                    .frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

/// 空态：一个图标 + 一句说明。
struct EmptyState: View {
    let icon: String
    let title: String
    var hint: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Theme.line)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
            if let hint {
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 横向卡片行：触控板横滑 / 拖滚动，鼠标停上来才浮出左右箭头，
/// 和 Windows 的 `HorizontalRow` 行为一致。
///
/// 箭头按「整屏」翻，用 `ScrollViewReader` 滚到某一项的 `id`；
/// 所以内容必须由这里喂进来（`items` + 闭包），不能直接塞 `ForEach`。
struct HorizontalRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    /// 一项占的横向步长（卡宽 + 间距），用来算一屏能放几张。
    var itemWidth: CGFloat
    var spacing: CGFloat = 16
    @ViewBuilder var content: (Item) -> Content

    @State private var index = 0
    @State private var hovering = ProcessInfo.processInfo.environment["DVPLAYER_ARROWS"] == "1"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(items) { item in
                        content(item)
                            .id(item.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .background(RowWheelBridge())
            .overlay {
                GeometryReader { geo in
                    let perPage = max(1, Int(geo.size.width / max(itemWidth, 1)))
                    let scrollable = CGFloat(items.count) * itemWidth > geo.size.width + 1

                    // 内容一屏放得下就不出箭头；箭头和整行垂直居中。
                    HStack {
                        if hovering && scrollable && index > 0 {
                            arrow("chevron.left") { move(proxy, by: -perPage) }
                        }
                        Spacer()
                        if hovering && scrollable && index < items.count - 1 {
                            arrow("chevron.right") { move(proxy, by: perPage) }
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .onHover { hovering = $0 }
            .onChange(of: items.count) { _ in index = 0 }
        }
    }

    private func move(_ proxy: ScrollViewProxy, by delta: Int) {
        guard !items.isEmpty else { return }
        let target = min(max(0, index + delta), items.count - 1)
        guard target != index else { return }
        index = target
        withAnimation(.easeOut(duration: 0.26)) {
            proxy.scrollTo(items[target].id, anchor: .leading)
        }
    }

    private func arrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.55), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
