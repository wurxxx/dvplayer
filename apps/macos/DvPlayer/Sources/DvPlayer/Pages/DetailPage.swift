import SwiftUI
import DvCore

/// 详情页：整块横版图铺满 + 信息叠加，下面是动作按钮和选集。
/// 和 Windows 一样，不再叠一张竖版海报卡；渐变淡到页面底色。
struct DetailPage: View {
    let itemId: String
    let onBack: () -> Void
    let onPlay: (String) -> Void

    @EnvironmentObject private var state: AppState

    @State private var detail: MediaDetail?
    @State private var seasons: [MediaItem] = []
    @State private var seasonId: String?
    @State private var episodes: [MediaItem] = []
    @State private var loading = true
    @State private var busy = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16, alignment: .top)]
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 22) {
                    if !seasons.isEmpty {
                        seasonBar
                    }

                    if !episodes.isEmpty {
                        VStack(alignment: .leading, spacing: 11) {
                            SectionTitle(text: "选集", trailing: "\(episodes.count) 集")
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                                ForEach(episodes) { episode in
                                    PosterCard(item: episode, width: 168) {
                                        onPlay(episode.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 24)
            .padding(.top, 20)
        }
        .task(id: itemId) { await load() }
        .overlay {
            if loading && detail == nil {
                ProgressView().controlSize(.large)
            }
        }
    }

    // MARK: - 顶部大图

    private var header: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                PosterImage(path: detail?.backdropPath ?? detail?.posterPath,
                            title: detail?.title ?? "")

                LinearGradient(
                    stops: [
                        .init(color: Theme.bg.opacity(0), location: 0.35),
                        .init(color: Theme.bg.opacity(0.45), location: 0.62),
                        .init(color: Theme.bg.opacity(0.85), location: 0.84),
                        .init(color: Theme.bg, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text(detail?.title ?? "正在读取…")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.98))
                        .lineLimit(2)

                    if let meta = metaLine, !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }

                    if !chips.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(chips, id: \.self) { chip in
                                Chip(text: chip, tint: Color.white.opacity(0.2))
                            }
                        }
                    }

                    if let overview = detail?.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(4)
                            .frame(maxWidth: 780, alignment: .leading)
                    }

                    actions
                        .padding(.top, 4)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 26)
                .frame(width: geo.size.width, alignment: .leading)
            }
            .frame(width: geo.size.width, height: 460)
            .clipped()
        }
        .frame(height: 460)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                guard let detail else { return }
                onPlay(detail.playItemId ?? detail.id)
            } label: {
                Label("播放", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                guard let detail else { return }
                onPlay(detail.playItemId ?? detail.id)
            } label: {
                Text("重头看")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                toggleFavorite()
            } label: {
                Label(detail?.isFavorite == true ? "已收藏" : "加入收藏",
                      systemImage: detail?.isFavorite == true ? "heart.fill" : "heart")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                toggleWatched()
            } label: {
                Label(detail?.isWatched == true ? "标记为未观看" : "标记为已观看",
                      systemImage: detail?.isWatched == true ? "checkmark.circle.fill" : "checkmark.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(SecondaryButtonStyle())

            if busy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var seasonBar: some View {
        HStack(spacing: 8) {
            ForEach(seasons) { season in
                Button {
                    seasonId = season.id
                    Task { await loadEpisodes(season.id) }
                } label: {
                    Text(seasonTitle(season))
                        .font(.system(size: 12.5))
                        .foregroundStyle(season.id == seasonId ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(season.id == seasonId ? Color(hex: 0x2E2412) : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 派生文案

    private var metaLine: String? {
        guard let detail else { return nil }
        var parts: [String] = []
        if let year = detail.releaseDate?.prefix(4) { parts.append(String(year)) }
        if let runtime = MediaText.runtime(detail.runtimeSeconds) { parts.append(runtime) }
        if let status = detail.status, !status.isEmpty { parts.append(status) }
        if let rating = detail.rating, rating > 0 {
            parts.append(String(format: "%.1f 分", rating))
        }
        return parts.joined(separator: " · ")
    }

    private var chips: [String] {
        guard let detail else { return [] }
        var parts: [String] = [MediaText.kindLabel(detail.kind)]
        if let resolution = detail.resolution, !resolution.isEmpty { parts.append(resolution) }
        if let audio = detail.audioType, !audio.isEmpty { parts.append(audio) }
        if let range = detail.colorRange, !range.isEmpty { parts.append(range) }
        if let episodes = detail.localEpisodeCount ?? detail.episodeCount, episodes > 0 {
            parts.append("\(episodes) 集")
        }
        return parts
    }

    private func seasonTitle(_ season: MediaItem) -> String {
        if let number = season.seasonNumber, number > 0 {
            return "第 \(number) 季"
        }
        return MediaText.clean(season.title)
    }

    // MARK: - 数据

    private func toggleFavorite() {
        guard let core = state.core, let detail else { return }
        let target = !(detail.isFavorite ?? false)
        busy = true
        Task {
            do {
                try await core.setFavorite(itemId, favorite: target)
                self.detail = try? await core.detail(itemId)
                state.showToast(target ? "已加入收藏" : "已取消收藏")
            } catch {
                state.showToast("操作失败：\(error.localizedDescription)")
            }
            busy = false
        }
    }

    private func toggleWatched() {
        guard let core = state.core, let detail else { return }
        let target = !(detail.isWatched ?? false)
        busy = true
        Task {
            do {
                try await core.setWatched(itemId, watched: target)
                self.detail = try? await core.detail(itemId)
                state.showToast(target ? "已标记为看过" : "已标记为未看")
            } catch {
                state.showToast("操作失败：\(error.localizedDescription)")
            }
            busy = false
        }
    }

    private func load() async {
        guard let core = state.core else {
            loading = false
            return
        }

        loading = true
        defer { loading = false }

        do {
            detail = try await core.detail(itemId)
        } catch {
            NSLog("[DvPlayer] detail \(itemId) failed: \(error.localizedDescription)")
            state.showToast("详情读取失败：\(error.localizedDescription)")
            return
        }

        guard let kind = detail?.kind.lowercased(),
              ["series", "tv", "season", "folder"].contains(kind) else { return }

        let children = (try? await core.children(itemId, pageSize: 300))?.items ?? []
        if children.first?.isSeason == true {
            seasons = children
            let first = children.first
            seasonId = first?.id
            if let first {
                episodes = (try? await core.children(first.id, pageSize: 300))?.items ?? []
                episodes = episodes.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
            }
        } else {
            episodes = children.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
        }
    }

    private func loadEpisodes(_ season: String) async {
        guard let core = state.core else { return }
        let items = (try? await core.children(season, pageSize: 300))?.items ?? []
        episodes = items.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
    }
}
