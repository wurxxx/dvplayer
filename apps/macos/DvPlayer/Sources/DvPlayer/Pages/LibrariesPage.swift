import SwiftUI
import DvCore

/// 一个媒体库的首页数据：库本身 + 第一页条目（用来铺横向行和库卡片拼图）。
struct LibrarySection: Identifiable {
    let library: MediaLibrary
    var items: [MediaItem]
    /// 库里条目总数（分页接口给的 total），标题右侧显示，和 Windows 的「数量 ›」一致。
    var total: Int
    var id: String { library.id }
}

/// 库内搜索的一条：展示用聚合条目，点开时用「本源那一条」的 id。
/// 核心搜索按主源去重，主源可能是别的服务器。
struct LibrarySearchHit: Identifiable {
    let item: MediaItem
    let id: String
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
    /// 只用于排序（有横版图 > 有简介 > 评分高），界面上不显示。
    var rating: Double = 0
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
    @State private var searchResults: [LibrarySearchHit] = []
    @State private var searching = false
    /// 截图巡检：`DVPLAYER_HERO_HOVER=1` 强制显示 Hero 左右箭头（平时只在悬停时出现）。
    @State private var heroHovering =
        ProcessInfo.processInfo.environment["DVPLAYER_HERO_HOVER"] == "1"
    @State private var tab: SourceTab = .media
    /// 这份页面状态属于哪个源：切源时要把详情 / 网格 / 页签清掉。
    @State private var loadedSourceId: String?
    /// 上次加载时的连接代号：重连后库数据要重新拉。
    @State private var loadedGeneration = -1
    /// Hero 详情补齐任务：换源 / 重新加载时取消上一个。
    @State private var heroUpgradeTask: Task<Void, Never>?

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
                DetailPage(itemId: detailId, onBack: { self.detailId = nil })
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
        // 库列表是 refresh() 里后到的：核心就绪那一刻它可能还是空的。
        // 只按 core 是否为空重载，会先画出一个空首页，之后 libraries 到了也不再拉。
        .task(id: "\(sourceId)|\(state.core == nil)|\(state.libraries.count)") { await load() }
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
                    .padding(.leading, Theme.sidebarWidth)
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

