import Foundation
import IOKit.pwr_mgt

/// 播放期间阻止系统锁屏 / 休眠。
///
/// 为什么需要：macOS 默认在闲置一段时间后熄屏，再久一点进入睡眠。
/// 看电影时既不动鼠标也不敲键盘，就会被当成「人走了」。系统一旦睡眠，
/// 网络会断、mpv 的解码线程被挂起，回来时要么缓冲半天要么直接卡死。
///
/// 用的是 `IOPMAssertionCreateWithName` 的 **两个** 断言：
///
/// - `PreventUserIdleDisplaySleep`：不熄屏。这是用户真正感知到的那一条
///   —— 屏幕黑了会以为播放器出问题了。
/// - `PreventUserIdleSystemSleep`：不进入系统睡眠。只挡熄屏是不够的，
///   有些场景（合上盖子之外的超时睡眠）屏幕已经亮着但系统还是会睡。
///
/// 为什么不用 `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)`：
/// 那个 API 需要 App 在前台才可靠，而且不能单独表达「只挡系统睡眠」；
/// IOKit 的断言是系统级电源管理的标准做法，播放器（包括 mpv 自己）都用它。
///
/// 生命周期：`start()` / `stop()` 成对调用，内部计数保护，重复调用安全。
/// 断言只在**真正在播**时持有——暂停时释放，让系统按用户设置正常熄屏，
/// 这是用户对「暂停」的预期（暂停了还亮着屏幕很怪）。
@MainActor
final class SleepBlocker {
    /// 当前持有的断言 id。`nil` 表示没有阻止。
    private var assertionIDs: [IOPMAssertionID] = []

    /// 开始阻止熄屏 + 休眠。已经在阻止时是空操作。
    func start(reason: String = "DvPlayer 正在播放") {
        guard assertionIDs.isEmpty else { return }

        var ids: [IOPMAssertionID] = []
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
                     kIOPMAssertionTypePreventUserIdleSystemSleep as String] {
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id)
            if status == kIOReturnSuccess {
                ids.append(id)
            } else {
                // 拿不到断言不该让播放失败：退化成「可能熄屏」而已。
                NSLog("[Sleep] 断言失败 type=\(type) status=\(status)")
            }
        }
        assertionIDs = ids
        if !ids.isEmpty {
            NSLog("[Sleep] 已阻止熄屏 / 休眠（\(ids.count) 个断言）")
        }
    }

    /// 释放断言，恢复系统正常的熄屏 / 睡眠行为。没有持有时是空操作。
    func stop() {
        guard !assertionIDs.isEmpty else { return }
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs.removeAll()
        NSLog("[Sleep] 已恢复系统熄屏 / 休眠")
    }

    deinit {
        // deinit 不在 MainActor 上，但 IOPMAssertionRelease 是线程安全的，
        // 这里直接释放，避免 App 退出时把断言漏给系统。
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
    }
}
