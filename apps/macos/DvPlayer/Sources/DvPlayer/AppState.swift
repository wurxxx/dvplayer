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
    @Published var page: Page = .sources
    @Published var connections: [SourceConnection] = []
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

        if settings.autoConnect {
            await connectAll()
        } else if let last = settings.lastSourceId {
            page = .home(last)
        }

        let env = ProcessInfo.processInfo.environment
        debugDetail = env["DVPLAYER_DETAIL"]
        debugLibrary = env["DVPLAYER_LIBRARY"]

        switch env["DVPLAYER_PAGE"] {
        case "records": page = .records
        case "search": page = .search
        case "settings": page = .settings
        case "sources": page = .sources
        default: break
        }
    }

    // MARK: - 连接

    /// 把所有配置好的源接进核心。单个源失败不影响其它源。
    func connectAll() async {
        guard !settings.sources.isEmpty else {
            connections = []
            core = nil
            coreError = nil
            page = .sources
            return
        }

        connecting = true
        defer { connecting = false }

        core = nil
        guard let hub = Core() else {
            coreError = "无法加载共享核心 dvplayer_media"
            connections = settings.sources.map {
                SourceConnection(id: $0.id, name: $0.name, kind: $0.kind,
                                 ok: false, error: "共享核心未加载")
            }
            return
        }

        var result: [SourceConnection] = []
        for config in settings.sources {
            do {
                let info = try await hub.add(config)
                result.append(SourceConnection(id: info.id, name: info.name,
                                               kind: info.kind, ok: true, error: nil))
            } catch {
                result.append(SourceConnection(id: config.id, name: config.name,
                                               kind: config.kind, ok: false,
                                               error: error.localizedDescription))
            }
        }

        connections = result
        guard result.contains(where: \.ok) else {
            coreError = result.map { "\($0.name)：\($0.error ?? "连接失败")" }
                .joined(separator: "；")
            return
        }

        core = hub
        coreError = nil
        settings.save()
        await refresh()

        if case .sources = page, let first = result.first(where: \.ok) {
            page = .home(first.id)
        }
    }

    /// 库里列表 + 观看记录 + 收藏（收藏页要用）。
    func refresh() async {
        guard let core else { return }

        do {
            libraries = try await core.libraries()
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

    // MARK: - 源管理

    func saveSource(_ config: SourceConfig) async {
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
