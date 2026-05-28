#!/usr/bin/env bash
# remote-agent-stack uninstaller
#
# Removes the userland artifacts installed by install.sh:
#   - /usr/local/bin/copilot-agent symlink
#   - /usr/local/bin/ca symlink (short alias)
#   - /etc/resolver/ts.net
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
