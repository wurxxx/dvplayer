import SwiftUI
import AppKit
import DvCore

/// 详情页的 Trakt 面板：匹配到哪一条、评分、收藏（collection）、待看（watchlist）。
///
/// 只对「整部片 / 整部剧」操作，和 Trakt 的网页一致；单集进度不在这里改
/// （播放时的 scrobble 会自动记）。匹配不上就什么都不写，宁可没有也不挂错。
struct TraktPanel: View {
    let title: String
    let year: Int?
    let series: Bool

    @EnvironmentObject private var state: AppState

    @State private var match: TraktMatch?
    @State private var loading = true
    @State private var error: String?
    @State private var rating: Int?
    @State private var inWatchlist = false
    @State private var inCollection = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Trakt")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let match, let url = match.webURL {
                    Link("在 Trakt 打开", destination: url)
                        .font(.system(size: 11.5))
                }
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在匹配…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
            } else if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let match {
                Text("\(match.title)\(match.year.map { "（\($0)）" } ?? "")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)

                Divider().overlay(Theme.line)

                ratingRow
                toggleRow("加入待看", "bookmark", inWatchlist) { setWatchlist($0) }
                toggleRow("加入收藏", "heart", inCollection) { setCollection($0) }
            } else {
                Text("Trakt 上没有找到「\(title)」，不挂载。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 272)
        .task { await load() }
    }

    private var ratingRow: some View {
        HStack(spacing: 8) {
            Text("评分")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
            Spacer()
            Menu(rating.map { "\($0) / 10" } ?? "未评分") {
                ForEach(1...10, id: \.self) { value in
                    Button("\(value) 分") { setRating(value) }
                }
                if rating != nil {
                    Divider()
                    Button("清除评分") { setRating(nil) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
        }
    }

    private func toggleRow(_ label: String, _ icon: String, _ on: Bool,
                           _ action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { action($0) })) {
            Label(label, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(busy)
    }

    // MARK: - 动作

    private func load() async {
        loading = true
        error = nil
        do {
            guard await TraktClient.shared.isLoggedIn() else {
                error = "还没连接 Trakt 账号（在「设置 → Trakt」里连接）"
                loading = false
                return
            }
            let found = try await TraktClient.shared.match(title: title, year: year,
                                                           series: series)
            match = found
            guard let found else {
                loading = false
                return
            }
            async let ratingValue = TraktClient.shared.rating(kind: found.kind,
                                                              traktId: found.traktId)
            async let watchValue = TraktClient.shared.isInWatchlist(kind: found.kind,
                                                                    traktId: found.traktId)
            async let collectionValue = TraktClient.shared.isInCollection(kind: found.kind,
                                                                          traktId: found.traktId)
            rating = try? await ratingValue
            inWatchlist = (try? await watchValue) ?? false
            inCollection = (try? await collectionValue) ?? false
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func setRating(_ value: Int?) {
        guard let match else { return }
        perform { try await TraktClient.shared.setRating(value, kind: match.kind,
                                                         traktId: match.traktId) } completion: {
            self.rating = value
            state.showToast(value.map { "Trakt 评分：\($0) 分" } ?? "已清除 Trakt 评分")
        }
    }

    private func setWatchlist(_ on: Bool) {
        guard let match else { return }
        perform { try await TraktClient.shared.setWatchlist(on, kind: match.kind,
                                                            traktId: match.traktId) } completion: {
            self.inWatchlist = on
            state.showToast(on ? "已加入 Trakt 待看" : "已从 Trakt 待看移除")
        }
    }

    private func setCollection(_ on: Bool) {
        guard let match else { return }
        perform { try await TraktClient.shared.setCollection(on, kind: match.kind,
                                                             traktId: match.traktId) } completion: {
            self.inCollection = on
            state.showToast(on ? "已加入 Trakt 收藏" : "已从 Trakt 收藏移除")
        }
    }

    private func perform(_ work: @escaping () async throws -> Void,
                         completion: @escaping () -> Void) {
        busy = true
        Task {
            do {
                try await work()
                completion()
            } catch {
                state.showToast("Trakt：\(error.localizedDescription)")
            }
            busy = false
        }
    }
}
