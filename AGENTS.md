# Working on this repo

Context for AI agents. Read `docs/findings.md` before changing anything in
`src/` — it records macOS and Windows behaviours that were discovered the hard
way and that the code deliberately works around.

## What this is

Autostart for `claude rc` (Claude Code Remote Control) at login, plus an
installer, an uninstaller, a health check and a skill, on two platforms:

- **macOS**: a LaunchAgent. `install.sh`, `uninstall.sh`, `doctor.sh`,
  `src/lib.sh`, `src/claude-rc-boot.sh`, `src/autostart.plist.template`.
- **Windows**: a scheduled task. `install.ps1`, `uninstall.ps1`, `doctor.ps1`,
  `src/lib.ps1`, `src/claude-rc-boot.ps1`, `src/native.cs`.

The two sides share no code, but keep the same commands, labels, log names and
behaviour. A change to one side usually needs its counterpart on the other.

## Ground rules

1. **The installer is the only way to apply a change.** The wrapper is *copied*
   to `~/.claude/scripts/` (with `claude-rc-native.cs` on Windows), so editing
   `src/` alone changes nothing on the running system. The doctor warns when
   the two have drifted.
2. **Match processes on argv fields, never a substring.** A substring match
   fires on any command line that merely mentions `claude rc`. On macOS never
   use `pgrep -f` (it silently misses processes); use `ps -Ao pid=,command=`.
   On Windows use `ClaudeRc.Native.RcServers`, which reads the command line and
   working directory from the PEB.
3. **Never resolve the `claude` symlink** (macOS). `~/.local/bin/claude` points
   at a versioned binary that rotates on auto-update. The installers hard-fail
   on any path containing `/versions/` (or `\versions\`); keep that guard.
4. **Do not kill a running `claude rc` as a side effect.** Claude Code sessions
   are its children — possibly including the session you are running in. On
   Windows, stop an agent only through `Stop-Agent`: `Stop-ScheduledTask` alone
   orphans the server and its sessions.
5. **Keep the wrapper free of templating** so the installed copy stays
   byte-identical to `src/`. One installed wrapper serves every agent. On macOS
   it takes its configuration from the environment (`CLAUDE_RC_BIN`,
   `CLAUDE_RC_DIR`, `CLAUDE_RC_LOG_DIR`, `CLAUDE_RC_LOG_NAME`, `CLAUDE_RC_ARGS`,
   `CLAUDE_RC_ALLOW_DUPLICATE`, `CLAUDE_RC_STAGGER`); on Windows from
   `~/.claude/claude-rc/<label>.json`, because the task can only pass `-Label`.
6. **One agent per directory.** Labels must start with `com.claude-rc.`; the
   doctor's all-agents mode and the uninstaller find agents by that prefix
   (Windows tasks live in the `\claude-rc\` folder). Anything that looks for
   "the running server" must filter by working directory (`rc_servers_in`,
   `Get-RcServersIn`), never count every `claude rc` on the machine.
7. **Keep `.ps1` and `.cs` files ASCII-only.** Windows PowerShell 5.1 reads
   BOM-less files as ANSI; an em dash in a message string breaks the script.
   Read UTF-8 files with `-Encoding UTF8`.

## Testing

There is no test suite; changes are verified against the live system.

macOS:

```sh
bash -n install.sh uninstall.sh src/lib.sh   # syntax
zsh  -n src/claude-rc-boot.sh
./install.sh --dir ~/git && ./doctor.sh      # expect exit 0
```

To exercise the real launch path while a server is already running, use the
`CLAUDE_RC_ALLOW_DUPLICATE=1` throwaway-plist recipe in
`docs/how-it-works.md`. Always `launchctl bootout` the throwaway agent
afterwards and confirm only one server remains.

Windows (PowerShell):

```powershell
# syntax: expect no output
'install.ps1','uninstall.ps1','doctor.ps1','src\lib.ps1','src\claude-rc-boot.ps1' | % {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $_), [ref]$null, [ref]$e); $e }
.\install.ps1 -Dir $HOME\git; .\doctor.ps1   # expect exit 0
```

To exercise the real launch path, use the throwaway-agent recipe in
`docs/how-it-works.md` (a different directory, since Claude Code refuses a
second server in the same one), and uninstall it afterwards.

Claims about behaviour belong in `docs/findings.md`, and each one should say how
it was checked. Keep verified and assumed clearly separated.
