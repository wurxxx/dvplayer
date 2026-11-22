# Run a command in the active console session (the logged-in desktop), from an
# elevated SSH / service session.
#
# Why: D3D11 / WPF rendering needs the interactive user session;
# in session 0 the D3D11 swapchain cannot be created (0x887A0022).
#
# Two ways to get the interactive user's token:
#   - running as SYSTEM (preferred): WTSQueryUserToken(active console session)
#   - running as an elevated admin: duplicate explorer.exe's primary token
#
# Usage (direct, admin):
#   powershell -ExecutionPolicy Bypass -File scripts\windows\run-in-session.ps1 `
#       -CommandLine 'cmd.exe /c "D:\path\job.bat > D:\path\job.log 2>&1"'
#
# Usage from a SYSTEM scheduled task (needed when the admin path cannot create
# a process on winsta0\default):
#   schtasks /create /tn DvInteractive /tr "powershell ... run-in-session.ps1 -CommandLine ..." /sc once /st 23:59 /ru SYSTEM /f
#   schtasks /run /tn DvInteractive

param(
    [Parameter(Mandatory = $true)]
    [string]$CommandLine
)

$ErrorActionPreference = 'Stop'

if (-not ('SessionRunner' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class SessionRunner
{
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint TOKEN_ASSIGN_PRIMARY = 0x0001;
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint MAXIMUM_ALLOWED = 0x02000000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        public LUID_AND_ATTRIBUTES Privileges;
    }

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(uint sessionId, out IntPtr token);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(
        IntPtr existing, uint access, IntPtr attrs, int impLevel, int tokenType, out IntPtr newToken);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr token, bool inherit);

    [DllImport("userenv.dll")]
    private static extern bool DestroyEnvironmentBlock(IntPtr env);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUser(
        IntPtr token, string appName, string cmdLine, IntPtr pa, IntPtr ta, bool inherit,
        uint creationFlags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint bufferLength,
        IntPtr previousState, IntPtr returnLength);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private static void EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(Process.GetCurrentProcess().Handle,
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
            return;

        LUID luid;
        if (LookupPrivilegeValue(null, name, out luid))
        {
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Privileges.Luid = luid;
            tp.Privileges.Attributes = 2; // SE_PRIVILEGE_ENABLED
            AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }
        CloseHandle(token);
    }

    private static string StartWith(IntPtr primary, string commandLine)
    {
        IntPtr env = IntPtr.Zero;
        CreateEnvironmentBlock(out env, primary, false);

        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        si.lpDesktop = "winsta0\\default";

        PROCESS_INFORMATION pi;
        bool ok = CreateProcessAsUser(primary, null, commandLine, IntPtr.Zero, IntPtr.Zero,
            false, CREATE_UNICODE_ENVIRONMENT, env, @"C:\Windows", ref si, out pi);
        int error = Marshal.GetLastWin32Error();

        if (env != IntPtr.Zero) DestroyEnvironmentBlock(env);
        if (!ok) return null;

        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return "started pid=" + pi.dwProcessId;
    }

    public static string Launch(string commandLine)
    {
        uint session = WTSGetActiveConsoleSessionId();
        if (session == 0xFFFFFFFF)
            return "no active console session";

        EnablePrivilege("SeAssignPrimaryTokenPrivilege");
        EnablePrivilege("SeIncreaseQuotaPrivilege");
        EnablePrivilege("SeTcbPrivilege");
        EnablePrivilege("SeDebugPrivilege");

        // Running as SYSTEM: WTSQueryUserToken gives the real interactive token.
        IntPtr userToken;
        if (WTSQueryUserToken(session, out userToken))
        {
            string started = StartWith(userToken, commandLine);
            CloseHandle(userToken);
            if (started != null) return started + " via WTSQueryUserToken";
        }

        // Fallback: duplicate explorer.exe's primary token.
        Process explorer = null;
        foreach (Process p in Process.GetProcessesByName("explorer"))
        {
            if ((uint)p.SessionId == session) { explorer = p; break; }
        }
        if (explorer == null)
            return "no explorer.exe in session " + session;

        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, explorer.Id);
        if (process == IntPtr.Zero)
            return "OpenProcess failed: " + Marshal.GetLastWin32Error();

        IntPtr token;
        if (!OpenProcessToken(process, TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY, out token))
            return "OpenProcessToken failed: " + Marshal.GetLastWin32Error();

        IntPtr primary;
        if (!DuplicateTokenEx(token, MAXIMUM_ALLOWED, IntPtr.Zero, 2, 1, out primary))
            return "DuplicateTokenEx failed: " + Marshal.GetLastWin32Error();

        string result = StartWith(primary, commandLine);
        CloseHandle(primary);
        CloseHandle(token);
        CloseHandle(process);

        return result ?? "CreateProcessAsUser failed";
    }
}
"@
}

$result = [SessionRunner]::Launch($CommandLine)
Write-Host $result
if ($result -notlike 'started*') { exit 1 }
