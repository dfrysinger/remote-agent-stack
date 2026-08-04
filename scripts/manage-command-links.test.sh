#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="$ROOT/scripts/manage-command-links.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WRAPPER="$TMP/agent"
SCREEN_WRAPPER="$TMP/agent-screen"
BIN_DIR="$TMP/bin"
mkdir -p "$BIN_DIR"
touch "$WRAPPER" "$SCREEN_WRAPPER"

run_manager() {
  "$MANAGER" --mode "$1" --wrapper "$WRAPPER" \
    --screen-wrapper "$SCREEN_WRAPPER" --bin-dir "$BIN_DIR"
}

run_manager install >/dev/null
for name in agent-stack copilot-agent claude-agent codex-agent; do
  [ -L "$BIN_DIR/$name" ]
  [ "$(readlink "$BIN_DIR/$name")" = "$WRAPPER" ]
done
[ "$(readlink "$BIN_DIR/agent-screen")" = "$SCREEN_WRAPPER" ]
for name in ca cc co ss remote-agent remote-screen; do
  [ ! -e "$BIN_DIR/$name" ]
done

ln -s "$WRAPPER" "$BIN_DIR/ca"
ln -s "$TMP/foreign" "$BIN_DIR/cc"
ln -s "$(dirname "$SCREEN_WRAPPER")/ss" "$BIN_DIR/ss"
run_manager install >/dev/null
[ ! -e "$BIN_DIR/ca" ]
[ "$(readlink "$BIN_DIR/cc")" = "$TMP/foreign" ]
[ ! -e "$BIN_DIR/ss" ]

run_manager install >/dev/null
run_manager uninstall >/dev/null
for name in agent-stack copilot-agent claude-agent codex-agent agent-screen ca co ss remote-agent remote-screen; do
  [ ! -e "$BIN_DIR/$name" ]
done
[ "$(readlink "$BIN_DIR/cc")" = "$TMP/foreign" ]

ln -s "$TMP/foreign" "$BIN_DIR/agent-stack"
if run_manager check >/dev/null 2>&1; then
  echo "foreign canonical command passed preflight" >&2
  exit 1
fi
[ "$(readlink "$BIN_DIR/agent-stack")" = "$TMP/foreign" ]

rm "$BIN_DIR/agent-stack"
ln -s "$TMP/foreign" "$BIN_DIR/agent-screen"
if run_manager check >/dev/null 2>&1; then
  echo "foreign agent-screen command passed preflight" >&2
  exit 1
fi
[ "$(readlink "$BIN_DIR/agent-screen")" = "$TMP/foreign" ]

MISSING_BIN="$TMP/missing/bin"
"$MANAGER" --mode uninstall --wrapper "$WRAPPER" \
  --screen-wrapper "$SCREEN_WRAPPER" --bin-dir "$MISSING_BIN" >/dev/null
[ ! -e "$MISSING_BIN" ]

echo "manage-command-links tests passed"
