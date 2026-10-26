# How it works

The macOS design comes first; [Windows](#windows) follows the same shape with
different mechanisms.

## The chain

```
login
  └─ launchd loads ~/Library/LaunchAgents/com.claude-rc.autostart.plist
       └─ /bin/zsh -lc  exec ~/.claude/scripts/claude-rc-boot.sh
            ├─ staggered start: wait for this agent's slot after login
            ├─ wait for the network (up to 2 min)
            ├─ idle while another `claude rc` is alive
            └─ exec claude rc      (cwd: ~, stdout discarded, stderr to log)
                 └─ Claude Code sessions started from the phone
```

`~/.claude/scripts/claude-rc-boot.sh` is a **copy** of `src/claude-rc-boot.sh`,
not a symlink, so the setup keeps working if this repo is moved or deleted.
Re-run `./install.sh` to push changes — it is idempotent.

## Why each piece is there

**`/bin/zsh -lc`** — a login shell, so the job gets the same PATH as a terminal
tab. launchd's own environment is nearly empty. (`.zshrc` is *not* sourced;
see [findings](findings.md).)

**Config through `EnvironmentVariables`** — the plist carries `CLAUDE_RC_BIN`,
`CLAUDE_RC_DIR` and `CLAUDE_RC_LOG_DIR`, so the wrapper needs no templating and
the installed copy is byte-identical to the one in this repo. `doctor.sh` uses
that to detect drift.

**`RunAtLoad`** starts it at login. **`KeepAlive`** restarts it if it dies, and
**`ThrottleInterval 60`** stops a broken binary from hot-looping.

**Staggered start** — right after login every agent would otherwise start in
the same second as every login item, and the desktop (Spotlight first) stays
slow for minutes. Each agent waits for its own slot: 60 s after login, then
one every 12 s, in the sorted order of the installed agents. The wrapper finds
its own label in `XPC_SERVICE_NAME`, which launchd sets. A restart by
`KeepAlive` later in the session is past every slot, so it starts at once.
`CLAUDE_RC_STAGGER=0` turns it off. macOS only for now.

**Network wait** — at login the network is often not up yet. Two minutes, then
it runs anyway and lets `KeepAlive` retry.

**Duplicate guard** — if a `claude rc` is already running, the wrapper idles and
takes over within 30s of that one exiting. This keeps the habit of launching it
by hand working without ending up with two servers. Bypass with
`CLAUDE_RC_ALLOW_DUPLICATE=1`.

**stdout to `/dev/null`** — it is a TUI that repaints every few seconds. Errors
go to stderr and are kept in `~/.claude/logs/claude-rc.log`, which the wrapper
trims to the last 200 lines once it passes 256 KB.

## Testing the real launch path

The duplicate guard makes the production path awkward to test while a server is
already up. To exercise it for real, point a throwaway agent at the *installed*
wrapper with the guard off and its own log directory:

```sh
# plist EnvironmentVariables:
#   CLAUDE_RC_ALLOW_DUPLICATE = 1
#   CLAUDE_RC_LOG_DIR         = /tmp/claude-rc-test-logs
launchctl bootstrap gui/$(id -u) /tmp/com.claude-rc.prodtest.plist
grep exec: /tmp/claude-rc-test-logs/claude-rc.log
ps -Ao pid=,ppid=,command= | awk '$3 ~ /claude$/ && $4 == "rc"'   # expect a second server, ppid 1
launchctl bootout gui/$(id -u)/com.claude-rc.prodtest
```

A server started this way is reparented to launchd (`ppid=1`), which is how you
tell it apart from one launched in a terminal.

## Windows

```
logon
  └─ Task Scheduler runs \claude-rc\com.claude-rc.autostart
       └─ conhost.exe --headless            (a console with no window)
            └─ powershell.exe -File ~\.claude\scripts\claude-rc-boot.ps1 -Label <label>
                 ├─ read ~\.claude\claude-rc\<label>.json
                 └─ loop:
                      ├─ wait for the network (up to 2 min)
                      ├─ idle while another `claude rc` runs in the same directory
                      ├─ cmd /c claude.exe rc <NUL >NUL 2>>log
                      └─ on exit: wait so restarts are at least 60s apart
```

The pieces map onto the macOS ones:

| macOS | Windows | why it differs |
|-------|---------|----------------|
| LaunchAgent plist | scheduled task + `<label>.json` | `powershell -File` cannot pass `--`-style arguments, so the task passes only `-Label` |
| `KeepAlive` + `ThrottleInterval` | the wrapper's loop | Task Scheduler restarts only on failure, at most every minute, and never if the task "succeeds" |
| `zsh -lc` | `conhost --headless` | a console app started by a task would otherwise open a window |
| `ps` + `lsof` | `src/native.cs`, reading the PEB | Windows exposes no other process's working directory |
| `launchctl bootout` | `Stop-Agent` in `lib.ps1` | `Stop-ScheduledTask` orphans the task's children |
| skill symlink | skill junction | symlinks need admin or Developer Mode |

**`Stop-Agent`** first sends Ctrl+C to the wrapper's console from a throwaway
process, which stops the wrapper, the server and its sessions cleanly within
seconds. Then it stops the task, then force-kills anything left. The order
matters: Ctrl+C cannot reach the console once the task's `conhost` is gone.

**After a restart** Claude Code may still consider the directory served by the
previous server for up to about three minutes (mostly after a forced kill). The
new server then exits with "already served", and the loop simply retries.
`install.ps1` reports this rather than failing.

**Task settings** override three defaults that would break a persistent
server: the 72-hour execution limit, the battery restrictions and the
below-normal priority.

### Testing the real launch path on Windows

Claude Code refuses a second server in the same directory, so on Windows the
real path is tested with a throwaway agent in a **different** trusted
directory:

```powershell
.\install.ps1 -Dir <trusted dir> -Label com.claude-rc.test -NoSkill -- --no-create-session-in-dir
.\doctor.ps1 com.claude-rc.test
Get-Content -Tail 20 $HOME\.claude\logs\claude-rc.test.log
.\uninstall.ps1 -Label com.claude-rc.test -PurgeLogs
```

To check the guard, start a server by hand in that directory from a
**non-elevated** terminal before installing. The log should say `idling`, and
`taking over` within 30 s of stopping yours.

## Uninstalling

`./uninstall.sh` unloads the agent, deletes the plist, the installed wrapper and
the skill symlink, and leaves the running server alone — so removing autostart
never kills sessions in flight. `--kill-server` opts into stopping it,
`--purge-logs` into deleting the logs.

On Windows, `.\uninstall.ps1` does the same with `-KillServer` and
`-PurgeLogs`. It stops the agent through `Stop-Agent`, so the server the agent
started and its sessions end with it.
