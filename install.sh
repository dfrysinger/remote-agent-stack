#!/usr/bin/env bash
# remote-agent-stack installer
#
# Installs the userland prerequisites for running named Copilot CLI agents
# in tmux over Tailscale SSH on macOS:
#   - Homebrew (if missing)
#   - tmux + tailscale (via brew)
#   - /etc/resolver/ts.net (MagicDNS fix for Homebrew tailscaled)
#   - copilot-agent wrapper symlinked into /usr/local/bin
#
# Manual GUI/interactive steps are printed at the end (they can't be
# automated).
#
# Idempotent: safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_SRC="$REPO_ROOT/bin/copilot-agent"
WRAPPER_DST="/usr/local/bin/copilot-agent"
RESOLVER_SRC="$REPO_ROOT/etc/resolver-ts.net"
RESOLVER_DST="/etc/resolver/ts.net"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/remote-agent-stack"

# ---- helpers ---------------------------------------------------------------

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip()  { printf '  \033[2m·\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
todo()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }

# ---- preflight -------------------------------------------------------------

bold "Preflight"

if [ "$(uname)" != "Darwin" ]; then
  fail "This installer currently supports macOS only."
fi
ok "macOS detected ($(sw_vers -productVersion))"

if [ "$(uname -m)" != "arm64" ]; then
  warn "Non-arm64 Mac detected — paths assume /opt/homebrew; expect bumps."
fi

# ---- Xcode Command Line Tools ---------------------------------------------

bold "Xcode Command Line Tools"

if xcode-select -p >/dev/null 2>&1; then
  ok "already installed ($(xcode-select -p))"
else
  warn "not installed — triggering installer GUI"
  xcode-select --install || true
  echo
  echo "    Complete the GUI installer, then re-run this script."
  exit 0
fi

# ---- Homebrew --------------------------------------------------------------

bold "Homebrew"

if have brew; then
  ok "already installed ($(brew --version | head -1))"
else
  todo "installing Homebrew (will prompt for sudo password)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add to PATH for the rest of this script
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# ---- brew packages ---------------------------------------------------------

bold "Homebrew packages"

for pkg in tmux tailscale; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    todo "brew install $pkg"
    brew install "$pkg"
  fi
done

# ---- tailscaled service ----------------------------------------------------

bold "Tailscale daemon"

if sudo brew services list 2>/dev/null | awk '$1=="tailscale"{print $2}' | grep -qi started; then
  ok "tailscaled already running"
else
  todo "starting tailscaled (sudo brew services start tailscale)"
  sudo brew services start tailscale
fi

# ---- MagicDNS resolver fix -------------------------------------------------

bold "MagicDNS resolver"

if [ -f "$RESOLVER_DST" ] && cmp -s "$RESOLVER_SRC" "$RESOLVER_DST"; then
  ok "$RESOLVER_DST already up to date"
else
  todo "writing $RESOLVER_DST (sudo)"
  sudo install -m 0644 "$RESOLVER_SRC" "$RESOLVER_DST"
  sudo dscacheutil -flushcache 2>/dev/null || true
  ok "wrote $RESOLVER_DST"
fi

# ---- copilot-agent wrapper -------------------------------------------------

bold "copilot-agent wrapper"

chmod +x "$WRAPPER_SRC"

# Ensure /usr/local/bin exists (rare on fresh Apple silicon Macs).
if [ ! -d /usr/local/bin ]; then
  todo "creating /usr/local/bin (sudo)"
  sudo mkdir -p /usr/local/bin
fi

if [ -L "$WRAPPER_DST" ] && [ "$(readlink "$WRAPPER_DST")" = "$WRAPPER_SRC" ]; then
  ok "$WRAPPER_DST already points at this repo"
else
  if [ -e "$WRAPPER_DST" ] || [ -L "$WRAPPER_DST" ]; then
    todo "replacing existing $WRAPPER_DST (sudo)"
    sudo rm -f "$WRAPPER_DST"
  else
    todo "symlinking $WRAPPER_DST -> $WRAPPER_SRC (sudo)"
  fi
  sudo ln -s "$WRAPPER_SRC" "$WRAPPER_DST"
  ok "$WRAPPER_DST -> $WRAPPER_SRC"
fi

# ---- config file -----------------------------------------------------------

bold "Configuration"

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config" ]; then
  cat > "$CONFIG_DIR/config" <<'EOF'
# remote-agent-stack — copilot-agent wrapper config
#
# WORKSPACE_BASE: where agent working directories live.
#   Each agent <Name> uses: $WORKSPACE_BASE/agent-<lowercase-name>
# WORKSPACE_BASE="$HOME/Library/CloudStorage/Dropbox/copilot-workspace"

# COPILOT_BIN: name of the Copilot CLI binary (must be in PATH).
# COPILOT_BIN="copilot"

# AGENT_DIR_PREFIX: prefix for per-agent directory names.
# AGENT_DIR_PREFIX="agent-"
EOF
  ok "wrote default config to $CONFIG_DIR/config"
else
  skip "$CONFIG_DIR/config already exists"
fi

# ---- Copilot CLI detection -------------------------------------------------

bold "Copilot CLI"

if have copilot; then
  ok "copilot CLI found ($(copilot --version 2>&1 | head -1))"
else
  warn "copilot CLI not found in PATH."
  echo "    Install per https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli"
fi

# ---- manual steps ---------------------------------------------------------

echo
bold "Manual steps remaining (can't be automated)"
cat <<MANUAL

  1. Grant Full Disk Access to the binaries that need it:
       System Settings → Privacy & Security → Full Disk Access → +
       Add the REAL binaries (not the symlinks):
         $(brew --prefix tailscale)/bin/tailscaled
         $(brew --prefix tmux)/bin/tmux
       (Use Cmd-Shift-G in the file picker to paste these paths.)

  2. Authenticate the Tailscale daemon and enable Tailscale SSH:
       sudo tailscale up --ssh
       (Follow the auth URL it prints; this only needs to happen once
       per machine.)

  3. First Copilot CLI launch will ask:
       "System vault not available — store token in plain text config file?"
     Answer Yes. The token lands in ~/.copilot/config.json (mode 600).

  4. Test:
       copilot-agent Alpha

  5. (Optional) In Termius, set each agent's snippet to a single line:
       copilot-agent Alpha
       copilot-agent Bravo
       ...

MANUAL

bold "Install complete."
