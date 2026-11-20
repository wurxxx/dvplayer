import SwiftUI
import AppKit
import DvCore

/// 选集里的一项：带上真正的集号（有些源不给 `episodeNumber`，就按顺序补）。
struct EpisodeRow: Identifiable {
    let item: MediaItem
    let number: Int
    var id: String { item.id }

    var badge: String { String(format: "E%02d", number) }

    /// 文件名（`S01E03` / `第 3 集`）就退化成「第 N 集」，别把文件名怼到卡片上。
    var title: String {
        let raw = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || MediaText.looksLikeFileName(raw) {
            return "第 \(number) 集"
        }
        return MediaText.trimExtension(raw)
    }
}

/// 详情页：整块横版图铺满 + 信息叠加，下面是动作按钮、选集、演职人员、
/// 链接和媒体信息（和 Windows 的 `SeriesPage` 一一对应）。
struct DetailPage: View {
    let itemId: String
    let onBack: () -> Void
    let onPlay: (String) -> Void

    @EnvironmentObject private var state: AppState

    @State private var detail: MediaDetail?
    @State private var seasons: [MediaItem] = []
    @State private var seasonId: String?
    @State private var episodes: [EpisodeRow] = []
    @State private var people: [Person] = []
    @State private var mediaInfo: MediaInfo?
    @State private var loading = true
    @State private var busy = false

    /// 点演职人员后浮出来的作品页。
    @State private var works: PersonWorks?
    /// 从作品页再点进另一部片的详情（详情页套详情页）。
    @State private var nestedItemId: String?

