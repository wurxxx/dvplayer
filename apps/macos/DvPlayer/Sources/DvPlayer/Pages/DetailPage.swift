import SwiftUI
import AppKit
import DvCore

/// 详情页「资源」里的一张卡：源名 + 分辨率 + 进度；当前源描边、最佳来源标「推荐」。
private struct SourceCard: View {
    let source: ItemSource
    let current: Bool
    let best: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(source.sourceName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    if current {
                        tag("当前", color: Theme.accent)
                    } else if best {
                        tag("推荐", color: Theme.muted)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    if let resolution = source.resolution, !resolution.isEmpty {
                        Text(resolution)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 5))
                    }

                    Text(source.progress > 0.01
                         ? "看过 \(Int(source.progress * 100))%"
                         : "未看")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(current ? Theme.accent : Theme.line.opacity(0.6),
                            lineWidth: current ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

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

    @EnvironmentObject private var state: AppState

    @State private var detail: MediaDetail?
    @State private var seasons: [MediaItem] = []
    @State private var seasonId: String?
    @State private var episodes: [EpisodeRow] = []
    @State private var people: [Person] = []
    @State private var mediaInfo: MediaInfo?
    /// 当前播放目标的续播位置（秒）。和 Windows 一样靠它决定
    /// 「重头看」要不要出现、播放键上要不要带「上次看到 01:23」。
    @State private var resumeSeconds: Int = 0
    /// 当前播放源自己的续播位置与片长；跨源合并时以它为基准。
    @State private var ownResumeSeconds: Int = 0
    @State private var resumeDuration: Int = 0
    /// 合并后要覆盖的起播位置：nil = 用源自己的，0 = 别的源已看完（从头播）。
    @State private var mergedStart: Int?
    /// Trakt 上记的播放进度（0–1）；电影换设备 / 换源时用来补续播点。
    @State private var traktProgress: Double?
    /// 其它源「同一集」的最大进度（0–1）。剧集在「资源」里只有整剧进度，
    /// 要按季 + 集号找到同一集再比。
    @State private var crossEpisodeProgress: Double?
    /// 同一部片在各源的条目（详情页「资源」）。
    @State private var sources: [ItemSource] = []
    @State private var loading = true
    @State private var busy = false
    @State private var showingAudio = false
    @State private var showingSubtitle = false
    @State private var showingTrakt = false
    /// 选了音轨 / 字幕之后戳一下，让按钮上的文字跟着变。
    @State private var trackRevision = 0

    /// 点演职人员后浮出来的作品页。
    @State private var works: PersonWorks?
    /// 从作品页再点进另一部片的详情（详情页套详情页）。
    @State private var nestedItemId: String?

    var body: some View {
        ZStack {
            if let nestedItemId {
                DetailPage(itemId: nestedItemId,
                           onBack: { self.nestedItemId = nil })
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

    // MARK: - 背景

    /// 详情页背景：**一张图**，顶部清晰、往下逐渐模糊。
    ///
    /// 关键是两层用同一份几何：清晰图和模糊图都按同一块区域做 aspect-fill，
    /// 像素位置完全一致，mask 交叉淡化时不会有任何错位。
    /// 以前是「460pt 的清晰图 + 整页的模糊图」，同一张图被裁成两个不同
    /// 比例，交界线上下根本不是同一块画面 —— 渐变怎么调都能看出接缝。
    ///
    /// `height` 由调用方给（视口高度）：这张图是**滚动内容的一部分**，
    /// 跟着页面上移，滚过去之后就露出页面底色。
    private func backdrop(height: CGFloat) -> some View {
        GeometryReader { geo in
            if let path = detail?.backdropPath ?? detail?.posterPath {
                ZStack {
                    PosterImage(path: path, title: detail?.title ?? "")
                        .frame(width: geo.size.width, height: height)

                    // 模糊层：同源、同尺寸，只多一点缩放把模糊的发虚边缘推出画面。
                    PosterImage(path: path, title: detail?.title ?? "")
                        .blur(radius: 36, opaque: true)
                        .scaleEffect(1.08)
                        .frame(width: geo.size.width, height: height)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.26),
                                    .init(color: .white.opacity(0.35), location: 0.42),
                                    .init(color: .white.opacity(0.8), location: 0.55),
                                    .init(color: .white, location: 0.68),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
                .frame(width: geo.size.width, height: height, alignment: .top)
                .overlay {
                    // 顶部压一点给返回按钮，中段压一点给白字，整体仍然透亮。
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.30), location: 0),
                            .init(color: Color.black.opacity(0.12), location: 0.18),
                            .init(color: Color.black.opacity(0.30), location: 0.48),
                            .init(color: Color.black.opacity(0.42), location: 0.62),
                            .init(color: Color.black.opacity(0.50), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: height)
                }
                // 底边淡到页面底色：图滚到尽头时不要切出一条硬边。
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: max(height - 120, 0))
                        LinearGradient(colors: [.white, .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 120)
                    }
                )
                .frame(width: geo.size.width, height: height, alignment: .top)
                .clipped()
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    // MARK: - 主体

    private var content: some View {
        GeometryReader { screen in
            ZStack(alignment: .top) {
                // 图滚过去之后露出来的底色。
                Theme.bg

                PageScroll {
                    // 背景和正文放进同一个滚动内容里：滚动时图跟着上移。
                    ZStack(alignment: .top) {
                        backdrop(height: screen.size.height)

                        VStack(alignment: .leading, spacing: 0) {
                            header

                            VStack(alignment: .leading, spacing: 30) {
                                if !seasons.isEmpty {
                                    seasonBar
                                }

                                // 季已知但第一页集还没回来：给一行提示，别让中间空一块。
                                if !seasons.isEmpty && episodes.isEmpty {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(Theme.accent)
                                        Text("正在读取选集…")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.faint)
                                    }
                                    .padding(.vertical, 4)
                                }

                                if !episodes.isEmpty {
                                    episodeBlock
                                }

                                // 同一部片在多个源里都有：详情页列出来，点一下切源（详情页的「资源」）。
                                if sources.count > 1 {
                                    sourcesBlock
                                }

                                if !people.isEmpty {
                                    castBlock
                                }

                                linksBlock

                                if let mediaInfo, hasTracks(mediaInfo) {
                                    mediaInfoBlock(mediaInfo)
                                }

                                // 视频存放位置：电影 / 单集给文件路径，剧集 / 季给所在目录。
                                if let location = locationText {
                                    VStack(alignment: .leading, spacing: 11) {
                                        SectionTitle(text: "存储位置")

                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(Theme.faint)
                                                .padding(.top, 2)

                                            Text(location)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(Theme.muted)
                                                .lineLimit(3)
                                                .truncationMode(.middle)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, Theme.contentLeading)
                            .padding(.trailing, 32)
                            .padding(.top, 26)
                            .padding(.bottom, 40)
                        }
                    }
                    .frame(width: screen.size.width, alignment: .topLeading)
                }
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
            .padding(.leading, Theme.sidebarWidth + 24)
            .padding(.top, 20)
        }
        .task(id: itemId) { await load() }
        // 续播集可能在后面的分页里：集数变多就再试一次定位。
        .onChange(of: episodes.count) { _ in autoJumpToResumeIfNeeded() }
        // 自检：`DVPLAYER_PICK_TRACK="subtitle:1"`，等详情读完按卡片点击的同一条路切轨，
        // 验证卡片打勾与顶部按钮联动（合成点击在手动滚动的 ScrollView 里不可靠）。
        .task {
            guard let spec = ProcessInfo.processInfo.environment["DVPLAYER_PICK_TRACK"] else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            let parts = spec.split(separator: ":")
            guard parts.count == 2, let index = Int(parts[1]) else { return }
            if parts[0] == "subtitle" {
                TrackPrefs.setSubtitle(trackKey, index)
            } else {
                TrackPrefs.setAudio(trackKey, index)
            }
            trackRevision += 1
        }
        .overlay {
            if loading && detail == nil {
                ProgressView().controlSize(.large)
            }
        }
    }

    // MARK: - 顶部信息

    /// 顶部只放文字和按钮：大图完全交给 `backdrop`。
    ///
    /// 以前 header 自己也画一张清晰图，和背景那张模糊图铺在两个不同
    /// 尺寸的框里，交界处必然错位。现在图只有一份，header 是纯浮层。
    private var header: some View {
        GeometryReader { geo in
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
            .padding(.leading, Theme.contentLeading)
            .padding(.trailing, 32)
            .padding(.bottom, 26)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .frame(height: 460)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                guard let detail else { return }
                play(playTargetId ?? detail.id,
                     startSeconds: mergedStart.map(Double.init))
            } label: {
                // 看过但没看完：剧集带上正在看的那一集，再加上次看到哪，
                // 对齐 Windows 的 `播放 第 20 集 01:53`（SeriesPage.UpdatePlayButton）。
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("播放")
                    if let episode = resumeEpisode {
                        Text("第 \(episode.number) 集")
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                    if resumeSeconds >= 5 {
                        Text(MediaText.duration(Double(resumeSeconds)))
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .help(resumeSeconds >= 5
                  ? "从 \(MediaText.duration(Double(resumeSeconds))) 继续播放"
                  : "播放")

            // 「重头看」只在看过之后才有意义（Windows 同样按
            // playSource 的续播位置 >= 5 秒判断）。没看过的片子
            // 这个按钮点了等于「播放」，纯属噪音。
            if resumeSeconds >= 5 {
                Button {
                    guard let detail else { return }
                    play(playTargetId ?? detail.id, startSeconds: 0)
                } label: {
                    Text("重头看")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("重头看（上次看到 \(MediaText.duration(Double(resumeSeconds)))）")
            }

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

            if let info = mediaInfo, info.audios.count > 1 {
                Button {
                    showingAudio.toggle()
                } label: {
                    Label(audioLabel, systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SecondaryButtonStyle())
                .popover(isPresented: $showingAudio, arrowEdge: .bottom) {
                    TrackMenuView(title: "选择音轨", choices: audioChoices(info))
                }
            }

            if let info = mediaInfo, !info.subtitles.isEmpty {
                Button {
                    showingSubtitle.toggle()
                } label: {
                    Label(subtitleLabel, systemImage: "captions.bubble")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SecondaryButtonStyle())
                .popover(isPresented: $showingSubtitle, arrowEdge: .bottom) {
                    TrackMenuView(title: "选择字幕", choices: subtitleChoices(info))
                }
            }

            // Trakt 只在包里带了应用凭据时出现：没有凭据的构建不摆一个点了就报错的按钮。
            if TraktSettings.isConfigured {
                Button {
                    showingTrakt.toggle()
                } label: {
                    Label("Trakt", systemImage: "play.tv")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Trakt：评分 / 收藏 / 待看")
                .popover(isPresented: $showingTrakt, arrowEdge: .bottom) {
                    TraktPanel(title: MediaText.clean(detail?.title),
                               year: detailYear,
                               series: detailIsSeries,
                               tmdbId: detail?.tmdbId,
                               imdbId: detail?.imdbId)
                        .environmentObject(state)
                }
            }

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
            SectionTitle(text: "选集",
                         trailing: "\(episodeTotal > 0 ? episodeTotal : episodes.count) 集")

            // 集数多时给一排「1-30 / 31-60 …」：点一下滚到那一段。
            if episodeTotal > episodeRangeSize {
                episodeRangeChips
            }

            HorizontalRow(items: episodes, itemWidth: 314, spacing: 18,
                          jumpID: jumpEpisodeID, jumpToken: jumpToken) { row in
                EpisodeCard(episode: row, active: row.id == resumeEpisode?.id) {
                    play(row.id, startSeconds: nil)
                }
            }
        }
    }

    // MARK: - 快捷选集

    private var episodeRanges: [(from: Int, to: Int)] {
        guard episodeTotal > episodeRangeSize else { return [] }
        return stride(from: 1, through: episodeTotal, by: episodeRangeSize).map {
            ($0, min($0 + episodeRangeSize - 1, episodeTotal))
        }
    }

    /// 看到一半的那一集（进度 1%..99.5%）：详情页的「续播集」。
    /// 一集看完（≥99.5%）不算，下一集没开始时不会误高亮。
    private var resumeEpisode: EpisodeRow? {
        episodes.first { $0.item.progress > 0.01 && $0.item.progress < 0.995 }
    }

    /// 高亮哪一段：点过的优先，否则跟着续播点所在的那段。
    private var activeRangeStart: Int {
        if selectedRangeStart > 0 { return rangeStart(selectedRangeStart) }
        return rangeStart(resumeEpisode?.number ?? 1)
    }

    private func rangeStart(_ number: Int) -> Int {
        max(1, (max(number, 1) - 1) / episodeRangeSize * episodeRangeSize + 1)
    }

    /// 段按钮铺成自动换行的多行：一行放不下时能点回前面那几段
    /// （横向滚动的行没有箭头，滚不过去就再也点不回来）。
    private var episodeRangeChips: some View {
        FlowChips(items: episodeRanges.map { ("\($0.from)", "\($0.from)-\($0.to)") },
                  active: "\(activeRangeStart)") { id in
            guard let from = Int(id) else { return }
            let to = min(from + episodeRangeSize - 1, max(episodeTotal, from))
            jump(toRange: from, to: to)
        }
    }

    /// 点某一段：先把这一段拉出来，再让选集行滚到这段的第 1 集。
    private func jump(toRange from: Int, to: Int) {
        selectedRangeStart = from
        let need = min(to, episodeTotal)

        Task {
            if episodes.count < need {
                await ensureEpisodes(through: need)
            }

            // 等一帧让新卡片进视图，ScrollViewReader 才找得到目标 id。
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let target = episodes.first(where: { $0.number >= from }) else { return }
            NSLog("[Detail] range jump %d-%d -> E%d", from, to, target.number)
            jumpEpisodeID = target.id
            jumpToken += 1
        }
    }

    /// 跳段：等后台补页让开，缺的从当前页往后拉到至少 need 集。
    private func ensureEpisodes(through need: Int) async {
        guard state.core != nil, let season = seasonId else { return }

        var waited = 0
        while filling && waited < 150 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        if episodes.count >= need || filling {
            return
        }

        filling = true
        await fetchEpisodes(season: season, through: need, from: nil)
        filling = false
    }

    // MARK: - 资源（同一部片的多个来源）

    private var sourcesBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "资源", trailing: "\(sources.count) 个来源")

            HorizontalRow(items: sources, itemWidth: 250, spacing: 14) { source in
                SourceCard(source: source,
                           current: source.itemId == itemId,
                           best: source.id == sources.first?.id) {
                    // 当前正在看的那张不做任何事，免得白刷一次详情。
                    guard source.itemId != itemId else { return }
                    state.openDetail(source.itemId)
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

            HStack(spacing: 8) {
                linkButton("豆瓣", action: openDouban)
                // Emby / Jellyfin 刮削时记下的 id 才显示，飞牛这类没有就不摆。
                if let url = tmdbURL {
                    linkButton("TMDB", url: url)
                }
                if let url = imdbURL {
                    linkButton("IMDb", url: url)
                }
            }
        }
    }

    private func linkButton(_ label: String, url: URL? = nil,
                            action: (() -> Void)? = nil) -> some View {
        Button {
            if let url {
                NSWorkspace.shared.open(url)
            } else {
                action?()
            }
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
            // 和次级按钮一致：半透明，详情页的模糊背景能透上来。
            .background(Theme.surface.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var tmdbURL: URL? {
        guard let id = detail?.tmdbId, !id.isEmpty else { return nil }
        return URL(string: "https://www.themoviedb.org/\(detailIsSeries ? "tv" : "movie")/\(id)")
    }

    private var imdbURL: URL? {
        guard let id = detail?.imdbId, !id.isEmpty else { return nil }
        return URL(string: "https://www.imdb.com/title/\(id)/")
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
        info.video != nil || !info.audios.isEmpty || !info.subtitles.isEmpty
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
                                   active: effectiveAudioIndex(info) == index,
                                   onPick: {
                                       TrackPrefs.setAudio(trackKey, index)
                                       trackRevision += 1
                                   }))
        }

        for (index, subtitle) in info.subtitles.enumerated() {
            var rows: [(String, String)] = []
            rows.append(("语言", subtitle.language ?? "--"))
            rows.append(("标题", subtitle.title ?? ""))
            rows.append(("编码", subtitle.codec ?? ""))
            rows.append(("格式", subtitle.format ?? ""))
            rows.append(("图形字幕", subtitle.isBitmap == true ? "是" : "否"))
            rows.append(("外部", subtitle.isExternal == true ? "是" : "否"))
            rows.append(("默认", (subtitle.isDefault ?? false) ? "是" : "否"))

            cards.append(TrackCard(id: "subtitle-\(index)",
                                   icon: "captions.bubble",
                                   title: subtitleName(subtitle, ordinal: index + 1),
                                   rows: rows,
                                   active: effectiveSubtitleIndex(info) == index,
                                   onPick: {
                                       TrackPrefs.setSubtitle(trackKey, index)
                                       trackRevision += 1
                                   }))
        }

        return cards
    }

    // MARK: - 派生文案

    private var playTargetId: String? {
        // 详情里的 playItemId 是「整部剧下一条要看的」；本地源跨季时会指到别的季。
        // 已经选中某一季（episodes 是当前季的行）就以这季为准：
        // 先找看到一半的集，再退回第一集。
        if let resumable = episodes.first(where: {
            $0.item.progress > 0.01 && $0.item.progress < 0.995
        }) {
            return resumable.id
        }

        if let first = episodes.first {
            return first.id
        }

        return detail?.playItemId ?? (detail != nil ? itemId : nil)
    }

    /// 当前季的季号：选集面板里补成 `S01E03` 这种。
    private var currentSeasonNumber: Int? {
        let number = seasons.first { $0.id == seasonId }?.seasonNumber
        return (number ?? 0) > 0 ? number : nil
    }

    /// 起播。选集用当前季这行集，和 Windows 的 `BuildPlaylist()` 一致。
    private func play(_ target: String, startSeconds: Double?) {
        let list = episodes.map { row in
            PlayerEpisode(item: row.item, number: row.number, season: currentSeasonNumber)
        }

        PlayerLauncher.shared.play(
            itemId: target,
            startSeconds: startSeconds,
            playlist: list,
            seriesTitle: detail.map { MediaText.clean($0.title) },
            seriesYear: detailYear,
            seriesTmdbId: detail?.tmdbId,
            seriesImdbId: detail?.imdbId,
            hintTitle: detail.map { MediaText.clean($0.title) })
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

    /// 视频存放位置：电影 / 单集给文件路径，剧集 / 季给所在目录。
    private var locationText: String? {
        guard let raw = mediaInfo?.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let kind = (detail?.kind ?? "").lowercased()
        if ["movie", "video", "episode"].contains(kind) {
            return raw
        }

        let directory = (raw as NSString).deletingLastPathComponent
        return directory.isEmpty || directory == raw ? raw : directory
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

    // MARK: - 音轨 / 字幕

    private var trackKey: String { playTargetId ?? itemId }

    /// 没选过就用服务器给的默认轨。
    private func effectiveAudioIndex(_ info: MediaInfo) -> Int {
        if let saved = TrackPrefs.audio(trackKey), info.audios.indices.contains(saved) {
            return saved
        }
        return max(0, info.audios.firstIndex(where: { $0.isDefault == true }) ?? 0)
    }

    /// 没选过就先挑简体中文、再任意中文，其次服务器默认轨；都没有就当关闭。
    private func effectiveSubtitleIndex(_ info: MediaInfo) -> Int {
        if let saved = TrackPrefs.subtitle(trackKey) { return saved }

        let simplified = info.subtitles.firstIndex(where: {
            TrackPrefs.isSimplified($0.language, $0.title)
        })

        let chinese = info.subtitles.firstIndex(where: {
            TrackPrefs.isChinese($0.language, $0.title)
        })

        if let index = simplified ?? chinese {
            return index
        }

        return info.subtitles.firstIndex(where: { $0.isDefault == true }) ?? TrackPrefs.subtitleOff
    }

    /// 字幕按钮 / 卡片里的名字：`语言 · 标题`，别露出容器标签。
    private func subtitleName(_ subtitle: SubtitleInfo, ordinal: Int = 0) -> String {
        TrackPrefs.subtitleLabel(language: subtitle.language,
                                 title: subtitle.title,
                                 ordinal: ordinal)
    }

    private var audioLabel: String {
        _ = trackRevision
        guard let info = mediaInfo, info.audios.count > 1 else { return "音轨" }
        let index = effectiveAudioIndex(info)
        guard info.audios.indices.contains(index) else { return "音轨" }
        let audio = info.audios[index]
        return "音轨：" + (audio.language ?? audio.title ?? audio.codec ?? "默认")
    }

    private var subtitleLabel: String {
        _ = trackRevision
        guard let info = mediaInfo, !info.subtitles.isEmpty else { return "字幕" }
        let index = effectiveSubtitleIndex(info)
        if index == TrackPrefs.subtitleOff { return "字幕：关" }
        guard info.subtitles.indices.contains(index) else { return "字幕" }
        return "字幕：" + subtitleName(info.subtitles[index])
    }

    private func audioChoices(_ info: MediaInfo) -> [TrackChoice] {
        let current = effectiveAudioIndex(info)
        return info.audios.enumerated().map { index, audio in
            var parts: [String] = []
            if let language = audio.language, !language.isEmpty { parts.append(language) }
            if let codec = audio.codec, !codec.isEmpty { parts.append(codec) }
            if let profile = audio.profile, !profile.isEmpty { parts.append(profile) }
            if let layout = audio.layout, !layout.isEmpty { parts.append(layout) }
            if let channels = audio.channels, channels > 0 { parts.append("\(channels) 声道") }
            if let rate = audio.sampleRate, rate > 0 { parts.append("\(rate) Hz") }
            if let bitRate = MediaText.bitRate(audio.bitRate) { parts.append(bitRate) }

            return TrackChoice(id: index,
                               label: audio.title ?? audio.language ?? audio.codec ?? "音轨 \(index + 1)",
                               detail: parts.joined(separator: " · "),
                               selected: index == current) {
                TrackPrefs.setAudio(trackKey, index)
                trackRevision += 1
                showingAudio = false
            }
        }
    }

    private func subtitleChoices(_ info: MediaInfo) -> [TrackChoice] {
        let current = effectiveSubtitleIndex(info)

        var choices: [TrackChoice] = [
            TrackChoice(id: TrackPrefs.subtitleOff,
                        label: "关闭字幕",
                        detail: "",
                        selected: current == TrackPrefs.subtitleOff) {
                TrackPrefs.setSubtitle(trackKey, TrackPrefs.subtitleOff)
                trackRevision += 1
                showingSubtitle = false
            },
        ]

        // 「语言 · 标题」，编码 / 容器标签不进菜单；重名的追加序号。
        let labels = TrackPrefs.subtitleLabels(info.subtitles.map { subtitle in
            (language: subtitle.language, title: subtitle.title)
        })

        choices.append(contentsOf: info.subtitles.enumerated().map { index, subtitle in
            // 编码 / 格式属性属于媒体信息卡，菜单里只保留「图形 / 外挂」提示。
            var parts: [String] = []
            if subtitle.isBitmap == true { parts.append("图形") }
            if subtitle.isExternal == true { parts.append("外挂") }

            return TrackChoice(id: index,
                               label: labels[index],
                               detail: parts.joined(separator: " · "),
                               selected: index == current) {
                TrackPrefs.setSubtitle(trackKey, index)
                trackRevision += 1
                showingSubtitle = false
            }
        })

        return choices
    }

    // MARK: - 数据

    /// 详情页条目的年份：Trakt 搜索用来避免重拍版挂错。
    private var detailYear: Int? {
        guard let date = detail?.releaseDate, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private var detailIsSeries: Bool {
        guard let kind = detail?.kind.lowercased() else { return false }
        return ["series", "tv", "season", "episode"].contains(kind)
    }

    private func toggleFavorite() {
        guard let core = state.core, let detail else { return }
        let target = !(detail.isFavorite ?? false)
        busy = true
        Task {
            do {
                try await core.setFavorite(itemId, favorite: target)
                self.detail = try? await core.detail(itemId)
                DetailCache.shared.drop(itemId)
                await state.refreshFavorites()
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
                DetailCache.shared.drop(itemId)
                await state.refreshRecords()
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

    /// 选集分页：飞牛 `/item/list` 的耗时基本随 `page_size` 线性涨，
    /// 一次要 300 集得等 1.7s。先拿一页把首屏铺出来，剩下的后台补。
    private let episodePageSize = 80

    /// 当前季服务器说的总集数（首屏可能只有一页）。
    @State private var episodeTotal = 0

    /// 快捷选集：一段多少集（「1-30」「31-60」），以及当前高亮段的起点。
    private let episodeRangeSize = 30
    @State private var selectedRangeStart = 0

    /// 让 HorizontalRow 滚到某一集：换 token 触发，id 是目标卡。
    @State private var jumpEpisodeID: String?
    @State private var jumpToken = 0

    /// 后台补页正在跑：跳段时先等它，别两边各拉一遍同一页。
    @State private var filling = false

    /// 补页期间又来了新的请求（切季 / 跳段）：等这一趟结束再跑。
    @State private var fillPending: (season: String, page: Int)?

    /// 截图巡检：DVPLAYER_RANGE=31 就自动点一次这一段。
    @State private var rangeShotDone = false

    /// 进来后已经自动滚到续播集：只做一次，别把用户手动滚的位置拽回去。
    @State private var didAutoJumpResume = false

    private func load() async {
        guard let core = state.core else {
            loading = false
            return
        }

        // 同一部片两分钟内回来，直接用上次的结果，不再等 /item/list。
        if let cached = DetailCache.shared.get(itemId) {
            detail = cached.detail
            people = cached.people
            seasons = cached.seasons
            seasonId = cached.seasonId
            episodes = cached.episodes
            episodeTotal = cached.total
            loading = false

            // 上次可能只补到一半（用户提前离开），接着往下补。
            let next = max(2, cached.episodes.count / episodePageSize + 1)
            if let season = cached.seasonId, cached.episodes.count < cached.total {
                Task { await fillEpisodes(season, from: next) }
            }

            Task { await loadMediaInfo() }
            Task { await loadSources() }
            Task { await loadTraktProgress() }
            Task { await loadCrossSourceEpisodeProgress() }
            autoJumpToResumeIfNeeded()
            autoRangeShotIfNeeded()
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

        // 「资源」要跨源再搜一遍，慢一点，别挡首屏。
        Task { await loadSources() }
        Task { await loadTraktProgress() }

        guard let kind = detail?.kind.lowercased(),
              ["series", "tv", "season", "folder"].contains(kind) else {
            await loadMediaInfo()
            await loadCrossSourceEpisodeProgress()
            saveCache()
            return
        }

        let flat = try? await core.children(itemId, pageSize: episodePageSize)
        let children = flat?.items ?? []
        if children.first?.isSeason == true {
            seasons = children.sorted { ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }
            let first = seasons.first
            seasonId = first?.id
            if let first {
                await loadFirstEpisodes(first.id)
            }
        } else {
            episodes = makeRows(children)
            episodeTotal = max(flat?.total ?? 0, episodes.count)

            // 无季的长剧（目录里直接几百集）：第一页之后继续后台补，
            // 以前只显示前 100 集，total 再大也翻不到。
            if episodes.count < episodeTotal {
                seasonId = itemId
                Task { await fillEpisodes(itemId, from: 2) }
            }
        }

        await loadMediaInfo()
        await loadCrossSourceEpisodeProgress()
        saveCache()
        autoJumpToResumeIfNeeded()
        autoRangeShotIfNeeded()
    }

    /// 第一页集先渲染，`total` 还有剩就后台补（不挡首屏）。
    private func loadFirstEpisodes(_ season: String) async {
        guard let core = state.core else { return }

        let paged = try? await core.children(season, page: 1, pageSize: episodePageSize)
        episodes = makeRows(paged?.items ?? [])
        episodeTotal = paged?.total ?? episodes.count

        if episodes.count < episodeTotal {
            Task { await fillEpisodes(season, from: 2) }
        }
    }

    /// 后台按页把剩下的集补进来；中途切了季就停。
    /// 同时只跑一趟：又有新请求时先记下，等这趟结束再跑。
    private func fillEpisodes(_ season: String, from page: Int) async {
        guard state.core != nil else { return }

        if filling {
            fillPending = (season, page)
            return
        }

        filling = true
        await fetchEpisodes(season: season, through: nil, from: page)
        filling = false

        if let pending = fillPending {
            fillPending = nil
            await fillEpisodes(pending.season, from: pending.page)
        }
    }

    /// 拉页的公共实现。`through == nil` 表示把剩下的全补完，
    /// 否则补到至少 need 集。`from` 给定时从这一页开始。
    private func fetchEpisodes(season: String, through need: Int?, from start: Int?) async {
        guard let core = state.core else { return }

        var next = start ?? max(2, episodes.count / episodePageSize + 1)
        while seasonId == season {
            if let need, episodes.count >= need {
                return
            }

            guard let paged = try? await core.children(season, page: next,
                                                      pageSize: episodePageSize),
                  !paged.items.isEmpty else { return }
            guard seasonId == season else { return }

            let rows = makeRows(paged.items, used: Set(episodes.map(\.number)))
            episodes.append(contentsOf: rows)
            episodes.sort { $0.number < $1.number }
            episodeTotal = max(episodeTotal, paged.total)
            saveCache()

            if paged.items.count < episodePageSize {
                return
            }

            if let need {
                if episodes.count >= need {
                    return
                }
            } else if episodes.count >= episodeTotal {
                return
            }

            next += 1
        }
    }

    private func loadEpisodes(_ season: String) async {
        seasonId = season
        selectedRangeStart = 0
        didAutoJumpResume = false
        // 上一季还没跑完的补页请求作废（旧 fill 自己会因为 seasonId 变了退出）。
        fillPending = nil
        await loadFirstEpisodes(season)
        await loadMediaInfo()
        await loadCrossSourceEpisodeProgress()
        saveCache()
    }

    /// 一进详情就定位到看到一半的那一集：集卡高亮 + 选集行滚过去。
    /// 首屏只拿一页，续播集可能在后面的分页里，所以集数变多时还会再试。
    private func autoJumpToResumeIfNeeded() {
        guard !didAutoJumpResume, let resume = resumeEpisode else { return }
        didAutoJumpResume = true

        Task {
            // 等一帧让新卡片进视图，桥才找得到目标位置。
            try? await Task.sleep(nanoseconds: 200_000_000)
            NSLog("[Detail] auto jump resume E%d", resume.number)
            jumpEpisodeID = resume.id
            jumpToken += 1
        }
    }

    /// 截图巡检：DVPLAYER_RANGE=31 自动点一次「31-60」，用来截跳段后的画面。
    private func autoRangeShotIfNeeded() {
        guard let raw = ProcessInfo.processInfo.environment["DVPLAYER_RANGE"],
              let from = Int(raw), from > 0, !rangeShotDone else { return }

        rangeShotDone = true
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            let to = min(from + episodeRangeSize - 1, max(episodeTotal, from))
            jump(toRange: from, to: to)
        }
    }

    /// 把当前状态写回缓存；收藏 / 进度这类会主动 drop。
    private func saveCache() {
        guard let detail else { return }
        DetailCache.shared.put(itemId, .init(detail: detail, people: people,
                                            seasons: seasons, seasonId: seasonId,
                                            episodes: episodes, total: episodeTotal,
                                            at: Date()))
    }

    /// 「资源」列表：核心按详情标题跨源找回同一部片，去重规则和搜索一样。
    private func loadSources() async {
        guard let core = state.core else { return }
        sources = (try? await core.itemSources(itemId)) ?? []
        // 「资源」一到就能判断别的源有没有看得更多；剧集要再找同一集。
        // 合并在 loadCrossSourceEpisodeProgress 里统一做一次，免得日志重复。
        await loadCrossSourceEpisodeProgress()
    }

    /// 合并用的片长：播放源 → 当前集 → 详情。飞牛等源经常不给 duration。
    private func mergedDuration() -> Int {
        if resumeDuration > 0 { return resumeDuration }
        if let resume = resumeEpisode, let runtime = resume.item.runtimeSeconds, runtime > 0 {
            return runtime
        }
        return detail?.runtimeSeconds ?? 0
    }

    /// 剧集按「同一集」跨源合并：在别的源里找同季同集号的集，读它的位置。
    private func loadCrossSourceEpisodeProgress() async {
        guard let resume = resumeEpisode, sources.count > 1 else {
            crossEpisodeProgress = nil
            applyMergedResume()
            return
        }

        let season = currentSeasonNumber
        let number = resume.number
        let target = playTargetId
        var best: Double?

        for source in sources
        where source.itemId != itemId && source.itemId != target {
            if let value = await episodeProgress(
                in: source.itemId, season: season, number: number) {
                best = max(best ?? 0, value)
            }
        }

        crossEpisodeProgress = best
        if let best {
            NSLog("[Detail] 跨源同集 E%d 最大进度 %.0f%%", number, best * 100)
        } else {
            NSLog("[Detail] 跨源同集 E%d 没找到", number)
        }
        applyMergedResume()
    }

    /// 另一个源的同一部剧里找同季同集号的那一集，返回它的播放进度（0–1）。
    /// 只认 1%–99.5%：另一源已看完的集不拿来覆盖，免得把这一集从 0 重播。
    private func episodeProgress(in sourceItemId: String, season: Int?,
                                 number: Int) async -> Double? {
        guard let core = state.core else { return nil }

        var episode: MediaItem?
        let first = try? await core.children(sourceItemId, pageSize: 300)
        let kids = first?.items ?? []
        if kids.contains(where: \.isSeason) {
            let seasonItem = kids.first { ($0.seasonNumber ?? 0) == (season ?? 1) }
            if let seasonItem {
                let paged = try? await core.children(seasonItem.id, pageSize: 600)
                let items = paged?.items ?? []
                // 集号优先；未刮削目录里常没有 episodeNumber，按顺序补第 N 集。
                episode = items.first { ($0.episodeNumber ?? 0) == number }
                if episode == nil, number >= 1, number <= items.count {
                    episode = items[number - 1]
                }
            }
        } else {
            episode = kids.first { ($0.episodeNumber ?? 0) == number }
            if episode == nil, number >= 1, number <= kids.count {
                episode = kids[number - 1]
            }
        }

        guard let episode, let play = try? await core.playSource(episode.id) else { return nil }

        // 飞牛等源播放源不给 duration，退到条目的片长。
        let duration = play.durationSeconds > 0
            ? play.durationSeconds
            : (episode.runtimeSeconds ?? 0)
        guard duration > 0 else { return nil }

        let progress = Double(play.positionSeconds) / Double(duration)
        return progress > 0.01 && progress < 0.995 ? progress : nil
    }

    /// Trakt 的 playback：电影在别的设备 / 别的源看过更多时，用它补续播点。
    /// 匹配走 TMDB / IMDb id，没有才按片名 + 年份；拿不到就当作没有。
    private func loadTraktProgress() async {
        guard let detail, detail.kind.lowercased() == "movie" else { return }
        guard await TraktClient.shared.isLoggedIn() else { return }

        let year = detail.releaseDate.flatMap { Int($0.prefix(4)) }
        guard let match = try? await TraktClient.shared.match(
            title: MediaText.clean(detail.title), year: year, series: false,
            tmdbId: detail.tmdbId, imdbId: detail.imdbId) else {
            NSLog("[Trakt] playback 跳过：没匹配到《\(detail.title)》")
            return
        }

        traktProgress = await TraktClient.shared.playbackProgress(
            for: match, season: nil, episode: nil)
        if let traktProgress {
            NSLog("[Trakt] playback \(match.title) \(Int(traktProgress * 100))%")
            applyMergedResume()
        } else {
            NSLog("[Trakt] playback \(match.title) 没有记录")
        }
    }

    /// 同一部片在别的源看过更多时，按进度取较长的那条续播。
    /// 只在片长可用、且另一条明显更大（>1%）时覆盖；≥99.5% 视为看完，从头播。
    /// 换到另一个源播放时片长可能略有出入，这里用当前源的时长换算秒数。
    private func applyMergedResume() {
        let kind = detail?.kind.lowercased() ?? ""
        let isMovie = kind == "movie" || kind == "video"
        let isSeries = kind == "series" || kind == "tv" || kind == "season" || kind == "folder"

        // 飞牛的播放源不给片长（duration=0），退到当前集 / 详情的片长。
        let duration = mergedDuration()
        guard duration > 0 else {
            mergedStart = nil
            resumeSeconds = ownResumeSeconds
            return
        }

        let own = Double(ownResumeSeconds) / Double(duration)
        let best: Double
        if isMovie {
            // 同一部片在其它源 / Trakt 上看得更多。
            best = max(sources.map(\.progress).max() ?? 0, traktProgress ?? 0)
        } else if isSeries {
            // 剧集只能比「同一集」：整剧 progress 是最近一集的比例，直接比会跳错。
            best = crossEpisodeProgress ?? 0
        } else {
            best = 0
        }

        if best >= 0.995 {
            mergedStart = 0
            resumeSeconds = 0
            NSLog("[Detail] 跨源进度 %d%% 已看完，从头播", Int(best * 100))
        } else if best > own + 0.01 {
            let seconds = min(duration, Int((Double(duration) * best).rounded()))
            mergedStart = seconds
            resumeSeconds = seconds
            NSLog("[Detail] 跨源续播合并 %d%% -> %ds（本源 %d%%）",
                  Int(best * 100), seconds, Int(own * 100))
        } else {
            mergedStart = nil
            resumeSeconds = ownResumeSeconds
            if best > 0 || own > 0 {
                let other = isSeries ? "同集" : "其它源"
                NSLog("[Detail] 续播用源自己的 %ds（本源 %d%%，%@ %d%%，差不足 1%%）",
                      ownResumeSeconds, Int(own * 100), other, Int(best * 100))
            }
        }
    }

    private func loadMediaInfo() async {
        guard let core = state.core, let target = playTargetId else { return }

        // 媒体信息（轨道清单）和播放源（续播位置）互不依赖，并发发出去。
        // 续播位置决定「重头看」出不出现：没看过的片子不该有这一项。
        async let infoTask = try? await core.mediaInfo(target)
        async let playTask = try? await core.playSource(target)
        let (info, play) = await (infoTask, playTask)

        mediaInfo = info
        ownResumeSeconds = max(0, play?.positionSeconds ?? 0)
        resumeDuration = max(0, play?.durationSeconds ?? 0)
        applyMergedResume()
        NSLog("[Detail] \(target) resume=\(resumeSeconds) duration=\(resumeDuration) info=\(info != nil)")

        // 截图巡检：直接展开音轨 / 字幕菜单（等界面铺好再弹）。
        if let menu = ProcessInfo.processInfo.environment["DVPLAYER_MENU"] {
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                if menu == "audio" { showingAudio = true }
                if menu == "subtitle" { showingSubtitle = true }
            }
        }
    }

    private func makeRows(_ items: [MediaItem], used: Set<Int> = []) -> [EpisodeRow] {
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
            // `used` 是前面几页已经占掉的集号：分页补集时不能从 1 重新补，
            // 否则第二页会再补出一个 E01。
            var taken = used.union(numbered.map(\.number))
            let upper = max(taken.max() ?? 0, used.count + items.count)
            var candidate = 1
            for item in missing {
                while taken.contains(candidate) && candidate <= upper { candidate += 1 }
                numbered.append((item, candidate))
                taken.insert(candidate)
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
    /// 看到一半的那一集：描边 + 集号用强调色，进详情一眼能找到。
    var active: Bool = false
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
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(active ? Theme.accent : .clear, lineWidth: 2)
                }
                .overlay(alignment: .bottom) {
                    if episode.item.progress > 0.01 && episode.item.progress < 0.995 {
                        // 往里缩 4pt：贴着底边会和强调色描边连成一条，
                        // 分不清「高亮」还是「进度」。
                        ProgressBar(value: episode.item.progress, height: 3,
                                    tint: active ? Color.white.opacity(0.95) : Theme.accent,
                                    track: active ? Color.black.opacity(0.45) : Color.white.opacity(0.18))
                            .clipShape(Capsule())
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                    }
                }

                HStack(spacing: 7) {
                    Text(episode.badge)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(active ? Theme.accent : Theme.text)
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
    /// 音频 / 字幕卡可点：点了就切到这条轨；视频卡没有。
    var onPick: (() -> Void)?
}

private struct MediaInfoCard: View {
    let card: TrackCard

    @State private var hovering = false

    private var clickable: Bool { card.onPick != nil }

    var body: some View {
        Button {
            card.onPick?()
        } label: {
            cardBody
                .padding(16)
                .frame(width: 326, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        }
        .buttonStyle(.plain)
        // 详情页整页是模糊大图，卡片不能再用不透明的 Theme.surface：
        // 那样在画面上就是一块死黑的板子（截图里红框那块）。
        // 半透明 + 背景透出来，才有「卡片浮在画面上」的感觉。
        .background(
            (hovering && clickable ? Theme.surfaceHover : Theme.surface).opacity(0.55),
            in: RoundedRectangle(cornerRadius: Theme.radiusCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var cardBody: some View {
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
                    .padding(.leading, Theme.contentLeading)
                    .padding(.trailing, 32)
                    .padding(.top, 40)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(works.items) { item in
                            PosterCard(item: item, width: 168) {
                                onOpen(item.id)
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
    }
}

// MARK: - 音轨 / 字幕菜单

private struct TrackChoice: Identifiable {
    /// 「关闭字幕」用 `TrackPrefs.subtitleOff`，其余是轨下标。
    let id: Int
    let label: String
    let detail: String
    let selected: Bool
    let pick: () -> Void
}

private struct TrackMenuView: View {
    let title: String
    let choices: [TrackChoice]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 5)

            ForEach(choices) { choice in
                Button(action: choice.pick) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .opacity(choice.selected ? 1 : 0)
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)

                            if !choice.detail.isEmpty {
                                Text(choice.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.faint)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 300, alignment: .leading)
        .background(Theme.surface)
    }
}
