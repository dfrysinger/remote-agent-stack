#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT/bin/agent"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
BIN_DIR="$TMP/bin"
STATE_DIR="$TMP/tmux"
LOG="$TMP/tmux.log"
AUX_LOG="$TMP/aux.log"
mkdir -p "$HOME_DIR" "$BIN_DIR" "$STATE_DIR/sessions"

for name in remote-agent copilot-agent claude-agent codex-agent agent ca cc co mystery-agent; do
  ln -s "$WRAPPER" "$BIN_DIR/$name"
done

for name in copilot claude codex; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DIR/$name"
  chmod +x "$BIN_DIR/$name"
done

cat > "$BIN_DIR/security" <<'FAKE_SECURITY'
#!/usr/bin/env bash
printf 'security|%s\n' "$*" >> "$FAKE_AUX_LOG"
FAKE_SECURITY
chmod +x "$BIN_DIR/security"

cat > "$BIN_DIR/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -euo pipefail
command="$1"
shift
case "$command" in
  has-session)
    target="${*: -1}"
    target="${target#=}"
    [ -f "$FAKE_TMUX_STATE/sessions/$target" ]
    ;;
  display-message)
    target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$target" in
      =*:) target="${target#=}"; target="${target%:}" ;;
      *) echo "display-message requires an exact session-form target" >&2; exit 1 ;;
    esac
    cat "$FAKE_TMUX_STATE/sessions/$target"
    ;;
  new-session)
    session=""
    directory=""
    args="$*"
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) session="$2"; shift 2 ;;
        -c) directory="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$directory" > "$FAKE_TMUX_STATE/sessions/$session"
    printf 'new-session|%s|%s|%s\n' "$session" "$directory" "$args" >> "$FAKE_TMUX_LOG"
    ;;
  switch-client|attach)
    printf '%s|%s\n' "$command" "$*" >> "$FAKE_TMUX_LOG"
    ;;
  list-panes)
    ;;
  capture-pane)
    printf '\n'
    ;;
  send-keys)
    printf 'send-keys|%s\n' "$*" >> "$FAKE_TMUX_LOG"
    ;;
  *)
    echo "unexpected fake tmux command: $command" >&2
    exit 1
    ;;
esac
FAKE_TMUX
chmod +x "$BIN_DIR/tmux"

COPILOT_BASE="$TMP/copilot-workspace"
CLAUDE_BASE="$TMP/claude-workspace"
CODEX_BASE="$TMP/codex-workspace"
mkdir -p "$COPILOT_BASE" "$CLAUDE_BASE" "$CODEX_BASE"

run_agent() {
  env -u TMUX \
    HOME="$HOME_DIR" \
    XDG_CONFIG_HOME="$TMP/config" \
    PATH="$BIN_DIR:/usr/bin:/bin" \
    TMUX="fake" \
    FAKE_TMUX_STATE="$STATE_DIR" \
    FAKE_TMUX_LOG="$LOG" \
    FAKE_AUX_LOG="$AUX_LOG" \
    COPILOT_WORKSPACE_BASE="$COPILOT_BASE" \
    CLAUDE_WORKSPACE_BASE="$CLAUDE_BASE" \
    CODEX_WORKSPACE_BASE="$CODEX_BASE" \
    SESSION_WARN_MB=0 \
    "$@"
}

run_agent_without_tmux() {
  env -u TMUX \
    HOME="$HOME_DIR" \
    XDG_CONFIG_HOME="$TMP/config" \
    PATH="$BIN_DIR:/usr/bin:/bin" \
    FAKE_TMUX_STATE="$STATE_DIR" \
    FAKE_TMUX_LOG="$LOG" \
    FAKE_AUX_LOG="$AUX_LOG" \
    COPILOT_WORKSPACE_BASE="$COPILOT_BASE" \
    CLAUDE_WORKSPACE_BASE="$CLAUDE_BASE" \
    CODEX_WORKSPACE_BASE="$CODEX_BASE" \
    SESSION_WARN_MB=0 \
    "$@"
}

reset_tmux() {
  rm -rf "$STATE_DIR/sessions"
  mkdir -p "$STATE_DIR/sessions"
  : > "$LOG"
  : > "$AUX_LOG"
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    echo "did not expect '$2' in $1" >&2
    cat "$1" >&2
    exit 1
  fi
}

assert_contains() {
  grep -Fq -- "$2" "$1" || {
    echo "expected '$2' in $1" >&2
    cat "$1" >&2
    exit 1
  }
}

assert_fails_with() {
  expected="$1"
  shift
  set +e
  run_agent "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  status=$?
  set -e
  [ "$status" -eq "$expected" ] || {
    echo "expected status $expected, got $status: $*" >&2
    cat "$TMP/stderr" >&2
    exit 1
  }
}

run_agent "$BIN_DIR/remote-agent" --help >/dev/null
for backend in copilot claude codex; do
  run_agent "$BIN_DIR/remote-agent" "$backend" --help >/dev/null
  run_agent "$BIN_DIR/$backend-agent" --help >/dev/null
done
assert_fails_with 2 "$BIN_DIR/remote-agent"
assert_fails_with 2 "$BIN_DIR/remote-agent" unknown alpha
assert_fails_with 2 "$BIN_DIR/remote-agent" copilot alpha extra
assert_fails_with 2 "$BIN_DIR/remote-agent" copilot "x/../../claude-workspace/agent-victim"
[ ! -e "$TMP/claude-workspace/agent-victim" ]
assert_fails_with 2 "$BIN_DIR/ca" alpha
assert_fails_with 2 "$BIN_DIR/cc" alpha
assert_fails_with 2 "$BIN_DIR/co" alpha
assert_fails_with 2 "$BIN_DIR/mystery-agent" alpha

