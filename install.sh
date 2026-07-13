#!/usr/bin/env bash
# remote-agent-stack installer
#
# Installs the userland prerequisites for running named Copilot CLI agents
# in tmux over Tailscale SSH on macOS:
#   - Homebrew (if missing)
#   - tmux + tailscale (via brew)
#   - /etc/resolver/ts.net (MagicDNS fix for Homebrew tailscaled)
#   - copilot-agent wrapper symlinked into /usr/local/bin (also as `ca`)
#   - ss + vncfix GUI-access helpers symlinked into /usr/local/bin
#   - ~/.tmux.conf managed block (hides the redundant tmux status bar)
#
# All operations that require root are batched into a single sudo
# invocation, so you only type your password once even on systems where
# the sudo cache expires per-command (managed Macs, etc).
#
# Manual GUI/interactive steps are printed at the end.
#
# Idempotent: safe to re-run.

set -euo pipefail

# ---- args ------------------------------------------------------------------

WORKSPACE_BASE_ARG=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --workspace-base PATH   Where agent workspaces live (parent dir for
                          agent-<name>/ subdirs). If omitted, the
                          installer auto-detects Dropbox and prompts
                          interactively with a smart default.
  -h, --help              Show this help and exit.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace-base)
      [ $# -ge 2 ] || { echo "--workspace-base requires a path" >&2; exit 2; }
      WORKSPACE_BASE_ARG="$2"
      shift 2
      ;;
    --workspace-base=*)
      WORKSPACE_BASE_ARG="${1#*=}"
      shift
      ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
WRAPPER_SRC="$REPO_ROOT/bin/copilot-agent"
WRAPPER_DST="/usr/local/bin/copilot-agent"
WRAPPER_SHORT_DST="/usr/local/bin/ca"
CLAUDE_WRAPPER_DST="/usr/local/bin/claude-agent"
CLAUDE_WRAPPER_SHORT_DST="/usr/local/bin/cc"
SS_SRC="$REPO_ROOT/bin/ss"
SS_DST="/usr/local/bin/ss"
VNCFIX_SRC="$REPO_ROOT/bin/vncfix"
VNCFIX_DST="/usr/local/bin/vncfix"
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

# Same collision-avoidance for the claude-agent long name and the 'cc' short
# alias. All four names ('copilot-agent', 'ca', 'claude-agent', 'cc') point at
# the same multi-call wrapper — backend is chosen from $0's basename inside
# the script.
for _dst in "$CLAUDE_WRAPPER_DST" "$CLAUDE_WRAPPER_SHORT_DST"; do
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$WRAPPER_SRC" ]; then
    :  # already correct
  elif [ -e "$_dst" ]; then
    warn "$_dst already exists (points elsewhere or is not ours) — leaving it alone (skipping $(basename "$_dst"))"
  else
    NEED_SYMLINK=true
  fi
done

# GUI helpers (ss, vncfix) — linked into /usr/local/bin the same way as the
# wrapper, with the same collision-avoidance as the 'ca' alias.
for _pair in "$SS_SRC:$SS_DST" "$VNCFIX_SRC:$VNCFIX_DST"; do
  _src="${_pair%%:*}"; _dst="${_pair##*:}"
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_src" ]; then
    :  # already correct
  elif [ -e "$_dst" ]; then
    warn "$_dst already exists (points elsewhere or is not ours) — leaving it alone (skipping $(basename "$_dst"))"
  else
    NEED_SYMLINK=true
  fi
done

# Ensure the wrapper + GUI helpers are executable (no sudo needed).
chmod +x "$WRAPPER_SRC" "$SS_SRC" "$VNCFIX_SRC"

# ---- single sudo block -----------------------------------------------------

bold "Privileged operations"

