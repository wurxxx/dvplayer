using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DvPlayer.Player;

/// <summary>
/// 把子进程绑到当前进程的 Job Object 上：DvPlayer 退出（包括崩溃、被结束）
/// 时，Windows 会连带结束这些子进程。
///
/// 只靠 <c>Process.Kill</c> 不够：应用被强杀或异常退出时收尾代码不一定跑得完，
/// 播放器的 mpv 就会留在后台继续占着 GPU 和端口。
/// </summary>
internal static class ChildProcessJob
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x2000;

    private static readonly object Gate = new();
    private static IntPtr _job;

    public static void Assign(Process process)
    {
        try
        {
            lock (Gate)
            {
                if (_job == IntPtr.Zero)
                {
                    _job = CreateJobObject(IntPtr.Zero, null);
                    if (_job == IntPtr.Zero)
                    {
                        return;
                    }

                    var info = new JobObjectExtendedLimitInformation_
                    {
                        BasicLimitInformation = new JobObjectBasicLimitInformation
                        {
                            LimitFlags = JobObjectLimitKillOnJobClose,
                        },
                    };

                    SetInformationJobObject(
                        _job,
                        JobObjectExtendedLimitInformation,
                        ref info,
                        (uint)Marshal.SizeOf<JobObjectExtendedLimitInformation_>());
                }

                AssignProcessToJobObject(_job, process.Handle);
            }
        }
        catch (Exception)
        {
            // 分配失败不影响播放；Stop() 仍会尝试主动结束。
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation_
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int infoClass,
        ref JobObjectExtendedLimitInformation_ info,
        uint infoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
