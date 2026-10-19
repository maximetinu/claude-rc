#!/usr/bin/env bash
# Shared configuration and helpers for install.sh / uninstall.sh / doctor.sh.
# shellcheck shell=bash

DEFAULT_LABEL="com.claude-rc.autostart"
# Every agent this project installs has a label under this prefix, so one
# agent per directory can coexist (see installed_labels).
LABEL_PREFIX="com.claude-rc."
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

# These scripts drive launchd. On Windows the same job is done by the
# PowerShell scripts next to them, with Task Scheduler instead of launchd.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    die 'on Windows use the PowerShell scripts: .\install.ps1, .\doctor.ps1, .\uninstall.ps1' ;;
esac

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

# Log file stem for a label. The default agent keeps the historical
# claude-rc.log; every other agent gets claude-rc.<suffix>.log.
log_name() {  # log_name <label>
  case "$1" in
    "$DEFAULT_LABEL") printf 'claude-rc' ;;
    "$LABEL_PREFIX"*) printf 'claude-rc.%s' "${1#"$LABEL_PREFIX"}" ;;
    *)                printf 'claude-rc.%s' "$1" ;;
  esac
}

# Labels of every agent this project has installed, one per line.
installed_labels() {
  local p
  for p in "$HOME/Library/LaunchAgents/$LABEL_PREFIX"*.plist; do
    [ -f "$p" ] && basename "$p" .plist
  done
  return 0
}

# WorkingDirectory of an installed plist, or empty.
plist_workdir() {  # plist_workdir <plist>
  python3 -c '
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f: print(plistlib.load(f).get("WorkingDirectory", ""))
except Exception: print("")' "$1" 2>/dev/null
}

# Claude Code refuses to start in a directory whose trust dialog was never
# accepted, and under launchd there is nobody to answer it — so the agent would
# fail silently at every login. Check up front instead.
#
#   0 trusted   1 not trusted   2 no ~/.claude.json   3 untrusted home directory
#
# Trust accepted in a parent directory also covers its children, but the walk
# stops at the git repository root: a repo inside a trusted folder needs its own
# trust. Claude Code no longer saves trust for $HOME, so an untrusted home can
# never become trusted; a home trusted earlier still works. See
# docs/findings.md.
workspace_trusted() {  # workspace_trusted <dir>
  python3 - "$1" <<'PY'
import json, os, sys
d = os.path.realpath(sys.argv[1])
home = d == os.path.realpath(os.path.expanduser("~"))
try:
    cfg = json.load(open(os.path.expanduser("~/.claude.json")))
except Exception:
    sys.exit(3 if home else 2)
trusted = {os.path.realpath(os.path.expanduser(k))
           for k, v in (cfg.get("projects") or {}).items() if v.get("hasTrustDialogAccepted")}
if home:
    sys.exit(0 if d in trusted else 3)
stop = d
while not os.path.exists(os.path.join(stop, ".git")) and os.path.dirname(stop) != stop:
    stop = os.path.dirname(stop)
if not os.path.exists(os.path.join(stop, ".git")):
    stop = None
while True:
    if d in trusted:
        sys.exit(0)
    parent = os.path.dirname(d)
    if d == stop or parent == d:
        sys.exit(1)
    d = parent
PY
}

# PIDs of running Remote Control servers. Matches on argv fields, never a
# substring; `pgrep -f` is unreliable on macOS (see docs/findings.md).
rc_servers() {
  ps -Ao pid=,command= | awk \
    '$2 ~ /(^|\/)claude$/ && ($3 == "rc" || $3 == "remote-control") { print $1 }'
}

# PIDs of the Remote Control servers whose working directory is <dir>.
rc_servers_in() {  # rc_servers_in <dir>
  local pid cwd
  for pid in $(rc_servers); do
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    [ "$cwd" = "$1" ] && printf '%s\n' "$pid"
  done
  return 0
}
