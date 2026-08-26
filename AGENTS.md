# Working on this repo

Context for AI agents. Read `docs/findings.md` before changing anything in
`src/` — it records macOS behaviours that were discovered the hard way and that
the code deliberately works around.

## What this is

A macOS LaunchAgent that autostarts `claude rc` (Claude Code Remote Control) at
login, plus an installer, an uninstaller, a health check and a skill.

## Ground rules

1. **`install.sh` is the only way to apply a change.** The wrapper is *copied*
   to `~/.claude/scripts/`, so editing `src/` alone changes nothing on the
   running system. `doctor.sh` warns when the two have drifted.
2. **Never use `pgrep -f`.** It silently misses processes on macOS — verified,
   see findings. Use `ps -Ao pid=,command=` and compare **argv fields**, never a
   substring: a substring match fires on any command line that merely mentions
   `claude rc`.
3. **Never resolve the `claude` symlink.** `~/.local/bin/claude` points at a
   versioned binary that rotates on auto-update. `install.sh` hard-fails on any
   path containing `/versions/`; keep that guard.
4. **Do not kill a running `claude rc` as a side effect.** Claude Code sessions
   are its children — possibly including the session you are running in.
5. **The wrapper takes configuration from the environment**
   (`CLAUDE_RC_BIN`, `CLAUDE_RC_DIR`, `CLAUDE_RC_LOG_DIR`,
   `CLAUDE_RC_ALLOW_DUPLICATE`). Keep it free of templating so the installed
   copy stays byte-identical to `src/`.

## Testing

There is no test suite; changes are verified against the live system.

```sh
bash -n install.sh uninstall.sh src/lib.sh   # syntax
zsh  -n src/claude-rc-boot.sh
./install.sh && ./doctor.sh                  # expect exit 0
```

To exercise the real launch path while a server is already running, use the
`CLAUDE_RC_ALLOW_DUPLICATE=1` throwaway-plist recipe in
`docs/how-it-works.md`. Always `launchctl bootout` the throwaway agent
afterwards and confirm only one server remains.

Claims about behaviour belong in `docs/findings.md`, and each one should say how
it was checked. Keep verified and assumed clearly separated.
