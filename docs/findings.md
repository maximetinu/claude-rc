# Findings

Everything here was observed on this machine (macOS 26.5.2, Claude Code 2.1.246)
while building this project. Each entry says how it was checked, so a future
reader can tell evidence from assumption.

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

## Not verified

- Behaviour across an actual reboot — it could not be tested without rebooting.
  Everything a reboot depends on (RunAtLoad, agent enabled, trust on disk,
  stable binary path) was checked individually.
- Whether the server recovers on its own from sleep/wake or a long network
  outage. `KeepAlive` covers the process *dying*; it would not help a process
  that stays alive but stops being reachable. No evidence either way was
  collected, so no watchdog was built for a problem not known to exist.