if $NEED_TAILSCALED_START || $NEED_RESOLVER_WRITE || $NEED_USRLOCALBIN_MKDIR || $NEED_SYMLINK; then
  echo
  echo "  The following privileged operations are needed:"
  $NEED_TAILSCALED_START   && echo "    • start tailscaled (brew services start tailscale)"
  $NEED_RESOLVER_WRITE     && echo "    • write $RESOLVER_DST (MagicDNS resolver)"
  $NEED_USRLOCALBIN_MKDIR  && echo "    • create /usr/local/bin"
  $NEED_SYMLINK            && echo "    • symlink $WRAPPER_DST, $WRAPPER_SHORT_DST -> $WRAPPER_SRC"
  $NEED_SYMLINK            && echo "    • symlink $CLAUDE_WRAPPER_DST, $CLAUDE_WRAPPER_SHORT_DST -> $WRAPPER_SRC"
  $NEED_SYMLINK            && echo "    • symlink $SS_DST, $VNCFIX_DST -> bin/{ss,vncfix}"
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
  CLAUDE_WRAPPER_DST="$CLAUDE_WRAPPER_DST" \
  CLAUDE_WRAPPER_SHORT_DST="$CLAUDE_WRAPPER_SHORT_DST" \
  SS_SRC="$SS_SRC" \
  SS_DST="$SS_DST" \
  VNCFIX_SRC="$VNCFIX_SRC" \
  VNCFIX_DST="$VNCFIX_DST" \
  BREW_BIN="$(command -v brew)" \
  sudo --preserve-env=NEED_TAILSCALED_START,NEED_RESOLVER_WRITE,NEED_USRLOCALBIN_MKDIR,NEED_SYMLINK,RESOLVER_SRC,RESOLVER_DST,WRAPPER_SRC,WRAPPER_DST,WRAPPER_SHORT_DST,CLAUDE_WRAPPER_DST,CLAUDE_WRAPPER_SHORT_DST,SS_SRC,SS_DST,VNCFIX_SRC,VNCFIX_DST,BREW_BIN \
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

      # Short 'ca' alias + claude-agent names: only create/replace if absent,
      # or already a symlink pointing at THIS wrapper. Leave any pre-existing
      # real file OR foreign symlink alone (collision avoidance). All four
      # names point at the same multi-call wrapper.
      for _alias_dst in "$WRAPPER_SHORT_DST" "$CLAUDE_WRAPPER_DST" "$CLAUDE_WRAPPER_SHORT_DST"; do
        if [ ! -e "$_alias_dst" ] || { [ -L "$_alias_dst" ] && [ "$(readlink "$_alias_dst")" = "$WRAPPER_SRC" ]; }; then
          echo "  → symlinking $_alias_dst"
          rm -f "$_alias_dst"
          ln -s "$WRAPPER_SRC" "$_alias_dst"
        fi
      done

      # GUI helpers (ss, vncfix): same collision-avoidance as the 'ca' alias.
      for _pair in "$SS_SRC:$SS_DST" "$VNCFIX_SRC:$VNCFIX_DST"; do
        _src="${_pair%%:*}"; _dst="${_pair##*:}"
        if [ ! -e "$_dst" ] || { [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_src" ]; }; then
          echo "  → symlinking $_dst"
          rm -f "$_dst"
          ln -s "$_src" "$_dst"
        fi
      done
    fi
PRIVILEGED_BLOCK

  $NEED_TAILSCALED_START   && ok "tailscaled started"   || true
  $NEED_RESOLVER_WRITE     && ok "$RESOLVER_DST written" || true
  $NEED_USRLOCALBIN_MKDIR  && ok "/usr/local/bin created" || true
  $NEED_SYMLINK            && ok "$WRAPPER_DST -> $WRAPPER_SRC" || true
  $NEED_SYMLINK            && [ -L "$WRAPPER_SHORT_DST" ] && [ "$(readlink "$WRAPPER_SHORT_DST")" = "$WRAPPER_SRC" ] && ok "$WRAPPER_SHORT_DST -> $WRAPPER_SRC" || true
  $NEED_SYMLINK            && [ -L "$CLAUDE_WRAPPER_DST" ] && [ "$(readlink "$CLAUDE_WRAPPER_DST")" = "$WRAPPER_SRC" ] && ok "$CLAUDE_WRAPPER_DST -> $WRAPPER_SRC" || true
  $NEED_SYMLINK            && [ -L "$CLAUDE_WRAPPER_SHORT_DST" ] && [ "$(readlink "$CLAUDE_WRAPPER_SHORT_DST")" = "$WRAPPER_SRC" ] && ok "$CLAUDE_WRAPPER_SHORT_DST -> $WRAPPER_SRC" || true
  $NEED_SYMLINK            && [ -L "$SS_DST" ] && [ "$(readlink "$SS_DST")" = "$SS_SRC" ] && ok "$SS_DST -> $SS_SRC" || true
  $NEED_SYMLINK            && [ -L "$VNCFIX_DST" ] && [ "$(readlink "$VNCFIX_DST")" = "$VNCFIX_SRC" ] && ok "$VNCFIX_DST -> $VNCFIX_SRC" || true
else
  ok "nothing to do (system already configured)"
fi

# ---- workspace base + config file (no sudo) -------------------------------

bold "Workspace base"

# Read existing WORKSPACE_BASE from the config file (if any) so re-runs
# don't pester the user.
EXISTING_WORKSPACE_BASE=""
if [ -f "$CONFIG_DIR/config" ]; then
  EXISTING_WORKSPACE_BASE="$(
    awk -F'=' '/^[[:space:]]*WORKSPACE_BASE=/{
      sub(/^[[:space:]]*WORKSPACE_BASE=/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }' "$CONFIG_DIR/config" 2>/dev/null || true
  )"
fi

DROPBOX_DEFAULT="$HOME/Library/CloudStorage/Dropbox/copilot-workspace"
PLAIN_DEFAULT="$HOME/copilot-workspace"

if [ -d "$HOME/Library/CloudStorage/Dropbox" ]; then
  SMART_DEFAULT="$DROPBOX_DEFAULT"
  DEFAULT_REASON="Dropbox detected — workspaces will sync across Macs"
else
  SMART_DEFAULT="$PLAIN_DEFAULT"
  DEFAULT_REASON="no Dropbox found"
fi

WORKSPACE_BASE_RESOLVED=""

if [ -n "$WORKSPACE_BASE_ARG" ]; then
  WORKSPACE_BASE_RESOLVED="$WORKSPACE_BASE_ARG"
  ok "using --workspace-base: $WORKSPACE_BASE_RESOLVED"
elif [ -n "$EXISTING_WORKSPACE_BASE" ]; then
  WORKSPACE_BASE_RESOLVED="$EXISTING_WORKSPACE_BASE"
  ok "keeping existing config: $WORKSPACE_BASE_RESOLVED"
elif [ -t 0 ] && [ -t 1 ]; then
  # Interactive: prompt with the smart default.
  echo "    Where should agent workspaces live? (parent dir for agent-<name>/)"
  echo "    Default: $SMART_DEFAULT"
  echo "             ($DEFAULT_REASON)"
  printf "    Path [%s]: " "$SMART_DEFAULT"
  read -r WORKSPACE_BASE_INPUT || WORKSPACE_BASE_INPUT=""
  if [ -z "$WORKSPACE_BASE_INPUT" ]; then
    WORKSPACE_BASE_RESOLVED="$SMART_DEFAULT"
  else
    # Expand a leading ~ and any $VARS.
    WORKSPACE_BASE_RESOLVED="$(eval echo "$WORKSPACE_BASE_INPUT")"
  fi
  ok "workspace base: $WORKSPACE_BASE_RESOLVED"
else
  # Non-interactive (e.g., piped install) and no flag: take the smart default.
  WORKSPACE_BASE_RESOLVED="$SMART_DEFAULT"
  warn "non-interactive shell — using $WORKSPACE_BASE_RESOLVED ($DEFAULT_REASON)"
  todo "override later with: $0 --workspace-base PATH"
fi

# ---- mailbox integration prompt -------------------------------------------
#
# The optional dfrysinger-skills `mailbox` skill lets one named agent send
# messages/files to another (e.g., handoffs). When enabled, the ca wrapper
# auto-pokes the recipient's tmux pane on attach + new-session if there is
# pending mail. Off by default; opt-in here.

bold "Mailbox integration (optional)"

# Smart default: if the plugin is already installed for either backend,
# suggest yes; else no.
MAILBOX_COPILOT_PATH="$HOME/.copilot/installed-plugins/_direct/dfrysinger--skills/skills/mailbox"
MAILBOX_CLAUDE_PATH="$HOME/.claude/plugins/repos/dfrysinger/skills/skills/mailbox"
if [ -d "$MAILBOX_COPILOT_PATH" ] || [ -d "$MAILBOX_CLAUDE_PATH" ]; then
  MAILBOX_DEFAULT="yes"
  MAILBOX_DEFAULT_REASON="dfrysinger-skills/mailbox plugin already installed"
else
  MAILBOX_DEFAULT="no"
  MAILBOX_DEFAULT_REASON="dfrysinger-skills plugin not detected (install via the CLI you use: /plugin install dfrysinger/skills)"
fi

# Read existing setting from config (re-runs don't pester).
EXISTING_MAILBOX_INTEGRATION=""
if [ -f "$CONFIG_DIR/config" ]; then
  EXISTING_MAILBOX_INTEGRATION="$(
    awk -F'=' '/^[[:space:]]*MAILBOX_INTEGRATION=/{
      sub(/^[[:space:]]*MAILBOX_INTEGRATION=/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }' "$CONFIG_DIR/config" 2>/dev/null || true
  )"
