#!/usr/bin/env bash
# install-gui.command
#
# Double-clickable installer launcher for macOS.
#
# Opens a fresh Terminal.app window (so sudo password prompts are visible
# and you can type into them — including over VNC / Screens) and runs the
# real installer there.
#
# Why this exists: when install.sh is launched from a non-interactive
# context (a CI tool, an editor's "run script" button, an MCP/agent
# session, etc.) the sudo password prompt is hidden or unreachable. This
# wrapper sidesteps that by always landing the installer in a real
# Terminal.app window.
#
# Files with the .command extension are double-clickable in Finder.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

if [ ! -x "$INSTALLER" ]; then
  echo "Installer not found or not executable: $INSTALLER" >&2
  exit 1
fi

# AppleScript needs the path quoted carefully. Use single-quotes around
# the shell command and embed the path via printf -q.
osascript <<EOF
tell application "Terminal"
  activate
  do script "clear && echo '--- remote-agent-stack installer ---' && $(printf '%q' "$INSTALLER")"
end tell
EOF

echo "Installer launched in a new Terminal.app window."
echo "Switch to that window (or VNC in) to enter your password when prompted."
