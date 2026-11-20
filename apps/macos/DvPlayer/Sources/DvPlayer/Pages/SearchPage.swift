import SwiftUI
import DvCore

/// 「搜索」页：一次搜索覆盖所有已连接源，结果平铺成网格。
struct SearchPage: View {
    @EnvironmentObject private var state: AppState

    @State private var keyword = ""
    @State private var results: [MediaItem] = []
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
                        Caption(text: "没有找到匹配的内容。", size: 12)
                    } else if !results.isEmpty {
                        Caption(text: "\(results.count) 个结果 · 跨 \(sourceCount) 个源", size: 12)
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(results) { item in
                            PosterCard(item: item, width: 168) {
                                state.showToast("详情页下一轮接入")
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

    private var sourceCount: Int {
        Set(results.map(\.sourceId)).count
    }

    private func search() async {
        guard let core = state.core else { return }
        let text = keyword.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            searched = false
            return
        }

        searching = true
        defer { searching = false }

        results = (try? await core.search(text)) ?? []
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
