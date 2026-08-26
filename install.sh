#!/usr/bin/env bash
#
# Install the claude-rc autostart LaunchAgent.
#
# Idempotent: safe to re-run after editing anything in src/ — that is the
# supported way to apply changes.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/lib.sh
source "$SCRIPT_DIR/src/lib.sh"

LABEL="$DEFAULT_LABEL"
WORKDIR="$HOME"
INSTALL_SKILL=1

usage() {
  cat <<USAGE
Usage: ./install.sh [options]

Installs a LaunchAgent that starts \`claude rc\` (Claude Code Remote Control)
headlessly at every login, so you can open Claude Code sessions from your phone
without remembering to launch anything.

Options:
  --dir <path>    Directory the server runs in       (default: \$HOME)
  --label <id>    launchd label                      (default: $DEFAULT_LABEL)
  --no-skill      Do not link the /claude-rc skill into ~/.claude/skills
  -h, --help      Show this help

After install:
  ./doctor.sh                 check everything is healthy
  tail -f $LOG_FILE
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    WORKDIR="${2:?--dir needs a path}"; shift 2 ;;
    --label)  LABEL="${2:?--label needs a value}"; shift 2 ;;
    --no-skill) INSTALL_SKILL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

WORKDIR="$(python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$WORKDIR")"
PLIST="$(plist_path "$LABEL")"

# ---------------------------------------------------------------- preflight --
step "Preflight"

[ "$(uname -s)" = "Darwin" ] || die "this installer is macOS-only (launchd)"
ok "macOS $(sw_vers -productVersion)"

CLAUDE_BIN="$(find_claude_bin || true)"
[ -n "$CLAUDE_BIN" ] || die "could not find the \`claude\` binary (looked on PATH and in ~/.local/bin)"
case "$CLAUDE_BIN" in
  */versions/*) die "refusing to install: $CLAUDE_BIN is a version-specific path.
       It would break the next time Claude Code auto-updates. Expected the
       stable shim at ~/.local/bin/claude." ;;
esac
ok "claude binary: $CLAUDE_BIN"

[ -d "$WORKDIR" ] || die "--dir $WORKDIR is not a directory"
ok "working directory: $WORKDIR"

if workspace_trusted "$WORKDIR"; then
  ok "workspace is trusted"
else
  case $? in
    2) warn "no ~/.claude.json yet — run \`claude\` once before relying on this" ;;
    *) die "$WORKDIR has not been trusted by Claude Code.
       Under launchd nobody can answer the trust dialog, so the agent would fail
       silently at every login. Run \`claude\` once in $WORKDIR, accept the
       dialog, then re-run this installer." ;;
  esac
fi

# ------------------------------------------------------------------ migrate --
step "Removing the previous version of this agent"
if agent_loaded "$LABEL"; then
  launchctl bootout "$(gui_domain)/$LABEL" 2>/dev/null || true
  ok "unloaded $LABEL"
fi

# ------------------------------------------------------------------ install --
step "Installing files"

mkdir -p "$(dirname "$SCRIPT_DEST")" "$LOG_DIR" "$(dirname "$PLIST")"

install -m 755 "$SCRIPT_DIR/src/claude-rc-boot.sh" "$SCRIPT_DEST"
ok "wrapper -> $SCRIPT_DEST"

sed -e "s|@LABEL@|$LABEL|g" \
    -e "s|@SCRIPT@|$SCRIPT_DEST|g" \
    -e "s|@CLAUDE_BIN@|$CLAUDE_BIN|g" \
    -e "s|@WORKDIR@|$WORKDIR|g" \
    -e "s|@LOG_DIR@|$LOG_DIR|g" \
    "$SCRIPT_DIR/src/autostart.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null || die "generated plist is invalid: $PLIST"
ok "LaunchAgent -> $PLIST"

if [ "$INSTALL_SKILL" -eq 1 ]; then
  mkdir -p "$(dirname "$SKILL_DEST")"
  if [ -e "$SKILL_DEST" ] && [ ! -L "$SKILL_DEST" ]; then
    warn "$SKILL_DEST exists and is not a symlink — leaving it alone"
  else
    ln -sfn "$SCRIPT_DIR/skills/claude-rc" "$SKILL_DEST"
    ok "skill -> $SKILL_DEST"
  fi
fi

# --------------------------------------------------------------------- load --
step "Loading the agent"
launchctl bootstrap "$(gui_domain)" "$PLIST"
launchctl enable "$(gui_domain)/$LABEL" 2>/dev/null || true
ok "bootstrapped $LABEL"

# ------------------------------------------------------------------- verify --
step "Verifying"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  agent_loaded "$LABEL" && break
  sleep 1
done

state="$(agent_field "$LABEL" state)"
if [ "$state" = "running" ]; then
  ok "agent state: running"
else
  bad "agent state: ${state:-unknown}"
  info "see $LOG_FILE and ${LOG_DIR}/claude-rc.launchd.log"
  exit 1
fi

running=$(rc_servers | wc -l | tr -d ' ')
if [ "$running" -gt 1 ]; then
  warn "$running 'claude rc' servers are running"
elif [ "$running" -eq 1 ]; then
  ok "one 'claude rc' server is running"
else
  info "no server yet — the wrapper is waiting for the network"
fi

say ""
say "${C_GREEN}Installed.${C_RESET} \`claude rc\` will now start automatically at every login."
say ""
info "If you already have one running by hand, the agent idles until that one"
info "exits, then takes over — so nothing is duplicated."
say ""
say "  ./doctor.sh                                   check health"
say "  tail -f $LOG_FILE"
say "  launchctl kickstart -k $(gui_domain)/$LABEL   restart now"
