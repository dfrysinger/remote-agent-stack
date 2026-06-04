#!/usr/bin/env bash
# remote-agent-stack installer
#
# Installs the userland prerequisites for running named Copilot CLI agents
# in tmux over Tailscale SSH on macOS:
#   - Homebrew (if missing)
#   - tmux + tailscale (via brew)
#   - /etc/resolver/ts.net (MagicDNS fix for Homebrew tailscaled)
#   - copilot-agent wrapper symlinked into /usr/local/bin (also as `ca`)
#
# All operations that require root are batched into a single sudo
# invocation, so you only type your password once even on systems where
# the sudo cache expires per-command (managed Macs, etc).
#
# Manual GUI/interactive steps are printed at the end.
#
# Idempotent: safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_SRC="$REPO_ROOT/bin/copilot-agent"
WRAPPER_DST="/usr/local/bin/copilot-agent"
WRAPPER_SHORT_DST="/usr/local/bin/ca"
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
  todo "installing Homebrew (its installer will prompt for sudo itself)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
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

# ---- detect what needs root -----------------------------------------------
#
# We figure out exactly what privileged work is needed BEFORE prompting
# for sudo, so we can run it all in one sudo invocation below.

NEED_TAILSCALED_START=false
NEED_RESOLVER_WRITE=false
NEED_USRLOCALBIN_MKDIR=false
NEED_SYMLINK=false

if ! pgrep -xq tailscaled; then
  NEED_TAILSCALED_START=true
fi

if [ ! -f "$RESOLVER_DST" ] || ! cmp -s "$RESOLVER_SRC" "$RESOLVER_DST"; then
  NEED_RESOLVER_WRITE=true
fi

if [ ! -d /usr/local/bin ]; then
  NEED_USRLOCALBIN_MKDIR=true
fi

if [ -L "$WRAPPER_DST" ] && [ "$(readlink "$WRAPPER_DST")" = "$WRAPPER_SRC" ]; then
  :  # already correct
else
  NEED_SYMLINK=true
fi

if [ -L "$WRAPPER_SHORT_DST" ] && [ "$(readlink "$WRAPPER_SHORT_DST")" = "$WRAPPER_SRC" ]; then
  :  # already correct
elif [ -e "$WRAPPER_SHORT_DST" ]; then
  warn "$WRAPPER_SHORT_DST already exists (points elsewhere or is not ours) — leaving it alone (skipping 'ca' shortcut)"
else
  NEED_SYMLINK=true
fi

# Ensure the wrapper is executable (no sudo needed).
chmod +x "$WRAPPER_SRC"

# ---- single sudo block -----------------------------------------------------

bold "Privileged operations"

if $NEED_TAILSCALED_START || $NEED_RESOLVER_WRITE || $NEED_USRLOCALBIN_MKDIR || $NEED_SYMLINK; then
  echo
  echo "  The following privileged operations are needed:"
  $NEED_TAILSCALED_START   && echo "    • start tailscaled (brew services start tailscale)"
  $NEED_RESOLVER_WRITE     && echo "    • write $RESOLVER_DST (MagicDNS resolver)"
  $NEED_USRLOCALBIN_MKDIR  && echo "    • create /usr/local/bin"
  $NEED_SYMLINK            && echo "    • symlink $WRAPPER_DST and $WRAPPER_SHORT_DST -> $WRAPPER_SRC"
  echo
  echo "  ============================================================"
  echo "  >>>  Enter your login password at the prompt below.       <<<"
  echo "  ============================================================"
  echo

  # Build a single sudo script so the password is asked at most once.
  # We pass our state into the sub-shell via environment variables.
  NEED_TAILSCALED_START="$NEED_TAILSCALED_START" \
  NEED_RESOLVER_WRITE="$NEED_RESOLVER_WRITE" \
  NEED_USRLOCALBIN_MKDIR="$NEED_USRLOCALBIN_MKDIR" \
  NEED_SYMLINK="$NEED_SYMLINK" \
  RESOLVER_SRC="$RESOLVER_SRC" \
  RESOLVER_DST="$RESOLVER_DST" \
  WRAPPER_SRC="$WRAPPER_SRC" \
  WRAPPER_DST="$WRAPPER_DST" \
  WRAPPER_SHORT_DST="$WRAPPER_SHORT_DST" \
  BREW_BIN="$(command -v brew)" \
  sudo --preserve-env=NEED_TAILSCALED_START,NEED_RESOLVER_WRITE,NEED_USRLOCALBIN_MKDIR,NEED_SYMLINK,RESOLVER_SRC,RESOLVER_DST,WRAPPER_SRC,WRAPPER_DST,WRAPPER_SHORT_DST,BREW_BIN \
    bash -euo pipefail <<'PRIVILEGED_BLOCK'
    if [ "$NEED_TAILSCALED_START" = "true" ]; then
      echo "  → starting tailscaled"
      "$BREW_BIN" services start tailscale
    fi
    if [ "$NEED_RESOLVER_WRITE" = "true" ]; then
      echo "  → writing $RESOLVER_DST"
      mkdir -p /etc/resolver
      install -m 0644 "$RESOLVER_SRC" "$RESOLVER_DST"
      dscacheutil -flushcache 2>/dev/null || true
    fi
    if [ "$NEED_USRLOCALBIN_MKDIR" = "true" ]; then
      echo "  → creating /usr/local/bin"
      mkdir -p /usr/local/bin
    fi
    if [ "$NEED_SYMLINK" = "true" ]; then
      echo "  → symlinking $WRAPPER_DST"
      rm -f "$WRAPPER_DST"
      ln -s "$WRAPPER_SRC" "$WRAPPER_DST"

      # Short 'ca' alias: only create/replace if absent, or already a symlink
      # pointing at THIS wrapper. Leave any pre-existing real file OR foreign
      # symlink alone (collision avoidance).
      if [ ! -e "$WRAPPER_SHORT_DST" ] || { [ -L "$WRAPPER_SHORT_DST" ] && [ "$(readlink "$WRAPPER_SHORT_DST")" = "$WRAPPER_SRC" ]; }; then
        echo "  → symlinking $WRAPPER_SHORT_DST"
        rm -f "$WRAPPER_SHORT_DST"
        ln -s "$WRAPPER_SRC" "$WRAPPER_SHORT_DST"
      fi
    fi