for backend in copilot claude codex; do
  reset_tmux
  run_agent "$BIN_DIR/remote-agent" "$backend" alpha
  assert_contains "$LOG" "new-session|$backend-alpha|$TMP/$backend-workspace/agent-alpha"
  assert_contains "$LOG" "$backend"
  if [ "$backend" = "codex" ]; then
    assert_not_contains "$LOG" "resume --last"
  fi

  canonical_log="$(cat "$LOG")"
  reset_tmux
  run_agent "$BIN_DIR/$backend-agent" alpha
  [ "$(cat "$LOG")" = "$canonical_log" ] || {
    echo "$backend alias differs from canonical command" >&2
    exit 1
  }
done

reset_tmux
mkdir -p "$COPILOT_BASE/agent-alpha"
printf '%s\n' "$COPILOT_BASE/agent-alpha" > "$STATE_DIR/sessions/alpha"
run_agent "$BIN_DIR/remote-agent" copilot alpha
assert_contains "$LOG" "switch-client|-t =alpha"

reset_tmux
mkdir -p "$TMP/other"
printf '%s\n' "$TMP/other" > "$STATE_DIR/sessions/alpha"
run_agent "$BIN_DIR/remote-agent" copilot alpha
assert_contains "$LOG" "new-session|copilot-alpha|$COPILOT_BASE/agent-alpha"

reset_tmux
mkdir -p "$CLAUDE_BASE/agent-alpha" "$TMP/other"
printf '%s\n' "$TMP/other" > "$STATE_DIR/sessions/claude-alpha"
assert_fails_with 1 "$BIN_DIR/remote-agent" claude alpha
[ ! -s "$LOG" ]
assert_contains "$TMP/stderr" "belongs to another workspace"

reset_tmux
mkdir -p "$CLAUDE_BASE/agent-alpha"
ln -s "$CLAUDE_BASE/agent-alpha" "$TMP/claude-agent-link"
printf '%s\n' "$TMP/claude-agent-link" > "$STATE_DIR/sessions/claude-alpha"
run_agent "$BIN_DIR/remote-agent" claude alpha
assert_contains "$LOG" "switch-client|-t =claude-alpha"

reset_tmux
printf '%s\n' "$CLAUDE_BASE/agent-alpha" > "$STATE_DIR/sessions/claude-alpha"
run_agent_without_tmux "$BIN_DIR/remote-agent" claude alpha >"$TMP/stdout" 2>"$TMP/stderr" || status=$?
[ "${status:-0}" -eq 1 ]
assert_contains "$TMP/stderr" "refusing to attach"
unset status

reset_tmux
mkdir -p "$HOME_DIR/.copilot/session-state/selected" "$COPILOT_BASE/agent-selected"
cat > "$HOME_DIR/.copilot/session-state/selected/workspace.yaml" <<EOF
id: 11111111-1111-1111-1111-111111111111
cwd: $COPILOT_BASE/agent-selected
updated_at: 2026-08-02T10:00:00Z
summary_count: 2
EOF
run_agent "$BIN_DIR/remote-agent" copilot selected
assert_contains "$LOG" "--session-id='11111111-1111-1111-1111-111111111111'"

reset_tmux
mkdir -p "$HOME_DIR/Library/Keychains"
touch "$HOME_DIR/Library/Keychains/login.keychain-db"
run_agent "$BIN_DIR/remote-agent" copilot keychain
assert_contains "$AUX_LOG" "security|unlock-keychain"

reset_tmux
MAILBOX_DIR="$HOME_DIR/.copilot/installed-plugins/_direct/dfrysinger--skills/skills/mailbox/scripts"
mkdir -p "$MAILBOX_DIR"
cat > "$MAILBOX_DIR/mailbox-poke.sh" <<'MAILBOX'
#!/usr/bin/env bash
printf 'mailbox|%s\n' "$*" >> "$FAKE_AUX_LOG"
MAILBOX
chmod +x "$MAILBOX_DIR/mailbox-poke.sh"
MAILBOX_INTEGRATION=true run_agent "$BIN_DIR/remote-agent" copilot mailbox
sleep 0.1
assert_contains "$AUX_LOG" "mailbox|copilot-mailbox --wait"

reset_tmux
mkdir -p "$HOME_DIR/.claude/projects/$(printf '%s' "$CLAUDE_BASE/agent-alpha" | sed 's|/|-|g')"
touch "$HOME_DIR/.claude/projects/$(printf '%s' "$CLAUDE_BASE/agent-alpha" | sed 's|/|-|g')/session.jsonl"
run_agent "$BIN_DIR/remote-agent" claude alpha
assert_contains "$LOG" "claude --continue"

reset_tmux
mkdir -p "$HOME_DIR/.codex/sessions/2026/08/02"
printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' \
  "$CODEX_BASE/agent-alpha" > "$HOME_DIR/.codex/sessions/2026/08/02/rollout.jsonl"
run_agent "$BIN_DIR/remote-agent" codex alpha
assert_contains "$LOG" "codex resume --last"

for backend in copilot claude codex; do
  reset_tmux
  ALLOW_ALL=true run_agent "$BIN_DIR/remote-agent" "$backend" permissions
  case "$backend" in
    copilot) flag="--allow-all" ;;
    claude) flag="--dangerously-skip-permissions" ;;
    codex) flag="--dangerously-bypass-approvals-and-sandbox" ;;
  esac
  assert_contains "$LOG" "$flag"
done

echo "agent wrapper tests passed"
