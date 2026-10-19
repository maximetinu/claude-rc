---
name: claude-rc
description: Set up, check, repair or remove the LaunchAgent (macOS) or scheduled task (Windows) that autostarts `claude rc` (Claude Code Remote Control) at login, so Claude Code sessions can be started from the phone without launching anything by hand. Use when the user says Remote Control / `claude rc` does not start on its own, asks to enable or disable it at boot or login, cannot see their machine in the Claude mobile app or claude.ai/code, or asks why the server is not running.
---

# claude-rc

Manage the LaunchAgent (macOS) or scheduled task (Windows) that keeps **Claude
Code Remote Control** (`claude rc`) running, so `claude.ai/code` and the Claude
mobile app can always reach this machine.

The repo lives at `~/git/claude-rc`. Everything is driven by three tested
scripts per platform (`.sh` on macOS, `.ps1` on Windows — see
[Windows](#windows)) — prefer running them over reconstructing the steps by hand, because
they encode failure modes that are easy to miss (see `docs/findings.md`).

## Decide what the user is asking for

| Ask | Do |
|-----|-----|
| "set it up" / "make it start on its own" | `./install.sh --dir <trusted project dir>` (not `$HOME`: Claude Code no longer saves trust for it) |
| "is it working?" / "why can't my phone see it?" | `./doctor.sh`, then read the table below |
| "turn it off" / "stop it starting at login" | `./uninstall.sh` |
| "restart it now" | `launchctl kickstart -k gui/$(id -u)/com.claude-rc.autostart` |
| "run it somewhere else" | `./install.sh --dir <path>` (that dir must be trusted first; a git repo needs its own trust, a trusted parent folder does not cover it) |
| "also start sessions in repo X" | `./install.sh --no-skill --dir <repo> --label com.claude-rc.<name> -- --no-create-session-in-dir` (one agent per directory) |
| "is everything working?" with several agents | `./doctor.sh --all`, then `./doctor.sh <label>` for any FAIL |
| "stop serving repo X" | `./uninstall.sh --label com.claude-rc.<name>` |

Always run the scripts from the repo root:

```sh
cd ~/git/claude-rc && ./doctor.sh
```

`install.sh` is idempotent — re-running it is the supported way to apply changes
after editing anything in `src/`.

## Reading doctor.sh output

`doctor.sh` exits 0 when healthy, 1 otherwise. Map its FAIL lines to a cause:

| FAIL line | Cause and fix |
|-----------|---------------|
| `no plist at ...` / `agent is not loaded` | Never installed, or uninstalled. Run `./install.sh`. |
| `... is NOT trusted` | Claude Code refuses to start in an untrusted directory and launchd cannot answer the trust dialog, so the agent dies at every login. Tell the user to run `claude` once in that directory and accept the dialog, then re-run `./install.sh`. |
| `agent is DISABLED in launchd` | Someone ran `launchctl disable`. Fix: `launchctl enable gui/$(id -u)/com.claude-rc.autostart`, then `./install.sh`. |
| `cannot find the claude binary` | Claude Code moved or was uninstalled. Reinstall it, then `./install.sh`. |
| `agent state:` anything but `running` | Read the agent's log: `~/.claude/logs/claude-rc.log` for the default agent, `claude-rc.<suffix>.log` for `com.claude-rc.<suffix>`. The wrapper writes `FATAL:` lines for a bad path, and `claude rc`'s own stderr lands there too. `xpcproxy` right after install is launchd still spawning the job; check again a few seconds later. |

A `WARN` about **no server running** while the agent state is `running` is
usually not a bug: the wrapper is either waiting for the network, or idling
because another `claude rc` is already up in the same directory. The log says
which.

## Things that look broken but are not

- **Two servers running in the same directory.** Harmless — they coexist and
  each registers its own session. Happens when the user also launched one by
  hand. The next login resolves it. Servers in *different* directories are
  normal: each `com.claude-rc.*` agent serves its own directory.
- **The agent is `running` but no `claude rc` process exists.** The wrapper is
  the running process; it idles while a manual server is alive and takes over
  within 30s of that one exiting.
- **Nothing in the log after `exec:`.** That is the healthy steady state. The
  status TUI is discarded on purpose; only errors are kept.

## Never do this

- Do **not** kill the running `claude rc` to "restart it cleanly" without
  warning the user first — Claude Code sessions run as its children, including
  possibly the very session you are in. `uninstall.sh` leaves it alone by
  default for this reason.
- Do **not** point the plist at `~/.local/share/claude/versions/<version>`.
  That path changes on every auto-update. Always use the `~/.local/bin/claude`
  shim; `install.sh` refuses anything else.
- Do **not** use `pgrep -f` to look for the server — on macOS it silently misses
  processes. Use `ps -Ao pid=,command=` and match argv fields.

## Windows

Same commands with PowerShell names, run from a PowerShell prompt in the repo
root (`cd $HOME\git\claude-rc`):

| macOS | Windows |
|-------|---------|
| `./install.sh --dir <path>` | `.\install.ps1 -Dir <path>` |
| `--label <id>`, `--no-skill` | `-Label <id>`, `-NoSkill` |
| `./doctor.sh [label]`, `--all` | `.\doctor.ps1 [label]`, `-All` |
| `./uninstall.sh`, `--kill-server`, `--purge-logs` | `.\uninstall.ps1`, `-KillServer`, `-PurgeLogs` |
| `launchctl kickstart -k ...` (restart) | re-run `.\install.ps1` with the same `-Dir` and `-Label` |

The agent is a scheduled task in the `\claude-rc\` folder of Task Scheduler;
its configuration is `~\.claude\claude-rc\<label>.json`.

Windows-specific readings of doctor output and logs:

- `task state: Ready` (not `Running`): the wrapper is not running. It normally
  starts at logon; `.\install.ps1` starts it now.
- `This folder is already served ...` in the log: either a server was stopped
  less than about three minutes ago (Claude Code still holds the directory), or
  someone runs `claude rc` by hand in that directory **from an elevated
  terminal**, which the agent cannot see. The wrapper retries on its own.
- Never stop the agent with `Stop-ScheduledTask` or from Task Scheduler: that
  orphans the server and its sessions. Use `.\uninstall.ps1` or re-run
  `.\install.ps1`, which stop the whole tree cleanly.

## Verifying a change

After touching `src/`, re-run the installer and the doctor for that platform. To prove the real
launch path works while another server is alive, set
`CLAUDE_RC_ALLOW_DUPLICATE=1` in a throwaway plist pointing at the installed
wrapper — see `docs/how-it-works.md`.
