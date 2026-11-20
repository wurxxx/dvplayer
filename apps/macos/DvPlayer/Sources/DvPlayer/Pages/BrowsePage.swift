import SwiftUI
import DvCore

/// 库 / 季 / 目录的网格视图：类别、排序、风格筛选 + 海报网格。
struct BrowseView: View {
    let scopeId: String
    let title: String
    var isLibrary: Bool = true
    let onBack: () -> Void
    let onOpen: (String) -> Void

    @EnvironmentObject private var state: AppState

    @State private var items: [MediaItem] = []
    @State private var total = 0
    @State private var page = 1
    @State private var loading = false
    @State private var category = "全部"
    @State private var sort = "added"
    @State private var descending = true
    @State private var genres: [Genre] = []
    @State private var genre: String?
    @State private var filter = ""

    private let pageSize = 60

    init(library: MediaLibrary, onBack: @escaping () -> Void,
         onOpen: @escaping (String) -> Void) {
        scopeId = library.id
        title = MediaText.clean(library.title)
        isLibrary = true
        self.onBack = onBack
        self.onOpen = onOpen
    }

    init(scopeId: String, title: String, isLibrary: Bool,
         onBack: @escaping () -> Void, onOpen: @escaping (String) -> Void) {
        self.scopeId = scopeId
        self.title = title
        self.isLibrary = isLibrary
        self.onBack = onBack
        self.onOpen = onOpen
    }

    private var visible: [MediaItem] {
        guard !filter.isEmpty else { return items }
        let keyword = filter.lowercased()
        return items.filter { $0.title.lowercased().contains(keyword) }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 40)

            controls
                .padding(.horizontal, 32)
                .padding(.top, 14)

            PageScroll {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(visible) { item in
                        PosterCard(item: item, width: 168) { onOpen(item.id) }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 20)

                if items.count < total {
                    Button(loading ? "加载中…" : "加载更多") { Task { await load(reset: false) } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(loading)
                        .padding(.bottom, 36)
                }
            }
            .overlay {
                if loading && items.isEmpty {
                    ProgressView().controlSize(.large)
                } else if !loading && items.isEmpty {
                    EmptyState(icon: "rectangle.on.rectangle.slash",
                               title: "没有内容",
                               hint: "换个类别或者清空搜索看看")
                }
            }
        }
        .task(id: reloadKey) { await load(reset: true) }
    }

    private var reloadKey: String {
        "\(scopeId)|\(category)|\(genre ?? "")|\(sort)|\(descending)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 32)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            PageTitle(text: title, size: 21)

            Spacer()

            SearchField(placeholder: "在这个库里查找", text: $filter, width: 240)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(["全部", "剧集", "电影", "风格", "文件夹"], id: \.self) { name in
                        Button {
                            category = name
                            genre = nil
                        } label: {
                            Text(name)
                                .font(.system(size: 12.5))
                                .foregroundStyle(category == name ? Theme.text : Theme.muted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(category == name ? Color.white.opacity(0.09) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))

                Spacer()

                Picker("", selection: $sort) {
                    Text("添加日期").tag("added")
                    Text("名称").tag("name")
                    Text("发行日期").tag("release")
                    Text("评分").tag("rating")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)

                Button {
                    descending.toggle()
                } label: {
                    Image(systemName: descending ? "arrow.down" : "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 28)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if !items.isEmpty {
                    Caption(text: "共 \(total) 条", size: 12)
                }
            }

            if category == "风格" && !genres.isEmpty {
                FlowChips(items: genres.map { ($0.id, $0.title) }, active: genre) { id in
                    genre = (genre == id) ? nil : id
                }
            }
        }
    }

    private var kinds: [String] {
        switch category {
        case "剧集": return ["tv", "series", "folder"]
        case "电影": return ["movie"]
        case "文件夹": return ["folder"]
        default: return []
        }
    }

    private func load(reset: Bool) async {
        guard let core = state.core else { return }

        if reset {
            page = 1
            items = []
        }

        loading = true
        defer { loading = false }

        if category == "风格" && genres.isEmpty {
            genres = (try? await core.genres(scopeId)) ?? []
        }

        let query = ListQuery(kinds: kinds, genre: genre, sort: sort, descending: descending)
        do {
            let result = isLibrary
                ? try await core.items(scopeId, page: page, pageSize: pageSize, query: query)
                : try await core.children(scopeId, page: page, pageSize: pageSize, query: query)

            items = reset ? result.items : items + result.items
            total = result.total
            page += 1
        } catch {
            if reset { items = [] }
            state.showToast("读取失败：\(error.localizedDescription)")
        }
    }
}

/// 一行会自动换行的标签（风格）。
struct FlowChips: View {
    let items: [(id: String, title: String)]
    let active: String?
    let onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.id) { item in
                Button {
                    onTap(item.id)
                } label: {
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(active == item.id ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(active == item.id ? Color(hex: 0x2E2412) : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 最简的自动换行布局：macOS 13 没有自带 Layout，自己算行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
