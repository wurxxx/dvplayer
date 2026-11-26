import AppKit

/// 当前显示器的 tone map 目标。
///
/// 为什么要单独算：macOS 走 render API 时没有 swapchain，`libmpv_gpu_next.c`
/// 给 gpu-next 的 `display_csp` 是空的，gpu-next 只能回落到 203 nit 的 SDR
/// 参考白——同一部 HDR 片会比 Windows（DXGI 会报显示器 SDR 白点）暗一大截。
///
/// macOS 没有公开 API 能直接拿到显示器的 SDR 白点 nits：
/// - `NSScreen` 只给 EDR headroom（相对 SDR 白的倍数，1.0 = 纯 SDR）；
/// - `CGDisplay` 的 ICC profile 里通常没有 `lumi` tag（实测 DELL D2421H 没有）；
/// - `IODisplay` 的亮度是 0–1 的相对值，不是 nits。
///
/// 业界约定（Apple 的 EDR 规范、Windows DXGI 的 SDR 白点）都是 100 nit 左右，
/// 所以自动值取 100；用户可以在设置里覆盖（个别显示器观感不同）。EDR 只影响
/// HDR 峰值：真做 EDR 直通时，峰值 = `toneMapPeak * headroom`，SDR 白点本身不变。
struct DisplayTarget: Equatable {
    /// 屏幕名，日志用。
    let screenName: String
    /// 相对 SDR 白的 EDR 倍数：1.0 = 纯 SDR。
    let edrHeadroom: Double
    /// 自动的 SDR 参考白（nits）。
    let sdrWhite: Double
    /// 用户在设置里微调的亮度参考（nits）；nil / 0 = 自动。
    let overrideNits: Double?

    /// 显示器理论上能到的最亮值（nits）。当前没有 EDR 输出，先留着给以后。
    var peak: Double { toneMapPeak * max(1.0, edrHeadroom) }

    /// 是否有 EDR（HDR）余量。
    var isHDR: Bool { edrHeadroom > 1.0 }

    /// 是否用用户覆盖值。
    var usesOverride: Bool { overrideNits != nil }

    /// 当前渲染路径（NSOpenGLView 8bit SDR）的 tone map 目标。
    ///
    /// 输出的是 SDR 编码，WindowServer 按 SDR 白显示，所以即使屏幕有 EDR，
    /// 目标也应该是 SDR 白点，而不是 EDR 峰值。等 `MpvVideoView` 支持
    /// `wantsExtendedDynamicRangeContent` 之后，这里才改成 `peak`。
    var toneMapPeak: Double {
        if let overrideNits, overrideNits > 0 { return overrideNits }
        return sdrWhite
    }

    static func current(for screen: NSScreen? = nil,
                        overrideNits: Int? = nil) -> DisplayTarget {
        let s = screen ?? NSScreen.main
        let headroom = s?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        let override: Double? = {
            guard let nits = overrideNits, nits > 0 else { return nil }
            return Double(nits)
        }()
        return DisplayTarget(screenName: s?.localizedName ?? "未知屏幕",
                             edrHeadroom: headroom,
                             sdrWhite: 100,
                             overrideNits: override)
    }
}
