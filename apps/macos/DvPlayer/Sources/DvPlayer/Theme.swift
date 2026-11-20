import SwiftUI

// 色板与字号照 docs/UI-DESIGN.md（和 Windows 的 AppTheme.xaml 同一套）。
enum Theme {
    static let bg = Color(hex: 0x141419)
    static let sidebar = Color(hex: 0x17171D)
    static let surface = Color(hex: 0x1F1F27)
    static let surfaceHover = Color(hex: 0x2B2B35)
    static let line = Color(hex: 0x3B3B49)
    static let text = Color(hex: 0xF5F5F8)
    static let muted = Color(hex: 0xBDBDCB)
    static let faint = Color(hex: 0x9696A4)
    static let accent = Color(hex: 0xFFB020)
    static let danger = Color(hex: 0xFF6B6B)
    static let success = Color(hex: 0x4ADE80)

    static let radiusCard: CGFloat = 12
    static let radiusControl: CGFloat = 9
    static let sidebarWidth: CGFloat = 216
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - 文字

struct PageTitle: View {
    let text: String
    var size: CGFloat = 27

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .bottom) {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}

struct Caption: View {
    let text: String
    var size: CGFloat = 11.5

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(Theme.faint)
    }
}

/// 一行小标签（分辨率、编码、动态范围）。
struct Chip: View {
    let text: String
    var tint: Color = Color.white.opacity(0.18)

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint, in: RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - 容器

struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
    }
}

/// 主按钮（琥珀底黑字）。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color(hex: 0x1A1200))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.radiusControl))
    }
}

/// 次级按钮（描边）。
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .stroke(Theme.line, lineWidth: 1)
            )
    }
}

/// 危险操作（删除 / 清空）：红色实底，和 Windows 的 DangerButton 一致。
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(hex: 0xC42B1C).opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.radiusControl))
    }
}

// MARK: - 输入

struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
    }
}

struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13.5))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .stroke(Theme.line, lineWidth: 1)
        )
    }
}

/// 顶部搜索框（圆角深底 + 放大镜）。
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(width: width)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
    }
}
