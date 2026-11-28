import SwiftUI
import AppKit
import DvCore

/// 「每日推荐」页：TMDB / 豆瓣的热门，媒体源里有的点开进详情，
/// 没有的打开豆瓣 / TMDB 的资料页，在资料页里再决定要不要订阅。
struct DailyPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = DailyStore.shared

    /// 媒体源里没有的条目：点开后盖在列表上的资料页。
    @State private var detailItem: DailyItem?

    /// 电影 / 剧集分开看：原来上下叠着，用户不知道下面还有剧集。
    private enum DailyTab: String, CaseIterable {
        case movie = "电影"
        case series = "剧集"
    }

    @State private var tab: DailyTab = .movie

    /// 某一类为空时直接落到另一类，不留下一个空 tab。
    private var activeTab: DailyTab {
        if store.movies.isEmpty && !store.series.isEmpty { return .series }
        if store.series.isEmpty && !store.movies.isEmpty { return .movie }
        return tab
    }

    private func count(of tab: DailyTab) -> Int {
        tab == .movie ? store.movies.count : store.series.count
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16, alignment: .top)]
    }

    var body: some View {
        ZStack {
            list
                .allowsHitTesting(detailItem == nil)

            if let detailItem {
                // 换条目时整页重建：上一部的简介 / 演职人员不残留。
                DailyDetailPage(item: detailItem,
                                onBack: { self.detailItem = nil })
                    .id(detailItem.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: detailItem?.id)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs

            PageScroll {
                VStack(alignment: .leading, spacing: 22) {
                    notes

                    if store.loading && store.items.isEmpty {
                        loadingBlock
                    } else if store.items.isEmpty {
                        emptyBlock
                    } else {
                        if activeTab == .movie && !store.movies.isEmpty {
                            grid(store.movies)
                        }
                        if activeTab == .series && !store.series.isEmpty {
                            grid(store.series)
                        }
                        footer
                    }
                }
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .task {
            // 自检：`DVPLAYER_DAILY_TAB=series` 直接停在剧集。
            if ProcessInfo.processInfo.environment["DVPLAYER_DAILY_TAB"] == "series" {
                tab = .series
            }
            await firstLoad()
            await openDebugDetailIfRequested()
        }
    }

    /// 自检：`DVPLAYER_DAILY_DETAIL=<片名>` 等推荐就绪后直接打开那条的资料页。
    private func openDebugDetailIfRequested() async {
        guard let wanted = ProcessInfo.processInfo.environment["DVPLAYER_DAILY_DETAIL"],
              !wanted.isEmpty else { return }
        for _ in 0..<30 {
            if let hit = store.items.first(where: {
                $0.title.contains(wanted) && $0.matchedItemId == nil
            }) {
                detailItem = hit
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        NSLog("[DailyTest] 没找到可打开详情的条目：%@", wanted)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            PageTitle(text: "每日推荐")

            if store.matching && !store.items.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Caption(text: "正在匹配媒体源…", size: 12)
                }
            } else if let fetchedAt = store.fetchedAt {
                Caption(text: "\(dayText(fetchedAt)) · \(store.items.count) 条", size: 12)
            }

            Spacer()

            Button {
                store.refresh(core: state.core, settings: state.settings, force: true)
            } label: {
                Text(store.loading ? "刷新中…" : "刷新")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(store.loading)
        }
        .padding(.leading, Theme.contentLeading)
        .padding(.trailing, 32)
        .padding(.top, 18)
    }

    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter.string(from: date)
    }

    // MARK: - 分类切换

    @ViewBuilder
    private var tabs: some View {
        if !store.movies.isEmpty && !store.series.isEmpty {
            HStack(spacing: 2) {
                ForEach(DailyTab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        Text("\(item.rawValue) \(count(of: item))")
                            .font(.system(size: 13.5, weight: activeTab == item
                                          ? .semibold : .regular))
                            .foregroundStyle(activeTab == item ? Theme.accentInk : Theme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(activeTab == item ? Theme.accentSoft : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 9))
            .padding(.leading, Theme.contentLeading)
            .padding(.top, 14)
        }
    }

    // MARK: - 提示

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if (state.settings.tmdbApiKey ?? "").isEmpty {
                note("没填 TMDB API Key，现在只显示豆瓣热门。"
                     + "填上之后会一起显示 TMDB 的趋势榜。", tint: Theme.faint)
            }

            if let error = store.error {
                note(error, tint: Theme.danger)
            } else if let error = store.tmdbError,
                      !(state.settings.tmdbApiKey ?? "").isEmpty {
                note(error, tint: Theme.faint)
            }

            if let error = store.feed?.doubanError, !store.items.isEmpty,
               store.movies.isEmpty || store.series.isEmpty {
                note(error, tint: Theme.faint)
            }

            if (state.settings.moviePilotUrl ?? "").isEmpty {
                note("没配 MoviePilot：详情页里的「添加订阅」会提示先配置。"
                     + "在「设置 → 每日推荐」里填地址和 API Token。", tint: Theme.faint)
            }
        }
    }

    private func note(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 分组

    private func grid(_ items: [DailyItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(items) { item in
                DailyCard(item: item, onTap: { activate(item) })
            }
        }
    }

    private var footer: some View {
        Text("推荐来自 TMDB / 豆瓣，每天打开应用时更新一次；"
             + "媒体源里有的点开直接进详情页，没有的会打开豆瓣 / TMDB 的资料页，"
             + "可以在里面「添加订阅」推到 MoviePilot。")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.faint)
            .padding(.top, 4)
    }

    private var loadingBlock: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Caption(text: "正在获取今日热门…", size: 12)
        }
        .padding(.vertical, 24)
    }

    private var emptyBlock: some View {
        EmptyState(icon: "sparkles",
                   title: "今天还没有推荐",
                   hint: store.loading ? "正在获取…" : "刷新一下试试，或者检查网络。")
    }

    // MARK: - 行为

    private func firstLoad() async {
        if store.items.isEmpty || store.feed?.date != store.today {
            store.refresh(core: state.core, settings: state.settings, force: false)
        } else {
            store.refreshIfNeeded(core: state.core, settings: state.settings)
        }
    }

    private func activate(_ item: DailyItem) {
        // 媒体源里有：直接进详情。
        if let id = item.matchedItemId {
            state.openDetail(id)
            return
        }

        // 媒体源里没有：先看豆瓣 / TMDB 的资料，订阅放进资料页里。
        detailItem = item
    }
}

