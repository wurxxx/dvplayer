import SwiftUI
import AppKit
import DvCore

/// 「每日推荐」页：TMDB / 豆瓣的热门，媒体源里有的点开进详情，
/// 没有的推到 MoviePilot 订阅。
struct DailyPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = DailyStore.shared

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            PageScroll {
                VStack(alignment: .leading, spacing: 22) {
                    notes

                    if store.loading && store.items.isEmpty {
                        loadingBlock
                    } else if store.items.isEmpty {
                        emptyBlock
                    } else {
                        if !store.movies.isEmpty {
                            section(title: "电影", items: store.movies)
                        }
                        if !store.series.isEmpty {
                            section(title: "剧集", items: store.series)
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
        .task { await firstLoad() }
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
                note("没配 MoviePilot：媒体源里没有的条目暂时不能直接订阅。"
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

    private func section(title: String, items: [DailyItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: title,
                         trailing: "\(items.count)")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(items) { item in
                    DailyCard(item: item,
                              subscribing: store.subscribing.contains(item.id),
                              onTap: { activate(item) })
                }
            }
        }
    }

    private var footer: some View {
        Text("推荐来自 TMDB / 豆瓣，每天打开应用时更新一次；"
             + "在媒体源里匹配到的条目可以直接打开，其余可以一键推到 MoviePilot 订阅。")
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

        if item.subscribed == true {
            state.showToast("已经推送到 MoviePilot 了")
            return
        }

        Task {
            let message = await store.subscribe(item, settings: state.settings)
            if !message.isEmpty {
                state.showToast(message)
            }
        }
    }
}

/// 推荐卡：海报 + 标题 + 状态。点按的语义由页面决定（进详情 / 订阅）。
private struct DailyCard: View {
    let item: DailyItem
    let subscribing: Bool
    let onTap: () -> Void

    @State private var hovering = false

    private var stateText: String {
        if item.matchedItemId != nil { return "在媒体源里" }
        if item.subscribed == true { return "已订阅" }
        return "点按订阅"
    }

    private var stateColor: Color {
        if item.matchedItemId != nil { return Theme.success }
        if item.subscribed == true { return Theme.accent }
        return Theme.faint
    }

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
                              ? "play.fill" : "plus.circle.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 6)
                    }

                    if subscribing {
                        Color.black.opacity(0.5)
                        ProgressView().controlSize(.small)
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x1A1200))
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
                            Circle().fill(Theme.success).frame(width: 5, height: 5)
                            Text("在库")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white)
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
                    Text(stateText)
                        .font(.system(size: 12))
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                    if let year = item.year {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint.opacity(0.6))
                        Text(String(year))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                }
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
        if item.subscribed == true { return "已经推送到 MoviePilot" }
        return "媒体源里没有，点按推到 MoviePilot 订阅"
    }
}
