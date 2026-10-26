# claude-rc

Keep **Claude Code Remote Control** running on your Mac or Windows PC without
thinking about it, so you can start Claude Code sessions from your phone at any
time.

`claude rc` is a persistent server: run it in a directory and that machine shows
up in the Claude mobile app and at [claude.ai/code](https://claude.ai/code). The
catch is remembering to launch it in a terminal after every reboot — and it is
only ever missing at the exact moment you reach for your phone.

This starts it at every login, headlessly, with no window and nothing to
remember: a LaunchAgent on macOS, a scheduled task on Windows.

**macOS**

```sh
git clone <this repo> ~/git/claude-rc
cd ~/git/claude-rc
./install.sh --dir ~/git
```

**Windows** (from a PowerShell prompt)

```powershell
git clone <this repo> $HOME\git\claude-rc
cd $HOME\git\claude-rc
.\install.ps1 -Dir $HOME\git
```

That is it. `claude rc` now runs in that directory from every login onwards.
Pick a directory you have trusted in Claude Code (see
[Requirements](#requirements)); your home directory usually cannot be used,
because Claude Code no longer saves trust for it.

## Commands

| macOS | Windows | |
|-------|---------|---|
| `./install.sh --dir <path>` | `.\install.ps1 -Dir <path>` | install (idempotent — also the way to apply changes) |
| `./doctor.sh` | `.\doctor.ps1` | health check; exit 0 = healthy |
| `./doctor.sh --all` | `.\doctor.ps1 -All` | one line per installed agent |
| `./uninstall.sh` | `.\uninstall.ps1` | remove autostart; stops the server the agent started |

## One server per directory

The Claude app lists one entry per running server, and a session opened from
it starts in that server's directory. To start sessions directly in several
repositories, install one agent per directory, each with its own label:

```sh
./install.sh --dir ~/git/app --label com.claude-rc.app -- --no-create-session-in-dir
./doctor.sh com.claude-rc.app
./uninstall.sh --label com.claude-rc.app
```

```powershell
.\install.ps1 -Dir $HOME\git\app -Label com.claude-rc.app -- --no-create-session-in-dir
.\doctor.ps1 com.claude-rc.app
.\uninstall.ps1 -Label com.claude-rc.app
```

Everything after `--` goes to `claude rc`. `--no-create-session-in-dir` keeps an
idle server at about 90 MB instead of about 240 MB, because it does not start a
session (and its MCP servers) until you open one. Each agent has its own log,
`~/.claude/logs/claude-rc.<suffix>.log`; the default agent keeps
`claude-rc.log`.

From Claude Code itself, the bundled skill covers the same ground
conversationally — "is remote control running?", "why can't my phone see this
machine?", "turn autostart off":

```
/claude-rc
```

## What you get

- Starts at login, invisibly. No terminal window, no dock icon.
- Restarts itself if the server ever dies (`KeepAlive` on macOS, a supervising
  loop in the wrapper on Windows).
- Waits for the network before starting, which at login is usually not up yet.
- Staggers the start on macOS: one agent every 12 s from 60 s after login, so
  many agents do not slow down the desktop (Spotlight first) right after login.
- **Never doubles up.** If you still launch `claude rc` by hand out of habit in
  the same directory, the agent notices, idles, and takes over when yours exits.
  Servers in other directories do not count.
- Small, self-trimming log at `~/.claude/logs/claude-rc.log` with the errors and
  none of the status-screen noise.
- Refuses to install against a version-pinned binary path that would break on
  the next Claude Code update.

## Login, not boot

The agent starts at **login**, not at power-on. That is deliberate: something
that runs before login (a LaunchDaemon, or a task that runs whether you are
logged in or not) runs outside your session and, on Windows, needs your
password stored in the task. If you want it literally on power-on, enable
automatic login.

## Requirements

- macOS (launchd) or Windows 10/11 (Task Scheduler, Windows PowerShell 5.1)
- Claude Code installed natively: `~/.local/bin/claude` on macOS,
  `~\.local\bin\claude.exe` on Windows
- The target directory trusted once by Claude Code — run `claude` there and
  accept the trust dialog. Trust in a parent directory covers its children,
  except that it does not reach into a git repository: a repo needs its own.
  The installer checks this and refuses otherwise, because nobody can answer
  that dialog at login and the agent would fail silently every time.

On Windows, a `claude rc` you start by hand from an **elevated** terminal is
invisible to the agent. Nothing is duplicated (Claude Code refuses a second
server in the same directory), but the log fills with retries until yours
exits. See `docs/findings.md`.

## Layout

```
install.sh uninstall.sh doctor.sh      entry points (macOS)
install.ps1 uninstall.ps1 doctor.ps1   entry points (Windows)
src/claude-rc-boot.sh                  the wrapper launchd runs
src/autostart.plist.template           LaunchAgent template
src/lib.sh                             shared helpers (macOS)
src/claude-rc-boot.ps1                 the wrapper the scheduled task runs
src/lib.ps1                            shared helpers (Windows)
src/native.cs                          Windows process inspection and Ctrl+C
skills/claude-rc/SKILL.md              the /claude-rc skill
docs/how-it-works.md                   design and how to test the real launch path
docs/findings.md                       what was measured on each platform, and how
```

`docs/findings.md` is worth a read if you are doing anything similar: it
documents platform behaviours that quietly break this class of setup, such as
`pgrep -f` missing processes on macOS and `Stop-ScheduledTask` orphaning a
task's children on Windows.

## License

MIT
