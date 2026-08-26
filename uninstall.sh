#!/usr/bin/env bash
#
# Remove the claude-rc autostart LaunchAgent and everything install.sh created.
# Never touches the `claude` binary or your Claude Code configuration.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$SCRIPT_DIR/src/lib.sh"

LABEL="$DEFAULT_LABEL"
PURGE_LOGS=0
KILL_SERVER=0

usage() {
  cat <<USAGE
Usage: ./uninstall.sh [options]

Options:
  --label <id>    launchd label to remove   (default: $DEFAULT_LABEL)
  --purge-logs    also delete $LOG_DIR/claude-rc*.log
  --kill-server   also stop the running \`claude rc\` server
                  (WARNING: this kills any Claude Code sessions running under it)
  -h, --help      Show this help

By default the currently running server is left alone: removing the agent only
means it will not come back at the next login.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
    --purge-logs) PURGE_LOGS=1; shift ;;
    --kill-server) KILL_SERVER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

step "Unloading the agent"
if agent_loaded "$LABEL"; then
  launchctl bootout "$(gui_domain)/$LABEL" 2>/dev/null || true
  ok "unloaded $LABEL"
fi
p="$(plist_path "$LABEL")"
if [ -f "$p" ]; then rm -f "$p"; ok "removed $p"; fi

step "Removing files"
if [ -f "$SCRIPT_DEST" ]; then rm -f "$SCRIPT_DEST"; ok "removed $SCRIPT_DEST"; fi

if [ -L "$SKILL_DEST" ]; then
  rm -f "$SKILL_DEST"; ok "removed skill symlink $SKILL_DEST"
elif [ -e "$SKILL_DEST" ]; then
  warn "$SKILL_DEST is a real directory, not ours — left alone"
fi

if [ "$PURGE_LOGS" -eq 1 ]; then
  rm -f "$LOG_DIR"/claude-rc*.log
  ok "purged logs"
else
  info "logs kept at $LOG_DIR/claude-rc*.log (use --purge-logs to delete)"
fi

step "Running server"
pids="$(rc_servers || true)"
if [ -z "$pids" ]; then
  ok "no 'claude rc' server running"
elif [ "$KILL_SERVER" -eq 1 ]; then
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  ok "stopped: $(echo "$pids" | tr '\n' ' ')"
else
  info "still running (pids: $(echo "$pids" | tr '\n' ' ')) — it will simply not"
  info "come back after the next reboot. Use --kill-server to stop it now."
fi

say ""
say "${C_GREEN}Uninstalled.${C_RESET}"
