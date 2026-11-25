using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

namespace DvPlayer.Services;

/// <summary>
/// 播放期间阻止系统关屏 / 休眠。
///
/// 为什么需要：Windows 默认在闲置一段时间后关屏，再久一点进入睡眠。
/// 看电影时既不动鼠标也不敲键盘，就会被当成「人走了」。系统一旦睡眠，
/// 网络会断、解码线程被挂起，回来时要么缓冲半天要么直接卡死。
///
/// 用的是 <c>SetThreadExecutionState</c>：
///
/// - <c>ES_CONTINUOUS</c>：必须带上，否则只是「这一次」有效，下次
///   系统检查时又变回可睡眠。
/// - <c>ES_DISPLAY_REQUIRED</c>：不关屏。这是用户真正感知到的那一条
///   —— 屏幕黑了会以为播放器出问题了。
/// - <c>ES_SYSTEM_REQUIRED</c>：不进入系统睡眠。只挡关屏是不够的，
///   有些电源计划会关屏但继续睡眠。
///
/// **两个坑，改这个类之前先看清楚**：
///
/// 1. 作用范围是**调用它的线程**。必须和 <see cref="Stop"/> 在同一个线程上
///    调用，否则清除不掉。本类要求在 UI 线程使用（WPF 的 Dispatcher）。
/// 2. 它是**幂等**的，不是计数的：重复 <see cref="Start"/> 不会叠加，
///    一次 <see cref="Stop"/> 就恢复。调用方负责记住「我现在是不是已经
///    在阻止了」，只在状态变化时调——不要每次属性变化都无脑 Start。
///
/// 另外它挡不住「用户手动点关机」和「合上盖子」（除非电源计划里把合盖
/// 设成「不采取任何操作」）—— 那是用户明确意图，不该拦。
/// </summary>
public static class SleepBlocker
{
    [Flags]
    private enum ExecutionState : uint
    {
        // 让上面两条要求持续有效，而不是只影响下一次系统检查。
        Continuous = 0x80000000,
        // 系统需要保持运行（不睡眠）。
        SystemRequired = 0x00000001,
        // 显示器需要保持开启（不关屏）。
        DisplayRequired = 0x00000002,
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern ExecutionState SetThreadExecutionState(ExecutionState esFlags);

    /// <summary>
    /// 开始阻止关屏 + 睡眠。重复调用是空操作（不是计数）。
    /// </summary>
    public static void Start()
    {
        var result = SetThreadExecutionState(
            ExecutionState.Continuous |
            ExecutionState.DisplayRequired |
            ExecutionState.SystemRequired);

        if (result == 0)
        {
            // 拿不到不该让播放失败：退化成「可能关屏」而已。
            Trace.Write("SleepBlocker: SetThreadExecutionState 失败 " +
                        Marshal.GetLastWin32Error());
            return;
        }

        Trace.Write("SleepBlocker: 已阻止关屏 / 睡眠");
    }

    /// <summary>
    /// 释放阻止，恢复系统正常的关屏 / 睡眠行为。重复调用是空操作。
    /// </summary>
    public static void Stop()
    {
        // 传 Continuous 单独一个值 = 清除之前的所有要求。
        SetThreadExecutionState(ExecutionState.Continuous);
        Trace.Write("SleepBlocker: 已恢复系统关屏 / 睡眠");
    }
}