fi

MAILBOX_INTEGRATION_RESOLVED=""

if [ -n "$EXISTING_MAILBOX_INTEGRATION" ]; then
  MAILBOX_INTEGRATION_RESOLVED="$EXISTING_MAILBOX_INTEGRATION"
  ok "keeping existing config: MAILBOX_INTEGRATION=$MAILBOX_INTEGRATION_RESOLVED"
elif [ -t 0 ] && [ -t 1 ]; then
  echo "    Enable mailbox integration in the ca wrapper?"
  echo "    (cross-session message/file handoff between named agents)"
  echo "    Default: $MAILBOX_DEFAULT  ($MAILBOX_DEFAULT_REASON)"
  printf "    Enable? [y/N, default %s]: " "$MAILBOX_DEFAULT"
  read -r MAILBOX_INPUT || MAILBOX_INPUT=""
  if [ -z "$MAILBOX_INPUT" ]; then
    MAILBOX_INPUT="$MAILBOX_DEFAULT"
  fi
  case "$MAILBOX_INPUT" in
    y|Y|yes|YES|true) MAILBOX_INTEGRATION_RESOLVED="true" ;;
    *)                MAILBOX_INTEGRATION_RESOLVED="false" ;;
  esac
  ok "mailbox integration: $MAILBOX_INTEGRATION_RESOLVED"
