import AppKit
import SwiftUI
import DvCore

/// 「服务器」页：已配置的源 + 添加 / 编辑表单。布局和 Windows 的 SourcesPage 一致。
struct SourcesPage: View {
    @EnvironmentObject private var state: AppState

    @State private var editing: SourceConfig?
    @State private var kind = "fnos"
    @State private var name = "飞牛影视"
    @State private var base = ""
    @State private var username = ""
    @State private var password = ""
    @State private var proxy = ""
    @State private var saving = false

    /// 拖动时鼠标下的目标源，用来画落点高亮。
    @State private var dropTargetId: String?

    private var isEditing: Bool { editing != nil }

    /// 表单里的源已经在设置里（编辑）；新增时 `editing` 也非空，但那是草稿。
    private var isExisting: Bool {
        guard let editing else { return false }
        return state.settings.sources.contains { $0.id == editing.id }
    }

    /// 本地文件夹源：地址是一个目录（或单个视频 / ISO），没有账号密码。
    private var isFolder: Bool { kind == "local" }

    /// 需要「用户名 / 密码」的类型（飞牛影视也要，别只把文件协议算进来）。
    private var needsCredentials: Bool {
        ["fnos", "feiniu", "emby", "jellyfin", "smb", "cifs", "webdav"].contains(kind)
    }

    /// 走 HTTP 的服务器才有代理；本地目录、SMB / NFS / WebDAV 是系统挂载。
    private var needsProxy: Bool {
        ["fnos", "feiniu", "emby", "jellyfin"].contains(kind)
    }

    private static func typeNoun(_ kind: String) -> String {
        switch kind {
        case "local": return "本地文件夹"
        case "smb", "cifs": return "SMB"
        case "nfs": return "NFS"
        case "webdav": return "WebDAV"
        default: return "服务器"
        }
    }

    /// 新增时 `editing` 也有值（拿着表单的临时配置），别把标题写成「编辑」。
    private var addressLabel: String {
        switch kind {
        case "local": return "文件夹 / ISO"
        case "smb", "cifs": return "SMB 地址"
        case "nfs": return "NFS 地址"
        case "webdav": return "WebDAV 地址"
        default: return "服务器地址"
        }
    }

    private var addressPlaceholder: String {
        switch kind {
        case "local": return "/Volumes/Media 或 /path/to/movie.iso"
        case "smb", "cifs": return "smb://192.168.1.10/影视"
        case "nfs": return "nfs://192.168.1.10:/volume1/media"
        case "webdav": return "https://192.168.1.10:5006/dav"
        default: return "http://192.168.1.10:8005"
        }
    }

    private var credentialsLabel: String {
        kind == "emby" || kind == "jellyfin" ? "用户名（可留空，只用 API Key）" : "用户名"
    }

    private var hint: String {
        switch kind {
        case "local":
            return "选一个目录：里面的每个视频是一个条目，剧按 Season / S01E01 分季分集。"
        case "smb", "cifs":
            return "写到共享名；系统会把它挂载成目录，播放器直接读本地路径，ISO 原盘也能播。"
        case "nfs":
            return "NFS 不需要密码；Windows 需要在「启用或关闭 Windows 功能」里装 NFS 客户端。"
        case "webdav":
            return "WebDAV 会挂载成一个目录；Windows 需要 WebClient 服务（默认关闭）。"
        default:
            return "飞牛影视 / Emby / Jellyfin 用账号密码登录；Emby 也可以只填 API Key（用户名留空）。"
        }
    }

    private var formTitle: String {
        let exists = editing.map { draft in
            state.settings.sources.contains { $0.id == draft.id }
        } ?? false
        return (exists ? "编辑" : "添加") + Self.typeNoun(kind)
    }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                header

