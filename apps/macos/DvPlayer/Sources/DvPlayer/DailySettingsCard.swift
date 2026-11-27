import SwiftUI
import DvCore

/// 设置页的「每日推荐」卡片：TMDB API Key 与 MoviePilot 地址 / Token。
///
/// 两项都是可选的：没填 TMDB 就只显示豆瓣热门；没填 MoviePilot 时
/// 媒体源里没有的条目只能看，不能订阅。
struct DailySettingsCard: View {
    @EnvironmentObject private var state: AppState

    @State private var testing = false
    @State private var testStatus: String?
    @State private var testOK = false

    var body: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "每日推荐")
                Text("打开应用时取 TMDB 和豆瓣的热门。媒体源里有的点开直接进详情，"
                     + "没有的可以一键推到 MoviePilot 订阅。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "TMDB API Key（可选）")
                    InputField(placeholder: "留空则只显示豆瓣热门",
                               text: tmdbBinding, secure: true)
                    Text("在 themoviedb.org 免费申请 v3 API Key。填了才会显示 TMDB 趋势榜。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "TMDB 代理（可选）")
                    InputField(placeholder: "http://127.0.0.1:7897",
                               text: binding(\.tmdbProxy))
                    Text("留空跟随系统代理。只影响 TMDB 的 API 和海报，豆瓣 / MoviePilot 不走。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Theme.line)

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "MoviePilot 地址")
                    InputField(placeholder: "https://moviepilot.example.com",
                               text: binding(\.moviePilotUrl))
                }

                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "MoviePilot API Token")
                    InputField(placeholder: "MoviePilot 设置 → API 里的 Token",
                               text: binding(\.moviePilotToken), secure: true)
                }

                HStack(spacing: 10) {
                    Button(testing ? "测试中…" : "测试连接") { test() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(testing)

                    if let testStatus {
                        Text(testStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(testOK ? Theme.success : Theme.danger)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("订阅时会优先用 TMDB id；豆瓣条目没有 id，MoviePilot 按标题识别，识别不到时会提示。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 绑定与动作

    /// TMDB Key 填 / 清空时重抓一次：当天缓存里可能只有豆瓣，
    /// 不重抓的话用户回到推荐页会以为 Key 没生效。
    private var tmdbBinding: Binding<String> {
        Binding(
            get: { state.settings.tmdbApiKey ?? "" },
            set: { value in
                let old = (state.settings.tmdbApiKey ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                state.settings.tmdbApiKey = trimmed.isEmpty ? nil : trimmed
                state.settings.save()
                testStatus = nil

                if old.isEmpty != trimmed.isEmpty {
                    DailyStore.shared.refresh(core: state.core,
                                              settings: state.settings,
                                              force: true)
                }
            })
    }

    /// 边输入边写回设置，清空就当作没填。
    private func binding(_ keyPath: WritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: { state.settings[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                state.settings[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
                state.settings.save()
                testStatus = nil
            })
    }

    private func test() {
        let base = state.settings.moviePilotUrl ?? ""
        let token = state.settings.moviePilotToken ?? ""
        testing = true
        testStatus = nil
        Task {
            do {
                let message = try await DailyAPI.checkPilot(base: base, token: token)
                await MainActor.run {
                    testOK = true
                    testStatus = message
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testOK = false
                    testStatus = error.localizedDescription
                    testing = false
                }
            }
        }
    }
}
