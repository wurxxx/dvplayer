import SwiftUI

/// 需要用户确认的操作（删除源之类）。由 `ShellView` 在整窗上盖一张深色卡片。
struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let danger: Bool
    let action: () -> Void
}

/// 和 Windows 的 `ConfirmDialog` 对齐：`#1F1F27` 圆角卡片 + 阴影，
/// 危险操作用红色按钮；Esc 走「取消」，回车不绑定动作，避免误删。
struct ConfirmDialogView: View {
    let request: ConfirmRequest
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            // 压暗整窗，卡片外面的点击等于取消。
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(0.15))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: request.danger
                                  ? "exclamationmark.triangle"
                                  : "info.circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(tint)
                        )

                    Text(request.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }

                Text(request.message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                HStack(spacing: 8) {
                    Spacer()

                    Button("取消", action: onCancel)
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)

                    Button(request.confirmTitle, action: onConfirm)
                        .buttonStyle(request.danger ? AnyButtonStyle(DangerButtonStyle())
                                                    : AnyButtonStyle(PrimaryButtonStyle()))
                }
                .padding(.top, 22)
            }
            .padding(24)
            .frame(width: 460, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 26, x: 0, y: 10)
        }
        .transition(.opacity)
    }

    private var tint: Color {
        request.danger ? Theme.danger : Theme.accent
    }
}

/// `ButtonStyle` 是泛型，条件选择两种样式时用这个包一层。
struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}
