#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN_DIR="$TMP/bin"
mkdir -p "$BIN_DIR"
for name in remote-agent copilot-agent claude-agent codex-agent ca cc co; do
  ln -s "$ROOT/bin/agent" "$BIN_DIR/$name"
done
rm "$BIN_DIR/cc"
ln -s "$TMP/foreign" "$BIN_DIR/cc"
touch "$TMP/non-command-artifact"

REMOTE_AGENT_STACK_BIN_DIR="$BIN_DIR" "$ROOT/uninstall.sh" --commands-only >/dev/null

for name in remote-agent copilot-agent claude-agent codex-agent ca co; do
  [ ! -e "$BIN_DIR/$name" ]
done
[ "$(readlink "$BIN_DIR/cc")" = "$TMP/foreign" ]
[ -f "$TMP/non-command-artifact" ]

echo "commands-only uninstall tests passed"