    var body: some View {
        ZStack {
            if let nestedItemId {
                DetailPage(itemId: nestedItemId,
                           onBack: { self.nestedItemId = nil },
                           onPlay: onPlay)
            } else {
                content
            }

            if let works {
                PersonWorksPanel(works: works,
                                 onBack: { self.works = nil },
                                 onOpen: { id in
                                     self.works = nil
                                     self.nestedItemId = id
                                 })
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 主体

    private var content: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 30) {
                    if !seasons.isEmpty {
                        seasonBar
                    }

                    if !episodes.isEmpty {
                        episodeBlock
                    }

                    if !people.isEmpty {
                        castBlock
                    }

                    linksBlock

                    if let mediaInfo, hasTracks(mediaInfo) {
                        mediaInfoBlock(mediaInfo)
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
                onPlay(playTargetId ?? detail.id)
            } label: {
                Label("播放", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                guard let detail else { return }
                onPlay(playTargetId ?? detail.id)
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

    // MARK: - 选集

    private var episodeBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "选集", trailing: "\(episodes.count) 集")

            HorizontalRow(items: episodes, itemWidth: 314, spacing: 18) { row in
                EpisodeCard(episode: row) {
                    onPlay(row.id)
                }
            }
        }
    }

    // MARK: - 演职人员

    private var castBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "演职人员", trailing: "\(people.count) 位")

            HorizontalRow(items: people, itemWidth: 112) { person in
                CastCard(person: person) {
                    Task { await openWorks(person) }
                }
            }
        }
    }

    // MARK: - 链接

    private var linksBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "链接")

            Button {
                openDouban()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                    Text("豆瓣")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.line.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func openDouban() {
        let title = MediaText.clean(detail?.title)
        guard title != "(未命名)" else { return }
        var components = URLComponents(string: "https://search.douban.com/movie/subject_search")
        components?.queryItems = [URLQueryItem(name: "search_text", value: title)]
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 媒体信息

    private func mediaInfoBlock(_ info: MediaInfo) -> some View {
        let cards = trackCards(info)
        return VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "媒体信息", trailing: "\(cards.count) 条轨道")

            HorizontalRow(items: cards, itemWidth: 342) { card in
                MediaInfoCard(card: card)
            }
        }
    }

    private func hasTracks(_ info: MediaInfo) -> Bool {
        info.video != nil || !info.audios.isEmpty
    }

    private func trackCards(_ info: MediaInfo) -> [TrackCard] {
        var cards: [TrackCard] = []

        if let video = info.video {
            var rows: [(String, String)] = []
            rows.append(("编码", video.codec ?? ""))
            if let width = video.width, let height = video.height, width > 0, height > 0 {
                rows.append(("分辨率", "\(width) x \(height)"))
            } else if let label = video.resolutionLabel {
                rows.append(("分辨率", label))
            }
            if let rate = video.frameRate, rate > 0 {
                rows.append(("帧率", String(format: "%.2f fps", rate)))
            }
            rows.append(("比特率", MediaText.bitRate(video.bitRate) ?? ""))
            rows.append(("动态范围", video.colorRange ?? (video.dolbyVision == true ? "DV" : "")))
            rows.append(("配置", video.profile ?? ""))
            if let level = video.level {
                rows.append(("等级", String(format: "%.1f", level)))
            }
            rows.append(("长宽比", video.aspectRatio ?? ""))
            if let interlaced = video.interlaced {
                rows.append(("交错", interlaced ? "是" : "否"))
            }
            if let depth = video.bitDepth, depth > 0 {
                rows.append(("位深", "\(depth) bit"))
            }
            rows.append(("像素格式", video.pixelFormat ?? ""))

            cards.append(TrackCard(id: "video", icon: "film", title: video.title ?? "视频",
                                   rows: rows, active: true))
        }

        for (index, audio) in info.audios.enumerated() {
            var rows: [(String, String)] = []
            rows.append(("语言", audio.language ?? "--"))
            rows.append(("编码", audio.codec ?? ""))
            rows.append(("配置", audio.profile ?? ""))
            rows.append(("布局", audio.layout ?? ""))
            if let channels = audio.channels, channels > 0 {
                rows.append(("声道", "\(channels) ch"))
            }
            if let sampleRate = audio.sampleRate, sampleRate > 0 {
                rows.append(("采样率", "\(sampleRate) Hz"))
            }
            rows.append(("比特率", MediaText.bitRate(audio.bitRate) ?? ""))
            rows.append(("默认", (audio.isDefault ?? false) ? "是" : "否"))
            if audio.isExternal == true {
                rows.append(("外部", "是"))
            }

            cards.append(TrackCard(id: "audio-\(index)",
                                   icon: "waveform",
                                   title: audio.title ?? "音频 \(index + 1)",
                                   rows: rows,
                                   active: audio.isDefault ?? false))
        }

        return cards
    }

    // MARK: - 派生文案

    private var playTargetId: String? {
        detail?.playItemId ?? episodes.first?.id ?? (detail != nil ? itemId : nil)
    }

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

    private func openWorks(_ person: Person) async {
        guard let core = state.core else { return }
        let items = (try? await core.personWorks(person.id)) ?? []
        guard !items.isEmpty else {
            state.showToast("没有找到 \(person.name) 的作品")
            return
        }
        withAnimation(.easeOut(duration: 0.16)) {
            works = PersonWorks(id: person.id, name: person.name,
                                role: person.role ?? person.job, items: items)
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

        // 演职人员对整部剧取，和 Windows 一致。
        people = (try? await core.people(itemId)) ?? []

        guard let kind = detail?.kind.lowercased(),
              ["series", "tv", "season", "folder"].contains(kind) else {
            await loadMediaInfo()
            return
        }

        let children = (try? await core.children(itemId, pageSize: 300))?.items ?? []
        if children.first?.isSeason == true {
            seasons = children.sorted { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }
            let first = seasons.first
            seasonId = first?.id
            if let first {
                episodes = makeRows((try? await core.children(first.id, pageSize: 300))?.items ?? [])
            }
        } else {
            episodes = makeRows(children)
        }

        await loadMediaInfo()
    }

    private func loadEpisodes(_ season: String) async {
        guard let core = state.core else { return }
        let items = (try? await core.children(season, pageSize: 300))?.items ?? []
        episodes = makeRows(items)
        await loadMediaInfo()
    }

    private func loadMediaInfo() async {
        guard let core = state.core, let target = playTargetId else { return }
        mediaInfo = try? await core.mediaInfo(target)
    }

    private func makeRows(_ items: [MediaItem]) -> [EpisodeRow] {
        var numbered: [(item: MediaItem, number: Int)] = []
        var missing: [MediaItem] = []

        for item in items {
            if let number = item.episodeNumber, number > 0 {
                numbered.append((item, number))
            } else {
                missing.append(item)
            }
        }
        numbered.sort { $0.number < $1.number }

        // 服务器有时漏掉某一集的集号（这一季就丢了第 6 集）。
        // 用这段里没被占用的最小号码补上，别和前面的撞成两个 E01。
        if !missing.isEmpty {
            var used = Set(numbered.map(\.number))
            let upper = max(numbered.last?.number ?? 0, items.count)
            var candidate = 1
            for item in missing {
                while used.contains(candidate) && candidate <= upper { candidate += 1 }
                numbered.append((item, candidate))
                used.insert(candidate)
                candidate += 1
            }
        }

        return numbered
            .sorted { $0.number < $1.number }
            .map { EpisodeRow(item: $0.item, number: $0.number) }
    }
}

