# How it works

## The chain

```
login
  └─ launchd loads ~/Library/LaunchAgents/com.claude-rc.autostart.plist
       └─ /bin/zsh -lc  exec ~/.claude/scripts/claude-rc-boot.sh
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

## Uninstalling

`./uninstall.sh` unloads the agent, deletes the plist, the installed wrapper and
the skill symlink, and leaves the running server alone — so removing autostart
never kills sessions in flight. `--kill-server` opts into stopping it,
`--purge-logs` into deleting the logs.
