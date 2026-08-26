#!/bin/zsh
#
# claude-rc — launch `claude rc` (Claude Code Remote Control) headlessly at login.
#
# This script is the ProgramArguments target of the LaunchAgent installed by
# install.sh. It is deliberately generic: all configuration arrives through the
# environment variables set in the plist, so this file never needs templating.
#
#   CLAUDE_RC_BIN      absolute path to the `claude` binary
#   CLAUDE_RC_DIR      directory the Remote Control server runs in
#   CLAUDE_RC_LOG_DIR  where to write claude-rc.log
#
# Do not edit the installed copy at ~/.claude/scripts/ — edit this file in the
# repo and re-run install.sh, which is idempotent.

set -u

CLAUDE_BIN="${CLAUDE_RC_BIN:-$HOME/.local/bin/claude}"
WORKDIR="${CLAUDE_RC_DIR:-$HOME}"
LOG_DIR="${CLAUDE_RC_LOG_DIR:-$HOME/.claude/logs}"
LOG="$LOG_DIR/claude-rc.log"

mkdir -p "$LOG_DIR"
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG" }

# Trim the log so it can never grow without bound across many logins.
if [[ -f "$LOG" ]] && (( $(wc -c <"$LOG") > 262144 )); then
  tail -n 200 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# launchd runs us via `zsh -lc`, which sources .zprofile but NOT .zshrc — and
# ~/.local/bin is typically only added in .zshrc. Add it so sessions spawned by
# the server can find `claude` by name, exactly as in a normal terminal tab.
export PATH="$HOME/.local/bin:$PATH"

log "--- launchd start (pid $$) ---"
log "config: bin=$CLAUDE_BIN dir=$WORKDIR"

[[ -x "$CLAUDE_BIN" ]] || { log "FATAL: $CLAUDE_BIN is not executable"; exit 1 }
[[ -d "$WORKDIR"   ]] || { log "FATAL: $WORKDIR is not a directory";    exit 1 }

# 1. At login the network is usually not up yet; give it up to two minutes.
#    If it never comes up we run anyway and let KeepAlive retry us.
for i in {1..24}; do
  /usr/bin/nc -z -G 2 api.anthropic.com 443 >/dev/null 2>&1 && break
  (( i == 1 )) && log "waiting for network..."
  sleep 5
done

# 2. Never double up. If a `claude rc` is already running (e.g. one started by
#    hand in a terminal), idle until it exits and then take over, so the user
#    keeps their familiar manual workflow without ending up with two servers.
#
#    Match on the argv fields (argv0 ends in /claude, argv1 is rc) rather than a
#    substring: an unrelated command that merely mentions "claude rc" in its
#    command line must not count. Note that `pgrep -f` is NOT usable here — see
#    docs/findings.md, it silently misses processes on macOS.
rc_running() {
  ps -Ao pid=,command= | awk \
    '$2 ~ /(^|\/)claude$/ && ($3 == "rc" || $3 == "remote-control") { found = 1 } END { exit !found }'
}

# CLAUDE_RC_ALLOW_DUPLICATE=1 skips the guard. Used by the test harness to
# exercise this exact launch path while another server is alive, and available
# to anyone who deliberately wants a second server.
[[ "${CLAUDE_RC_ALLOW_DUPLICATE:-0}" == "1" ]] && log "duplicate guard disabled"

waited=0
while [[ "${CLAUDE_RC_ALLOW_DUPLICATE:-0}" != "1" ]] && rc_running; do
  (( waited == 0 )) && log "another 'claude rc' is already running - idling until it exits"
  waited=1
  sleep 30
done
(( waited == 1 )) && log "previous 'claude rc' exited - taking over"

cd "$WORKDIR" || { log "FATAL: cannot cd to $WORKDIR"; exit 1 }
log "exec: $CLAUDE_BIN rc   (cwd: $WORKDIR)"

# The status TUI on stdout redraws every few seconds and would grow the log
# without bound, so it is discarded. Real failures go to stderr and are kept.
exec "$CLAUDE_BIN" rc </dev/null >/dev/null 2>>"$LOG"