                if state.settings.sources.isEmpty && !isEditing {
                    emptyState
                } else {
                    ForEach(state.settings.sources) { config in
                        // 拖到另一个源上就占它的位置，顺序写回设置。
                        let isTarget = dropTargetId == config.id
                        sourceCard(config)
                            .scaleEffect(isTarget ? 1.015 : 1)
                            .animation(.easeOut(duration: 0.12), value: isTarget)
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.radiusCard)
                                    .stroke(Theme.accent, lineWidth: isTarget ? 1.5 : 0)
                            }
                            .onDrag { NSItemProvider(object: config.id as NSString) }
                            .onDrop(
                                of: [.text],
                                isTargeted: Binding(
                                    get: { dropTargetId == config.id },
                                    set: { targeted in
                                        if targeted {
                                            dropTargetId = config.id
                                        } else if dropTargetId == config.id {
                                            dropTargetId = nil
                                        }
                                    }
                                )
                            ) { providers in
                                dropSource(providers, onto: config.id)
                            }
                    }
                }

                if isEditing {
                    form
                }

                if let error = state.coreError {
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.danger)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 截图巡检：直接把确认卡片弹出来看样式。
        .task {
            // 截图巡检：`DVPLAYER_ADD=1` 启动就展开添加表单，`DVPLAYER_ADD_KIND=local` 切到本地文件夹。
            let env = ProcessInfo.processInfo.environment
            if env["DVPLAYER_ADD"] == "1" {
                beginAdd()
                if let wanted = env["DVPLAYER_ADD_KIND"], !wanted.isEmpty {
                    kind = wanted
                    name = Self.defaultName(for: wanted)
                }
            }

            if env["DVPLAYER_CONFIRM"] == "1" {
                state.askConfirm(
                    title: "删除服务器",
                    message: "删除服务器「飞牛影视」？\n播放记录与已收藏的进度都还在，\n重新添加这个源就能接上。",
                    confirmTitle: "删除"
                ) {}
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            PageTitle(text: "服务器")

            Spacer()

            if state.connecting {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                Caption(text: "正在连接…", size: 12)
            }

            if !isEditing {
                Button("添加服务器") { beginAdd() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(Theme.line)
            Text("还没有服务器")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
            Text("支持飞牛影视、Emby 与 Jellyfin")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.faint)
            Button("添加服务器") { beginAdd() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(Theme.surface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private func sourceCard(_ config: SourceConfig) -> some View {
        let connection = state.connections.first { $0.id == config.id }

        return HStack(spacing: 14) {
            // 按种类给品牌图标：飞牛牛头 / Emby 绿三角 / Jellyfin 紫三角 /
            // 本地文件夹 / SMB 共享 / NFS 硬盘 / WebDAV 云。
            SourceIcon(kind: config.kind, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(config.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(MediaText.sourceKindLabel(config.kind))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.faint)
                }

                Text(config.base)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor(config, connection))
                        .frame(width: 6, height: 6)
                    Text(statusText(config, connection))
                        .font(.system(size: 12))
                        .foregroundStyle(connection?.ok == true ? Theme.muted : Theme.faint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                beginEdit(config)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30)
                    .background(Theme.surfaceHover,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("编辑这个源")

            Button {
                // 删除会重连整库，误触代价不小，先弹确认卡片。
                state.askConfirm(
                    title: "删除服务器",
                    message: "删除服务器「\(config.name)」？\n播放记录与已收藏的进度都还在，\n重新添加这个源就能接上。",
                    confirmTitle: "删除"
                ) {
                    Task { await state.removeSource(config.id) }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.danger)
                    .frame(width: 30, height: 30)
                    .background(Theme.surfaceHover,
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("删除这个源")
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    /// 连上绿点、失败红点、还在连灰点、没试过灰点。
    private func dotColor(_ config: SourceConfig, _ connection: SourceConnection?) -> Color {
        if state.pendingConnections.contains(config.id) { return Theme.faint }
        guard let connection else { return Theme.faint }
        return connection.ok ? Theme.success : Theme.danger
    }

    /// 拖拽落位：把拖过来的源挪到 targetId 的位置。
    private func dropSource(_ providers: [NSItemProvider], onto targetId: String) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in state.moveSource(id, to: targetId) }
        }
        return true
    }

    private func statusText(_ config: SourceConfig, _ connection: SourceConnection?) -> String {
        guard let connection else {
            return "未连接"
        }
        if state.pendingConnections.contains(config.id) {
            return "正在连接…"
        }
        if connection.ok {
            var parts = ["已连接"]
            let libraries = state.libraryCount(of: config.id)
            if libraries > 0 {
                parts.append("\(libraries) 个媒体库")
            }
            if let latency = connection.latencyMs {
                parts.append(latency < 1 ? "延迟 <1 ms" : "延迟 \(latency) ms")
            }
            return parts.joined(separator: " · ")
        }
        return connection.error ?? "连接失败"
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(formTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "类型")
                    Picker("", selection: $kind) {
                        Text("飞牛影视").tag("fnos")
                        Text("Emby").tag("emby")
                        Text("Jellyfin").tag("jellyfin")
                        Text("SMB").tag("smb")
                        Text("NFS").tag("nfs")
                        Text("WebDAV").tag("webdav")
                        Text("本地文件夹").tag("local")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160, alignment: .leading)
                    .onChange(of: kind) { value in
                        // 切类型时把默认名称一起换掉，别把「飞牛影视」留给本地目录。
                        if name == defaultName || name.isEmpty {
                            name = Self.defaultName(for: value)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "名称")
                    InputField(placeholder: "飞牛影视", text: $name)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: addressLabel)
                HStack(spacing: 10) {
                    InputField(placeholder: addressPlaceholder, text: $base)
                    if isFolder {
                        Button("选择…") { chooseFolder() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }

            if needsCredentials {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: credentialsLabel)
                        InputField(placeholder: "用户名", text: $username)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "密码")
                        InputField(placeholder: isExisting ? "留空表示不修改" : "密码",
                                   text: $password, secure: true)
                    }
                }
            }

            if needsProxy {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "HTTP 代理（可选）")
                    InputField(placeholder: "http://127.0.0.1:7890，留空表示直连", text: $proxy)
                    Text("这个服务器的接口、海报和播放请求都会走这个代理。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                }
            }

            HStack {
                Spacer()
                Button("取消") { editing = nil }
                    .buttonStyle(SecondaryButtonStyle())

                Button(saving ? "保存中…" : "保存") { save() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving || base.isEmpty || name.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private func beginAdd() {
        editing = SourceConfig(name: "飞牛影视", kind: "fnos", base: "")
        kind = "fnos"
        name = "飞牛影视"
        base = ""
        username = ""
        password = ""
        proxy = ""
    }

    private static func defaultName(for kind: String) -> String {
        switch kind {
        case "local": return "本地文件"
        case "smb", "cifs": return "SMB"
        case "nfs": return "NFS"
        case "webdav": return "WebDAV"
        default: return MediaText.sourceKindLabel(kind)
        }
    }

    private var defaultName: String { Self.defaultName(for: kind) }

    /// 选目录或单个 ISO / 视频文件。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择要加入媒体库的文件夹"
        panel.message = "目录会整库扫描；也可以直接选一个 ISO 或视频文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            base = url.path
            if name.isEmpty || name == defaultName || name == "飞牛影视" {
                name = url.lastPathComponent
            }
        }
    }

    private func beginEdit(_ config: SourceConfig) {
        editing = config
        kind = config.kind
        name = config.name
        base = config.base
        username = config.username
        password = config.password
        proxy = config.proxy ?? ""
    }

    private func save() {
        guard var config = editing else { return }
        config.kind = kind
        config.name = name.trimmingCharacters(in: .whitespaces)
        config.base = base.trimmingCharacters(in: .whitespaces)
        config.username = username
        // 编辑时密码框是空的：沿用原来的密码，别因为改个名字就把源改失联。
        if password.isEmpty,
           let old = state.settings.sources.first(where: { $0.id == config.id }) {
            config.password = old.password
        } else {
            config.password = password
        }
        config.proxy = proxy.trimmingCharacters(in: .whitespaces)

        saving = true
        Task {
            await state.saveSource(config)
            saving = false
            editing = nil
            if state.isConnected {
                state.showToast("已保存并连接")
            }
        }
    }
}