else
  MAILBOX_INTEGRATION_RESOLVED="false"
  warn "non-interactive shell — leaving mailbox integration disabled"
  todo "enable later: edit $CONFIG_DIR/config and set MAILBOX_INTEGRATION=\"true\""
fi

# ---- allow-all prompt -----------------------------------------------------
#
# When enabled, ca passes --allow-all to copilot on new-session launch
# (--allow-all-tools + --allow-all-paths + --allow-all-urls). Reasonable
# for a personal-machine, named-agent workflow where the human is steering;
# NOT recommended for shared/CI environments. Off by default.

bold "Allow-all permissions (optional)"

EXISTING_ALLOW_ALL=""
if [ -f "$CONFIG_DIR/config" ]; then
  EXISTING_ALLOW_ALL="$(
    awk -F'=' '/^[[:space:]]*ALLOW_ALL=/{
      sub(/^[[:space:]]*ALLOW_ALL=/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }' "$CONFIG_DIR/config" 2>/dev/null || true
  )"
fi

ALLOW_ALL_RESOLVED=""

if [ -n "$EXISTING_ALLOW_ALL" ]; then
  ALLOW_ALL_RESOLVED="$EXISTING_ALLOW_ALL"
  ok "keeping existing config: ALLOW_ALL=$ALLOW_ALL_RESOLVED"
