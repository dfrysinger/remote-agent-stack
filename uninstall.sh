#!/usr/bin/env bash
# remote-agent-stack uninstaller
#
# Removes the userland artifacts installed by install.sh:
#   - /usr/local/bin/copilot-agent + ca symlinks (copilot backend)
#   - /usr/local/bin/claude-agent  + cc symlinks (claude  backend)
#   - /usr/local/bin/ss and /usr/local/bin/vncfix symlinks (GUI helpers)
#   - selected CLI agent-help MCP entries + managed instruction blocks
#   - an owned headless Dreaming runtime
#   - bounded Screen Sharing helper, watchdog, root config, state, and sudoers
#   - /etc/resolver/ts.net
#   - ~/.tmux.conf managed block (status-bar-off settings)
#
# Does NOT uninstall Homebrew packages (tmux, tailscale) — those may be
# used by other tools on your system. Run `brew uninstall tmux tailscale`
# manually if you want them gone.
#
# Does NOT remove ~/.config/remote-agent-stack/ unless --purge is given.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_SRC="$REPO_ROOT/bin/agent"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/remote-agent-stack"
MCP_SERVER="$CONFIG_DIR/agent-help/server/server.mjs"
MANAGE_AGENT_HELP="$REPO_ROOT/scripts/manage-agent-help.mjs"
MANAGE_SKILLS_PLUGIN="$REPO_ROOT/scripts/manage-skills-plugin.mjs"
MANAGE_DREAMING="$REPO_ROOT/scripts/manage-dreaming.mjs"
SS_ROOT_DST="/usr/local/libexec/ss-on-demand"
SS_ROOT_CONFIG_DIR="/usr/local/etc/remote-agent-stack"
SS_STATE_DIR="/var/db/remote-agent-stack"
SS_EXPIRY_PLIST="/Library/LaunchDaemons/com.remote-agent-stack.screen-sharing-expiry.plist"
SS_EXPIRY_LABEL="com.remote-agent-stack.screen-sharing-expiry"
SS_SUDOERS="/etc/sudoers.d/ss-on-demand"

PURGE=false
UNINSTALL_STATUS=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=true ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[2m·\033[0m %s\n' "$*"; }
todo() { printf '  \033[36m→\033[0m %s\n' "$*"; }

read_config_var() {
  local var="$1"
  [ -f "$CONFIG_DIR/config" ] || return 0
  awk -v v="$var" -F'=' '$1 ~ "^[[:space:]]*" v "$" {
    sub("^[[:space:]]*" v "=", "", $0)
    gsub(/^"|"$/, "", $0)
    print
    exit
  }' "$CONFIG_DIR/config" 2>/dev/null || true
}

bold "Removing bounded Screen Sharing support"
if [ -L "$SS_ROOT_DST" ]; then
  echo "Symlinked helper at $SS_ROOT_DST; refusing to execute or remove it." >&2
  exit 1
elif [ -f "$SS_ROOT_DST" ]; then
  for privileged_path in /usr/local /usr/local/libexec "$SS_ROOT_DST"; do
    OWNER="$(stat -f %Su "$privileged_path")"
    MODE="$(stat -f %OLp "$privileged_path")"
    if [ "$OWNER" != root ] || [ $((8#$MODE & 8#022)) -ne 0 ]; then
      echo "Unsafe privileged path ownership or mode: $privileged_path" >&2
      exit 1
    fi
  done
  if grep -q "remote-agent-stack managed helper" "$SS_ROOT_DST" ||
     grep -q "ss-on-demand must run as root" "$SS_ROOT_DST"; then
    todo "disable active access, unload watchdog, and remove privileged files"
    SCREEN_SHARING_PORT="$(
      awk -F= '$1=="SCREEN_SHARING_PORT" {
        gsub(/^"|"$/, "", $2)
        print $2
        exit
      }' "$CONFIG_DIR/config" 2>/dev/null || true
    )"
    SCREEN_SHARING_PORT="${SCREEN_SHARING_PORT:-15900}"
    if command -v tailscale >/dev/null 2>&1; then
      MAPPING_TARGET="$(
        tailscale serve status --json 2>/dev/null |
          /usr/bin/python3 -c '
import json, sys
port = sys.argv[1]
try:
    entry = (json.load(sys.stdin).get("TCP") or {}).get(port) or {}
    print(entry.get("TCPForward") or "")
except Exception:
    pass
' "$SCREEN_SHARING_PORT" || true
      )"
      if [ "$MAPPING_TARGET" = "localhost:5900" ] ||
         [ "$MAPPING_TARGET" = "tcp://localhost:5900" ]; then
        tailscale serve --yes --tcp "$SCREEN_SHARING_PORT" off >/dev/null
      fi
    fi
    sudo bash -euo pipefail <<PRIVILEGED_REMOVE
      "$SS_ROOT_DST" off >/dev/null
      launchctl bootout "system/$SS_EXPIRY_LABEL" 2>/dev/null || true
      rm -f "$SS_EXPIRY_PLIST" "$SS_SUDOERS" "$SS_ROOT_DST"
      rm -f "$SS_ROOT_CONFIG_DIR/screen-sharing.conf"
      rmdir "$SS_ROOT_CONFIG_DIR" 2>/dev/null || true
      rm -f "$SS_STATE_DIR/screen-sharing-lease"
      rm -f "$SS_STATE_DIR/screen-sharing.lock"
      rmdir "$SS_STATE_DIR" 2>/dev/null || true
      if [ -f /tmp/ss-lease.pid ]; then
        legacy_pid="\$(cat /tmp/ss-lease.pid 2>/dev/null || true)"
        case "\$legacy_pid" in
          *[!0-9]*|"") ;;
          *)
            legacy_command="\$(ps -p "\$legacy_pid" -o command= 2>/dev/null || true)"
            if printf '%s' "\$legacy_command" | grep -Eq 'sleep [0-9]+.*ss off'; then
              kill "\$legacy_pid" 2>/dev/null || true
            fi
            ;;
        esac
        rm -f /tmp/ss-lease.pid
      fi
      rm -f /tmp/ss-auto-off.log
