import Foundation
import SwiftUI
import DvCore

/// 进程级状态：配置、连接、当前页。正式项目会用依赖注入，这里先保持简单。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Page: Hashable {
        case home(String)      // 某个源的首屏（媒体库页）
        case sources
        case records
        case search
        case settings
    }

    @Published var settings = AppSettings.load()
    @Published var page: Page = .sources {
        // 侧栏换页时收起详情，避免「搜索 → 详情 → 点记录」还停在详情上。
        didSet {
            if page != oldValue {
                detailItemId = nil
            }
        }
    }

    /// 从搜索结果 / 记录收藏这类页面打开的详情（nil = 不显示）。
    @Published var detailItemId: String?

    func openDetail(_ itemId: String) {
        detailItemId = itemId
    }
    @Published var connections: [SourceConnection] = []
    /// 还在建连的源。卡片 / 侧栏据此显示「正在连接…」和灰点。
    @Published var pendingConnections: Set<String> = []
    @Published var libraries: [MediaLibrary] = []
    @Published var records: [PlayRecord] = []
    @Published var favorites: [MediaItem] = []
    @Published var connecting = false
    @Published var coreError: String?
    @Published var toast: String?
    /// 待确认的操作；ShellView 负责画那张深色确认卡片。
    @Published var confirm: ConfirmRequest?

    private(set) var core: Core?
    private var toastTask: Task<Void, Never>?

    var coreVersion: String { Core.version }

    var isConnected: Bool { core != nil }

    var hasSources: Bool { !settings.sources.isEmpty }

    func libraries(of sourceId: String) -> [MediaLibrary] {
        libraries.filter { $0.sourceId == sourceId }
    }

    func libraryCount(of sourceId: String) -> Int {
        libraries(of: sourceId).count
    }

    func itemCount(of sourceId: String) -> Int {
        libraries(of: sourceId).count
    }

    func openSource(_ id: String) {
        page = .home(id)
    }

    /// 截图巡检用：直接落在某页 / 某个条目上（`DVPLAYER_PAGE` / `DVPLAYER_DETAIL` / `DVPLAYER_LIBRARY`）。
    var debugDetail: String?
    var debugLibrary: String?

    private var started = false

    /// 启动：有配置就自动连；没有就落在「服务器」页引导添加。
    func start() async {
        guard !started else { return }
        started = true

        guard hasSources else {
            page = .sources
            return
        }

        // 自检：把第一个源拖到最后一个位置，验证排序真的写回设置。
        if ProcessInfo.processInfo.environment["DVPLAYER_REORDER_TEST"] == "1" {
            let before = settings.sources.map(\.name).joined(separator: " | ")
            if settings.sources.count >= 2 {
                moveSource(settings.sources[0].id, to: settings.sources[settings.sources.count - 1].id)
            }
            let after = settings.sources.map(\.name).joined(separator: " | ")
            NSLog("[ReorderTest] before: %@ / after: %@", before, after)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        if settings.autoConnect {
            await connectAll()
        } else if let last = settings.lastSourceId {
            page = .home(last)
        }

        let env = ProcessInfo.processInfo.environment
        debugDetail = env["DVPLAYER_DETAIL"]
        debugLibrary = env["DVPLAYER_LIBRARY"]

        switch env["DVPLAYER_PAGE"] {
        case "home":
            if let last = settings.lastSourceId { page = .home(last) }
        case "records": page = .records
        case "search": page = .search
        case "settings": page = .settings
        case "sources": page = .sources
        default: break
        }

        // 自检：直接从全局详情路由打开（搜索 / 记录页点卡片走的就是这一条）。
        // 放在切页之后——切页会把详情收起来。
        if let detail = debugDetail, !detail.isEmpty {
            detailItemId = detail
        }
    }

    // MARK: - 连接

    /// 连接代号：连点重连 / 启动并发两轮时，只有最后一轮能写状态。
    private var connectGeneration = 0

    /// 给页面用：连接代号变了（重连 / 切源）说明缓存的数据可能过期。
    var connectionSerial: Int { connectGeneration }

    /// 连接任务串行化：并发两轮会各建一个 hub，先建好的那份没人释放。
    private var connectTask: Task<Void, Never>?

    /// 把所有配置好的源接进核心。单个源失败不影响其它源。
    func connectAll() async {
        let previous = connectTask
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            await self.connectAllCore()
        }
        connectTask = task
        await task.value
    }

    private func connectAllCore() async {
        connectGeneration += 1
        let generation = connectGeneration

        guard !settings.sources.isEmpty else {
            connections = []
            core = nil
            coreError = nil
            page = .sources
            return
        }

        connecting = true
        defer {
            // 旧的一轮结束不能把新的一轮标成「已连完」。
            if generation == connectGeneration {
                connecting = false
            }
        }

        core = nil
        guard let hub = Core() else {
            coreError = "无法加载共享核心 dvplayer_media"
            connections = settings.sources.map {
                SourceConnection(id: $0.id, name: $0.name, kind: $0.kind,
                                 ok: false, error: "共享核心未加载")
            }
            return
        }

        // 每个源先以「正在连接」出现在列表里：谁先连完谁先变状态，
        // 不用等最慢的那个（以前是全部完成才一次性写结果）。
        let configs = settings.sources
        pendingConnections = Set(configs.map(\.id))
        connections = configs.map {
            SourceConnection(id: $0.id, name: $0.name, kind: $0.kind,
                             ok: false, error: nil)
        }

        // 文件协议源（SMB / NFS / WebDAV）先让系统挂载，再当本地目录接核心。
        // 挂载和登录都是网络等待：每源一个任务并行做，3 个服务器不用等 3 份时间。
        var prepared: [(config: SourceConfig, effective: SourceConfig?, error: String?)] = []
        await withTaskGroup(of: (SourceConfig, SourceConfig?, String?).self) { group in
            for config in configs {
                group.addTask {
                    do {
                        return (config, try await MountSources.prepare(config), nil)
                    } catch {
                        return (config, nil, error.localizedDescription)
                    }
                }
            }
            for await item in group {
                prepared.append((config: item.0, effective: item.1, error: item.2))
                // 挂载失败也算这个源出结果了，立刻标出来。
                if let error = item.2 {
                    applyConnection(SourceConnection(id: item.0.id, name: item.0.name,
                                                     kind: item.0.kind, ok: false,
                                                     error: error))
                }
            }
        }

        // 并行返回的顺序不定，按用户配置的顺序排回来。
        // 重复 id 时取先出现的那一条（uniqueKeysWithValues 会直接 trap）。
        let order = Dictionary(
            configs.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first })
        prepared.sort { (order[$0.config.id] ?? 0) < (order[$1.config.id] ?? 0) }

        // 挂载期间又点了一次重连：这一轮的结果已经过期，别再往下写。
        guard generation == connectGeneration else { return }

        var connects: [String: SourceConnection] = [:]
        var batchError: String?
        let toConnect = prepared.compactMap { $0.effective }
        if !toConnect.isEmpty {
            do {
                // 每连完一个源就回调一次，卡片和侧栏立即更新。
                let streamed = try await hub.addManyStream(toConnect) { [weak self] connection in
                    Task { @MainActor in
                        guard let self, generation == self.connectGeneration else { return }
                        self.applyConnection(connection)
                    }
                }
                for connect in streamed {
                    connects[connect.id] = connect
                }
            } catch {
                batchError = error.localizedDescription
            }
        }

        guard generation == connectGeneration else { return }

        let result: [SourceConnection] = prepared.map { item in
            if let error = item.error {
                return SourceConnection(id: item.config.id, name: item.config.name,
                                        kind: item.config.kind, ok: false, error: error)
            }
            if let error = batchError {
                return SourceConnection(id: item.config.id, name: item.config.name,
                                        kind: item.config.kind, ok: false, error: error)
            }
            if let connect = connects[item.config.id] {
                return connect
            }
            return SourceConnection(id: item.config.id, name: item.config.name,
                                    kind: item.config.kind, ok: false,
                                    error: "核心未返回该源的连接结果")
        }

        // 连接期间用户可能删了源：只保留还配置着的。
        // 旧一轮回来时这里也能挡住「已删源又被写回」。
        let live = Set(settings.sources.map(\.id))
        let current = result.filter { live.contains($0.id) }

        // 已删掉的源留下的挂载点顺手卸掉（后台执行，别卡住连接流程）。
        await cleanupStaleMounts(keep: live)

        connections = current
        pendingConnections.removeAll()

        guard !current.isEmpty else {
            core = nil
            coreError = nil
            page = .sources
            return
        }

        guard current.contains(where: \.ok) else {
            coreError = current.map { "\($0.name)：\($0.error ?? "连接失败")" }
                .joined(separator: "；")
            return
        }

        core = hub
        coreError = nil
        settings.save()

        // 连接已经完成，别再显示「正在连接…」：下面刷新库列表 / 记录可能还要几秒。
        // 启动后停在「服务器」页，菜单选中哪一项，右边就是哪一页。
        connecting = false
        await refresh()
    }

    /// 单个源的连接结果到了：按 id 替换，清掉它的「连接中」标记。
    private func applyConnection(_ connection: SourceConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        pendingConnections.remove(connection.id)
    }

    /// 拖动排序：把 id 挪到 targetId 的位置，顺序写回设置。
    func moveSource(_ id: String, to targetId: String) {
        guard id != targetId,
              let from = settings.sources.firstIndex(where: { $0.id == id }),
              let to = settings.sources.firstIndex(where: { $0.id == targetId }) else {
            return
        }

        // 带动画换位：卡片 / 侧栏条目之间平滑让位，不是瞬间跳过去。
        withAnimation(.easeInOut(duration: 0.24)) {
            let item = settings.sources.remove(at: from)
            settings.sources.insert(item, at: to)

            // 侧栏直接读 connections，顺序也跟着换，不用等重连。
            let order = Dictionary(
                settings.sources.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { first, _ in first })
            connections.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
        settings.save()
    }

    /// 库里列表 + 观看记录 + 收藏（收藏页要用）。
    func refresh() async {
        guard let core else { return }

        do {
            libraries = try await core.libraries()
            // 上一次读库失败留下的错误不能带到这次成功的刷新里：
            // 首页会直接展示 coreError（见 LibrariesPage.emptyHint）。
            coreError = nil
        } catch {
            coreError = "读取媒体库失败：\(error.localizedDescription)"
        }

        do {
            records = try await core.records()
        } catch {
            records = []
        }

        do {
            favorites = try await core.favorites().items
        } catch {
            favorites = []
        }
    }

    /// 只刷新收藏（详情页点了收藏之后调，别的页面下一次进来就是新状态）。
    func refreshFavorites() async {
        guard let core else { return }
        favorites = (try? await core.favorites().items) ?? []
    }

    /// 只刷新观看记录（详情页标记看过 / 看完之后调）。
    func refreshRecords() async {
        guard let core else { return }
        records = (try? await core.records()) ?? []
    }

    // MARK: - 源管理

    func saveSource(_ incoming: SourceConfig) async {
        var config = incoming
        // 本地 / 文件协议源一定要有 data_dir，否则进度只活在内存里。
        if (config.kind == "local" || MountSources.isMount(config.kind)),
           (config.dataDir ?? "").isEmpty {
            config.dataDir = AppSettings.directory.path
        }

        // 地址或协议改了：旧挂载点先卸，connectAll 会按新地址重挂。
        if let old = settings.sources.first(where: { $0.id == config.id }),
           old.kind != config.kind || old.base != config.base {
            await releaseMount(config.id)
        }

        if let index = settings.sources.firstIndex(where: { $0.id == config.id }) {
            settings.sources[index] = config
        } else {
            settings.sources.append(config)
        }

        settings.lastSourceId = config.id
        settings.save()
        await connectAll()
    }

    func removeSource(_ id: String) async {
        await releaseMount(id)
        settings.sources.removeAll { $0.id == id }
        if settings.lastSourceId == id {
            settings.lastSourceId = settings.sources.first?.id
        }
        settings.save()
        await connectAll()
    }

    // MARK: - 提示

    /// 弹一张确认卡片。`action` 只在用户点确认后执行。
    func askConfirm(title: String, message: String, confirmTitle: String = "确定",
                    danger: Bool = true, action: @escaping () -> Void) {
        confirm = ConfirmRequest(title: title, message: message,
                                 confirmTitle: confirmTitle, danger: danger,
                                 action: action)
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toast = nil }
        }
    }
}
