import SwiftUI
import DvCore

/// 一个媒体库的首页数据：库本身 + 第一页条目（用来铺横向行和库卡片拼图）。
struct LibrarySection: Identifiable {
    let library: MediaLibrary
    var items: [MediaItem]
    var id: String { library.id }
}

/// Hero 轮播的一条。
struct HeroItem: Identifiable {
    let id: String
    let title: String
    let meta: String
    let overview: String?
    let chips: [String]
    let backdrop: String?
    let poster: String?
}

/// 页面内要打开的网格：库用 items，季 / 剧 / 目录用 children。
struct BrowseTarget {
    let id: String
    let title: String
    let isLibrary: Bool
}

/// 某个源的首屏：Hero + 我的媒体 + 继续观看 + 每库一行。
/// 点点卡片进详情 / 库网格，都在这个页面里换路由，和 Windows 一样不另开窗口。
struct LibrariesPage: View {
    let sourceId: String

    @EnvironmentObject private var state: AppState

    @State private var sections: [LibrarySection] = []
    @State private var heroes: [HeroItem] = []
    @State private var heroIndex = 0
    @State private var loading = true
    @State private var browseTarget: BrowseTarget?
    @State private var detailId: String?
    @State private var searchText = ""
    @State private var searchResults: [MediaItem] = []
    @State private var searching = false
    @State private var heroHovering = false
    @State private var tab: SourceTab = .media

    private enum SourceTab: String, CaseIterable {
        case media = "媒体"
        case search = "搜索"
        case favorites = "收藏"
    }

    private var sourceName: String {
        state.connections.first { $0.id == sourceId }?.name ?? "媒体库"
    }

    private var continueRecords: [PlayRecord] {
        state.records
            .filter { $0.sourceId == sourceId }
            .filter { $0.durationSeconds <= 0 || Double($0.positionSeconds) < Double($0.durationSeconds) * 0.98 }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        ZStack {
            if let detailId {
                DetailPage(itemId: detailId, onBack: { self.detailId = nil },
                           onPlay: { _ in state.showToast("播放器下一轮接入") })
                    .transition(.opacity)
            } else if let target = browseTarget {
                BrowseView(scopeId: target.id, title: target.title,
                           isLibrary: target.isLibrary,
                           onBack: { self.browseTarget = nil },
                           onOpen: { self.detailId = $0 })
                    .transition(.opacity)
            } else {
                sourceHome
                    .transition(.opacity)
            }
        }
        .task(id: sourceId) { await load() }
        .task(id: heroes.count) { await rotateHero() }
    }

    // MARK: - 首屏

