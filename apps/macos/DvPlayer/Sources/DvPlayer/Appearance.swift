import AppKit
import Foundation

/// 外观：跟随系统 / 深色 / 浅色。
///
/// 这是纯 UI 偏好，存在 UserDefaults（`appearance`），不进共享核心的 AppSettings：
/// 核心那套设置是两端共用的播放配置，外观只影响这台机器怎么画。
/// 切 NSApp.appearance 之后，色板里的动态颜色（Theme）会在下一次绘制时自动取新值。
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    static var current: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// 应用到整个 App。`.system` 交回系统（nil 即跟随）。
    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    /// 自检：`DVPLAYER_APPEARANCE_SWITCH=light@8` —— 启动 8 秒后再切到浅色，
    /// 用来验证「运行中换外观」整窗即时重绘（不是只有启动时生效）。
    static func scheduleSwitchFromEnvironment() {
        guard let spec = ProcessInfo.processInfo.environment["DVPLAYER_APPEARANCE_SWITCH"],
              let at = spec.lastIndex(of: "@") else { return }
        let raw = String(spec[spec.startIndex..<at]).lowercased()
        let delay = Double(spec[spec.index(after: at)...]) ?? 8
        guard let mode = Appearance(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, delay)) {
            mode.apply()
        }
    }

    /// 自检：`DVPLAYER_APPEARANCE=light|dark|system`，只影响这次运行，不写回设置。
    static var fromEnvironment: Appearance? {
        guard let value = ProcessInfo.processInfo.environment["DVPLAYER_APPEARANCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return nil }
        return Appearance(rawValue: value)
    }
}
