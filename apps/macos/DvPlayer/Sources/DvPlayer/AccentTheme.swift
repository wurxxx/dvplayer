import SwiftUI
import AppKit

/// 预设主题色：都取自 UI 配色库里验证过的强调色（影视 / 音频 / 游戏场景）。
///
/// 只看这一个主色（填充色），文字色、选中块底、填充上的文字都由
/// `AccentPalette` 按色相派生，换颜色不用手调一整套色板。
enum AccentTheme: String, CaseIterable, Identifiable {
    case amber, orange, red, purple, blue, cyan, green

    var id: String { rawValue }

    var title: String {
        switch self {
        case .amber: return "琥珀"
        case .orange: return "橙"
        case .red: return "玫红"
        case .purple: return "紫"
        case .blue: return "蓝"
        case .cyan: return "青"
        case .green: return "绿"
        }
    }

    var hex: UInt32 {
        switch self {
        case .amber: return 0xFFB020   // 现有默认
        case .orange: return 0xF97316  // 深色音频场景的暖橙
        case .red: return 0xE11D48     // 影院深色 + 播放红
        case .purple: return 0x7C3AED  // 游戏霓虹紫
        case .blue: return 0x2563EB    // 流媒体 / 社交蓝
        case .cyan: return 0x0891B2    // 编辑器滤镜青
        case .green: return 0x22C55E   // 音乐 / 仪表盘绿
        }
    }

    var fill: NSColor { NSColor(hex: hex) }
}

/// 主题色的存储：预设 id，或 `custom:RRGGBB`。
///
/// 和外观一样存在 UserDefaults（`accentColor`），不进共享核心的 AppSettings。
enum AccentSettings {
    static let defaultsKey = "accentColor"

    static var stored: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? AccentTheme.amber.rawValue
    }

    /// 当前是不是某个预设（是的话色块上打勾）。
    static var preset: AccentTheme? {
        AccentTheme(rawValue: stored)
    }

    /// 当前主色：预设或自定义。
    static var fill: NSColor {
        if let preset { return preset.fill }
        if let hex = customHex { return NSColor(hex: hex) }
        return AccentTheme.amber.fill
    }

    /// 自定义色的 24 位值；当前是预设时为 nil。
    static var customHex: UInt32? {
        let prefix = "custom:"
        guard stored.hasPrefix(prefix) else { return nil }
        return UInt32(stored.dropFirst(prefix.count), radix: 16)
    }

    static func selectPreset(_ theme: AccentTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: defaultsKey)
    }

    static func selectCustom(_ hex: UInt32) {
        UserDefaults.standard.set(String(format: "custom:%06X", hex), forKey: defaultsKey)
    }

    /// 自检：`DVPLAYER_ACCENT=blue` 或 `DVPLAYER_ACCENT=3B82F6`，只影响这次运行。
    /// 只读一次环境变量，动态色每次解析时不用重复取。
    static let environmentOverride: UInt32? = {
        guard let raw = ProcessInfo.processInfo.environment["DVPLAYER_ACCENT"] else { return nil }
        return parse(raw)
    }()

    /// `blue` / `3B82F6` / `#3B82F6` → 24 位主色。
    static func parse(_ raw: String) -> UInt32? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if let theme = AccentTheme(rawValue: value.lowercased()) { return theme.hex }
        return UInt32(value, radix: 16)
    }

    /// 自检：`DVPLAYER_ACCENT_SWITCH=blue@8` —— 启动 8 秒后再换主题色，
    /// 用来验证「运行中换主题色」整窗即时重绘（和外观的 SWITCH 自检同一条路）。
    static func scheduleSwitchFromEnvironment() {
        guard let spec = ProcessInfo.processInfo.environment["DVPLAYER_ACCENT_SWITCH"],
              let at = spec.lastIndex(of: "@") else { return }
        let raw = String(spec[spec.startIndex..<at])
        guard let hex = parse(raw) else { return }
        let delay = Double(spec[spec.index(after: at)...]) ?? 8
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, delay)) {
            if let theme = AccentTheme(rawValue: name) {
                selectPreset(theme)
            } else {
                selectCustom(hex)
            }
            Theme.refreshWindows()
        }
    }

    static var effectiveFill: NSColor {
        if let hex = environmentOverride { return NSColor(hex: hex) }
        return fill
    }
}

