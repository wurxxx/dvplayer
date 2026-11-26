import SwiftUI
import AppKit
import DvCore

/// 「搜索」页：一次搜索覆盖所有已连接源，结果平铺成网格。
struct SearchPage: View {
    @EnvironmentObject private var state: AppState

    @State private var keyword = ""
    @State private var results: [MediaItem] = []
    @State private var failures: [SourceFailure] = []
    /// 所有源都失败时的错误（单源失败走 failures）。
    @State private var errorText: String?
    @State private var searching = false
    @State private var searched = false
    /// 输入防抖：每次敲字取消上一条待执行的搜索。
    @State private var searchTask: Task<Void, Never>?
    /// 搜索世代号：已经发出去的旧搜索晚到，不能覆盖新词的结果。
    @State private var searchVersion = 0

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PageTitle(text: "搜索")
                Spacer()
                SearchField(placeholder: "片名、剧名或关键词", text: $keyword, width: 320)
            }
            .padding(.leading, Theme.contentLeading)
            .padding(.trailing, 32)
            .padding(.top, 18)

            PageScroll {
                VStack(alignment: .leading, spacing: 14) {
                    if searching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Caption(text: "正在搜索…", size: 12)
                        }
                    } else if searched && results.isEmpty {
                        HStack(spacing: 10) {
                            if let errorText {
                                Text("搜索失败：\(errorText)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.danger)
                                    .lineLimit(2)
                            } else {
                                Caption(text: "没有找到匹配的内容。", size: 12)
                            }
                            failureNote
                        }
                    } else if !results.isEmpty {
                        HStack(spacing: 10) {
                            Caption(text: "\(results.count) 个结果 · 跨 \(sourceCount) 个源", size: 12)
                            failureNote
                        }
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(results) { item in
                            // 多来源不在这里选：进详情页的「资源」里切。
                            PosterCard(item: item, width: 168) {
                                state.openDetail(item.id)
                            }
                        }
                    }
                }
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .overlay {
                if !searched && !searching {
                    EmptyState(icon: "magnifyingglass", title: "搜索所有已连接的源",
                               hint: "输入片名、剧名或关键词")
                }
            }
        }
        .onAppear {
            // 截图巡检：`DVPLAYER_SEARCH=<关键词>` 优先；
            // 否则接着上次的查询词，切页 / 重启回来还在。
            let env = ProcessInfo.processInfo.environment
            if let wanted = env["DVPLAYER_SEARCH"], !wanted.isEmpty {
                keyword = wanted
            } else if keyword.isEmpty,
                      let saved = state.settings.searchKeyword,
                      !saved.trimmingCharacters(in: .whitespaces).isEmpty {
                keyword = saved
            }
        }
        .onSubmit(of: .text) {
            searchTask?.cancel()
            Task { await search() }
        }
        .onChange(of: keyword) { _ in
            searchTask?.cancel()
            searchTask = Task {
                // 打完再搜：300ms 内又敲字就作废（取消上一次）。
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
        }
        .onDisappear {
            searchTask?.cancel()
            // 在途搜索也作废：页面已经不显示了，别让结果晚到再改状态。
            searchVersion &+= 1
            // 还没等到防抖就切页：把输入框里现在的词也留下。
            saveKeyword(keyword.trimmingCharacters(in: .whitespaces))
        }
    }

    /// 某个源挂了不影响其它源，但要让用户知道结果不全。
    @ViewBuilder
    private var failureNote: some View {
        if !failures.isEmpty {
            Text("\(failures.count) 个源没响应："
                 + failures.map(\.sourceName).joined(separator: "、"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
                .help(failures.map { "\($0.sourceName)：\($0.error)" }
                    .joined(separator: "\n"))
        }
    }

    private var sourceCount: Int {
        Set(results.flatMap { $0.sources.map(\.sourceId) }).count
    }

    private func saveKeyword(_ text: String) {
        guard state.settings.searchKeyword != text else { return }
        state.settings.searchKeyword = text
        state.settings.save()
    }

    private func search() async {
        let text = keyword.trimmingCharacters(in: .whitespaces)
        saveKeyword(text)

        // 防抖只能取消还没发出去的搜索；已经在核心里跑的那一轮要靠版本号拦。
        searchVersion &+= 1
        let version = searchVersion

        guard let core = state.core else { return }
        guard !text.isEmpty else {
            results = []
            failures = []
            errorText = nil
            searched = false
            return
        }

        searching = true
        defer {
            if version == searchVersion {
                searching = false
            }
        }

        do {
            let result = try await core.search(text)
            guard version == searchVersion else { return }
            results = result.items
            failures = result.failed
            errorText = nil
        } catch {
            guard version == searchVersion else { return }
            // 全失败才抛到这里；单个源失败在 result.failed 里。
            results = []
            failures = []
            errorText = error.localizedDescription
        }

        guard version == searchVersion else { return }
        searched = true
    }
}

/// 「设置」页：播放偏好 + 核心信息。
struct SettingsPage: View {
    @EnvironmentObject private var state: AppState

    /// 更新检查结果；nil = 还没查过。
    @State private var updateState: UpdateChecker.Result?
    @State private var checkingUpdate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "设置")
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.top, 18)

            PageScroll {
                VStack(alignment: .leading, spacing: 18) {
                    SurfaceCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(text: "播放")

                            Toggle("从上次停下的位置继续", isOn: $state.settings.resumePlayback)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text)
                                .toggleStyle(.switch)

                            Toggle("卡片上显示分辨率角标", isOn: $state.settings.showResolution)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text)
                                .toggleStyle(.switch)

                            Toggle("启动时自动连接所有源", isOn: $state.settings.autoConnect)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text)
                                .toggleStyle(.switch)

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("播放缓冲")
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(Theme.text)
                                    Text("mpv 最多预读多少；默认 512 MB，原盘可以调到 2 GB / 4 GB")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.faint)
                                }
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { state.settings.bufferSizeMb ?? 512 },
                                    set: { state.settings.bufferSizeMb = $0 })
                                ) {
                                    Text("256 MB").tag(256)
                                    Text("512 MB").tag(512)
                                    Text("1 GB").tag(1024)
                                    Text("2 GB").tag(2048)
                                    Text("4 GB").tag(4096)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 112)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("HDR 亮度参考")
                                            .font(.system(size: 13.5))
                                            .foregroundStyle(Theme.text)
                                        Text("HDR 片转 SDR 时的目标白点。默认自动（100 nit）。"
                                             + "觉得 HDR 片偏暗就把数值调小（画面更亮），偏亮就调大；"
                                             + "SDR 内容不受影响。")
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(Theme.faint)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Toggle("自动", isOn: hdrPeakAuto)
                                        .toggleStyle(.switch)
                                        .font(.system(size: 12))
                                }

                                HStack(spacing: 10) {
                                    Slider(value: hdrPeakSlider, in: 60...200, step: 5,
                                           onEditingChanged: { editing in
                                               if !editing { applyHdrPeakToPlayer() }
                                           })
                                        .disabled(hdrPeakAuto.wrappedValue)
                                    Text(hdrPeakText)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.faint)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(width: 104, alignment: .trailing)
                                }
                            }
                        }
                    }

                    SurfaceCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(text: "弹幕（弹弹play）")
                            Text("弹幕凭据已经内置在应用里，不用填任何东西；打开播放页「更多」里的"
                                 + "弹幕开关，会按「剧名 + 集号」自动匹配。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)

                            Toggle("打开播放页时默认开弹幕", isOn: boolBinding(\.danmakuEnabled))
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text)
                                .toggleStyle(.switch)

                            Text(danmakuHint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    TraktSettingsCard()

                    SurfaceCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(text: "在线字幕（OpenSubtitles）")
                            Text("注册 OpenSubtitles 后就能拿到 API Key；用户名 / 密码可以不填，"
                                 + "填了下载更稳。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "API Key")
                                InputField(placeholder: "OpenSubtitles API Key",
                                           text: textBinding(\.openSubtitlesApiKey), secure: true)
                            }

                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    FieldLabel(text: "用户名（可选）")
                                    InputField(placeholder: "用户名",
                                               text: textBinding(\.openSubtitlesUsername))
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    FieldLabel(text: "密码（可选）")
                                    InputField(placeholder: "密码",
                                               text: textBinding(\.openSubtitlesPassword), secure: true)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "搜索语言（逗号分隔）")
                                InputField(placeholder: "zh-cn,zh-tw,en",
                                           text: textBinding(\.subtitleLanguages))
                            }

                            Text(subtitleHint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    SurfaceCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(text: "关于")

                            KeyValueRow(key: "共享核心", value: state.coreVersion)
                            KeyValueRow(key: "应用", value: "DV Player for macOS \(appVersion)")

                            // 项目地址：点开默认浏览器，地址本身也完整显示。
                            HStack(alignment: .top, spacing: 12) {
                                Text("项目")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.faint)
                                    .frame(width: 72, alignment: .leading)

                                Button {
                                    NSWorkspace.shared.open(ProjectInfo.repoURL)
                                } label: {
                                    Text("github.com/\(ProjectInfo.repo)")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.accent)
                                        .underline()
                                }
                                .buttonStyle(.plain)
                                .help("在浏览器中打开项目主页")

                                Spacer(minLength: 0)
                            }

                            HStack(alignment: .center, spacing: 12) {
                                Text("更新")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.faint)
                                    .frame(width: 72, alignment: .leading)

                                HStack(spacing: 7) {
                                    if checkingUpdate {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(Theme.accent)
                                    }
                                    Text(updateText)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(updateTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)

                                Button(updateButtonTitle) {
                                    if case .available(_, let url) = updateState {
                                        NSWorkspace.shared.open(url)
                                    } else {
                                        Task { @MainActor in await checkUpdates(force: true) }
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(checkingUpdate)
                            }

                            KeyValueRow(key: "配置",
                                        value: AppSettings.fileURL.path)
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding(.leading, Theme.contentLeading)
                .padding(.trailing, 32)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 880, alignment: .leading)
            }
        }
        .onChange(of: state.settings.resumePlayback) { _ in state.settings.save() }
        .onChange(of: state.settings.showResolution) { _ in state.settings.save() }
        .onChange(of: state.settings.autoConnect) { _ in state.settings.save() }
        .onChange(of: state.settings.bufferSizeMb) { _ in state.settings.save() }
        .onChange(of: state.settings.hdrPeakNits) { _ in state.settings.save() }
        // 进设置页自动查一次（有 10 分钟缓存，切页面不会反复打接口）。
        .task {
            if updateState == nil {
                await checkUpdates(force: false)
            }
        }
    }

    // MARK: - 更新检查

    private var updateText: String {
        if checkingUpdate {
            return "正在检查…"
        }
        guard let updateState else {
            return "还没有检查过"
        }
        switch updateState {
        case .upToDate(let current):
            return "已是最新版本（v\(current)）"
        case .available(let version, _):
            return "发现新版本 v\(version)"
        case .noRelease:
            return "GitHub 上还没有发布版本"
        case .failed(let message):
            return message
        }
    }

    private var updateTextColor: Color {
        guard !checkingUpdate, let updateState else {
            return Theme.faint
        }
        switch updateState {
        case .upToDate:
            return Theme.success
        case .available:
            return Theme.accent
        case .noRelease:
            return Theme.faint
        case .failed:
            return Theme.danger
        }
    }

    private var updateButtonTitle: String {
        if checkingUpdate {
            return "检查中…"
        }
        if case .available = updateState {
            return "下载更新"
        }
        return updateState == nil ? "检查更新" : "重新检查"
    }

    @MainActor
    private func checkUpdates(force: Bool) async {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        defer { checkingUpdate = false }

        let result = await UpdateChecker.shared.check(currentVersion: appVersion,
                                                      force: force)
        updateState = result
        // 侧栏左下角跟着变：这里查到的新版本也要提示。
        state.applyUpdateCheck(result)
    }

    // MARK: - HDR 亮度参考

    /// 0 / nil = 自动（100 nit）。
    private var hdrPeakAuto: Binding<Bool> {
        Binding(
            get: { (state.settings.hdrPeakNits ?? 0) <= 0 },
            set: { auto in
                if auto {
                    state.settings.hdrPeakNits = 0
                } else if (state.settings.hdrPeakNits ?? 0) <= 0 {
                    state.settings.hdrPeakNits = 100
                }
                DispatchQueue.main.async { applyHdrPeakToPlayer() }
            })
    }

    private var hdrPeakSlider: Binding<Double> {
        Binding(
            get: { Double(state.settings.hdrPeakNits ?? 100) },
            set: { state.settings.hdrPeakNits = Int($0.rounded()) })
    }

    private var hdrPeakText: String {
        let nits = state.settings.hdrPeakNits ?? 0
        return nits > 0 ? "\(nits) nit" : "100 nit（自动）"
    }

    /// 设置页改动时，如果播放窗还开着就同步过去（不用等下一次播放）。
    private func applyHdrPeakToPlayer() {
        guard let session = PlayerLauncher.shared.current else { return }
        session.setHdrPeakNits(state.settings.hdrPeakNits ?? 0)
    }

    // MARK: - 弹幕 / 字幕凭据

    /// 版本号统一由 `AppState` 提供（侧栏更新提示用的是同一个值）。
    private var appVersion: String { state.appVersion }

    private var danmakuHint: String {
        DanmakuCredential.isConfigured
            ? "已内置：播放页打开弹幕时会按「剧名 + 集号」自动匹配。"
            : "这个构建没有内置弹幕凭据（开发版）：打开弹幕不会联网。"
    }

    private var subtitleHint: String {
        (state.settings.openSubtitlesApiKey ?? "").isEmpty
            ? "还没填 API Key：字幕搜索会提示缺什么，不会联网。"
            : "已配置：播放页「更多 → 搜索字幕」会按当前剧集与语言去搜。"
    }

    /// 文本框：边输入边写回 settings.json，清空就当作没填。
    private func textBinding(_ keyPath: WritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: { state.settings[keyPath: keyPath] ?? "" },
            set: { value in
                state.settings[keyPath: keyPath] = value.isEmpty ? nil : value
                state.settings.save()
            })
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings, Bool?>) -> Binding<Bool> {
        Binding(
            get: { state.settings[keyPath: keyPath] ?? false },
            set: { value in
                state.settings[keyPath: keyPath] = value
                state.settings.save()
            })
    }
}

private struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.faint)
                .frame(width: 72, alignment: .leading)

            Text(value)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }
}
