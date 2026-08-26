# claude-rc

Keep **Claude Code Remote Control** running on your Mac without thinking about
it, so you can start Claude Code sessions from your phone at any time.

`claude rc` is a persistent server: run it in a directory and that machine shows
up in the Claude mobile app and at [claude.ai/code](https://claude.ai/code). The
catch is remembering to launch it in a terminal after every reboot — and it is
only ever missing at the exact moment you reach for your phone.

This installs a macOS LaunchAgent that starts it at every login, headlessly,
with no window and nothing to remember.

```sh
git clone <this repo> ~/git/claude-rc
cd ~/git/claude-rc
./install.sh
```

That is it. `claude rc` now runs in `$HOME` from every login onwards.

## Commands

```sh
./install.sh              # install (idempotent — also the way to apply changes)
./install.sh --dir ~/code # run the server somewhere other than $HOME
./doctor.sh               # health check; exit 0 = healthy
./uninstall.sh            # remove autostart, leave the running server alone
```

From Claude Code itself, the bundled skill covers the same ground
conversationally — "is remote control running?", "why can't my phone see this
Mac?", "turn autostart off":

```
/claude-rc
```

## What you get

- Starts at login, invisibly. No terminal window, no dock icon.
- Restarts itself if the server ever dies (`KeepAlive`).
- Waits for the network before starting, which at login is usually not up yet.
- **Never doubles up.** If you still launch `claude rc` by hand out of habit, the
  agent notices, idles, and takes over when yours exits.
- Small, self-trimming log at `~/.claude/logs/claude-rc.log` with the errors and
  none of the status-screen noise.
- Refuses to install against a version-pinned binary path that would break on
  the next Claude Code update.

## Login, not boot

A LaunchAgent starts at **login**, not at power-on. That is deliberate: the
alternative — a LaunchDaemon — runs as root before login and cannot reach your
keychain, so `claude` would not be able to authenticate. If you want it
literally on power-on, enable automatic login in
*System Settings → Users & Groups*.

## Requirements

- macOS (this is launchd-specific)
- Claude Code installed, with `~/.local/bin/claude` on disk
- The target directory trusted once by Claude Code — run `claude` there and
  accept the trust dialog. `install.sh` checks this and refuses otherwise,
  because launchd cannot answer that dialog and the agent would fail silently at
  every login.

## Layout

```
install.sh uninstall.sh doctor.sh   entry points
src/claude-rc-boot.sh               the wrapper launchd actually runs
src/autostart.plist.template        LaunchAgent template
src/lib.sh                          shared helpers
skills/claude-rc/SKILL.md           the /claude-rc skill
docs/how-it-works.md                design and how to test the real launch path
docs/findings.md                    what was measured on macOS, and how
```

`docs/findings.md` is worth a read if you are doing anything similar: it
documents several macOS behaviours that quietly break this class of setup,
including `pgrep -f` missing processes and `zsh -lc` not sourcing `.zshrc`.

## License

MIT
