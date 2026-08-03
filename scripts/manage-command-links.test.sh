#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANAGER="$ROOT/scripts/manage-command-links.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WRAPPER="$TMP/agent"
BIN_DIR="$TMP/bin"
mkdir -p "$BIN_DIR"
touch "$WRAPPER"

run_manager() {
  "$MANAGER" --mode "$1" --wrapper "$WRAPPER" --bin-dir "$BIN_DIR"
}

run_manager install >/dev/null
for name in remote-agent copilot-agent claude-agent codex-agent; do
  [ -L "$BIN_DIR/$name" ]
  [ "$(readlink "$BIN_DIR/$name")" = "$WRAPPER" ]
done
for name in ca cc co; do
  [ ! -e "$BIN_DIR/$name" ]
done

ln -s "$WRAPPER" "$BIN_DIR/ca"
ln -s "$TMP/foreign" "$BIN_DIR/cc"
run_manager install >/dev/null
[ ! -e "$BIN_DIR/ca" ]
[ "$(readlink "$BIN_DIR/cc")" = "$TMP/foreign" ]

run_manager install >/dev/null
run_manager uninstall >/dev/null
for name in remote-agent copilot-agent claude-agent codex-agent ca co; do
  [ ! -e "$BIN_DIR/$name" ]
done
[ "$(readlink "$BIN_DIR/cc")" = "$TMP/foreign" ]

ln -s "$TMP/foreign" "$BIN_DIR/remote-agent"
if run_manager check >/dev/null 2>&1; then
  echo "foreign canonical command passed preflight" >&2
  exit 1
fi
[ "$(readlink "$BIN_DIR/remote-agent")" = "$TMP/foreign" ]

MISSING_BIN="$TMP/missing/bin"
"$MANAGER" --mode uninstall --wrapper "$WRAPPER" --bin-dir "$MISSING_BIN" >/dev/null
[ ! -e "$MISSING_BIN" ]

echo "manage-command-links tests passed"
