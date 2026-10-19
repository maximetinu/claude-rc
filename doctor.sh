#!/usr/bin/env bash
#
# Diagnose the claude-rc autostart setup. Exits 0 if healthy, 1 if something
# would stop `claude rc` from coming up at the next login.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$SCRIPT_DIR/src/lib.sh"

usage() {
  cat <<USAGE
Usage: ./doctor.sh [label]    check one agent   (default: $DEFAULT_LABEL)
       ./doctor.sh --all      one line per installed agent; exit 1 if any fails
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --all)
    labels="$(installed_labels)"
    [ -n "$labels" ] || { bad "no agents installed — run ./install.sh"; exit 1; }
    failed=0
    for l in $labels; do
      if "$0" "$l" >/dev/null 2>&1; then
        ok "$l  ($(plist_workdir "$(plist_path "$l")"))"
      else
        bad "$l  ($(plist_workdir "$(plist_path "$l")")) — run ./doctor.sh $l"
        failed=$((failed + 1))
      fi
    done
    exit $(( failed > 0 ? 1 : 0 )) ;;
esac

LABEL="${1:-$DEFAULT_LABEL}"
PLIST="$(plist_path "$LABEL")"
LOG_FILE="$LOG_DIR/$(log_name "$LABEL").log"
PROBLEMS=0
fail() { bad "$*"; PROBLEMS=$((PROBLEMS + 1)); }

step "LaunchAgent"
if [ -f "$PLIST" ]; then
  ok "plist present: $PLIST"
  plutil -lint "$PLIST" >/dev/null 2>&1 && ok "plist is valid" || fail "plist is malformed"
else
  fail "no plist at $PLIST — run ./install.sh"
fi

if agent_loaded "$LABEL"; then
  state="$(agent_field "$LABEL" state)"
  [ "$state" = "running" ] && ok "agent state: running" || fail "agent state: ${state:-unknown}"
  info "pid: $(agent_field "$LABEL" pid)   runs: $(agent_field "$LABEL" runs)"
  code="$(agent_field "$LABEL" 'last exit code')"
  [ -n "$code" ] && info "last exit code: $code"
else
  fail "agent is not loaded — run ./install.sh"
fi

if launchctl print-disabled "$(gui_domain)" 2>/dev/null | grep -q "\"$LABEL\" => \(disabled\|true\)"; then
  fail "agent is DISABLED in launchd (launchctl enable $(gui_domain)/$LABEL)"
else
  ok "agent is not disabled"
fi

step "Files"
[ -x "$SCRIPT_DEST" ] && ok "wrapper installed: $SCRIPT_DEST" || fail "missing wrapper: $SCRIPT_DEST"
if [ -x "$SCRIPT_DEST" ] && ! diff -q "$SCRIPT_DIR/src/claude-rc-boot.sh" "$SCRIPT_DEST" >/dev/null 2>&1; then
  warn "installed wrapper differs from src/ — re-run ./install.sh to sync"
fi

bin="$(find_claude_bin || true)"
[ -n "$bin" ] && ok "claude binary: $bin" || fail "cannot find the claude binary"

step "Workspace trust"
workdir="$(plist_workdir "$PLIST")"
workdir="${workdir:-$HOME}"
if workspace_trusted "$workdir"; then
  ok "$workdir is trusted by Claude Code"
elif [ $? -eq 3 ]; then
  fail "$workdir is your home directory, which Claude Code never trusts —
       reinstall with --dir <project>"
else
  fail "$workdir is NOT trusted — the agent will fail silently at login.
       Run \`claude\` there once and accept the trust dialog."
fi

step "Server"
pids="$(rc_servers_in "$workdir")"
count=$(printf '%s' "$pids" | grep -c . || true)
case "$count" in
  0) warn "no 'claude rc' server running in $workdir right now" ;;
  1) ok "one server running in $workdir (pid $pids)" ;;
  *) warn "$count servers running in $workdir (pids: $(echo "$pids" | tr '\n' ' ')) — harmless but duplicated" ;;
esac

step "Network"
/usr/bin/nc -z -G 3 api.anthropic.com 443 >/dev/null 2>&1 \
  && ok "api.anthropic.com:443 reachable" || warn "api.anthropic.com:443 unreachable"

step "Recent log"
if [ -f "$LOG_FILE" ]; then
  tail -n 8 "$LOG_FILE" | sed 's/^/  /'
else
  info "no log yet at $LOG_FILE"
fi

say ""
if [ "$PROBLEMS" -eq 0 ]; then
  say "${C_GREEN}Healthy.${C_RESET} \`claude rc\` will start on its own at the next login."
else
  say "${C_RED}$PROBLEMS problem(s) found.${C_RESET}"
fi
exit $(( PROBLEMS > 0 ? 1 : 0 ))
