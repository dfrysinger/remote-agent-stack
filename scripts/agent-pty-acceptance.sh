#!/usr/bin/env bash

set -euo pipefail

[ -t 0 ] && [ -t 1 ] || {
  echo "agent PTY acceptance must run in a real terminal" >&2
  exit 1
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN_DIR="$TMP/bin"
HOME_DIR="$TMP/home"
LOG="$TMP/backend.log"
TMUX_TMPDIR="$TMP/tmux"
mkdir -p "$BIN_DIR" "$HOME_DIR" "$TMUX_TMPDIR"
: > "$LOG"

bash "$ROOT/scripts/manage-command-links.sh" \
  --mode install \
  --wrapper "$ROOT/bin/agent" \
  --screen-wrapper "$ROOT/bin/agent-screen" \
  --bin-dir "$BIN_DIR" >/dev/null

REAL_TMUX="$(command -v tmux)"
ln -s "$REAL_TMUX" "$BIN_DIR/tmux"

for backend in copilot claude codex; do
  cat > "$BIN_DIR/$backend" <<EOF
#!/usr/bin/env bash
printf '$backend|%s|%s\n' "\$PWD" "\$*" >> "\$ACCEPT_LOG"
session="\$(tmux display-message -p '#S')"
tmux kill-session -t "=\$session"
EOF
  chmod +x "$BIN_DIR/$backend"
  mkdir -p "$TMP/$backend-workspace"
done
COPILOT_BASE="$TMP/copilot-workspace"
CLAUDE_BASE="$TMP/claude-workspace"
CODEX_BASE="$TMP/codex-workspace"

run_candidate() {
  env -u TMUX \
    HOME="$HOME_DIR" \
    XDG_CONFIG_HOME="$TMP/config" \
    PATH="$BIN_DIR:/usr/bin:/bin" \
    TERM=xterm-256color \
    TMUX_TMPDIR="$TMUX_TMPDIR" \
    ACCEPT_LOG="$LOG" \
    COPILOT_WORKSPACE_BASE="$TMP/copilot-workspace" \
    CLAUDE_WORKSPACE_BASE="$TMP/claude-workspace" \
    CODEX_WORKSPACE_BASE="$TMP/codex-workspace" \
    COPILOT_BIN="$BIN_DIR/copilot" \
    CLAUDE_BIN="$BIN_DIR/claude" \
    CODEX_BIN="$BIN_DIR/codex" \
    SESSION_WARN_MB=0 \
    "$@"
}

for backend in copilot claude codex; do
  : > "$LOG"
  run_candidate "$BIN_DIR/agent-stack" "$backend" pty
  canonical="$(cat "$LOG")"
  case "$canonical" in
    "$backend|$TMP/$backend-workspace/agent-pty|"*) ;;
    *) echo "unexpected canonical launch: $canonical" >&2; exit 1 ;;
  esac

  : > "$LOG"
  run_candidate "$BIN_DIR/$backend-agent" pty
  alias_launch="$(cat "$LOG")"
  [ "$alias_launch" = "$canonical" ] || {
    echo "$backend alias launch differs from canonical launch" >&2
    exit 1
  }
  echo "PTY PASS: $backend canonical and alias -> $canonical"
done

cat > "$BIN_DIR/hold-session" <<'HOLD'
#!/usr/bin/env bash
printf 'reattach|%s|%s\n' "$(tmux display-message -p '#S')" "$PWD" >> "$ACCEPT_LOG"
sleep 5
HOLD
chmod +x "$BIN_DIR/hold-session"

: > "$LOG"
mkdir -p "$CLAUDE_BASE/agent-reattach"
env -u TMUX TERM=xterm-256color TMUX_TMPDIR="$TMUX_TMPDIR" ACCEPT_LOG="$LOG" \
  "$REAL_TMUX" new-session -d -s claude-reattach \
  -c "$CLAUDE_BASE/agent-reattach" "$BIN_DIR/hold-session"
run_candidate "$BIN_DIR/agent-stack" claude reattach
grep -Fq "reattach|claude-reattach|$CLAUDE_BASE/agent-reattach" "$LOG"
if grep -Fq 'claude|' "$LOG"; then
  echo "reattach unexpectedly launched a second Claude backend" >&2
  exit 1
fi
echo "PTY PASS: existing prefixed session reattached by physical workspace"

: > "$LOG"
mkdir -p "$COPILOT_BASE/agent-legacy"
env -u TMUX TERM=xterm-256color TMUX_TMPDIR="$TMUX_TMPDIR" ACCEPT_LOG="$LOG" \
  "$REAL_TMUX" new-session -d -s legacy \
  -c "$COPILOT_BASE/agent-legacy" "$BIN_DIR/hold-session"
run_candidate "$BIN_DIR/agent-stack" copilot legacy
grep -Fq "reattach|legacy|$COPILOT_BASE/agent-legacy" "$LOG"
if grep -Fq 'copilot|' "$LOG"; then
  echo "legacy reattach unexpectedly launched a prefixed Copilot session" >&2
  exit 1
fi
echo "PTY PASS: matching legacy Copilot session reattached"

run_candidate "$BIN_DIR/agent-stack" --help | grep -q 'agent-stack <copilot|claude|codex> <Name>'
for backend in copilot claude codex; do
  run_candidate "$BIN_DIR/agent-stack" "$backend" --help |
    grep -q "agent-stack $backend <Name>"
  run_candidate "$BIN_DIR/$backend-agent" --help |
    grep -q "$backend-agent <Name>"
done

echo "PTY PASS: canonical and alias help"
echo "agent PTY acceptance passed"
