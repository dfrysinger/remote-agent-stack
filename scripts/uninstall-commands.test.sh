#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN_DIR="$TMP/bin"
mkdir -p "$BIN_DIR"
for name in agent-stack copilot-agent claude-agent codex-agent ca cc co remote-agent; do
  ln -s "$ROOT/bin/agent" "$BIN_DIR/$name"
done
ln -s "$ROOT/bin/agent-screen" "$BIN_DIR/agent-screen"
ln -s "$ROOT/bin/remote-screen" "$BIN_DIR/remote-screen"
ln -s "$ROOT/bin/ss" "$BIN_DIR/ss"
rm "$BIN_DIR/cc"
ln -s "$TMP/foreign" "$BIN_DIR/cc"
touch "$TMP/non-command-artifact"

REMOTE_AGENT_STACK_BIN_DIR="$BIN_DIR" "$ROOT/uninstall.sh" --commands-only >/dev/null

for name in agent-stack copilot-agent claude-agent codex-agent agent-screen remote-agent remote-screen ca co ss; do
  [ ! -e "$BIN_DIR/$name" ]
done
[ "$(readlink "$BIN_DIR/cc")" = "$TMP/foreign" ]
[ -f "$TMP/non-command-artifact" ]

echo "commands-only uninstall tests passed"
