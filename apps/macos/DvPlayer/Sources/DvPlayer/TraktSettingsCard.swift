import SwiftUI
import AppKit
import DvCore

/// 设置页的 Trakt 卡片：设备码登录、账号状态、自动同步开关、应用凭据。
///
/// 设备码流程不需要密码，也不开浏览器回调：点「连接」后显示 8 位码，
/// 用户在 trakt.tv/activate 上确认，这边轮询到 token 就完成。
struct TraktSettingsCard: View {
    @EnvironmentObject private var state: AppState

    @State private var loggedIn = false
    @State private var username: String?
    @State private var device: TraktDeviceCode?
    @State private var status: String?
    @State private var busy = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Trakt（观看记录）")
                Text("连接自己的 Trakt 账号：播放时自动上报进度，详情页可以评分、"
                     + "加入收藏 / 待看。数据只写到你的 Trakt 里，不经过我们的服务器。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)

                if !TraktSettings.isConfigured {
                    credentials
                }

                if loggedIn {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text(username.map { "已连接：\($0)" } ?? "已连接 Trakt")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Button("断开") { logOut() }
                            .buttonStyle(SecondaryButtonStyle())
                    }

                    Toggle("播放时自动同步观看进度", isOn: enabledBinding)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text)
                        .toggleStyle(DvSwitchStyle())
                        .onChange(of: state.settings.traktEnabled) { _ in
                            state.settings.save()
                        }
                } else {
                    loginSection
                }

                if let status {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await refresh() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - 子视图

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这个构建没有内置 Trakt 应用凭据。去 Trakt 网站建一个 API 应用"
                 + "（Redirect URI 填 urn:ietf:wg:oauth:2.0:oob），把 Client ID / Secret 填在这里。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Client ID")
                    InputField(placeholder: "Trakt Client ID",
                               text: credentialBinding(\.traktClientId))
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Client Secret")
                    InputField(placeholder: "Trakt Client Secret",
                               text: credentialBinding(\.traktClientSecret), secure: true)
                }
            }

            Link("打开 Trakt 应用管理页",
                 destination: URL(string: "https://app.trakt.tv/settings/apps/api")!)
                .font(.system(size: 11.5))
        }
    }

    @ViewBuilder
    private var loginSection: some View {
        if let device {
            VStack(alignment: .leading, spacing: 10) {
                Text("在浏览器里打开 \(device.verificationURL)，输入下面的码：")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)

                HStack(spacing: 12) {
                    Text(device.userCode)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .textSelection(.enabled)

                    Spacer()

                    Button("打开网页") {
                        if let url = URL(string: device.verificationURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("取消") { cancelLogin() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        } else {
            HStack(spacing: 12) {
                Button("连接 Trakt") { startLogin() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || !TraktSettings.isConfigured)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: - 绑定

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.settings.traktEnabled ?? true },
            set: { state.settings.traktEnabled = $0 })
    }

    private func credentialBinding(_ keyPath: WritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: { state.settings[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                state.settings[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
                state.settings.save()
                TraktSettings.invalidate()
            })
    }

    // MARK: - 动作

    private func refresh() async {
        let signedIn = await TraktClient.shared.isLoggedIn()
        await MainActor.run { loggedIn = signedIn }

        guard signedIn else { return }
        await TraktClient.shared.rememberUsername()
        let name = await TraktClient.shared.currentUsername()
        await MainActor.run { username = name }
    }

    private func startLogin() {
        busy = true
        status = nil
        Task {
            do {
                let code = try await TraktClient.shared.startDeviceLogin()
                await MainActor.run {
                    device = code
                    status = "等待在网页上确认…"
                    if let url = URL(string: code.verificationURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                poll(code)
            } catch {
                await MainActor.run { status = error.localizedDescription }
            }
            await MainActor.run { busy = false }
        }
    }

    private func poll(_ code: TraktDeviceCode) {
        pollTask?.cancel()
        pollTask = Task {
            var waited: TimeInterval = 0
            while waited < code.expiresIn {
                try? await Task.sleep(nanoseconds: UInt64(code.interval * 1_000_000_000))
                if Task.isCancelled { return }
                waited += code.interval
                do {
                    _ = try await TraktClient.shared.pollDeviceToken(code)
                    await TraktClient.shared.rememberUsername()
                    let name = await TraktClient.shared.currentUsername()
                    await MainActor.run {
                        loggedIn = true
                        username = name
                        device = nil
                        status = "已连接"
                    }
                    return
                } catch TraktError.devicePending {
                    continue
                } catch {
                    await MainActor.run {
                        status = error.localizedDescription
                        device = nil
                    }
                    return
                }
            }
            await MainActor.run {
                status = "设备码过期了，重新连接一次"
                device = nil
            }
        }
    }

    private func cancelLogin() {
        pollTask?.cancel()
        pollTask = nil
        device = nil
        status = nil
    }

    private func logOut() {
        pollTask?.cancel()
        busy = true
        Task {
            await TraktClient.shared.logOut()
            await MainActor.run {
                loggedIn = false
                username = nil
                device = nil
                status = "已断开 Trakt"
                busy = false
            }
        }
    }
}
