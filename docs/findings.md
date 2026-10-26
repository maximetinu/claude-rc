# Findings

Each entry says how it was checked, so a future reader can tell evidence from
assumption. The first part was observed on a Mac (macOS 26.5.2, Claude Code
2.1.246, later 2.1.303); [the Windows part](#windows) on a Windows 11 PC
(10.0.26200, Claude Code 2.1.303). Some Windows findings correct macOS ones;
those entries say so. The Windows findings that apply to macOS were re-checked
on a Mac on 2026-10-19 (macOS 26.6.2, Claude Code 2.1.304); each entry says
what was found.

## `claude rc` needs no TTY

**Verified.** Started with `nohup ... </dev/null` and again under launchd with
`TERM` unset; both reached `Connected · <host> · HEAD` and printed a working
`claude.ai/code?environment=...` URL. There is no interactive requirement, so a
LaunchAgent is a legitimate way to run it.

## stdout is a redrawing TUI, stderr carries the real errors

**Verified.** With stdout and stderr redirected to separate files, a failing run
put **0 bytes** on stdout and the whole error on stderr (exit code 1).

The status display repaints roughly every 5–8 seconds, ~450 bytes per frame
(≈7 MB/day). That is why the wrapper sends stdout to `/dev/null` and keeps only
stderr: the log stays small without losing any diagnostic.

## Workspace trust blocks startup, and launchd cannot answer the dialog

**Verified.** In an untrusted directory:

```
Error: Workspace not trusted. Please run `claude` in <dir> first to review and
accept the workspace trust dialog.
```

Under launchd nobody can accept it, so the agent would fail at *every* login
with nothing on screen. `install.sh` and `doctor.sh` therefore check
`hasTrustDialogAccepted` in `~/.claude.json` up front. Trust persists on disk,
so it survives reboots once granted.

## `pgrep -f` silently misses processes on macOS

**Verified, and it cost a rewrite.** `pgrep -f "claude rc"` returned nothing
while `ps` clearly listed `14468 claude rc`. The same happened for the Ghostty
process. `ps -Ao pid=,command=` saw both.

Matching must also be done on **argv fields**, not as a substring — an early
version matched any command line that merely *mentioned* "claude rc", so the
duplicate guard triggered on unrelated shell commands (including the test
harness checking for it). The working form:

```sh
ps -Ao pid=,command= | awk '$2 ~ /(^|\/)claude$/ && ($3 == "rc" || $3 == "remote-control")'
```

## `zsh -lc` does not source `.zshrc`

**Verified.** The PATH captured inside the launchd job contained everything from
`.zprofile` (homebrew, MacPorts, …) but **not** `~/.local/bin`, which on this
machine is added at `.zshrc:327`. A login shell sources `.zprofile`/`.zlogin`;
`.zshrc` is for interactive shells only.

The wrapper therefore prepends `~/.local/bin` itself, and never relies on PATH
to find the binary.

## `~/.local/bin/claude` is a symlink to a versioned binary

**Verified.** It points at `~/.local/share/claude/versions/<version>` and that
target rotates on auto-update (it had been rewritten hours earlier).

An early version of the installer called `realpath` and baked
`.../versions/2.1.246` into the plist. That would have kept working until the
next update and then broken silently. `install.sh` now refuses any path
containing `/versions/`.

## Two servers in the same directory coexist

**Superseded**: a second server is now refused, on Windows (2.1.303) and on
macOS (2.1.304) — see
[below](#claude-code-refuses-a-second-server-in-the-same-directory). The
original observation, on 2.1.246:

**Verified.** A second `claude rc` started in a directory that already had one
connected fine and reported `Capacity: 1/32` independently. Duplicates are
untidy, not dangerous — which is why the guard *waits* rather than erroring.

## Sessions are children of the server

**Verified** by walking the process tree: a Claude Code session started through
Remote Control appears as a descendant of the `claude rc` process. Killing the
server kills the sessions under it, so `uninstall.sh` does not kill servers it
did not start unless asked (`--kill-server`).

**Correction, verified on 2026-10-19:** `launchctl bootout` terminates the job,
so unloading an agent *does* stop the server that agent started, and its
sessions. `uninstall.sh --label com.claude-rc.claude-rc` removed pid 56182
within seconds with nothing else sending a signal. The old "left running"
message was a race: it checked before the process had exited. The same applies
to `install.sh`, which boots out the agent before loading the new plist.

## Keychain access works under launchd without a prompt

**Verified** in this account: a launchd-started server authenticated and reached
`Connected` with no dialog. A LaunchAgent runs inside the user's session after
login, so the keychain is already unlocked.

## LaunchAgent, not LaunchDaemon

**Reasoned, not tested.** A LaunchDaemon runs at boot as root, before login and
without the user's keychain, so `claude` could not authenticate. A LaunchAgent
starts at *login* instead. For "starts when I power on the Mac", combine it with
automatic login in System Settings.

## Trust in a parent directory covers its children

**Verified** on 2026-10-19 (Claude Code 2.1.303). `~/git/myproject` had no
entry of its own in `~/.claude.json`, but `~/git` was trusted. `claude rc`
started there with stdin from `/dev/null` and reached `Ready · myproject`
with nothing on stderr. `workspace_trusted` therefore walks up the parents.

**Refined on Windows:** the walk stops at the git repository root — see
[below](#parent-trust-stops-at-the-git-repository-root). Verified on macOS
too, in the same entry.

## `--no-create-session-in-dir` keeps idle servers small

**Measured** on 2026-10-19. The default server in `~/git` pre-creates one
session; its process tree (server, session, the session's MCP servers) used
about 240 MB RSS. Fourteen servers started with `--no-create-session-in-dir`
used 1.3 GB RSS in total, about 90 MB each, with no child processes until a
session is opened. A server started this way still registers its environment:
its status screen showed `Ready · <dir>` and a `claude.ai/code?environment=...`
URL.

## launchd reports `xpcproxy` for a few seconds after bootstrap

**Verified.** Installing 12 agents in a row, three were still in state
`xpcproxy` when `install.sh` checked right after `launchctl bootstrap`; a few
seconds later all were `running`. `install.sh` now waits while the state is
`xpcproxy`.

## Every agent starts after a reboot

**Verified** on 2026-10-20 (macOS 26.6.2, Claude Code 2.1.304). The Mac was
shut down with `shutdown -h` and powered on again; it boots to the login
window (no automatic login). After the password was typed, all 15 agents
logged a `launchd start` within 3 s of each other, each log ended in an
`exec:` line with nothing after it, and `./doctor.sh --all` exited 0 about
three minutes after boot.

## Many agents at login slow the whole desktop

**Verified** on 2026-10-25 (macOS 26, 15 agents, 12 login items). Five minutes
after login the 1-minute load average was 180 and the disk did 3000-4600
operations per second; Spotlight (Cmd+Space) was slow to react. Swap was 0 %,
so the limit was CPU and disk, not memory. All 15 agents had logged
`launchd start` in the same second (21:39:51), 20 s after login. Twenty-five
minutes after login the load average was down to 6. The wrapper now staggers
the start (see how-it-works.md). **Not yet verified:** the effect on a real
login; check the `staggered start` lines in the logs after the next reboot.

## launchd sets `XPC_SERVICE_NAME` to the job label

**Verified** with `ps eww` on a running server: `XPC_SERVICE_NAME=com.claude-rc.rallo`.
The wrapper uses it to find its own slot. Do not set this variable by hand to
test: any process started with an unknown `XPC_SERVICE_NAME` aborts at once
(exit 134), even `/bin/echo`. Test with another variable name in a scratch copy.

## Login time comes from `loginwindow`

**Verified** on 2026-10-25. With FileVault the password is typed before the
boot, so login came 33 s after `kern.boottime` (`loginwindow` owned by the user
started 21:39:31, boot 21:38:58). Boot time alone would skip the slots when the
user logs in late, so the wrapper uses the `etime` of the user's `loginwindow`
and falls back to boot time. **Assumed:** a logout and a new login start a new
`loginwindow`, so the slots apply again.

## Not verified

- Whether the server recovers on its own from sleep/wake or a long network
  outage. `KeepAlive` covers the process *dying*; it would not help a process
  that stays alive but stops being reachable. No evidence either way was
  collected, so no watchdog was built for a problem not known to exist.

# Windows

Observed on 2026-10-19 on a Windows 11 Home PC (10.0.26200), Claude Code
2.1.303 installed natively, Windows PowerShell 5.1.

## `claude rc` runs headless on Windows too

**Verified.** Started with stdin, stdout and stderr redirected to files and no
console of its own, it reached `Ready · git · HEAD` and printed a
`claude.ai/code?environment=...` URL. As on macOS, stdout carries only the
status screen and stderr stays empty on success; failures go to stderr.

## Home-directory trust is never saved

**Verified.** Started in `C:\Users\<user>`:

```
Error: Workspace not trusted. C:\Users\<user> is your home directory, and for
security home-directory trust is never saved, so running `claude` here first
won't help. Run `claude rc` from a project directory instead
```

`~/.claude.json` did list the home directory, with
`hasTrustDialogAccepted: false`. An untrusted home can therefore never become
trusted.

**Different on macOS, verified on 2026-10-19 (Claude Code 2.1.304).** On the
Mac, `~/.claude.json` lists the home directory with
`hasTrustDialogAccepted: true`, saved at some earlier time (when, and by which
version, is not known). `claude rc --no-create-session-in-dir` started in
`$HOME` with stdin from `/dev/null` reached `Ready · <user> · HEAD` with
nothing on stderr, and was still `Ready` after 30 s. A new directory directly
under `$HOME`, with no entry of its own and no trusted parent other than
`$HOME`, also reached `Ready`. So Claude Code still honours a home trust that
was saved earlier, and that trust covers the non-repo children of home.

The difference is the saved state, not the platform. `workspace_trusted`
(lib.sh) and `Test-WorkspaceTrusted` (lib.ps1) therefore return 3 only when the
home directory is *not* trusted in `~/.claude.json`, and both installers
refuse only that case. A home with saved trust passes like any other trusted
directory. Whether a current Claude Code on macOS also refuses to save a new
home trust was not checked: it needs an untrusted home and an interactive
trust dialog. The lib.sh version was checked on the Mac against both real
cases above and against a temporary `HOME` with no `~/.claude.json`, an
untrusted home and a trusted home (3, 3 and 0).

**The lib.ps1 version was verified on Windows** on 2026-10-20 (Claude Code
2.1.304). Against the real `~/.claude.json`, where the home is listed with
`hasTrustDialogAccepted: false`, `$HOME` gave 3. The trusted-home branch cannot
be reached on this PC, so a copy of `Test-WorkspaceTrusted`, with `$HOME`
replaced by a temporary folder, was run under `$ErrorActionPreference =
'Continue'` (as `doctor.ps1` runs). With no `.claude.json` the home gave 3 and
another directory 2. With the home untrusted it gave 3; trusted, it gave 0,
also when the path differed in case and had a trailing backslash. With a
corrupt `.claude.json` the home gave 3 and another directory 2. That run found
a bug, now fixed: a missing `.claude.json` made `Get-Content` raise a
non-terminating error, which `try`/`catch` does not catch, so a non-home
directory got 1 instead of 2 (see
[below](#try--catch-misses-non-terminating-errors)).

## Parent trust stops at the git repository root

**Verified** with four directories under a trusted `C:\Users\<user>\git`, which
is not a git repository itself:

| directory | git repo? | result |
|-----------|-----------|--------|
| `git\owilds-2019-backup` | no | `Ready` |
| `git\owilds\docs` | inside the trusted repo `git\owilds` | `Ready` |
| `git\owilds-2019` | yes, untrusted | `Workspace not trusted` |
| `git\claude-rc` | yes, untrusted | `Workspace not trusted` |

Trust in a parent covers non-repo children and subdirectories of a trusted
repo, but does not reach into a repo. `workspace_trusted` (lib.sh) and
`Test-WorkspaceTrusted` (lib.ps1) therefore walk up the parents and stop at the
innermost directory containing `.git`. Both were checked against this table.

**Re-checked on Windows** on 2026-10-20 (Claude Code 2.1.304) after the
home-trust change in lib.ps1. `claude rc --no-create-session-in-dir` was run in
its own headless console with stdin, stdout and stderr redirected, and read
after 12 s. `Test-WorkspaceTrusted` and the real server agreed in every case:
`claudeworkspace` (trusted, no repo) 0 and `Ready`; `git\owilds-2019-backup` 0
and `Ready`; `git\owilds-2019` 1 and `Workspace not trusted`. Each `Ready`
server was stopped with Ctrl+C sent to its console the way `Stop-Agent` does.
Its whole process tree was gone within 1 s, and no `claude.exe` was left beyond
those running before the test.

**Verified on macOS** on 2026-10-19 (Claude Code 2.1.304), with
`claude rc --no-create-session-in-dir`, stdin from `/dev/null`, stdout and
stderr to files, read after about 12 s. `~/git/test123` has trust of its own
and is not a git repository; the two subdirectories were made for the test:

| directory | git repo? | `workspace_trusted` | `claude rc` |
|-----------|-----------|---------------------|-------------|
| `~/git/test123` | no, trusted | 0 | `Ready` |
| `~/git/test123/sub` | no, no entry | 0 | `Ready` |
| `~/git/test123/subrepo` | yes (`git init`), no entry | 1 | `Workspace not trusted` |

The untrusted run exited at once with the same message as in
[the macOS trust entry](#workspace-trust-blocks-startup-and-launchd-cannot-answer-the-dialog).

## Claude Code refuses a second server in the same directory

**Verified.** With a server `Ready` in a directory, a second `claude rc` there
printed on stderr

```
Error: This folder is already served by a terminal `claude remote-control` on
this device. Stop it first.
Exiting in about 68 seconds.
```

and exited with code 1 after the announced 45–75 s. Servers in other
directories are unaffected. The wrapper's own guard is still useful: it idles
instead of logging this error every couple of minutes.

**Verified on macOS** on 2026-10-19 (Claude Code 2.1.304). With a server
`Ready` in `~/git/test123`, two more `claude rc --no-create-session-in-dir`
started there each printed the same error on stderr and nothing else. One
exited with code 1 after 57 s, the other after about 77 s. The first server
stayed `Ready`.

## A stopped server can hold its directory for about three minutes

**Measured.** After `Stop-Process -Force` on a `Ready` server, every new server
in that directory got the "already served" error for between 2 min 45 s and
3 min 10 s (polled every 30 s). A second run, under the agent, gave
2.5–3.75 min. No local file changed in `~/.claude`, `%TEMP%`, `%LOCALAPPDATA%`
or `%APPDATA%`, so the hold is most likely server-side.

On macOS a clean stop does the same: after `kill -INT` on a `Ready` server
started with `--no-create-session-in-dir` (gone within 1 s), a new server in
that directory reached `Ready` within 14 s with nothing on stderr (one test,
2026-10-19, Claude Code 2.1.304). A forced stop was not tested on macOS.

A clean stop (Ctrl+C, see below) released the directory immediately in the two
cases tested with `--no-create-session-in-dir`: the replacement reached `Ready`
with nothing on stderr. In the one case tested with a pre-created session,
after about 35 s of uptime, the replacement was refused. Not understood and not
investigated further. Either way the wrapper retries, so this only delays the
takeover.

## Stopping a scheduled task orphans everything under it

**Verified, and it shaped `Stop-Agent`.** `Stop-ScheduledTask` ended only the
task's own process (`conhost.exe`). The wrapper, `cmd.exe`, `claude rc`, its
session and the session's MCP servers all kept running.

What does stop the whole tree cleanly is Ctrl+C on the wrapper's console, sent
from a throwaway process with `FreeConsole` + `AttachConsole(<wrapper pid>)` +
`GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0)`. Every process in the tree,
including the session and its MCP servers, was gone within 2 s. It has to
happen before the task is stopped: once `conhost` is gone, `AttachConsole`
fails with error 233. So `Stop-Agent` sends Ctrl+C, then stops the task, then
force-kills whatever is left.

## `conhost --headless` hides every window

**Verified.** The task action is `conhost.exe --headless powershell.exe ...
-File <wrapper>`. Visible top-level windows were enumerated (`EnumWindows` +
`IsWindowVisible`) before and 20–30 s after starting the task: no new window,
including after the server pre-created a session. The session and each of its
MCP servers got their own windowless console (`conhost.exe 0x4`).

## Task Scheduler defaults would kill a persistent server

**Reasoned, from Microsoft's documented defaults; not observed failing.** A new
task is stopped after 72 hours (`ExecutionTimeLimit`), does not start on
battery and stops when switching to battery, and runs at priority 7 (below
normal). `install.ps1` sets no time limit, turns both battery options off and
uses priority 4. `doctor.ps1` checks the first two.

## A medium-integrity wrapper cannot see elevated processes

**Verified.** From a task with `RunLevel Limited` (how the agent runs), the
command line and working directory of a `claude rc` started by the agent were
readable. Those of a `claude rc` started from an elevated terminal came back
empty, and so did `Win32_Process.CommandLine` for it.

So a server started by hand **in an elevated terminal** is invisible to the
wrapper's guard. Nothing is duplicated, since Claude Code refuses the agent's
server (above), but the log shows the "already served" error every couple of
minutes until the manual server exits. A server started from a normal terminal
is seen and the agent idles. Verified: a medium-integrity "manual" server, the
agent logged `idling`, and logged `taking over` 23 s after that server was
stopped with Ctrl+C. The replacement connected without being refused.

## No `lsof`, no `nc`, no Python

**Verified on this machine.** `python3` is only the Microsoft Store alias, and
neither `lsof` nor `nc` exists. The working directory and command line of
another process are read from its PEB (`src/native.cs`), the network check uses
`TcpClient`, and JSON is read with `ConvertFrom-Json`.

## `claude.exe` is a plain file updated in place

**Verified.** `~/.local/bin/claude.exe` is a regular file, not a link. An
update leaves the previous copy beside it as `claude.exe.old.<n>`.
`~/.local/share/claude/versions/` holds other versions that nothing points at.
The stable path is `~/.local/bin/claude.exe`; the `versions` guard is kept
anyway.

## Credentials need no keychain and no stored password

**Verified.** A task with `LogonType Interactive` (no stored password) started
a server that authenticated and reached `Ready`. Credentials live in
`~/.claude/.credentials.json`.

## Git symlinks do not survive a Windows checkout

**Verified.** With `core.symlinks=false` (the Git for Windows default without
Developer Mode), the `CLAUDE.md -> AGENTS.md` symlink was checked out as a text
file containing just `AGENTS.md`. `CLAUDE.md` is now a regular file that
imports `@AGENTS.md`, which works on both platforms. On Windows the skill link
is a junction, which needs no privileges.

**Correction, verified on macOS on 2026-10-19.** Editing that text file on
Windows did not make it a regular file: git kept mode `120000`, so the commit
changed the link target to `@AGENTS.md`. On the Mac this checked out as a
broken symlink `CLAUDE.md -> @AGENTS.md`. The file was then re-added from the
Mac as a regular file (mode `100644`, `git ls-files -s CLAUDE.md`). To change
the type of a file on Windows, remove it from the index first
(`git rm --cached`).

## `powershell -File` does not pass `--` through

**Verified.** `powershell -File script.ps1 -Dir x -- --flag` fails with
`AmbiguousParameter`, while `.\script.ps1 -Dir x -- --flag` at a PowerShell
prompt works. The task therefore passes only `-Label`, and everything else is
in `~/.claude/claude-rc/<label>.json`.

## Windows PowerShell 5.1 reads BOM-less files as ANSI

**Known behaviour, not specifically tested here.** `Get-Content` and script
loading assume the ANSI code page for files without a BOM. The `.ps1` and `.cs`
files are kept ASCII-only, and JSON is read with `-Encoding UTF8`.

## `try` / `catch` misses non-terminating errors

**Verified** on 2026-10-20. `Get-Content` on a missing file raises a
*non-terminating* error. Unless the caller has set
`$ErrorActionPreference = 'Stop'`, a surrounding `try`/`catch` does not catch
it: the error is printed and the next statement runs with an empty result. In
`Test-WorkspaceTrusted` that turned "no `~/.claude.json`" (2) into "not
trusted" (1) under `doctor.ps1`, but not under `install.ps1`, which sets
`Stop`. Reads in `lib.ps1` that rely on `catch` now pass `-ErrorAction Stop`,
to `ConvertFrom-Json` as well.

## Not verified on Windows

- An actual logon after a reboot. The logon trigger, the task settings, trust
  on disk and the binary path were each checked individually.
- Installing from a non-elevated prompt. Everything above was run from an
  elevated one; the task itself runs non-elevated (`RunLevel Limited`).
- Sleep/wake and long network outages, as on macOS.