elif [ -t 0 ] && [ -t 1 ]; then
  echo "    Pass --allow-all to copilot on every ca launch?"
  echo "    (auto-approves all tools, paths, and URLs — skip per-call prompts)"
  echo "    Recommended only on personal machines where you steer the agent."
  printf "    Enable? [y/N]: "
  read -r ALLOW_ALL_INPUT || ALLOW_ALL_INPUT=""
  case "$ALLOW_ALL_INPUT" in
    y|Y|yes|YES|true) ALLOW_ALL_RESOLVED="true" ;;
    *)                ALLOW_ALL_RESOLVED="false" ;;
  esac
  ok "allow-all: $ALLOW_ALL_RESOLVED"
else
  ALLOW_ALL_RESOLVED="false"
  warn "non-interactive shell — leaving allow-all disabled"
  todo "enable later: edit $CONFIG_DIR/config and set ALLOW_ALL=\"true\""
fi

bold "Configuration"

mkdir -p "$CONFIG_DIR"

# Always (re-)write the config so WORKSPACE_BASE matches what we just resolved.
# COPILOT_BIN and AGENT_DIR_PREFIX stay as commented defaults — the wrapper
# falls back to its own defaults if they're absent.
cat > "$CONFIG_DIR/config" <<EOF
# remote-agent-stack — agent wrapper config
# Re-generated by install.sh; safe to edit by hand.
#
# One wrapper serves two backends, chosen by the invocation name:
#   copilot-agent / ca  -> Copilot CLI       (workspace: agent-<Name>)
#   claude-agent  / cc  -> Claude Code CLI   (workspace: claude-<Name>)

# WORKSPACE_BASE: where agent working directories live.
#   copilot backend: \$WORKSPACE_BASE/agent-<Name>
#   claude  backend: \$WORKSPACE_BASE/claude-<Name>
WORKSPACE_BASE="$WORKSPACE_BASE_RESOLVED"

# COPILOT_BIN: name of the Copilot CLI binary (must be in PATH).
# COPILOT_BIN="copilot"

# COPILOT_DIR_PREFIX: prefix for copilot-backend per-agent directory names.
# (Alias: AGENT_DIR_PREFIX, kept for backward compatibility.)
# COPILOT_DIR_PREFIX="agent-"

# CLAUDE_BIN: name of the Claude Code CLI binary (must be in PATH).
# CLAUDE_BIN="claude"

# CLAUDE_DIR_PREFIX: prefix for claude-backend per-agent directory names.
# CLAUDE_DIR_PREFIX="claude-"

# MAILBOX_INTEGRATION: enable cross-session message/file handoff via the
# optional dfrysinger-skills \`mailbox\` skill. When "true", the wrapper
# pokes the recipient's tmux pane on attach + new-session if pending mail
# exists. When unset or "false", the mailbox hook is skipped entirely.
MAILBOX_INTEGRATION="$MAILBOX_INTEGRATION_RESOLVED"

# ALLOW_ALL: when "true", the wrapper skips permission prompts on
# new-session launch (copilot: --allow-all; claude: --dangerously-skip-permissions).
# Personal-machine convenience; do NOT enable in shared environments.
ALLOW_ALL="$ALLOW_ALL_RESOLVED"
EOF
ok "wrote $CONFIG_DIR/config"

