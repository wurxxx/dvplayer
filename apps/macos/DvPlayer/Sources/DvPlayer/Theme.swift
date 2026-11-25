import SwiftUI
import AppKit

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

    /// 侧栏是浮在内容上的毛玻璃层（Hero 大图从窗口最左边铺到底），
    /// 正文要躲开它：左内边距 = 侧栏宽 + 常规留白。
    static let contentLeading: CGFloat = sidebarWidth + 32
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
    /// 有动作时 trailing 变成可点区域，并在数量后面补一个 ›（和 Windows 的「数量 ›」一致）。
    var onTrailingTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom) {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if let trailing, !trailing.isEmpty {
                // 数量和标题只差一档：以前这里 11.5pt，比 16pt 的标题小了整整
                // 两级，看着像漏了样式（用户反馈「右侧字体太小」）。
                // 可点 / 不可点两条分支也用同一套字号，不再一个 13 一个 11.5。
                if let onTrailingTap {
                    Button(action: onTrailingTap) {
                        HStack(spacing: 4) {
                            Text(trailing)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.muted)
                            Text("›")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.faint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看全部")
                } else {
                    Text(trailing)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
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
            // 半透明：详情页背后是模糊大图，实底按钮会变成一块黑胶布。
            // 深色页面上半透明看着和不透明几乎一样，不影响其它页面。
            .background(Theme.surface.opacity(configuration.isPressed ? 0.7 : 0.55),
                        in: RoundedRectangle(cornerRadius: Theme.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
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
///
/// 用 `NSSearchField` 而不是 SwiftUI 的 `TextField`：它整块（含放大镜）
/// 都能点进去输入，而 `TextField` 只认自己那一小块，点图标 / 内边距没反应。
/// 背景、圆角、描边还是 SwiftUI 画，视觉和别的控件一致。
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        SearchFieldControl(placeholder: placeholder, text: $text)
            .frame(width: width, height: 34)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusControl)
                    .stroke(Theme.line, lineWidth: 1)
            )
    }
}

private struct SearchFieldControl: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    /// 占位文字的样式。占位由 `SearchFieldCell` 自己居中绘制，不交给 cell。
    static func placeholderAttributed(for text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor(Theme.faint),
                .font: NSFont.systemFont(ofSize: 13.5),
            ]
        )
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchTextField()
        // 换成自定义 cell：让光标和占位文字用同一块矩形。
        // 必须在设 font / placeholder 之前换，否则这些属性会留在旧 cell 上。
        let cell = SearchFieldCell()
        field.cell = cell
        // 换 cell 会把 NSControl 转发给 cell 的状态一起换掉：新 cell 的
        // isEditable / isSelectable 默认是 false，不显式打开的话输入框
        // 就变成只读、点不进去。
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: 13.5)
        field.textColor = NSColor(Theme.text)
        // 占位文字**不设** field.placeholderAttributedString：NSSearchFieldCell
        // 会把它画在贴顶的位置，且设 nil 也拦不住（回退到内部 placeholderString）。
        // 交给 cell 自己保存、自己居中画。
        cell.myPlaceholder = Self.placeholderAttributed(for: placeholder)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    /// 让输入框撑满外层给的 34pt，而不是缩到 intrinsic 的 16pt。
    /// 否则视觉上是 34pt 的框，实际可点的只有中间一条 16pt，
    /// 点上下边缘没反应，看起来就是「点不进去」。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSSearchField,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: proposal.height ?? 34)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchFieldControl

        init(_ parent: SearchFieldControl) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}

/// 窗口不在前台时，第一次点击就直接进输入框（否则那一下只会激活窗口）。
private final class SearchTextField: NSSearchField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 让**光标**和占位文字落在同一块矩形里。
///
/// `NSSearchFieldCell` 在无边框时把占位文字画在 `searchTextRect`（已经给
/// 放大镜留出位置），但开始编辑时用的是整个 bounds，于是光标贴在左边框、
/// 文字却向右缩进约 26pt。
///
/// 覆盖公开的 `select(withFrame:in:editor:delegate:start:length:)`：它正是
/// AppKit 用来放置 field editor 的入口，把 frame 换成 `searchTextRect`
/// 光标就和占位文字对齐了。不用私有 selector——那个覆盖了根本不被调用。
private final class SearchFieldCell: NSSearchFieldCell {
    /// 自己保存一份占位文字，供 `drawInterior` 居中绘制。
    ///
    /// 不直接用 cell 的 `placeholderAttributedString`：`NSSearchFieldCell` 画它
    /// 时是贴顶的（实测文字中心 70，框中心 75），而且把属性设成 nil 也拦不住——
    /// 它会回退到内部的 `placeholderString` 再画一份。所以位置完全由这里接管。
    var myPlaceholder: NSAttributedString?

    /// 编辑中不画占位；未编辑时按墨迹范围垂直居中画。
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // super 会画一份贴顶的占位：光把 placeholderAttributedString 设 nil
        // 拦不住，它会回退到 placeholderString 再画一份（实测多出的灰色文字
        // 中心比正确位置高 9pt）。两个一起清掉，位置交给下面自己算。
        let savedAttr = placeholderAttributedString
        let savedString = placeholderString
        placeholderAttributedString = nil
        placeholderString = ""

        super.drawInterior(withFrame: cellFrame, in: controlView)

        placeholderAttributedString = savedAttr
        placeholderString = savedString

        guard (controlView as? NSTextField)?.currentEditor() == nil,
              let placeholder = myPlaceholder,
              let field = controlView as? NSTextField,
              field.stringValue.isEmpty else { return }

        let text = searchTextRect(forBounds: cellFrame)
        // 墨迹范围：boundingRect 返回的高度和 origin.y 都是相对基线盒的，
        // 直接用它的 height 居中，不要减 origin.y（那会把偏移抵消掉）。
        let ink = placeholder.boundingRect(
            with: NSSize(width: text.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let y = text.origin.y + (text.height - ink.height) / 2
        placeholder.draw(at: NSPoint(x: text.origin.x, y: y))
    }

    override func select(withFrame rect: NSRect, in view: NSView,
                         editor textObj: NSText, delegate: Any?,
                         start selStart: Int, length selLength: Int) {
        let text = searchTextRect(forBounds: rect)

        // 高度必须用**文字行高**并垂直居中，不能用整个 rect.height：
        // field editor 从 frame 顶部开始排文字，给它 34pt 高就会把光标顶到
        // 框的上边缘（实测光标 y 59..72，框是 57..93）。
        let font = self.font ?? NSFont.systemFont(ofSize: 13.5)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let frame = NSRect(x: text.origin.x,
                           y: rect.origin.y + (rect.height - lineHeight) / 2,
                           width: max(0, rect.maxX - text.origin.x),
                           height: lineHeight)
        super.select(withFrame: frame, in: view, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