/// 从主色派生其余档位。
///
/// 用 HSL 算，而不是给每个预设手调一套：主色换了以后，
/// 「文字 / 图标」「选中块底」「填充上的文字」都能自动达到可读的对比度。
enum AccentPalette {
    private struct HSL {
        var h: Double   // 0..<360
        var s: Double   // 0...1
        var l: Double   // 0...1
    }

    /// 填充上的文字：深字和白字里取对比度更高的那个。
    /// 不能只看「亮底深字」的固定阈值——橙 `F97316`、绿 `22C55E` 用白字
    /// 只有 2.3–2.8:1，换成深字才过 AA，而深蓝反过来要白字。
    static func onFill(_ fill: NSColor) -> NSColor {
        let dark = NSColor(hex: 0x1A1200)
        return contrast(dark, fill) >= contrast(.white, fill) ? dark : .white
    }

    /// 文字 / 图标 / 细描边：浅色下压到页面底色 ≥4.5:1，深色下提到卡片底 ≥4.5:1。
    /// 按对比度反推而不是写死 L：用户自定义的颜色再浅再暗也能读。
    /// 浅色取页面底色 `F4F5F7`（比卡片白更暗，是最坏情况），深色取卡片 `1F1F27`
    /// （比页面底色更亮，也是最坏情况）。
    static func ink(_ fill: NSColor, light: Bool) -> NSColor {
        var hsl = toHSL(fill)

        if light {
            let page = NSColor(hex: 0xF4F5F7)
            hsl.l = min(hsl.l, 0.42)
            var color = fromHSL(hsl)
            while hsl.l > 0.04 && contrast(color, page) < 4.5 {
                hsl.l = max(0.04, hsl.l - 0.01)
                color = fromHSL(hsl)
            }
            return color
        }

        hsl.s *= 0.9
        hsl.l = max(hsl.l, 0.5)
        let surface = NSColor(hex: 0x1F1F27)
        var color = fromHSL(hsl)
        while hsl.l < 0.96 && contrast(color, surface) < 4.5 {
            hsl.l = min(0.96, hsl.l + 0.01)
            color = fromHSL(hsl)
        }
        return color
    }

    /// 选中块的底：浅色下接近白，深色下接近黑，保留一点色相。
    static func soft(_ fill: NSColor, light: Bool) -> NSColor {
        var hsl = toHSL(fill)
        hsl.l = light ? 0.95 : 0.14
        hsl.s = light ? hsl.s * 0.85 : hsl.s * 0.6
        return fromHSL(hsl)
    }

    // MARK: - 工具

    /// WCAG 对比度（1…21）。
    private static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func lin(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent)
            + 0.7152 * lin(c.greenComponent)
            + 0.0722 * lin(c.blueComponent)
    }

    private static func toHSL(_ color: NSColor) -> HSL {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0.0001 else { return HSL(h: 0, s: 0, l: l) }

        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if maxV == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return HSL(h: h, s: s, l: l)
    }

    private static func fromHSL(_ hsl: HSL) -> NSColor {
        let c = (1 - abs(2 * hsl.l - 1)) * hsl.s
        let x = c * (1 - abs((hsl.h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = hsl.l - c / 2
        var r = 0.0, g = 0.0, b = 0.0
        switch hsl.h {
        case ..<60: r = c; g = x
        case ..<120: r = x; g = c
        case ..<180: g = c; b = x
        case ..<240: g = x; b = c
        case ..<300: r = x; b = c
        default: r = c; b = x
        }
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