# ---- tmux keychain bootstrap LaunchAgent ----------------------------------
#
# This is the durable fix for the "gh / git credential helper doesn't work
# inside agent shells" problem: a LaunchAgent that pre-warms the tmux
# server in the user's GUI (Aqua) login session at every login. That gives
# every shell hosted by that tmux server — including ones attached over
# Tailscale-SSH later — full login-keychain access. See the script's
# header comment at bin/tmux-keychain-bootstrap.sh for the full root-cause
# explanation.

bold "tmux keychain bootstrap (optional, recommended)"

LAUNCHAGENT_LABEL="com.dfrysinger.tmux-keychain-bootstrap"
LAUNCHAGENT_DST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"
LAUNCHAGENT_SRC="$REPO_ROOT/etc/${LAUNCHAGENT_LABEL}.plist"
BOOTSTRAP_SCRIPT="$REPO_ROOT/bin/tmux-keychain-bootstrap.sh"

EXISTING_LAUNCHAGENT="no"
[ -f "$LAUNCHAGENT_DST" ] && EXISTING_LAUNCHAGENT="yes"

INSTALL_LAUNCHAGENT="false"

if [ "$EXISTING_LAUNCHAGENT" = "yes" ]; then
  ok "keeping existing LaunchAgent: $LAUNCHAGENT_DST"
  INSTALL_LAUNCHAGENT="true"  # so we still re-stamp the script path / reload below
elif [ -t 0 ] && [ -t 1 ]; then
  echo "    Without this, the first \`ca <name>\` after a reboot bootstraps the"
  echo "    tmux server from your SSH login shell, which inherits a restricted"
  echo "    keychain context. Result: \`gh\`, the osxkeychain git helper, and"
  echo "    anything else that reads the login keychain silently fail inside"
  echo "    agent shells (even though they work in Terminal.app on the same Mac)."
  echo
  echo "    This LaunchAgent fires at every GUI login and starts a tiny anchor"
  echo "    tmux session named \`_keychain-anchor\` so the server inherits the"
  echo "    full login-keychain search list. One-time install."
  printf "    Install LaunchAgent? [Y/n]: "
  read -r LAUNCHAGENT_INPUT || LAUNCHAGENT_INPUT=""
  case "$LAUNCHAGENT_INPUT" in
    n|N|no|NO|false) INSTALL_LAUNCHAGENT="false" ;;
    *)               INSTALL_LAUNCHAGENT="true" ;;
  esac
else
  warn "non-interactive shell — skipping LaunchAgent install"
  todo "install later: re-run install.sh in an interactive terminal"
fi

