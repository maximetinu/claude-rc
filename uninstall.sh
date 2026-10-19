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
  --purge-logs    also delete this agent's logs in $LOG_DIR
  --kill-server   also stop the \`claude rc\` server in this agent's directory
                  (WARNING: this kills any Claude Code sessions running under it)
  -h, --help      Show this help

Unloading the agent stops the server it started, and the Claude Code sessions
under it (launchd terminates the job). A server you started by hand in the same
directory is left alone unless you pass --kill-server. The shared wrapper and
skill are removed only with the last agent.
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

LOG_NAME="$(log_name "$LABEL")"
WORKDIR="$(plist_workdir "$(plist_path "$LABEL")")"

step "Unloading the agent"
if agent_loaded "$LABEL"; then
  launchctl bootout "$(gui_domain)/$LABEL" 2>/dev/null || true
  ok "unloaded $LABEL"
fi
p="$(plist_path "$LABEL")"
if [ -f "$p" ]; then rm -f "$p"; ok "removed $p"; fi

step "Removing files"
remaining="$(installed_labels)"
if [ -n "$remaining" ]; then
  info "other agents still use the wrapper and skill — kept: $(echo "$remaining" | tr '\n' ' ')"
else
  if [ -f "$SCRIPT_DEST" ]; then rm -f "$SCRIPT_DEST"; ok "removed $SCRIPT_DEST"; fi

  if [ -L "$SKILL_DEST" ]; then
    rm -f "$SKILL_DEST"; ok "removed skill symlink $SKILL_DEST"
  elif [ -e "$SKILL_DEST" ]; then
    warn "$SKILL_DEST is a real directory, not ours — left alone"
  fi
fi

if [ "$PURGE_LOGS" -eq 1 ]; then
  rm -f "$LOG_DIR/$LOG_NAME.log" "$LOG_DIR/$LOG_NAME.launchd.log"
  ok "purged logs"
else
  info "logs kept at $LOG_DIR/$LOG_NAME*.log (use --purge-logs to delete)"
fi

step "Running server"
if [ -n "$WORKDIR" ]; then
  # bootout sends SIGTERM to the agent's server; give it time to exit so that
  # only servers started by hand are reported below.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(rc_servers_in "$WORKDIR")" ] && break
    sleep 1
  done
  pids="$(rc_servers_in "$WORKDIR")"
else
  pids=""
  info "no plist was installed for $LABEL, so its directory is unknown"
fi
if [ -z "$pids" ]; then
  ok "no 'claude rc' server running${WORKDIR:+ in $WORKDIR}"
elif [ "$KILL_SERVER" -eq 1 ]; then
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  ok "stopped: $(echo "$pids" | tr '\n' ' ')"
else
  info "a server not started by this agent is still running (pids: $(echo "$pids" | tr '\n' ' '))."
  info "Use --kill-server to stop it now."
fi

say ""
say "${C_GREEN}Uninstalled.${C_RESET}"
