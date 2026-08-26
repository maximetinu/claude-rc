#!/usr/bin/env bash
# Shared configuration and helpers for install.sh / uninstall.sh / doctor.sh.
# shellcheck shell=bash

DEFAULT_LABEL="com.claude-rc.autostart"
SCRIPT_DEST="$HOME/.claude/scripts/claude-rc-boot.sh"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/claude-rc.log"
SKILL_DEST="$HOME/.claude/skills/claude-rc"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_BOLD=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '  %sOK%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

gui_domain() { printf 'gui/%s' "$(id -u)"; }
plist_path() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$1"; }

agent_loaded() { launchctl print "$(gui_domain)/$1" >/dev/null 2>&1; }

agent_field() {  # agent_field <label> <key> -> value   (keys may be multi-word)
  launchctl print "$(gui_domain)/$1" 2>/dev/null | awk -v k="$2" '
    { line = $0; sub(/^[ \t]+/, "", line)
      i = index(line, " = ")
      if (i > 0 && substr(line, 1, i - 1) == k) { print substr(line, i + 3); exit } }'
}

# Absolute path to the `claude` binary, or empty if not found.
#
# Deliberately does NOT resolve symlinks. ~/.local/bin/claude is a stable shim
# pointing at ~/.local/share/claude/versions/<version>; resolving it would bake
# a version number into the plist and the agent would break silently the next
# time Claude Code auto-updates.
find_claude_bin() {
  local p
  if [ -x "$HOME/.local/bin/claude" ]; then
    p="$HOME/.local/bin/claude"
  else
    p="$(command -v claude 2>/dev/null || true)"
  fi
  [ -n "$p" ] || return 1
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  printf '%s' "$p"
}

# Claude Code refuses to start in a directory whose trust dialog was never
# accepted, and under launchd there is nobody to answer it — so the agent would
# fail silently at every login. Check up front instead.
workspace_trusted() {  # workspace_trusted <dir>
  python3 - "$1" <<'PY'
import json, os, sys
d = os.path.realpath(sys.argv[1])
try:
    cfg = json.load(open(os.path.expanduser("~/.claude.json")))
except Exception:
    sys.exit(2)
for key, val in (cfg.get("projects") or {}).items():
    if os.path.realpath(os.path.expanduser(key)) == d:
        sys.exit(0 if val.get("hasTrustDialogAccepted") else 1)
sys.exit(1)
PY
}

# PIDs of running Remote Control servers. Matches on argv fields, never a
# substring; `pgrep -f` is unreliable on macOS (see docs/findings.md).
rc_servers() {
  ps -Ao pid=,command= | awk \
    '$2 ~ /(^|\/)claude$/ && ($3 == "rc" || $3 == "remote-control") { print $1 }'
}
