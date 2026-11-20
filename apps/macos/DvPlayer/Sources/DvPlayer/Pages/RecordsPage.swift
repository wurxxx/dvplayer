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

    @State private var tab: Tab = .general
    @State private var loading = false

    private var continuing: [PlayRecord] {
        state.records
            .filter { $0.durationSeconds <= 0
                || Double($0.positionSeconds) < Double($0.durationSeconds) * 0.98 }
    }

    private var groups: [(title: String, records: [PlayRecord])] {
        var order: [String] = []
        var buckets: [String: [PlayRecord]] = [:]

        for record in continuing {
            let key = record.seriesTitle ?? MediaText.seriesTitle(from: record.title)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(record)
        }

        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 40)

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
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 11) {
                        SectionTitle(text: group.title,
                                     trailing: "\(group.records.count)")

                        HorizontalRow {
                            ForEach(group.records) { record in
                                ContinueCard(record: record) {
                                    state.showToast("播放器下一轮接入")
                                }
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
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
                        ForEach(state.favorites) { item in
                            PosterCard(item: item, width: 168) {
                                state.showToast("详情页下一轮接入")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 32)
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
                        state.showToast("播放器下一轮接入")
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
                .padding(.horizontal, 32)
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
                            state.showToast("详情页下一轮接入")
                        }
                    }
                }
                .padding(.horizontal, 32)
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