PRIVILEGED_REMOVE
    ok "removed bounded Screen Sharing support"
  else
    echo "Foreign helper at $SS_ROOT_DST; refusing to remove it." >&2
    exit 1
  fi
else
  skip "$SS_ROOT_DST not present"
fi

bold "Removing agent-help MCP configuration"
if command -v node >/dev/null 2>&1 && [ -f "$MANAGE_AGENT_HELP" ]; then
  if node "$MANAGE_AGENT_HELP" --mode reconcile --clis "" --node "$(command -v node)" --server "$MCP_SERVER"; then
    ok "removed owned MCP entries and managed instruction blocks"
  else
    echo "Agent-help configuration removal failed; refusing to continue." >&2
    exit 1
  fi
else
  echo "Node.js and $MANAGE_AGENT_HELP are required for ownership-safe MCP removal." >&2
  exit 1
fi

bold "Removing owned dfrysinger skills plugins"
if command -v node >/dev/null 2>&1 && [ -f "$MANAGE_SKILLS_PLUGIN" ]; then
  if node "$MANAGE_SKILLS_PLUGIN" \
    --mode reconcile \
    --clis "" \
    --explicit-clis "" \
    --fail-on-residual true; then
    ok "removed owned plugins and marketplaces from available CLIs"
  else
    echo "Some owned skills plugin artifacts could not be removed; continuing stack cleanup." >&2
    UNINSTALL_STATUS=1
  fi
else
  echo "Node.js and $MANAGE_SKILLS_PLUGIN are required for ownership-safe skills removal; continuing." >&2
  UNINSTALL_STATUS=1
fi

bold "Removing owned Dreaming runtime"
if command -v node >/dev/null 2>&1 && [ -f "$MANAGE_DREAMING" ]; then
  DREAMING_REPO_ROOT="$(read_config_var DREAMING_REPO_ROOT)"
  DREAMING_REPO_ROOT="${DREAMING_REPO_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/remote-agent-stack/dreaming}"
  if node "$MANAGE_DREAMING" \
    --mode reconcile \
    --enabled false \
    --explicit false \
    --repo "$DREAMING_REPO_ROOT" \
    --fail-on-residual true; then
    ok "removed owned Dreaming runtime and preserved its checkout"
  else
    echo "Owned Dreaming runtime could not be removed; continuing stack cleanup." >&2
    UNINSTALL_STATUS=1
  fi
else
  echo "Node.js and $MANAGE_DREAMING are required for ownership-safe Dreaming removal; continuing." >&2
  UNINSTALL_STATUS=1
fi

bold "Removing copilot-agent wrapper"
if [ -L /usr/local/bin/copilot-agent ] || [ -e /usr/local/bin/copilot-agent ]; then
  todo "sudo rm /usr/local/bin/copilot-agent"
  sudo rm -f /usr/local/bin/copilot-agent
  ok "removed"
else
  skip "/usr/local/bin/copilot-agent not present"
fi

