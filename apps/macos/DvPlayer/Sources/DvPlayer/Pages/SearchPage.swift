import SwiftUI
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
            .padding(.horizontal, 32)
            .padding(.top, 40)

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
                .padding(.horizontal, 32)
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
            // 截图巡检：`DVPLAYER_SEARCH=<关键词>` 直接带一个查询进来。
            let env = ProcessInfo.processInfo.environment
            if keyword.isEmpty, let wanted = env["DVPLAYER_SEARCH"], !wanted.isEmpty {
                keyword = wanted
            }
        }
        .onSubmit(of: .text) { Task { await search() } }
        .onChange(of: keyword) { _ in
            Task {
                // 打完再搜：300ms 内又敲字就作废。
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await search()
            }
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

    private func search() async {
        guard let core = state.core else { return }
        let text = keyword.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            failures = []
            errorText = nil
            searched = false
            return
        }

        searching = true
        defer { searching = false }

        do {
            let result = try await core.search(text)
            results = result.items
            failures = result.failed
            errorText = nil
        } catch {
            // 全失败才抛到这里；单个源失败在 result.failed 里。
            results = []
            failures = []
            errorText = error.localizedDescription
        }
        searched = true
    }
}

/// 「设置」页：播放偏好 + 核心信息。
struct SettingsPage: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "设置")
                .padding(.horizontal, 32)
                .padding(.top, 40)

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
                        }
                    }

                    SurfaceCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionTitle(text: "弹幕（弹弹play）")
                            Text("在弹弹play 控制台申请 AppId / AppSecret 后填在这里，"
                                 + "播放页「更多」里的弹幕开关才能拉到弹幕。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)

                            Toggle("打开播放页时默认开弹幕", isOn: boolBinding(\.danmakuEnabled))
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text)
                                .toggleStyle(.switch)

                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "AppId")
                                InputField(placeholder: "弹弹play AppId", text: textBinding(\.danmakuAppId))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                FieldLabel(text: "AppSecret")
                                InputField(placeholder: "弹弹play AppSecret",
                                           text: textBinding(\.danmakuAppSecret), secure: true)
                            }

                            Text(danmakuHint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

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
                            KeyValueRow(key: "应用", value: "DV Player for macOS 0.1")
                            KeyValueRow(key: "配置",
                                        value: AppSettings.fileURL.path)
                            KeyValueRow(key: "已连接", value: state.isConnected ? "是" : "否")
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .onChange(of: state.settings.resumePlayback) { _ in state.settings.save() }
        .onChange(of: state.settings.showResolution) { _ in state.settings.save() }
        .onChange(of: state.settings.autoConnect) { _ in state.settings.save() }
        .onChange(of: state.settings.bufferSizeMb) { _ in state.settings.save() }
    }

    // MARK: - 弹幕 / 字幕凭据

    private var danmakuHint: String {
        let settings = state.settings
        let filled = !(settings.danmakuAppId ?? "").isEmpty
            && !(settings.danmakuAppSecret ?? "").isEmpty
        return filled
            ? "已配置：播放页打开弹幕时会按「剧名 + 集号」自动匹配。"
            : "还没填全：打开弹幕时只会提示缺少 AppId / AppSecret，不会联网。"
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
