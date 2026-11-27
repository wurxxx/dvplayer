import AppKit
import SwiftUI
import DvCore

/// 推荐详情页：媒体源里没有的条目，先用豆瓣 / TMDB 的资料看清楚，
/// 再在页面上决定要不要推到 MoviePilot 订阅。
///
/// 结构和媒体详情页一致：大图铺满 + 信息叠加，下面是简介、演职人员、链接。
/// 区别只在数据来源和动作：这里没有播放，只有「添加订阅」。
struct DailyDetailPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = DailyStore.shared

    let item: DailyItem
    let onBack: () -> Void

    @State private var info: DailyDetailInfo?
    @State private var loadError: String?
    @State private var loading = true
    @State private var backdrop: NSImage?
    /// 竖版海报：豆瓣没有横版图，背景只做氛围，靠它把画面说清楚。
    @State private var poster: NSImage?
    @State private var subscribing = false
    @State private var subscribed = false

    private var current: DailyItem { store.item(id: item.id) ?? item }
    private var proxy: String { state.settings.tmdbProxy ?? "" }

    /// 接口还没回来时先用列表里已有的信息铺上，页面不空着。
    private var display: DailyDetailInfo { info ?? DailyAPI.baseInfo(item) }

    var body: some View {
        GeometryReader { screen in
            ZStack(alignment: .top) {
                Theme.bg

                PageScroll {
                    ZStack(alignment: .top) {
                        backdropView(height: max(360, screen.size.height * 0.68))

                        VStack(alignment: .leading, spacing: 30) {
                            header
                            overviewBlock
                            peopleBlock
                            subscribeBlock
                        }
                        .padding(.leading, Theme.contentLeading)
                        .padding(.trailing, 32)
                        .padding(.bottom, 40)
                    }
                    .frame(width: screen.size.width, alignment: .topLeading)
                }
            }
            .overlay(alignment: .topLeading) {
                backButton
            }
            .task(id: item.id) { await load() }
        }
    }

    // MARK: - 背景

    private func backdropView(height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg

                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: height)
                        .blur(radius: info?.backdrop == nil ? 46 : 0)
                        .opacity(info?.backdrop == nil ? 0.72 : 1)
                        .clipped()
                }

                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.42), location: 0),
                        .init(color: Color.black.opacity(0.18), location: 0.22),
                        .init(color: Color.black.opacity(0.42), location: 0.52),
                        .init(color: Theme.bg.opacity(0.88), location: 0.82),
                        .init(color: Theme.bg, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: height)
            .clipped()
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .help("返回每日推荐")
        .padding(.leading, Theme.sidebarWidth + 24)
        .padding(.top, 20)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .bottom, spacing: 26) {
            // 豆瓣只给竖版海报：左边放一张清楚的，别让整页只有一块模糊的底。
            if info?.backdrop == nil, display.poster != nil {
                posterCard
            }

            headerContent
        }
        .padding(.top, 118)
    }

    /// 竖版海报卡：和媒体详情页的竖版海报一个观感。
    private var posterCard: some View {
        ZStack {
            Palette.gradient(for: display.poster ?? display.title)
            Text(Palette.initial(for: display.title))
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.18))

            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 178, height: 267)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(current.trend)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x1A1200))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))

                if loading {
                    ProgressView().controlSize(.small)
                }
            }

            Text(display.title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.98))
                .lineLimit(2)

            if let original = display.originalTitle, !original.isEmpty,
               original != display.title {
                Text(original)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            HStack(spacing: 8) {
                Chip(text: display.isSeries ? "剧集" : "电影",
                     tint: Color.white.opacity(0.2))
                if let rating = display.rating, rating > 0 {
                    Chip(text: ratingText(rating, count: display.ratingCount),
                         tint: Theme.accent.opacity(0.24))
                }
                ForEach(Array(display.genres.prefix(3)), id: \.self) { genre in
                    Chip(text: genre, tint: Color.white.opacity(0.14))
                }
            }

            actions
                .padding(.top, 6)

            if let loadError {
                Text("豆瓣 / TMDB 资料没取全：\(loadError)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = display.year { parts.append(String(year)) }
        if !display.countries.isEmpty {
            parts.append(display.countries.prefix(2).joined(separator: " / "))
        }
        if let runtime = display.runtime, !runtime.isEmpty { parts.append(runtime) }
        if let episodes = display.episodes, episodes > 0 { parts.append("共 \(episodes) 集") }
        return parts.joined(separator: " · ")
    }

    private func ratingText(_ rating: Double, count: Int?) -> String {
        let value = String(format: "%.1f 分", rating)
        guard let count, count >= 100 else { return value }
        let text = count >= 10000
            ? String(format: "%.1f 万", Double(count) / 10000)
            : String(count)
        return "\(value) · \(text)人评价"
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await subscribe() }
            } label: {
                HStack(spacing: 8) {
                    if subscribing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: subscribed ? "checkmark.circle.fill" : "plus.circle.fill")
                    }
                    Text(subscribed ? "已订阅" : "添加订阅")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(subscribed || subscribing)
            .help(subscribed
                  ? "已经推送到 MoviePilot"
                  : "把这个条目推到 MoviePilot 自动搜索下载")

            if let url = doubanURL {
                linkButton("豆瓣", url: url)
            }
            if let url = tmdbURL {
                linkButton("TMDB", url: url)
            }
            if let url = imdbURL {
                linkButton("IMDb", url: url)
            }
        }
    }

    // MARK: - 简介 / 演职人员 / 链接

    @ViewBuilder
    private var overviewBlock: some View {
        if let overview = display.overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                SectionTitle(text: "简介")
                Text(overview)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(5)
                    .frame(maxWidth: 860, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var peopleBlock: some View {
        if !display.directors.isEmpty || !display.cast.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "演职人员")

                if !display.directors.isEmpty {
                    peopleRow(label: "导演", names: display.directors)
                }
                if !display.cast.isEmpty {
                    peopleRow(label: "主演", names: display.cast)
                }
            }
        }
    }

    private func peopleRow(label: String, names: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 1)

            Text(names.joined(separator: " / "))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .lineSpacing(4)
                .frame(maxWidth: 860, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var subscribeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "订阅")
            Text(subscribed
                 ? "已经推送到 MoviePilot，可以到那边看下载进度。"
                 : "订阅会把这个条目推到 MoviePilot，由它自动搜索资源并下载。"
                   + "只想先了解的话不用订阅，直接返回列表就行。")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            if !hasPilot {
                Text("还没配 MoviePilot：到「设置 → 每日推荐」填地址和 API Token 后，"
                     + "这里的「添加订阅」才能用。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasPilot: Bool {
        !(state.settings.moviePilotUrl ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !(state.settings.moviePilotToken ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func linkButton(_ label: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(Theme.surface.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var doubanURL: URL? {
        display.doubanURL.flatMap { URL(string: $0) }
    }

    private var tmdbURL: URL? {
        display.tmdbURL.flatMap { URL(string: $0) }
    }

    private var imdbURL: URL? {
        display.imdbURL.flatMap { URL(string: $0) }
    }

    // MARK: - 行为

    private func load() async {
        subscribed = current.subscribed == true
        let result = await store.detail(for: item, settings: state.settings)
        info = result.info
        loadError = result.error
        loading = false
        NSLog("[DailyTest] 详情 %@：原名=%@ 评分=%@ 类型=%@ 导演=%d 主演=%d 简介=%d 字 错误=%@",
              result.info.title,
              result.info.originalTitle ?? "-",
              result.info.rating.map { String(format: "%.1f", $0) } ?? "-",
              result.info.genres.joined(separator: "/"),
              result.info.directors.count,
              result.info.cast.count,
              result.info.overview?.count ?? 0,
              result.error ?? "-")
        await loadImages(info: result.info)
    }

    private func loadImages(info: DailyDetailInfo) async {
        if let backdropURL = info.backdrop {
            backdrop = await DailyImageCache.shared.image(backdropURL, proxy: proxy)
        } else if let posterURL = info.poster {
            backdrop = await DailyImageCache.shared.image(posterURL, proxy: proxy)
        }
        if let posterURL = info.poster {
            poster = await DailyImageCache.shared.image(posterURL, proxy: proxy)
        }
    }

    private func subscribe() async {
        guard !subscribed, !subscribing else { return }
        subscribing = true
        let message = await store.subscribe(item, settings: state.settings)
        subscribing = false
        if store.item(id: item.id)?.subscribed == true {
            subscribed = true
        }
        if !message.isEmpty {
            state.showToast(message)
        }
    }
}