// MARK: - 选集卡

private struct EpisodeCard: View {
    let episode: EpisodeRow
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    PosterImage(path: episode.item.posterPath ?? episode.item.backdropPath,
                                title: episode.item.title)

                    if hovering {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.white.opacity(0.95))
                    }
                }
                .frame(width: 296, height: 166)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if episode.item.progress > 0.01 && episode.item.progress < 0.995 {
                        ProgressBar(value: episode.item.progress, height: 3)
                    }
                }

                HStack(spacing: 7) {
                    Text(episode.badge)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("·")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.faint)
                    Text(episode.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.top, 9)
                .padding(.leading, 2)
            }
            .frame(width: 296, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 演职人员卡

private struct CastCard: View {
    let person: Person
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                PosterImage(path: person.imagePath, title: person.name)
                    .frame(width: 96, height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(hovering ? Color.white.opacity(0.22) : .clear, lineWidth: 1)
                    )

                Text(person.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 8)

                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 3)
                }

                if let job = person.job, !job.isEmpty, job != person.role {
                    Text(job)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .padding(.top, 3)
                }
            }
            .frame(width: 96, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 媒体信息卡

private struct TrackCard: Identifiable {
    let id: String
    let icon: String
    let title: String
    let rows: [(String, String)]
    let active: Bool
}

private struct MediaInfoCard: View {
    let card: TrackCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: card.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)

                Text(card.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                if card.active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }

                Spacer(minLength: 0)
            }
            .padding(.bottom, 4)

            ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                if !row.1.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.0)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 62, alignment: .leading)

                        Text(row.1)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 7)
                }
            }
        }
        .padding(16)
        .frame(width: 326, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    }
}

// MARK: - 演职人员作品

private struct PersonWorks {
    let id: String
    let name: String
    let role: String?
    let items: [MediaItem]
}

private struct PersonWorksPanel: View {
    let works: PersonWorks
    let onBack: () -> Void
    let onOpen: (String) -> Void

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16, alignment: .top)]
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            PageScroll {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 32, height: 32)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)

                        PageTitle(text: works.name, size: 21)

                        if let role = works.role, !role.isEmpty {
                            Caption(text: role, size: 12.5)
                        }

                        Spacer()

                        Caption(text: "\(works.items.count) 部作品", size: 12)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 40)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(works.items) { item in
                            PosterCard(item: item, width: 168) {
                                onOpen(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 22)
                    .padding(.bottom, 40)
                }
            }
        }
    }
}