if [ "$INSTALL_LAUNCHAGENT" = "true" ]; then
  # Snapshot pre-existing tmux BEFORE we launchctl-bootstrap below — the
  # bootstrap fires the script asynchronously via RunAtLoad and may spawn
  # its own tmux server, which would otherwise make the post-install
  # `pgrep -x tmux` check false-positive on clean installs.
  if pgrep -x tmux >/dev/null 2>&1; then
    PRE_EXISTING_TMUX=yes
  else
    PRE_EXISTING_TMUX=no
  fi

  mkdir -p "$HOME/Library/LaunchAgents"
  # Substitute the absolute bootstrap-script path AND the tmux socket path
  # into the plist template. The socket path uses the installing user's
  # UID; we assume default TMUX_TMPDIR (/private/tmp). The socket-path
  # placeholder powers the PathState watchdog: launchd refires the script
  # whenever the socket disappears (e.g. tmux kill-server).
  #
  # Escape sed-replacement metacharacters (`\`, `&`, and our delimiter `|`)
  # in case the install path ever contains them; the leading newline guard
  # via $'...' isn't needed because pgrep/launchctl already block actual
  # newlines in usable paths. The socket path is composed from numeric UID
  # and a fixed prefix so it can't contain metacharacters.
  BOOTSTRAP_SCRIPT_ESC=${BOOTSTRAP_SCRIPT//\\/\\\\}
  BOOTSTRAP_SCRIPT_ESC=${BOOTSTRAP_SCRIPT_ESC//&/\\&}
  BOOTSTRAP_SCRIPT_ESC=${BOOTSTRAP_SCRIPT_ESC//|/\\|}
  TMUX_SOCKET_PATH="/private/tmp/tmux-$(id -u)/default"
  sed -e "s|__SCRIPT_PATH__|$BOOTSTRAP_SCRIPT_ESC|g" \
      -e "s|__TMUX_SOCKET_PATH__|$TMUX_SOCKET_PATH|g" \
      "$LAUNCHAGENT_SRC" > "$LAUNCHAGENT_DST"
  ok "installed $LAUNCHAGENT_DST (watchdog path: $TMUX_SOCKET_PATH)"

  # Bootstrap into the user's GUI domain so it takes effect this login
  # without waiting for the next reboot. If it's already loaded (e.g.
  # re-run of the installer), bootout first so the new plist actually
  # gets picked up. `launchctl bootstrap` can require admin in some
  # contexts; the user domain (gui/<uid>) does not.
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LAUNCHAGENT_LABEL" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$LAUNCHAGENT_DST" 2>/dev/null; then
      ok "loaded LaunchAgent into gui/$(id -u) (fires at login + whenever tmux socket disappears)"
    else
      warn "couldn't load LaunchAgent automatically — log out and back in to activate"
    fi
  fi

  # If the user had a tmux server running BEFORE we installed (captured
  # in PRE_EXISTING_TMUX above), it's in whatever security context it
  # was originally launched from — most often a Tailscale-SSH shell,
  # which means it can't see login.keychain-db. To swap it for a
  # GUI-context server, they just need to kill the existing server —
  # the watchdog refires the script automatically because the socket
  # disappears.
  #
  # We only warn on fresh installs: if EXISTING_LAUNCHAGENT=yes, the
  # watchdog has already been running and the current server was
  # spawned by it, so it's already GUI-context.
  if [ "$PRE_EXISTING_TMUX" = "yes" ] && [ "$EXISTING_LAUNCHAGENT" = "no" ]; then
    warn "tmux server was already running before install — it's in its original security context."
    echo "    To activate keychain access for existing sessions:"
    echo "      1. Let any in-flight agent work finish."
    echo "      2. From any shell: tmux kill-server"
    echo "         (the watchdog will refire the bootstrap script within"
    echo "          a few seconds and the new server will be GUI-context)"
    echo "      3. Re-attach your named agents: ca alpha, ca bravo, ..."
    echo "    Each Copilot session resumes by UUID (no conversation lost)."
  fi
fi

# ---- tmux config (status bar off) -----------------------------------------
#
# The agents are full-screen Copilot CLI TUIs that own their own mouse and
# scrollback, and the terminal/Termius tabs already label each session, so
# tmux's status bar is just redundant chrome. We hide it by default.
#
# The settings live in etc/tmux.conf and are stamped into ~/.tmux.conf inside
# a clearly-marked managed block, so we never clobber a hand-written config:
#   - no ~/.tmux.conf            -> created with just our block
#   - has our managed block      -> block replaced in place (idempotent)
#   - has unrelated user config  -> our block appended, existing lines kept

bold "tmux config (status bar off)"

TMUXCONF_DST="$HOME/.tmux.conf"
TMUXCONF_SRC="$REPO_ROOT/etc/tmux.conf"
TMUX_BLOCK_BEGIN="# >>> remote-agent-stack (managed) >>>"
TMUX_BLOCK_END="# <<< remote-agent-stack (managed) <<<"

if [ ! -f "$TMUXCONF_SRC" ]; then
  warn "etc/tmux.conf missing from this clone — skipping tmux config"
else
  # Build the managed block: markers wrapped around the repo's canonical conf.
  TMUX_BLOCK="$(printf '%s\n' "$TMUX_BLOCK_BEGIN"; cat "$TMUXCONF_SRC"; printf '%s\n' "$TMUX_BLOCK_END")"

  if [ ! -f "$TMUXCONF_DST" ]; then
    printf '%s\n' "$TMUX_BLOCK" > "$TMUXCONF_DST"
    ok "created $TMUXCONF_DST (status bar off; prefix + b to toggle)"
  elif grep -qF "$TMUX_BLOCK_BEGIN" "$TMUXCONF_DST"; then
    # Replace the existing managed block in place; leave the rest untouched.
    TMUX_TMP="$(mktemp)"
    awk -v b="$TMUX_BLOCK_BEGIN" -v e="$TMUX_BLOCK_END" '
      $0==b { inblk=1; next }
      $0==e { inblk=0; next }
      !inblk { print }
    ' "$TMUXCONF_DST" > "$TMUX_TMP"
    printf '%s\n' "$TMUX_BLOCK" >> "$TMUX_TMP"
    mv "$TMUX_TMP" "$TMUXCONF_DST"
    ok "updated managed block in $TMUXCONF_DST"
  else
    # Preserve the user's existing config; append our block at the end.
    printf '\n%s\n' "$TMUX_BLOCK" >> "$TMUXCONF_DST"
    ok "appended managed block to existing $TMUXCONF_DST (kept your config)"
  fi

  # Apply live if a server is already running, so the bar disappears now
  # rather than only on the next server start.
  if pgrep -x tmux >/dev/null 2>&1; then
    if tmux source-file "$TMUXCONF_DST" >/dev/null 2>&1; then
      ok "reloaded tmux config into the running server"
    else
      warn "couldn't reload tmux config automatically — run: tmux source-file ~/.tmux.conf"
    fi
  fi
fi

# ---- Backend CLI detection -------------------------------------------------
#
# Both backends are optional at install time — the wrapper enforces
# "backend binary must be in PATH" at launch. Install only the ones you
# actually plan to use.

bold "Backend CLIs"

if have copilot; then
  ok "copilot CLI found ($(copilot --version 2>&1 | head -1))"
else
  warn "copilot CLI not found in PATH — 'ca' / 'copilot-agent' will error until installed."
  echo "    Install per https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli"
fi

if have claude; then
  ok "claude CLI found ($(claude --version 2>&1 | head -1))"
else
  warn "claude CLI not found in PATH — 'cc' / 'claude-agent' will error until installed."
  echo "    Install per https://docs.claude.com/en/docs/claude-code/quickstart"
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

     If you want computer-control (screenshots, AppleScript GUI driving,
     synthetic clicks/keystrokes) to work from inside agent shells,
     also grant tmux:
       System Settings → Privacy & Security → Accessibility       → + $TMUX_REAL
       System Settings → Privacy & Security → Screen Recording    → + $TMUX_REAL
     Without these, \`screencapture\`, \`osascript\` GUI commands, and
     anything that synthesizes mouse/keyboard events from an agent
     shell will silently fail or return blank output. Same Cellar-path
     and re-add-after-upgrade caveats apply.

  2. Authenticate the Tailscale daemon and enable Tailscale SSH:
       sudo tailscale up --ssh
       (Follow the auth URL it prints; once per machine.)

  3. First Copilot CLI launch (if you use the copilot backend) will ask:
       "System vault not available — store token in plain text config file?"
     Answer Yes. The token lands in ~/.copilot/config.json (mode 600).

     First Claude Code CLI launch (if you use the claude backend) will
     prompt for authentication in the terminal — follow the on-screen
     login flow.

  4. Test:
       ca alpha        # copilot backend  (long form: copilot-agent alpha)
       cc alpha        # claude  backend  (long form: claude-agent  alpha)

  5. (Optional) In Termius, set each agent's snippet to a single line:
       ca alpha        # or: cc alpha
       ca bravo
       ...

  See README.md for the full Termius walkthrough (iOS hosts + Mac
  desktop workspace setup with screenshots).

MANUAL

bold "Install complete."