/// 推荐卡：海报 + 标题 + 状态。点按的语义由页面决定（进媒体详情 / 打开资料页）。
private struct DailyCard: View {
    let item: DailyItem
    let onTap: () -> Void

    @State private var hovering = false

    /// 状态只留「已订阅」：「在媒体源里」已经有绿色在库角标，「点按查看」是废话。
    private var subscribed: Bool { item.subscribed == true }

    private var badge: String? {
        if let rating = item.rating, rating > 0 {
            return String(format: "%.1f", rating)
        }
        return nil
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    DailyPoster(url: item.poster, title: item.title)

                    // hover 时压暗，给中间的行动图标腾出对比。
                    Color.black.opacity(hovering ? 0.34 : 0).animation(.easeOut(duration: 0.12),
                                                                     value: hovering)

                    if hovering {
                        Image(systemName: item.matchedItemId != nil
                              ? "play.fill" : "info.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 6)
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Text(item.trend)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                }
                .overlay(alignment: .bottomLeading) {
                    if item.matchedItemId != nil {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.successOnImage).frame(width: 5, height: 5)
                            Text("在库")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.successOnImage)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())

                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 9)

                HStack(spacing: 5) {
                    if subscribed {
                        Text("已订阅")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accentInk)
                            .lineLimit(1)
                    }
                    if let year = item.year {
                        if subscribed {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint.opacity(0.6))
                        }
                        Text(String(year))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                }
                // 没有状态也没有年份时也占住一行，卡片高度不会忽高忽低。
                .frame(height: 16, alignment: .leading)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(.easeOut(duration: 0.12)) { hovering = value }
        }
        .help(hint)
    }

    private var hint: String {
        if let matched = item.matchedTitle, item.matchedItemId != nil {
            return "在媒体源里找到：\(matched)"
        }
        if item.subscribed == true { return "已经推送到 MoviePilot · 点按查看资料" }
        return "点按查看豆瓣 / TMDB 资料，在资料页里订阅"
    }
}
