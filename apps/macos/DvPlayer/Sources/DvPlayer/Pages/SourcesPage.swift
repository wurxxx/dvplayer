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
    @State private var saving = false

    private var isEditing: Bool { editing != nil }

    /// 本地文件夹源：地址是一个目录（或单个视频 / ISO），没有账号密码。
    private var isLocal: Bool { kind == "local" }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                header

                if state.settings.sources.isEmpty && !isEditing {
                    emptyState
                } else {
                    ForEach(state.settings.sources) { config in
                        sourceCard(config)
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
            if ProcessInfo.processInfo.environment["DVPLAYER_CONFIRM"] == "1" {
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
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surfaceHover)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.muted)
                )

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
                        .fill(connection?.ok == true ? Theme.success
                              : (connection == nil ? Theme.faint : Theme.danger))
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

    private func statusText(_ config: SourceConfig, _ connection: SourceConnection?) -> String {
        guard let connection else {
            return state.connecting ? "正在连接…" : "未连接"
        }
        if connection.ok {
            let libraries = state.libraryCount(of: config.id)
            return libraries > 0 ? "已连接 · \(libraries) 个媒体库" : "已连接"
        }
        return connection.error ?? "连接失败"
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "编辑服务器" : "添加服务器")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)

            Text(isLocal
                 ? "选一个目录：里面的每个视频是一个条目，剧按 Season / S01E01 分季分集。"
                 : "Emby / Jellyfin 用账号密码登录，也可以只填 API Key（用户名留空）。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "类型")
                    Picker("", selection: $kind) {
                        Text("飞牛影视").tag("fnos")
                        Text("Emby").tag("emby")
                        Text("Jellyfin").tag("jellyfin")
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

            if isLocal {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "文件夹 / ISO")
                    HStack(spacing: 10) {
                        InputField(placeholder: "/Volumes/Media", text: $base)
                        Button("选择…") { chooseFolder() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "服务器地址")
                    InputField(placeholder: "http://192.168.1.10:8005", text: $base)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "用户名（Emby 可留空）")
                        InputField(placeholder: "用户名", text: $username)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(text: "密码 / API Key")
                        InputField(placeholder: "密码或 API Key", text: $password, secure: true)
                    }
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
    }

    private static func defaultName(for kind: String) -> String {
        kind == "local" ? "本地文件" : MediaText.sourceKindLabel(kind)
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
    }

    private func save() {
        guard var config = editing else { return }
        config.kind = kind
        config.name = name.trimmingCharacters(in: .whitespaces)
        config.base = base.trimmingCharacters(in: .whitespaces)
        config.username = username
        config.password = password

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