    /// 媒体 / 搜索 / 收藏三个页签，和 Windows 的源首页对齐。
    @ViewBuilder
    private var sourceHome: some View {
        Group {
            switch tab {
            case .media: mediaTab
            case .search: searchTab
            case .favorites: favoritesTab
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if tab == .media {
                    // 页签压在 Hero 上，只用渐变压暗，不做实底。
                    LinearGradient(colors: [Color.black.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 112)
                        .allowsHitTesting(false)
                }

                tabBar
                    .padding(.top, 16)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SourceTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12.5))
                        .foregroundStyle(tab == item ? Theme.text : Color.white.opacity(0.72))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(tab == item ? Color.white.opacity(0.12) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var mediaTab: some View {
        PageScroll {
            LazyVStack(alignment: .leading, spacing: 0) {
                hero
                    .frame(height: 560)

                VStack(alignment: .leading, spacing: 26) {
                    librariesBlock
                    continueBlock
                    ForEach(sections) { section in
                        sectionBlock(section)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .padding(.bottom, 48)
            }
        }
        .overlay(alignment: .center) {
            if loading && sections.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var searchTab: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                // 让出顶部页签。
                SearchField(placeholder: "在当前服务器中查找", text: $searchText, width: 420)
                    .padding(.top, 58)

                HStack(spacing: 8) {
                    if searching {
                        ProgressView().controlSize(.small)
                        Caption(text: "正在搜索…", size: 12)
                    } else if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Caption(text: "输入片名、剧名或关键词", size: 12)
                    } else {
                        Caption(text: searchResults.isEmpty ? "没有找到匹配的内容"
                                                            : "\(searchResults.count) 个结果",
                                size: 12)
                    }
                    Spacer()
                }

                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
                    ForEach(searchResults) { item in
                        PosterCard(item: item, width: cardWidth) { open(item) }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .onChange(of: searchText) { _ in
            Task { await runSearch() }
        }
    }

    private var favoritesTab: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "收藏",
                             trailing: sourceFavorites.isEmpty ? nil : "\(sourceFavorites.count)")
                    .padding(.top, 58)

                if sourceFavorites.isEmpty {
                    EmptyState(icon: "heart", title: "还没有收藏",
                               hint: "在详情页点「加入收藏」就会出现在这里")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
                        ForEach(sourceFavorites) { item in
                            PosterCard(item: item, width: cardWidth) { open(item) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }

    private var sourceFavorites: [MediaItem] {
        state.favorites.filter { $0.sourceId == sourceId }
    }

    private var hero: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let item = heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first {
                    // 没有横版图就拿海报顶上：放大 + 模糊，别让一张竖图怼满整屏。
                    PosterImage(path: item.backdrop ?? item.poster, title: item.title)
                        .blur(radius: item.backdrop == nil ? 22 : 0)
                        .scaleEffect(item.backdrop == nil ? 1.15 : 1)

                    LinearGradient(
                        stops: [
                            .init(color: Theme.bg.opacity(0), location: 0.45),
                            .init(color: Theme.bg.opacity(0.55), location: 0.68),
                            .init(color: Theme.bg.opacity(0.9), location: 0.84),
                            .init(color: Theme.bg, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )

                    VStack(spacing: 10) {
                        Text(item.title)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.98))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)

                        if !item.meta.isEmpty {
                            Text(item.meta)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }

                        if !item.chips.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(item.chips, id: \.self) { chip in
                                    Chip(text: chip, tint: Color.white.opacity(0.2))
                                }
                            }
                        }

                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(maxWidth: 800)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 74)
                    .contentShape(Rectangle())
                    .onTapGesture { detailId = item.id }

                    if heroes.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(heroes.indices, id: \.self) { index in
                                Circle()
                                    .fill(Color.white.opacity(index == heroIndex ? 0.9 : 0.35))
                                    .frame(width: 6, height: 6)
                                    .onTapGesture { heroIndex = index }
                            }
                        }
                        .padding(.bottom, 22)
                    }

                    if heroHovering && heroes.count > 1 {
                        HStack {
                            heroArrow("chevron.left") { stepHero(-1) }
                            Spacer()
                            heroArrow("chevron.right") { stepHero(1) }
                        }
                        .padding(.horizontal, 28)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onHover { heroHovering = $0 }
        }
    }

    private func heroArrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 46, height: 46)
                .background(Color.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var librariesBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "我的媒体",
                         trailing: sections.isEmpty ? nil : "\(sections.count) ›")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420, maximum: 420),
                                         spacing: 16, alignment: .leading)],
                      alignment: .leading, spacing: 16) {
                ForEach(sections) { section in
                    LibraryCard(library: section.library,
                                arts: Array(section.items.prefix(3).map(\.posterPath))) {
                        browseTarget = BrowseTarget(id: section.library.id,
                                                    title: MediaText.clean(section.library.title),
                                                    isLibrary: true)
                    }
                }
            }
        }
    }

    private var continueBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: "继续观看",
                         trailing: continueRecords.isEmpty ? nil : "\(continueRecords.count) ›")

            if continueRecords.isEmpty {
                Caption(text: "还没有看到一半的内容。", size: 12.5)
            } else {
                HorizontalRow(items: continueRecords, itemWidth: 264) { record in
                    ContinueCard(record: record) {
                        state.showToast("播放器下一轮接入")
                    }
                }
            }
        }
    }

    private func sectionBlock(_ section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(text: section.library.title,
                         trailing: section.items.isEmpty ? nil : "更多 ›")

            if section.items.isEmpty {
                Caption(text: "这个库里还没有条目。", size: 12.5)
            } else {
                HorizontalRow(items: section.items, itemWidth: 176) { item in
                    PosterCard(item: item, width: 160) {
                        open(item)
                    }
                }
            }
        }
    }

    // MARK: - 动作

    private func open(_ item: MediaItem) {
        if item.isSeason || item.isSeries || item.isFolder {
            browseTarget = BrowseTarget(id: item.id,
                                        title: MediaText.clean(item.title),
                                        isLibrary: false)
        } else {
            detailId = item.id
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16, alignment: .top)]
    }

    private var cardWidth: CGFloat { 168 }

    private func stepHero(_ delta: Int) {
        guard !heroes.isEmpty else { return }
        heroIndex = (heroIndex + delta + heroes.count) % heroes.count
    }

    private func rotateHero() async {
        guard heroes.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled, !heroes.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                heroIndex = (heroIndex + 1) % heroes.count
            }
        }
    }

    private func runSearch() async {
        guard let core = state.core else { return }
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard keyword.count >= 1 else {
            searchResults = []
            return
        }

        searching = true
        defer { searching = false }

        let all = (try? await core.search(keyword)) ?? []
        searchResults = all.filter { $0.sourceId == sourceId }
    }

    // MARK: - 加载

    private func load() async {
        guard let core = state.core else {
            loading = false
            return
        }

        loading = true
        defer { loading = false }

        var built: [LibrarySection] = []
        for library in state.libraries(of: sourceId) {
            let page = try? await core.items(library.id, pageSize: 18)
            built.append(LibrarySection(library: library, items: page?.items ?? []))
        }
        sections = built

        var pool: [HeroItem] = []
        for section in built {
            for item in section.items where item.backdropPath != nil || item.posterPath != nil {
                pool.append(HeroItem(
                    id: item.id,
                    title: MediaText.clean(item.title),
                    meta: heroMeta(item),
                    overview: item.overview,
                    chips: [item.resolution, item.year.map(String.init)]
                        .compactMap { $0 }.filter { !$0.isEmpty },
                    backdrop: item.backdropPath,
                    poster: item.posterPath
                ))
                if pool.count >= 8 { break }
            }
            if pool.count >= 8 { break }
        }
        heroes = pool
        heroIndex = 0

        // 截图巡检：直接打开某个条目 / 某个库。
        if let detail = state.debugDetail {
            detailId = detail
        } else if let library = state.debugLibrary,
                  let section = built.first(where: { $0.library.id == library }) {
            browseTarget = BrowseTarget(id: section.library.id,
                                        title: MediaText.clean(section.library.title),
                                        isLibrary: true)
        }

        // 截图巡检：`DVPLAYER_TAB=search|favorites` 直接落在某个页签，
        // `DVPLAYER_SEARCH=<关键词>` 预填搜索词。
        let env = ProcessInfo.processInfo.environment
        switch env["DVPLAYER_TAB"] {
        case "search": tab = .search
        case "favorites", "fav": tab = .favorites
        default: break
        }

        if let keyword = env["DVPLAYER_SEARCH"], !keyword.isEmpty {
            searchText = keyword
            await runSearch()
        }
    }

    private func heroMeta(_ item: MediaItem) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append("\(year)") }
        if let count = item.episodeCount ?? item.localEpisodeCount, count > 0 {
            parts.append("\(count) 集")
        } else if let runtime = MediaText.runtime(item.runtimeSeconds) {
            parts.append(runtime)
        }
        if let rating = item.rating, rating > 0 {
            parts.append(String(format: "%.1f 分", rating))
        }
        return parts.joined(separator: " · ")
    }
}