bold "Removing wrapper aliases (ca, claude-agent, cc)"
# Only remove links that point at THIS clone's wrapper (exact absolute
# match). Anything else — a foreign tool's symlink, a hand-rolled alias, a
# real file — is left alone.
for _dst in /usr/local/bin/ca /usr/local/bin/claude-agent /usr/local/bin/cc; do
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$WRAPPER_SRC" ]; then
    todo "sudo rm $_dst"
    sudo rm -f "$_dst"
    ok "removed $_dst"
  elif [ -L "$_dst" ]; then
    skip "$_dst symlinks to $(readlink "$_dst") — not ours, leaving alone"
  elif [ -e "$_dst" ]; then
    skip "$_dst exists and is not our symlink — leaving it alone"
  else
    skip "$_dst not present"
  fi
done

bold "Removing GUI helpers (ss, vncfix)"
# Same exact-match guard as the 'ca' alias: only remove links that point at
# THIS clone's bin/ scripts; leave foreign symlinks and real files alone.
for _pair in "ss:$REPO_ROOT/bin/ss" "vncfix:$REPO_ROOT/bin/vncfix"; do
  _name="${_pair%%:*}"; _src="${_pair##*:}"; _dst="/usr/local/bin/$_name"
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_src" ]; then
    todo "sudo rm $_dst"
    sudo rm -f "$_dst"
    ok "removed"
  elif [ -L "$_dst" ]; then
    skip "$_dst symlinks to $(readlink "$_dst") — not ours, leaving alone"
  elif [ -e "$_dst" ]; then
    skip "$_dst exists and is not our symlink — leaving it alone"
  else
    skip "$_dst not present"
  fi
done

bold "Removing MagicDNS resolver"
if [ -f /etc/resolver/ts.net ]; then
  todo "sudo rm /etc/resolver/ts.net"
  sudo rm -f /etc/resolver/ts.net
  sudo dscacheutil -flushcache 2>/dev/null || true
  ok "removed"
else
  skip "/etc/resolver/ts.net not present"
fi

bold "Removing tmux config managed block"
# Strip ONLY our marked block from ~/.tmux.conf; leave any hand-written
# config the user added around it untouched. If the file ends up empty
# (it only ever held our block), remove it entirely.
TMUXCONF_DST="$HOME/.tmux.conf"
TMUX_BLOCK_BEGIN="# >>> remote-agent-stack (managed) >>>"
TMUX_BLOCK_END="# <<< remote-agent-stack (managed) <<<"
if [ -f "$TMUXCONF_DST" ] && grep -qF "$TMUX_BLOCK_BEGIN" "$TMUXCONF_DST"; then
  TMUX_TMP="$(mktemp)"
  awk -v b="$TMUX_BLOCK_BEGIN" -v e="$TMUX_BLOCK_END" '
    $0==b { inblk=1; next }
    $0==e { inblk=0; next }
    !inblk { print }
  ' "$TMUXCONF_DST" > "$TMUX_TMP"
  # Collapse to empty if nothing but blank lines remain.
  if [ -n "$(tr -d '[:space:]' < "$TMUX_TMP")" ]; then
    mv "$TMUX_TMP" "$TMUXCONF_DST"
    ok "removed managed block from $TMUXCONF_DST (kept your other config)"
  else
    rm -f "$TMUX_TMP" "$TMUXCONF_DST"
    ok "removed $TMUXCONF_DST (it only held our block)"
  fi
  pgrep -x tmux >/dev/null 2>&1 && tmux set -g status on 2>/dev/null || true
else
  skip "no remote-agent-stack block in $TMUXCONF_DST"
fi

if $PURGE; then
  bold "Purging config"
  if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    ok "removed $CONFIG_DIR"
  else
    skip "$CONFIG_DIR not present"
  fi
fi

echo
bold "Done."
echo
echo "Not removed (do these manually if you want them gone):"
echo "  • Homebrew packages:        brew uninstall tmux tailscale"
echo "  • Tailscale daemon:         sudo brew services stop tailscale"
echo "  • FDA grants:               System Settings → Privacy & Security → Full Disk Access"
echo "  • Copilot CLI + ~/.copilot: per Copilot CLI docs"
echo "  • Tailscale network state:  sudo tailscale logout"
if [ "$PURGE" = "false" ]; then
  echo "  • Wrapper + recipient config: re-run with --purge"
fi
if [ "$UNINSTALL_STATUS" -ne 0 ]; then
  echo "  • Skills plugin state: restore missing CLIs and rerun uninstall"
  echo "  • Dreaming state: restore its checkout and rerun uninstall"
  exit "$UNINSTALL_STATUS"
fi
