// Native helpers for the Windows side of claude-rc, loaded with Add-Type by
// src/lib.ps1 and by the installed wrapper (as claude-rc-native.cs). Keep this
// file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
//
// Windows has no lsof, and Win32_Process does not expose a process's working
// directory, so both the command line and the cwd are read straight from the
// target's PEB. This works for any 64-bit process owned by the same user, which
// is every `claude rc` this project cares about (see docs/findings.md).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeRc {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_BASIC_INFORMATION {
            public IntPtr ExitStatus;
            public IntPtr PebBaseAddress;
            public IntPtr AffinityMask;
            public IntPtr BasePriority;
            public IntPtr UniqueProcessId;
            public IntPtr InheritedFromUniqueProcessId;
        }

        [DllImport("ntdll.dll")]
        static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION pbi, int len, out int ret);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr h);
        [DllImport("shell32.dll", SetLastError = true)]
        static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmd, out int argc);
        [DllImport("kernel32.dll")]
        static extern IntPtr LocalFree(IntPtr p);
        [DllImport("kernel32.dll")]
        static extern bool FreeConsole();
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AttachConsole(uint pid);
        [DllImport("kernel32.dll")]
        static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);

        const int PROCESS_QUERY_INFORMATION = 0x0400;
        const int PROCESS_VM_READ = 0x0010;

        // x64 offsets: PEB.ProcessParameters, and in RTL_USER_PROCESS_PARAMETERS
        // CurrentDirectory.DosPath and CommandLine (both UNICODE_STRING).
        const int PEB_PROCESS_PARAMETERS = 0x20;
        const int PARAMS_CURRENT_DIRECTORY = 0x38;
        const int PARAMS_COMMAND_LINE = 0x70;

        static IntPtr ReadPtr(IntPtr h, IntPtr addr) {
            byte[] b = new byte[8]; IntPtr n;
            if (!ReadProcessMemory(h, addr, b, (IntPtr)8, out n)) return IntPtr.Zero;
            return (IntPtr)BitConverter.ToInt64(b, 0);
        }

        static string ReadUnicodeString(IntPtr h, IntPtr addr) {
            byte[] us = new byte[16]; IntPtr n;
            if (!ReadProcessMemory(h, addr, us, (IntPtr)16, out n)) return null;
            int len = BitConverter.ToUInt16(us, 0);
            IntPtr buf = (IntPtr)BitConverter.ToInt64(us, 8);
            if (len == 0 || buf == IntPtr.Zero) return "";
            byte[] s = new byte[len];
            if (!ReadProcessMemory(h, buf, s, (IntPtr)len, out n)) return null;
            return Encoding.Unicode.GetString(s);
        }

        // Reads one UNICODE_STRING field of the process parameters, or null.
        static string ReadParam(int pid, int offset) {
            if (IntPtr.Size != 8) return null;
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) return null;
            try {
                PROCESS_BASIC_INFORMATION pbi = new PROCESS_BASIC_INFORMATION(); int ret;
                if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return null;
                IntPtr pp = ReadPtr(h, pbi.PebBaseAddress + PEB_PROCESS_PARAMETERS);
                if (pp == IntPtr.Zero) return null;
                return ReadUnicodeString(h, pp + offset);
            } finally { CloseHandle(h); }
        }

        public static string GetCwd(int pid) { return ReadParam(pid, PARAMS_CURRENT_DIRECTORY); }
        public static string GetCommandLine(int pid) { return ReadParam(pid, PARAMS_COMMAND_LINE); }

        // Splits a command line exactly the way the C runtime does.
        public static string[] SplitArgs(string cmd) {
            if (string.IsNullOrEmpty(cmd)) return new string[0];
            int argc;
            IntPtr argv = CommandLineToArgvW(cmd, out argc);
            if (argv == IntPtr.Zero) return new string[0];
            try {
                string[] r = new string[argc];
                for (int i = 0; i < argc; i++)
                    r[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
                return r;
            } finally { LocalFree(argv); }
        }

        // Canonical form for comparing directories: full path, backslashes, no
        // trailing separator. Comparisons using it must ignore case.
        public static string NormalizeDir(string p) {
            if (string.IsNullOrEmpty(p)) return "";
            string full = Path.GetFullPath(p.Replace('/', '\\'));
            string root = Path.GetPathRoot(full);
            if (full.Length > root.Length) full = full.TrimEnd('\\');
            return full;
        }

        // True when argv is a Remote Control server: argv0 is the claude binary
        // and argv1 is `rc` or `remote-control`. Matching argv fields, never a
        // substring, so a command that merely mentions "claude rc" does not count.
        public static bool IsRcServer(string[] argv) {
            if (argv.Length < 2) return false;
            string exe = Path.GetFileName(argv[0]).ToLowerInvariant();
            if (exe != "claude" && exe != "claude.exe") return false;
            return argv[1] == "rc" || argv[1] == "remote-control";
        }

        // PIDs of running Remote Control servers, optionally only those whose
        // working directory is <dir>.
        public static int[] RcServers(string dir) {
            string want = string.IsNullOrEmpty(dir) ? null : NormalizeDir(dir);
            List<int> r = new List<int>();
            foreach (Process p in Process.GetProcessesByName("claude")) {
                try {
                    if (!IsRcServer(SplitArgs(GetCommandLine(p.Id)))) continue;
                    if (want != null) {
                        string cwd = GetCwd(p.Id);
                        if (cwd == null || !string.Equals(NormalizeDir(cwd), want, StringComparison.OrdinalIgnoreCase)) continue;
                    }
                    r.Add(p.Id);
                } catch { } finally { p.Dispose(); }
            }
            return r.ToArray();
        }

        // Sends Ctrl+C to every process attached to <pid>'s console, which is how
        // a `claude rc` is stopped cleanly on Windows. Must run in a throwaway
        // process: it detaches the caller from its own console. Fails once the
        // console host is gone (error 233), so call it before stopping the task.
        public static string SendCtrlC(int pid) {
            FreeConsole();
            if (!AttachConsole((uint)pid)) return "attach failed: " + Marshal.GetLastWin32Error();
            SetConsoleCtrlHandler(IntPtr.Zero, true);
            if (!GenerateConsoleCtrlEvent(0, 0)) return "generate failed: " + Marshal.GetLastWin32Error();
            return "ok";
        }
    }
}
