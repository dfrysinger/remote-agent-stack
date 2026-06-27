#!/usr/bin/env bash
# remote-agent-stack uninstaller
#
# Removes the userland artifacts installed by install.sh:
#   - /usr/local/bin/copilot-agent symlink
#   - /usr/local/bin/ca symlink (short alias)
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
WRAPPER_SRC="$REPO_ROOT/bin/copilot-agent"

PURGE=false
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

bold "Removing copilot-agent wrapper"
if [ -L /usr/local/bin/copilot-agent ] || [ -e /usr/local/bin/copilot-agent ]; then
  todo "sudo rm /usr/local/bin/copilot-agent"
  sudo rm -f /usr/local/bin/copilot-agent
  ok "removed"
else
  skip "/usr/local/bin/copilot-agent not present"
fi

bold "Removing 'ca' short alias"
# Only remove the link if it points at THIS clone's wrapper (exact absolute
# match). Anything else — a foreign tool's symlink, a hand-rolled alias, a
# real file — is left alone.
if [ -L /usr/local/bin/ca ] && [ "$(readlink /usr/local/bin/ca)" = "$WRAPPER_SRC" ]; then
  todo "sudo rm /usr/local/bin/ca"
  sudo rm -f /usr/local/bin/ca
  ok "removed"
elif [ -L /usr/local/bin/ca ]; then
  skip "/usr/local/bin/ca symlinks to $(readlink /usr/local/bin/ca) — not ours, leaving alone"
elif [ -e /usr/local/bin/ca ]; then
  skip "/usr/local/bin/ca exists and is not our symlink — leaving it alone"
else
  skip "/usr/local/bin/ca not present"
fi

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
  CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/remote-agent-stack"
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
[ "$PURGE" = "false" ] && echo "  • Wrapper config:           re-run with --purge"