    /// 首页还没内容时解释一下：连接中 / 这个源离线 / 读库失败 / 没有源。
    /// 不能只看 `core == nil`：多个源里只有一个离线时，core 仍然非空，
    /// 点那个离线源会得到一个「空 Hero + 空块」的页面。
    private var emptyHint: (text: String, spinner: Bool)? {
        let connection = state.connections.first { $0.id == sourceId }

        if state.pendingConnections.contains(sourceId) {
            return ("正在连接媒体源…", true)
        }

        if state.core == nil {
            if state.connecting {
                return ("正在连接媒体源…", true)
            }
            if !state.hasSources {
                return ("还没有媒体源，去「服务器」添加一个。", false)
            }
            if let error = state.coreError {
                return (error, false)
            }
            return ("媒体源没有连上，去「服务器」检查一下。", false)
        }

        if connection == nil {
            return ("这个源已经不在服务器列表里了。", false)
        }

        if connection?.ok == false {
            return ("这个源没有连上，去「服务器」检查地址或账号。", false)
        }

        if let error = state.coreError {
            return (error, false)
        }

        return nil
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
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.top, 26)
                .padding(.bottom, 48)
            }
        }
        .overlay(alignment: .center) {
            if loading && sections.isEmpty {
                ProgressView().controlSize(.large)
            } else if sections.isEmpty, let hint = emptyHint {
                VStack(spacing: 10) {
                    if hint.spinner {
                        ProgressView().controlSize(.small)
                    }
                    Caption(text: hint.text, size: 13)
                }
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
                    ForEach(searchResults) { hit in
                        PosterCard(item: hit.item, width: cardWidth) {
                            open(hit.item, id: hit.id)
                        }
                    }
                }
            }
            .padding(.leading, Theme.contentLeading)
            .padding(.trailing, 32)
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
            .padding(.leading, Theme.contentLeading)
            .padding(.trailing, 32)
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
                    // 有横版图就铺横版图；没有就拿竖版海报顶上。
                    // 以前这里对海报放大 1.15 倍再模糊 22，出来是一张糊图 ——
                    // 和 Windows 一样直接铺，让「糊」这条路彻底消失。
                    PosterImage(path: item.backdrop ?? item.poster, title: item.title)

                    // 画面一直铺到窗口最左边，侧栏是浮在上面的毛玻璃：
                    // 这里不要再压黑，否则侧栏背后是「被压暗的画面」，
                    // 毛玻璃取不到真实颜色，看着就不跟着画面变了。

                    LinearGradient(
                        stops: [
                            .init(color: Theme.bg.opacity(0), location: 0.45),
                            .init(color: Theme.bg.opacity(0.55), location: 0.68),
                            .init(color: Theme.bg.opacity(0.9), location: 0.84),
                            .init(color: Theme.bg, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )

                    // 文字 / 圆点 / 箭头要居中在「侧栏右侧的可见区域」，
                    // 而不是整窗居中：侧栏是浮层，盖住左边 216pt。
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
                    .padding(.leading, Theme.sidebarWidth)
                    .padding(.bottom, 74)

                    if heroes.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(heroes.indices, id: \.self) { index in
                                Circle()
                                    .fill(Color.white.opacity(index == heroIndex ? 0.9 : 0.35))
                                    .frame(width: 6, height: 6)
                                    .onTapGesture { heroIndex = index }
                            }
                        }
                        .padding(.leading, Theme.sidebarWidth)
                        .padding(.bottom, 22)
                    }

                    if heroHovering && heroes.count > 1 {
                        // 箭头要垂直居中在 Hero 上，而不是跟着 ZStack 的 .bottom 贴到底部。
                        HStack {
                            heroArrow("chevron.left") { stepHero(-1) }
                            Spacer()
                            heroArrow("chevron.right") { stepHero(1) }
                        }
                        .padding(.leading, Theme.sidebarWidth + 28)
                        .padding(.trailing, 28)
                        .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            // 整块 Hero 都能点进详情（以前手势只绑在文字块上，
            // 点画面空白处没反应）。里面的箭头是 Button、圆点有自己的
            // onTapGesture，子视图的手势优先，不会被这层吃掉。
            .onTapGesture { openHero() }
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
                    // 和 Windows 一样只用有海报的前三张：不过滤的话，
                    // 缺海报的那一格会画成一块渐变占位，拼图看起来是断的。
                    LibraryCard(library: section.library,
                                arts: section.items.prefix(3)
                                    .compactMap(\.posterPath)
                                    .filter { !$0.isEmpty }
                                    .map { Optional($0) }) {
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
                        PlayerLauncher.shared.play(record: record)
                    }
                }
            }
        }
    }

    private func sectionBlock(_ section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            // 右侧显示库里总数，点它进库内网格（和 Windows 的「57 ›」一样）。
            SectionTitle(text: section.library.title,
                         trailing: "\(section.total)") {
                browseTarget = BrowseTarget(id: section.library.id,
                                            title: MediaText.clean(section.library.title),
                                            isLibrary: true)
            }

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

    private func open(_ item: MediaItem, id: String? = nil) {
        // 和 Windows 的 OnCardClick 一致：卡片点击一律进详情页，
        // 不再按 kind 分叉到库内网格（那个网格入口在区块标题右侧的「N ›」）。
        detailId = id ?? item.id
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16, alignment: .top)]
    }

    private var cardWidth: CGFloat { 168 }

    private func stepHero(_ delta: Int) {
        guard !heroes.isEmpty else { return }
        heroIndex = (heroIndex + delta + heroes.count) % heroes.count
    }

    /// 点 Hero 进当前这一条的详情页。
    private func openHero() {
        guard let item = heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first
        else { return }
        detailId = item.id
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

        let all = (try? await core.search(keyword)) ?? SearchResult()

        // 核心按主源去重，主源可能是别的服务器。本服务器也有这部片时，
        // 要在 `sources` 里找到本服务器那一条，点开才是本源的条目。
        // 以前直接按 item.sourceId 过滤，主源在别处就把本服务器的片也丢掉了。
        searchResults = all.items.compactMap { item in
            if item.sourceId == sourceId {
                return LibrarySearchHit(item: item, id: item.id)
            }

            guard let hit = item.sources.first(where: { $0.sourceId == sourceId }) else {
                return nil
            }

            return LibrarySearchHit(item: item, id: hit.itemId)
        }
    }

    // MARK: - 加载

    private func load() async {
        let id = sourceId
        let generation = state.connectionSerial

        // 换了源或重连过：上一条源的详情 / 网格 / 页签键不能留在这一条上。
        if loadedSourceId != id || loadedGeneration != generation {
            loadedSourceId = id
            loadedGeneration = generation
            detailId = nil
            browseTarget = nil
            tab = .media
            searchText = ""
            searchResults = []
            sections = []
            heroes = []
            heroIndex = 0
            // 上一条源的 Hero 补齐任务不能再往这一条上写。
            heroUpgradeTask?.cancel()
            heroUpgradeTask = nil
        } else if !sections.isEmpty, state.core != nil,
                  sections.count == state.libraries(of: id).count,
                  state.debugDetail == nil, state.debugLibrary == nil {
            // 从详情页返回时视图会重建，`.task` 跟着再跑一遍：
            // 同一个连接、首页已经有数据，直接复用，别整库重拉一遍。
            loading = false
            return
        }

        guard let core = state.core else {
            loading = false
            return
        }

        loading = true
        defer {
            // 被取消说明换源 / 换连接了，新 task 会自己接管 loading 状态。
            if !Task.isCancelled {
                loading = false
            }
        }

        var built: [LibrarySection] = []
        // 首页每行默认按「添加时间」倒序，和点进库里的默认排序一致。
        // 不传排序时各家服务器默认值不一样（飞牛入库倒序、Emby 按名称）。
        let addedQuery = ListQuery(sort: "added", descending: true)
        for library in state.libraries(of: id) {
            let page = try? await core.items(library.id, pageSize: 18, query: addedQuery)
            // 等待期间切了源：这一页是旧源的，不能再铺上来。
            guard !Task.isCancelled else { return }
            built.append(LibrarySection(library: library,
                                        items: page?.items ?? [],
                                        total: page?.total ?? 0))
        }
        guard !Task.isCancelled else { return }
        sections = built

        var pool: [HeroItem] = []
        for section in built {
            for item in section.items where item.backdropPath != nil || item.posterPath != nil {
                pool.append(heroItem(from: item))
                if pool.count >= 8 { break }
            }
            if pool.count >= 8 { break }
        }
        heroes = pool
        heroIndex = 0
        startHeroUpgrade(built, sourceId: id)

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

    private func heroItem(from item: MediaItem) -> HeroItem {
        HeroItem(
            id: item.id,
            title: MediaText.clean(item.title),
            meta: heroMeta(item),
            overview: item.overview,
            chips: [item.resolution].compactMap { $0 }.filter { !$0.isEmpty },
            backdrop: item.backdropPath,
            poster: item.posterPath
        )
    }

    private func heroItem(from detail: MediaDetail) -> HeroItem {
        var meta: [String] = []
        if let rating = detail.rating, rating > 0 {
            meta.append(String(format: "%.1f 分", rating))
        }
        if let date = detail.releaseDate, date.count >= 4 {
            meta.append(String(date.prefix(4)))
        }
        let kind = MediaText.kindLabel(detail.kind)
        if !kind.isEmpty { meta.append(kind) }
        let episodes = (detail.localEpisodeCount ?? 0) > 1
            ? detail.localEpisodeCount
            : detail.episodeCount
        if let episodes, episodes > 1 { meta.append("\(episodes) 集") }

        let chips = [detail.resolution, detail.colorRange, detail.audioType]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return HeroItem(
            id: detail.id,
            title: MediaText.clean(detail.title),
            meta: meta.joined(separator: " · "),
            overview: detail.overview?.replacingOccurrences(
                of: #"\s+"#, with: " ", options: .regularExpression),
            chips: chips,
            backdrop: detail.backdropPath,
            poster: detail.posterPath,
            rating: detail.rating ?? 0
        )
    }

    // MARK: - Hero 补齐

    /// 列表接口给的 `backdrops` 在飞牛上是空的，横版图只有详情接口才有。
    /// 以前 macOS 首页只吃列表数据，于是永远落进「竖版海报放大」的兜底，
    /// 首页横幅是一张糊图。这里照 Windows 的做法：先用列表数据出首屏，
    /// 再在后台拉详情，把横版图 / 简介 / 评分补上去。
    private func startHeroUpgrade(_ built: [LibrarySection], sourceId: String) {
        heroUpgradeTask?.cancel()
        heroUpgradeTask = Task { await upgradeHeroes(built, sourceId: sourceId) }
    }

    private func upgradeHeroes(_ built: [LibrarySection], sourceId: String) async {
        guard let core = state.core else { return }

        // 第一页可能全是未刮削的目录（飞牛整季目录 backdrops 为空），
        // 目录不进候选，和 Windows 的 `kind != folder` 一致。
        let ids = built
            .flatMap { $0.items }
            .filter { !$0.isFolder }
            .map(\.id)
            .reduce(into: [String]()) { unique, id in
                if !unique.contains(id) { unique.append(id) }
            }

        var upgraded: [HeroItem] = []

        // 分批取详情、拿到一批就换一次图：核心调用排在同一条串行队列上，
        // 一次等 6 条要十几秒，期间首屏一直挂着裁切放大的竖版海报。
        // 返回 true 表示这一批已经带回了真正的横版图，不用再找了。
        func collect(_ batchIds: ArraySlice<String>) async -> Bool {
            let details = await withTaskGroup(of: MediaDetail?.self) { group in
                for id in batchIds {
                    group.addTask { try? await core.detail(id) }
                }
                var found: [MediaDetail] = []
                for await detail in group {
                    if let detail { found.append(detail) }
                }
                return found
            }
            guard !Task.isCancelled, loadedSourceId == sourceId else { return false }

            upgraded.append(contentsOf: details
                .filter { !($0.backdropPath ?? "").isEmpty || !($0.posterPath ?? "").isEmpty }
                .map(heroItem(from:)))
            applyHeroUpgrade(upgraded)
            return upgraded.contains(where: { $0.backdrop != nil })
        }

        for batch in stride(from: 0, to: ids.count, by: 3) {
            let slice = ids[batch..<min(batch + 3, ids.count)]
            if await collect(slice) { return }
            guard !Task.isCancelled, loadedSourceId == sourceId else { return }
        }

        // 第一页全是目录（只有竖版海报）：按类型直接查电影 / 剧集，
        // 这类才可能有横版图。查到一批就换图，凑够 4 条就停。
        for section in built {
            for kind in ["movie", "tv"] {
                guard !Task.isCancelled, loadedSourceId == sourceId else { return }
                let query = ListQuery(kinds: [kind], sort: "added", descending: true)
                guard let paged = try? await core.items(section.library.id, page: 1,
                                                        pageSize: 24, query: query),
                      !paged.items.isEmpty else { continue }

                let sampleIds = paged.items.shuffled().map(\.id)
                for batch in stride(from: 0, to: sampleIds.count, by: 3) {
                    let slice = sampleIds[batch..<min(batch + 3, sampleIds.count)]
                    _ = await collect(slice)
                    guard !Task.isCancelled, loadedSourceId == sourceId else { return }
                    if upgraded.filter({ $0.backdrop != nil }).count >= 4 { return }
                }
            }
        }
    }

    /// 把补好详情的条目换成 Hero 候选：有横版图的排前面，同一条目原地换图。
    private func applyHeroUpgrade(_ incoming: [HeroItem]) {
        guard !incoming.isEmpty else { return }

        // 有横版图的排前面：竖版海报裁成横幅会放大、也不好看。
        let sorted = incoming.sorted { lhs, rhs in
            if (lhs.backdrop == nil) != (rhs.backdrop == nil) { return lhs.backdrop != nil }
            if (lhs.overview?.isEmpty ?? true) != (rhs.overview?.isEmpty ?? true) {
                return !(lhs.overview?.isEmpty ?? true)
            }
            return lhs.rating > rhs.rating
        }

        let currentId = heroes.indices.contains(heroIndex) ? heroes[heroIndex].id : heroes.first?.id
        var pool = sorted
        // 原来的候选留在后面当后备，别让圆点只剩一个。
        for hero in heroes where pool.count < 8 {
            if !pool.contains(where: { $0.id == hero.id }) {
                pool.append(hero)
            }
        }

        // 只要手里有真正的横版图，就把「只有竖版海报」的候选全部剔掉。
        // 否则轮播到后备那一条时，横幅是一张被裁切放大的竖图（用户看到的糊图）。
        if pool.contains(where: { $0.backdrop != nil }) {
            pool.removeAll { $0.backdrop == nil }
        }

        heroes = Array(pool.prefix(8))
        if let currentId, let index = heroes.firstIndex(where: { $0.id == currentId }) {
            heroIndex = index
        } else {
            heroIndex = 0
        }
    }
}
