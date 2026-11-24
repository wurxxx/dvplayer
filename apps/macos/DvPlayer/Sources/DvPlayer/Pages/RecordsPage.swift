import SwiftUI
import DvCore

/// 「记录」页：通用（继续观看 + 视频收藏）/ 观看（一条条记录）/ 收藏（网格）。
struct RecordsPage: View {
    @EnvironmentObject private var state: AppState

    private enum Tab: String, CaseIterable {
        case general = "通用"
        case watch = "观看"
        case favorites = "收藏"
    }

    /// 截图巡检用：`DVPLAYER_RECORD_TAB=favorites|watch` 直接落在某个分段。
    @State private var tab: Tab = switch ProcessInfo.processInfo.environment["DVPLAYER_RECORD_TAB"] {
    case "favorites": .favorites
    case "watch": .watch
    default: .general
    }
    @State private var loading = false

    private var continuing: [PlayRecord] {
        state.records
            .filter { $0.durationSeconds <= 0
                || Double($0.positionSeconds) < Double($0.durationSeconds) * 0.98 }
    }

    /// 按媒体源分栏，和 Windows 的「继续观看」一致。
    ///
    /// 源名与顺序都来自当前连接列表：连上的排前面，没连上的源记录仍在，
    /// 但排到最后、状态点是灰的（点了打不开）。
    private struct SourceGroup: Identifiable {
        let id: String
        let title: String
        let ok: Bool
        let records: [PlayRecord]
    }

    private var groups: [SourceGroup] {
        var order: [String] = []
        var buckets: [String: [PlayRecord]] = [:]

        for record in continuing {
            let key = record.sourceId
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(record)
        }

        let connections = state.connections
        var index: [String: Int] = [:]
        for (position, connection) in connections.enumerated() {
            index[connection.id] = position
        }
        // 同 id 的源出现两次时 uniqueKeysWithValues 会 trap；用循环后者覆盖前者。
        var names: [String: String] = [:]
        var okStates: [String: Bool] = [:]
        for connection in connections {
            names[connection.id] = connection.name
            okStates[connection.id] = connection.ok
        }

        return order
            .sorted { (index[$0] ?? Int.max) < (index[$1] ?? Int.max) }
            .map { key in
                SourceGroup(
                    id: key,
                    title: names[key] ?? (key.isEmpty ? "其它" : key),
                    ok: okStates[key] ?? false,
                    records: buckets[key] ?? []
                )
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.top, 18)

            PageScroll {
                switch tab {
                case .general:
                    general
                case .watch:
                    watchList
                case .favorites:
                    favoritesGrid
                }
            }
            .overlay {
                if loading && state.records.isEmpty {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            PageTitle(text: "记录")

            HStack(spacing: 2) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12.5))
                            .foregroundStyle(tab == item ? Theme.text : Theme.muted)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(tab == item ? Color.white.opacity(0.09) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))

            Spacer()

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 28)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 26) {
            if groups.isEmpty {
                Caption(text: "还没有看到一半的内容。", size: 12.5)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 11) {
                        // 和 Windows 一样：状态点 + 源名 + 「N 条」，全部靠左。
                        HStack(spacing: 8) {
                            Circle()
                                .fill(group.ok ? Theme.success : Theme.faint)
                                .frame(width: 6, height: 6)

                            Text(group.title)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text)

                            Text("\(group.records.count) 条")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)

                            Spacer(minLength: 0)
                        }

                        HorizontalRow(items: group.records, itemWidth: 264) { record in
                            ContinueCard(record: record) {
                                PlayerLauncher.shared.play(record: record)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                SectionTitle(text: "视频收藏",
                             trailing: state.favorites.isEmpty ? nil : "\(state.favorites.count)")

                if state.favorites.isEmpty {
                    Caption(text: "还没有收藏的视频。在详情页点「加入收藏」即可。", size: 12.5)
                } else {
                    // 和 Windows 的通用页一样：一行横向海报，箭头滚动；
                    // 铺满的网格留给「收藏」分段。
                    HorizontalRow(items: state.favorites, itemWidth: 184) { item in
                        PosterCard(item: item, width: 168) {
                            state.openDetail(item.id)
                        }
                    }
                }
            }
        }
        .padding(.leading, Theme.contentLeading)
        .padding(.trailing, 32)
        .padding(.top, 22)
        .padding(.bottom, 40)
    }

    private var watchList: some View {
        VStack(spacing: 0) {
            ForEach(state.records) { record in
                HStack(spacing: 14) {
                    PosterImage(path: record.posterPath,
                                title: record.seriesTitle ?? record.title)
                        .frame(width: 128, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottom) {
                            ProgressBar(value: record.progress, height: 3)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.seriesTitle ?? MediaText.seriesTitle(from: record.title))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            if let badge = MediaText.badge(season: record.seasonNumber,
                                                           episode: record.episodeNumber) {
                                Text(badge)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.faint)
                            }
                            Text("看到 \(MediaText.duration(Double(record.positionSeconds)))")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                        }
                    }

                    Spacer()

                    Button("播放") {
                        PlayerLauncher.shared.play(record: record)
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button {
                        Task {
                            if let core = state.core {
                                try? await core.removeRecord(record.itemId)
                                await state.refresh()
                            }
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.vertical, 10)

                Divider().overlay(Theme.line.opacity(0.5)).padding(.leading, 32)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 32)
    }

    private var favoritesGrid: some View {
        Group {
            if state.favorites.isEmpty {
                EmptyState(icon: "heart", title: "还没有收藏",
                           hint: "在详情页点「加入收藏」就会出现在这里")
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
                    ForEach(state.favorites) { item in
                        PosterCard(item: item, width: 168) {
                            state.openDetail(item.id)
                        }
                    }
                }
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.top, 22)
                .padding(.bottom, 40)
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16, alignment: .top)]
    }

    private func reload() async {
        loading = true
        await state.refresh()
        loading = false
    }
}