PRIVILEGED_BLOCK

  $NEED_TAILSCALED_START   && ok "tailscaled started"   || true
  $NEED_RESOLVER_WRITE     && ok "$RESOLVER_DST written" || true
  $NEED_USRLOCALBIN_MKDIR  && ok "/usr/local/bin created" || true
  $NEED_SYMLINK            && ok "$WRAPPER_DST -> $WRAPPER_SRC" || true
  $NEED_SYMLINK            && [ -L "$WRAPPER_SHORT_DST" ] && [ "$(readlink "$WRAPPER_SHORT_DST")" = "$WRAPPER_SRC" ] && ok "$WRAPPER_SHORT_DST -> $WRAPPER_SRC" || true
else
  ok "nothing to do (system already configured)"
fi

# ---- config file (no sudo) ------------------------------------------------

bold "Configuration"

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config" ]; then
  cat > "$CONFIG_DIR/config" <<'EOF'
# remote-agent-stack — copilot-agent wrapper config
#
# WORKSPACE_BASE: where agent working directories live.
#   Each agent <Name> uses: $WORKSPACE_BASE/agent-<Name>  (case-preserved)
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
#
# FDA paths must be the REAL binary (the Cellar path), not the symlink
# under /opt/homebrew/opt/. macOS records the resolved-at-grant-time path.

resolve_real() {
  # Portable readlink -f for macOS (which has it on Sonoma+ but we play safe).
  local p="$1"
  if [ -L "$p" ] || [ -e "$p" ]; then
    if readlink -f "$p" >/dev/null 2>&1; then
      readlink -f "$p"
    else
      # Manual resolve: cd to dir, pwd -P, append basename.
      (cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
    fi
  fi
}

TAILSCALED_REAL="$(resolve_real "$(brew --prefix tailscale)/bin/tailscaled" 2>/dev/null || true)"
TMUX_REAL="$(resolve_real "$(brew --prefix tmux)/bin/tmux" 2>/dev/null || true)"

echo
bold "Manual steps remaining (can't be automated)"
cat <<MANUAL

  1. Grant Full Disk Access to the binaries that need it:
       System Settings → Privacy & Security → Full Disk Access → +
       Add these REAL Cellar paths (NOT the /opt/homebrew/opt symlinks):
         $TAILSCALED_REAL
         $TMUX_REAL
       (Use Cmd-Shift-G in the file picker to paste these paths.)
       Note: after a 'brew upgrade tmux' or 'brew upgrade tailscale',
       the version-numbered Cellar path changes — you'll need to re-add.

  2. Authenticate the Tailscale daemon and enable Tailscale SSH:
       sudo tailscale up --ssh
       (Follow the auth URL it prints; once per machine.)

  3. First Copilot CLI launch will ask:
       "System vault not available — store token in plain text config file?"
     Answer Yes. The token lands in ~/.copilot/config.json (mode 600).

  4. Test:
       ca alpha        # (long form: copilot-agent alpha)

  5. (Optional) In Termius, set each agent's snippet to a single line:
       ca alpha
       ca bravo
       ...

  See README.md for the full Termius walkthrough (iOS hosts + Mac
  desktop workspace setup with screenshots).

MANUAL

bold "Install complete."
