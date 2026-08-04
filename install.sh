#!/usr/bin/env bash
# remote-agent-stack installer
#
# Installs the userland prerequisites for running named Copilot CLI agents
# in tmux over Tailscale SSH on macOS:
#   - Homebrew (if missing)
#   - tmux + tailscale (via brew)
#   - /etc/resolver/ts.net (MagicDNS fix for Homebrew tailscaled)
#   - agent-stack wrapper + descriptive backend aliases in /usr/local/bin
#   - agent-screen + vncfix GUI-access helpers symlinked into /usr/local/bin
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

COPILOT_WORKSPACE_BASE_ARG=""
CLAUDE_WORKSPACE_BASE_ARG=""
CODEX_WORKSPACE_BASE_ARG=""
AGENT_HELP_CLIS_ARG=""
SKILLS_CLIS_ARG=""
DREAMING_ARG=""
DREAMING_REPO_ROOT_ARG="${DREAMING_REPO_ROOT:-}"
AGENT_HELP_RECIPIENT_ARG="${AGENT_HELP_RECIPIENT:-}"
SCREEN_SHARING_PORT_ARG=""
DESK_DISPLAY_COUNT_ARG=""
SCREEN_SHARING_HOURS_ARG=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --copilot-workspace-base PATH  Where copilot agent workspaces live
                                 (parent dir for agent-<name>/ subdirs).
  --claude-workspace-base  PATH  Where claude  agent workspaces live
                                 (parent dir for agent-<name>/ subdirs).
  --codex-workspace-base   PATH  Where codex agent workspaces live
                                 (parent dir for agent-<name>/ subdirs).
  --agent-help-clis LIST          Complete desired set of CLIs to configure:
                                 copilot,claude,codex or none.
  --skills-clis LIST              Complete desired set for dfrysinger-skills:
                                 copilot,claude,codex or none.
  --dreaming                      Install and enable the headless Dreaming
                                 service for Copilot CLI.
  --no-dreaming                   Disable an owned Dreaming service.
  --dreaming-repo PATH            Dreaming runtime checkout (default:
                                 ~/.local/share/remote-agent-stack/dreaming).
  --agent-help-recipient HANDLE  iMessage phone number or Apple ID. Prefer the
                                 interactive no-echo prompt or
                                 AGENT_HELP_RECIPIENT to avoid shell history.
  --screen-sharing-port PORT     Tailscale Serve TCP port (default: 15900).
  --screen-sharing-hours HOURS   Automatic access lease, 1-8 (default: 1).

  If a workspace flag is omitted, the installer auto-detects
  Dropbox and prompts interactively with smart defaults.

  -h, --help                     Show this help and exit.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --copilot-workspace-base)
      [ $# -ge 2 ] || { echo "--copilot-workspace-base requires a path" >&2; exit 2; }
      COPILOT_WORKSPACE_BASE_ARG="$2"; shift 2 ;;
    --copilot-workspace-base=*)
      COPILOT_WORKSPACE_BASE_ARG="${1#*=}"; shift ;;
    --claude-workspace-base)
      [ $# -ge 2 ] || { echo "--claude-workspace-base requires a path" >&2; exit 2; }
      CLAUDE_WORKSPACE_BASE_ARG="$2"; shift 2 ;;
    --claude-workspace-base=*)
      CLAUDE_WORKSPACE_BASE_ARG="${1#*=}"; shift ;;
    --codex-workspace-base)
      [ $# -ge 2 ] || { echo "--codex-workspace-base requires a path" >&2; exit 2; }
      CODEX_WORKSPACE_BASE_ARG="$2"; shift 2 ;;
    --codex-workspace-base=*)
      CODEX_WORKSPACE_BASE_ARG="${1#*=}"; shift ;;
    --agent-help-clis)
      [ $# -ge 2 ] || { echo "--agent-help-clis requires a list" >&2; exit 2; }
      AGENT_HELP_CLIS_ARG="$2"; shift 2 ;;
    --agent-help-clis=*)
      AGENT_HELP_CLIS_ARG="${1#*=}"; shift ;;
    --skills-clis)
      [ $# -ge 2 ] || { echo "--skills-clis requires a list" >&2; exit 2; }
      SKILLS_CLIS_ARG="$2"; shift 2 ;;
    --skills-clis=*)
      SKILLS_CLIS_ARG="${1#*=}"; shift ;;
    --dreaming)
      DREAMING_ARG="true"; shift ;;
    --no-dreaming)
      DREAMING_ARG="false"; shift ;;
    --dreaming-repo)
      [ $# -ge 2 ] || { echo "--dreaming-repo requires a path" >&2; exit 2; }
      DREAMING_REPO_ROOT_ARG="$2"; shift 2 ;;
    --dreaming-repo=*)
      DREAMING_REPO_ROOT_ARG="${1#*=}"; shift ;;
    --agent-help-recipient)
      [ $# -ge 2 ] || { echo "--agent-help-recipient requires a handle" >&2; exit 2; }
      AGENT_HELP_RECIPIENT_ARG="$2"; shift 2 ;;
    --agent-help-recipient=*)
      AGENT_HELP_RECIPIENT_ARG="${1#*=}"; shift ;;
    --screen-sharing-port)
      [ $# -ge 2 ] || { echo "--screen-sharing-port requires a port" >&2; exit 2; }
      SCREEN_SHARING_PORT_ARG="$2"; shift 2 ;;
    --screen-sharing-port=*)
      SCREEN_SHARING_PORT_ARG="${1#*=}"; shift ;;
    --desk-display-count)
      [ $# -ge 2 ] || { echo "--desk-display-count requires a count" >&2; exit 2; }
      DESK_DISPLAY_COUNT_ARG="$2"; shift 2 ;;
    --desk-display-count=*)
      DESK_DISPLAY_COUNT_ARG="${1#*=}"; shift ;;
    --screen-sharing-hours)
      [ $# -ge 2 ] || { echo "--screen-sharing-hours requires a duration" >&2; exit 2; }
      SCREEN_SHARING_HOURS_ARG="$2"; shift 2 ;;
    --screen-sharing-hours=*)
      SCREEN_SHARING_HOURS_ARG="${1#*=}"; shift ;;
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
WRAPPER_SRC="$REPO_ROOT/bin/agent"
COMMAND_LINK_MANAGER="$REPO_ROOT/scripts/manage-command-links.sh"
SCREEN_SHARING_SRC="$REPO_ROOT/bin/agent-screen"
VNCFIX_SRC="$REPO_ROOT/bin/vncfix"
VNCFIX_DST="/usr/local/bin/vncfix"
RESOLVER_SRC="$REPO_ROOT/etc/resolver-ts.net"
RESOLVER_DST="/etc/resolver/ts.net"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/remote-agent-stack"
MCP_SRC="$REPO_ROOT/mcp/agent-help"
MCP_DST="$CONFIG_DIR/agent-help/server"
MCP_SERVER="$MCP_DST/server.mjs"
MANAGE_AGENT_HELP="$REPO_ROOT/scripts/manage-agent-help.mjs"
MANAGE_SKILLS_PLUGIN="$REPO_ROOT/scripts/manage-skills-plugin.mjs"
MANAGE_DREAMING="$REPO_ROOT/scripts/manage-dreaming.mjs"
SS_ROOT_SRC="$REPO_ROOT/libexec/ss-on-demand"
SS_ROOT_DST="/usr/local/libexec/ss-on-demand"
SS_ROOT_CONFIG="/usr/local/etc/remote-agent-stack/screen-sharing.conf"
SS_EXPIRY_PLIST_SRC="$REPO_ROOT/etc/com.remote-agent-stack.screen-sharing-expiry.plist"
SS_EXPIRY_PLIST_DST="/Library/LaunchDaemons/com.remote-agent-stack.screen-sharing-expiry.plist"
SS_EXPIRY_LABEL="com.remote-agent-stack.screen-sharing-expiry"
SS_SUDOERS_DST="/etc/sudoers.d/ss-on-demand"

# ---- helpers ---------------------------------------------------------------

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip()  { printf '  \033[2m·\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
todo()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

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

validate_integer() {
  local label="$1" value="$2" minimum="$3" maximum="$4"
  case "$value" in ""|*[!0-9]*) fail "$label must be an integer" ;; esac
  [ "$value" -ge "$minimum" ] && [ "$value" -le "$maximum" ] ||
    fail "$label must be between $minimum and $maximum"
}

# ---- preflight -------------------------------------------------------------

bold "Preflight"

if [ "$(uname)" != "Darwin" ]; then
  fail "This installer currently supports macOS only."
fi
ok "macOS detected ($(sw_vers -productVersion))"

bash "$COMMAND_LINK_MANAGER" \
  --mode check \
  --wrapper "$WRAPPER_SRC" \
  --screen-wrapper "$SCREEN_SHARING_SRC" \
  --bin-dir /usr/local/bin
ok "managed command paths are ownership-safe"

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

for pkg in tmux tailscale node; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    todo "brew install $pkg"
    brew install "$pkg"
  fi
done

# ---- agent-help selection --------------------------------------------------

bold "Agent help MCP"

DETECTED_AGENT_HELP_LIST=""
for cli in copilot claude codex; do
  if have "$cli"; then
    [ -n "$DETECTED_AGENT_HELP_LIST" ] && DETECTED_AGENT_HELP_LIST="$DETECTED_AGENT_HELP_LIST,"
    DETECTED_AGENT_HELP_LIST="$DETECTED_AGENT_HELP_LIST$cli"
  fi
done
EXISTING_AGENT_HELP_CLIS="$(read_config_var AGENT_HELP_CLIS)"

if [ -n "$AGENT_HELP_CLIS_ARG" ]; then
  AGENT_HELP_CLIS_RESOLVED="$AGENT_HELP_CLIS_ARG"
elif [ -n "$EXISTING_AGENT_HELP_CLIS" ]; then
  AGENT_HELP_CLIS_RESOLVED="$EXISTING_AGENT_HELP_CLIS"
  ok "keeping existing CLI selection: ${AGENT_HELP_CLIS_RESOLVED:-none}"
elif [ -t 0 ] && [ -t 1 ]; then
  echo "    Configure the request_help tool for which CLIs?"
  echo "    Detected: ${DETECTED_AGENT_HELP_LIST:-none}"
  printf "    Comma-separated list or none [%s]: " "${DETECTED_AGENT_HELP_LIST:-none}"
  read -r AGENT_HELP_INPUT || AGENT_HELP_INPUT=""
  AGENT_HELP_CLIS_RESOLVED="${AGENT_HELP_INPUT:-${DETECTED_AGENT_HELP_LIST:-none}}"
else
  if [ -n "$AGENT_HELP_RECIPIENT_ARG" ] ||
     [ -f "$CONFIG_DIR/agent-help/config.json" ] ||
     [ -f "$HOME/.copilot/agent-help.json" ]; then
    AGENT_HELP_CLIS_RESOLVED="${DETECTED_AGENT_HELP_LIST:-none}"
    ok "non-interactive selection: $AGENT_HELP_CLIS_RESOLVED"
  else
    AGENT_HELP_CLIS_RESOLVED="none"
    warn "non-interactive shell without a recipient — leaving agent help disabled"
    todo "enable later with AGENT_HELP_RECIPIENT and --agent-help-clis"
  fi
fi

if [ "$AGENT_HELP_CLIS_RESOLVED" = "none" ]; then
  AGENT_HELP_CLIS_RESOLVED=""
fi
AGENT_HELP_CLIS_RESOLVED="$(printf '%s' "$AGENT_HELP_CLIS_RESOLVED" | tr -d '[:space:]')"
remaining_clis="$AGENT_HELP_CLIS_RESOLVED"
while [ -n "$remaining_clis" ]; do
  cli="${remaining_clis%%,*}"
  if [ "$remaining_clis" = "$cli" ]; then
    remaining_clis=""
  else
    remaining_clis="${remaining_clis#*,}"
  fi
  [ -n "$cli" ] || fail "agent-help CLI list contains an empty item"
  case "$cli" in copilot|claude|codex) ;; *) fail "unsupported agent-help CLI: $cli" ;; esac
  have "$cli" || fail "$cli was selected for agent help but is not installed"
done
[ -n "$AGENT_HELP_CLIS_RESOLVED" ] && ok "agent help CLIs: $AGENT_HELP_CLIS_RESOLVED" ||
  skip "agent help MCP disabled"

AGENT_HELP_CONFIG="$CONFIG_DIR/agent-help/config.json"
EXISTING_AGENT_HELP_RECIPIENT=""
if [ -f "$AGENT_HELP_CONFIG" ]; then
  EXISTING_AGENT_HELP_RECIPIENT="$(/usr/bin/python3 -c '
import json, sys
print((json.load(open(sys.argv[1])).get("recipient") or "").strip())
' "$AGENT_HELP_CONFIG" 2>/dev/null || true)"
elif [ -f "$HOME/.copilot/agent-help.json" ]; then
  EXISTING_AGENT_HELP_RECIPIENT="$(/usr/bin/python3 -c '
import json, sys
print((json.load(open(sys.argv[1])).get("recipient") or "").strip())
' "$HOME/.copilot/agent-help.json" 2>/dev/null || true)"
  [ -n "$EXISTING_AGENT_HELP_RECIPIENT" ] &&
    ok "found legacy private recipient for migration"
fi

AGENT_HELP_RECIPIENT_RESOLVED="${AGENT_HELP_RECIPIENT_ARG:-$EXISTING_AGENT_HELP_RECIPIENT}"
if [ -n "$AGENT_HELP_CLIS_RESOLVED" ] && [ -z "$AGENT_HELP_RECIPIENT_RESOLVED" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    printf "    iMessage phone number or Apple ID (input hidden): "
    IFS= read -r -s AGENT_HELP_RECIPIENT_RESOLVED || true
    echo
  else
    fail "agent help requires AGENT_HELP_RECIPIENT or --agent-help-recipient"
  fi
fi
[ -n "$AGENT_HELP_CLIS_RESOLVED" ] && [ -z "$AGENT_HELP_RECIPIENT_RESOLVED" ] &&
  fail "agent help recipient cannot be empty"

# ---- skills plugin selection ----------------------------------------------

bold "dfrysinger skills plugin"

DETECTED_SKILLS_LIST=""
for cli in copilot claude codex; do
  if have "$cli"; then
    [ -n "$DETECTED_SKILLS_LIST" ] && DETECTED_SKILLS_LIST="$DETECTED_SKILLS_LIST,"
    DETECTED_SKILLS_LIST="$DETECTED_SKILLS_LIST$cli"
  fi
done
EXISTING_SKILLS_CLIS="$(read_config_var SKILLS_CLIS)"
SKILLS_EXPLICIT_CLIS=""

if [ -n "$SKILLS_CLIS_ARG" ]; then
  SKILLS_CLIS_RESOLVED="$SKILLS_CLIS_ARG"
  SKILLS_EXPLICIT_CLIS="$SKILLS_CLIS_ARG"
elif [ -n "$EXISTING_SKILLS_CLIS" ]; then
  SKILLS_CLIS_RESOLVED="$EXISTING_SKILLS_CLIS"
  ok "keeping existing skills CLI selection: ${SKILLS_CLIS_RESOLVED:-none}"
elif [ -t 0 ] && [ -t 1 ]; then
  echo "    Install the dfrysinger-skills plugin for which CLIs?"
  echo "    Detected: ${DETECTED_SKILLS_LIST:-none}"
  printf "    Comma-separated list or none [%s]: " "${DETECTED_SKILLS_LIST:-none}"
  read -r SKILLS_INPUT || SKILLS_INPUT=""
  SKILLS_CLIS_RESOLVED="${SKILLS_INPUT:-${DETECTED_SKILLS_LIST:-none}}"
else
  SKILLS_CLIS_RESOLVED="${DETECTED_SKILLS_LIST:-none}"
  ok "non-interactive skills selection: $SKILLS_CLIS_RESOLVED"
fi

if [ "$SKILLS_CLIS_RESOLVED" = "none" ]; then
  SKILLS_CLIS_RESOLVED=""
fi
SKILLS_CLIS_RESOLVED="$(printf '%s' "$SKILLS_CLIS_RESOLVED" | tr -d '[:space:]')"
if [ "$SKILLS_EXPLICIT_CLIS" = "none" ]; then
  SKILLS_EXPLICIT_CLIS=""
fi
SKILLS_EXPLICIT_CLIS="$(printf '%s' "$SKILLS_EXPLICIT_CLIS" | tr -d '[:space:]')"
remaining_clis="$SKILLS_CLIS_RESOLVED"
while [ -n "$remaining_clis" ]; do
  cli="${remaining_clis%%,*}"
  if [ "$remaining_clis" = "$cli" ]; then
    remaining_clis=""
  else
    remaining_clis="${remaining_clis#*,}"
  fi
  [ -n "$cli" ] || fail "skills CLI list contains an empty item"
  case "$cli" in copilot|claude|codex) ;; *) fail "unsupported skills CLI: $cli" ;; esac
done
[ -n "$SKILLS_CLIS_RESOLVED" ] && ok "skills CLIs: $SKILLS_CLIS_RESOLVED" ||
  skip "dfrysinger-skills disabled"

# ---- Dreaming selection ---------------------------------------------------

bold "Dreaming (optional)"

EXISTING_DREAMING_ENABLED="$(read_config_var DREAMING_ENABLED)"
EXISTING_DREAMING_REPO_ROOT="$(read_config_var DREAMING_REPO_ROOT)"
DREAMING_REPO_ROOT_RESOLVED="${DREAMING_REPO_ROOT_ARG:-${EXISTING_DREAMING_REPO_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/remote-agent-stack/dreaming}}"
DREAMING_EXPLICIT="false"

if [ -n "$DREAMING_ARG" ]; then
  DREAMING_ENABLED_RESOLVED="$DREAMING_ARG"
  DREAMING_EXPLICIT="true"
elif [ -n "$EXISTING_DREAMING_ENABLED" ]; then
  DREAMING_ENABLED_RESOLVED="$EXISTING_DREAMING_ENABLED"
  ok "keeping existing Dreaming selection: $DREAMING_ENABLED_RESOLVED"
elif [ -t 0 ] && [ -t 1 ]; then
  DREAMING_DEFAULT="false"
  if [ -f "$HOME/Library/LaunchAgents/com.$(id -un).dreaming.dreaming.plist" ]; then
    DREAMING_DEFAULT="true"
  fi
  echo "    Install the headless Dreaming learning and skill-curation service?"
  echo "    Its private skills stay out of normal interactive CLI context."
  if [ "$DREAMING_DEFAULT" = "true" ]; then
    printf "    Enable? [Y/n]: "
  else
    printf "    Enable? [y/N]: "
  fi
  read -r DREAMING_INPUT || DREAMING_INPUT=""
  case "$DREAMING_INPUT" in
    y|Y|yes|YES|true) DREAMING_ENABLED_RESOLVED="true" ;;
    n|N|no|NO|false) DREAMING_ENABLED_RESOLVED="false" ;;
    "") DREAMING_ENABLED_RESOLVED="$DREAMING_DEFAULT" ;;
    *) fail "Dreaming selection must be yes or no" ;;
  esac
else
  DREAMING_ENABLED_RESOLVED="false"
  ok "non-interactive Dreaming selection: disabled"
fi

case "$DREAMING_ENABLED_RESOLVED" in
  true|false) ;;
  *) fail "saved DREAMING_ENABLED must be true or false" ;;
esac

if [ "$DREAMING_ENABLED_RESOLVED" = "true" ]; then
  ok "Dreaming enabled from $DREAMING_REPO_ROOT_RESOLVED"
else
  skip "Dreaming disabled"
fi

EXISTING_SCREEN_SHARING_PORT="$(read_config_var SCREEN_SHARING_PORT)"
EXISTING_DESK_DISPLAY_COUNT="$(read_config_var DESK_DISPLAY_COUNT)"
EXISTING_SCREEN_SHARING_HOURS="$(read_config_var SCREEN_SHARING_HOURS)"
SCREEN_SHARING_PORT_RESOLVED="${SCREEN_SHARING_PORT_ARG:-${EXISTING_SCREEN_SHARING_PORT:-15900}}"
DESK_DISPLAY_COUNT_RESOLVED="${DESK_DISPLAY_COUNT_ARG:-${EXISTING_DESK_DISPLAY_COUNT:-3}}"
SCREEN_SHARING_HOURS_RESOLVED="${SCREEN_SHARING_HOURS_ARG:-${EXISTING_SCREEN_SHARING_HOURS:-1}}"
validate_integer "screen sharing port" "$SCREEN_SHARING_PORT_RESOLVED" 1 65535
validate_integer "desk display count" "$DESK_DISPLAY_COUNT_RESOLVED" 1 16
validate_integer "screen sharing hours" "$SCREEN_SHARING_HOURS_RESOLVED" 1 8

node "$MANAGE_AGENT_HELP" \
  --mode check \
  --clis "$AGENT_HELP_CLIS_RESOLVED" \
  --node "$(command -v node)" \
  --server "$MCP_SERVER"
ok "selected CLI configuration is ownership-safe"

node "$MANAGE_SKILLS_PLUGIN" \
  --mode check \
  --clis "$SKILLS_CLIS_RESOLVED" \
  --explicit-clis "$SKILLS_EXPLICIT_CLIS"
ok "selected skills plugin configuration is ownership-safe"

node "$MANAGE_DREAMING" \
  --mode check \
  --enabled "$DREAMING_ENABLED_RESOLVED" \
  --explicit "$DREAMING_EXPLICIT" \
  --repo "$DREAMING_REPO_ROOT_RESOLVED"
ok "selected Dreaming configuration is ownership-safe"

# ---- detect what needs root -----------------------------------------------
#
# We figure out exactly what privileged work is needed BEFORE prompting
# for sudo, so we can run it all in one sudo invocation below.

NEED_TAILSCALED_START=false
NEED_RESOLVER_WRITE=false
NEED_USRLOCALBIN_MKDIR=false
NEED_SYMLINK=false
NEED_SCREEN_SHARING_INSTALL=false

# ---- tailscaled: detect sandboxed / non-brew build ------------------------
#
# The Homebrew tailscaled formula runs unsandboxed and can bind :22 for
# Tailscale SSH. The GUI Tailscale.app (both Mac App Store and, since
# ~1.98, the standalone download from tailscale.com) ships a sandboxed
# daemon that refuses `tailscale up --ssh` with:
#   "The Tailscale SSH server does not run in sandboxed Tailscale GUI builds."
#
# The old logic (`if ! pgrep -xq tailscaled`) treated any running tailscaled
# as "already good" and silently skipped `brew services start tailscale`.
# That left users with a sandboxed daemon in place and no obvious signal
# that Tailscale SSH would refuse to enable. Fix: identify the running
# binary's path and warn loudly if it isn't Homebrew's.

_running_tailscaled_path() {
  # Print the executable path of the first running tailscaled process, or
  # empty string if none. Uses `ps -Ao command` because on macOS that
  # shows argv[0] as the absolute path when the process was launched via
  # one (which is how launchd and brew services both start tailscaled).
  # We deliberately match only exec paths that END in /tailscaled so we
  # don't false-positive on the io.tailscale.ipn.macsys.* system extension.
  ps -Ao command 2>/dev/null |
    awk '!found && $1 ~ /\/tailscaled$/ { print $1; found = 1 }'
}

RUNNING_TAILSCALED_PATH="$(_running_tailscaled_path)"
BREW_TAILSCALED_PATH="$(brew --prefix tailscale 2>/dev/null)/bin/tailscaled"

if [ -z "$RUNNING_TAILSCALED_PATH" ]; then
  NEED_TAILSCALED_START=true
elif [ -n "$BREW_TAILSCALED_PATH" ] && [ "$RUNNING_TAILSCALED_PATH" = "$BREW_TAILSCALED_PATH" ]; then
  :  # already running from brew, good
else
  # A tailscaled is running but it isn't brew's — most likely the sandboxed
  # GUI Tailscale.app daemon at /usr/local/bin/tailscaled. Do NOT run
  # `brew services start tailscale` (would silently no-op or race); warn
  # the user with concrete switchover commands instead.
  bold "Tailscale daemon"
  warn "non-Homebrew tailscaled is running: $RUNNING_TAILSCALED_PATH"
  cat <<TSSWITCH
    That daemon is almost certainly the sandboxed Tailscale.app GUI
    build, which refuses to run Tailscale SSH ("The Tailscale SSH
    server does not run in sandboxed Tailscale GUI builds.").

    Switch to Homebrew's tailscaled before enabling SSH:

      osascript -e 'quit app "Tailscale"'
      sudo "$RUNNING_TAILSCALED_PATH" uninstall-system-daemon
      sudo brew services start tailscale
      sudo tailscale up --ssh --accept-routes    # re-auth when prompted

    You'll be asked to visit an auth URL — brew's tailscaled has its
    own state dir and doesn't inherit the GUI daemon's login.

    Skipping "brew services start tailscale" for now; re-run this
    installer after the switch to finish setup.
TSSWITCH
  # We intentionally do NOT set NEED_TAILSCALED_START=true here — we
  # want the install to proceed for the parts it CAN still complete
  # (symlinks, resolver, tmux config) without also trying to poke
  # brew's tailscaled while the GUI one is holding the socket.
fi

if [ ! -f "$RESOLVER_DST" ] || ! cmp -s "$RESOLVER_SRC" "$RESOLVER_DST"; then
  NEED_RESOLVER_WRITE=true
fi

if [ ! -d /usr/local/bin ]; then
  NEED_USRLOCALBIN_MKDIR=true
fi

for _name in agent-stack copilot-agent claude-agent codex-agent agent-screen; do
  _dst="/usr/local/bin/$_name"
  if [ "$_name" = "agent-screen" ]; then
    _expected="$SCREEN_SHARING_SRC"
  else
    _expected="$WRAPPER_SRC"
  fi
  if ! { [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_expected" ]; }; then
    NEED_SYMLINK=true
  fi
done
for _name in ca cc co ss remote-agent remote-screen; do
  _dst="/usr/local/bin/$_name"
  case "$_name" in
    ss) _expected="$REPO_ROOT/bin/ss" ;;
    remote-screen) _expected="$REPO_ROOT/bin/remote-screen" ;;
    *) _expected="$WRAPPER_SRC" ;;
  esac
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_expected" ]; then
    NEED_SYMLINK=true
  fi
done

# vncfix remains a standalone GUI recovery helper.
for _pair in "$VNCFIX_SRC:$VNCFIX_DST"; do
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
chmod +x "$WRAPPER_SRC" "$SCREEN_SHARING_SRC" "$VNCFIX_SRC" "$SS_ROOT_SRC" \
  "$MCP_SRC/server.mjs" "$MCP_SRC/configure.mjs" "$MANAGE_AGENT_HELP" \
  "$MANAGE_SKILLS_PLUGIN" "$MANAGE_DREAMING" "$COMMAND_LINK_MANAGER"

if [ ! -f "$SS_ROOT_DST" ] || ! cmp -s "$SS_ROOT_SRC" "$SS_ROOT_DST" ||
   [ ! -f "$SS_EXPIRY_PLIST_DST" ] ||
   ! cmp -s "$SS_EXPIRY_PLIST_SRC" "$SS_EXPIRY_PLIST_DST" ||
   [ ! -f "$SS_SUDOERS_DST" ] ||
   [ ! -f "$SS_ROOT_CONFIG" ] ||
   ! grep -q "^INSTALL_USER='$USER'$" "$SS_ROOT_CONFIG" 2>/dev/null ||
   ! grep -q "^SCREEN_SHARING_PORT='$SCREEN_SHARING_PORT_RESOLVED'$" "$SS_ROOT_CONFIG" 2>/dev/null ||
   ! launchctl print "system/$SS_EXPIRY_LABEL" >/dev/null 2>&1; then
  NEED_SCREEN_SHARING_INSTALL=true
fi

# ---- single sudo block -----------------------------------------------------

bold "Privileged operations"

if $NEED_TAILSCALED_START || $NEED_RESOLVER_WRITE || $NEED_USRLOCALBIN_MKDIR ||
   $NEED_SYMLINK || $NEED_SCREEN_SHARING_INSTALL; then
  echo
  echo "  The following privileged operations are needed:"
  $NEED_TAILSCALED_START   && echo "    • start tailscaled (brew services start tailscale)"
  $NEED_RESOLVER_WRITE     && echo "    • write $RESOLVER_DST (MagicDNS resolver)"
  $NEED_USRLOCALBIN_MKDIR  && echo "    • create /usr/local/bin"
  $NEED_SYMLINK            && echo "    • install agent-stack, backend aliases, and agent-screen; retire owned short and remote-* links"
  $NEED_SYMLINK            && echo "    • symlink $VNCFIX_DST -> bin/vncfix"
  $NEED_SCREEN_SHARING_INSTALL && echo "    • install bounded Screen Sharing helper, watchdog, and exact sudoers rules"
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
  NEED_SCREEN_SHARING_INSTALL="$NEED_SCREEN_SHARING_INSTALL" \
  RESOLVER_SRC="$RESOLVER_SRC" \
  RESOLVER_DST="$RESOLVER_DST" \
  WRAPPER_SRC="$WRAPPER_SRC" \
  COMMAND_LINK_MANAGER="$COMMAND_LINK_MANAGER" \
  SCREEN_SHARING_SRC="$SCREEN_SHARING_SRC" \
  VNCFIX_SRC="$VNCFIX_SRC" \
  VNCFIX_DST="$VNCFIX_DST" \
  SS_ROOT_SRC="$SS_ROOT_SRC" \
  SS_ROOT_DST="$SS_ROOT_DST" \
  SS_ROOT_CONFIG="$SS_ROOT_CONFIG" \
  SS_EXPIRY_PLIST_SRC="$SS_EXPIRY_PLIST_SRC" \
  SS_EXPIRY_PLIST_DST="$SS_EXPIRY_PLIST_DST" \
  SS_EXPIRY_LABEL="$SS_EXPIRY_LABEL" \
  SS_SUDOERS_DST="$SS_SUDOERS_DST" \
  INSTALL_USER="$USER" \
  SCREEN_SHARING_PORT="$SCREEN_SHARING_PORT_RESOLVED" \
  TAILSCALE_BIN="$(command -v tailscale)" \
  BREW_BIN="$(command -v brew)" \
  sudo --preserve-env=NEED_TAILSCALED_START,NEED_RESOLVER_WRITE,NEED_USRLOCALBIN_MKDIR,NEED_SYMLINK,NEED_SCREEN_SHARING_INSTALL,RESOLVER_SRC,RESOLVER_DST,WRAPPER_SRC,COMMAND_LINK_MANAGER,SCREEN_SHARING_SRC,VNCFIX_SRC,VNCFIX_DST,SS_ROOT_SRC,SS_ROOT_DST,SS_ROOT_CONFIG,SS_EXPIRY_PLIST_SRC,SS_EXPIRY_PLIST_DST,SS_EXPIRY_LABEL,SS_SUDOERS_DST,INSTALL_USER,SCREEN_SHARING_PORT,TAILSCALE_BIN,BREW_BIN \
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
    if [ "$NEED_SCREEN_SHARING_INSTALL" = "true" ]; then
      case "$INSTALL_USER" in
        ""|*[!A-Za-z0-9._-]*) echo "invalid installing username" >&2; exit 1 ;;
      esac
      case "$SCREEN_SHARING_PORT" in
        ""|*[!0-9]*) echo "invalid Screen Sharing port" >&2; exit 1 ;;
      esac
      for managed_parent in /usr/local/libexec /usr/local/etc /var/db; do
        if [ -L "$managed_parent" ]; then
          echo "refusing symlinked privileged parent: $managed_parent" >&2
          exit 1
        fi
      done
      validate_privileged_dir() {
        local path="$1" owner mode
        [ -d "$path" ] || return 0
        owner="$(stat -f %Su "$path")"
        mode="$(stat -f %OLp "$path")"
        if [ "$owner" != root ] || [ $((8#$mode & 8#022)) -ne 0 ]; then
          echo "privileged path must be root-owned and not group/other-writable: $path" >&2
          exit 1
        fi
      }
      validate_privileged_dir /usr/local
      validate_privileged_dir /usr/local/libexec
      validate_privileged_dir /usr/local/etc
      validate_privileged_dir /var
      validate_privileged_dir /var/db

      if [ -L "$SS_ROOT_DST" ]; then
        echo "refusing to replace symlinked helper: $SS_ROOT_DST" >&2
        exit 1
      fi
      if [ -f "$SS_ROOT_DST" ]; then
        if grep -q "remote-agent-stack managed helper" "$SS_ROOT_DST" ||
           grep -q "ss-on-demand must run as root" "$SS_ROOT_DST"; then
          "$SS_ROOT_DST" off >/dev/null
        else
          echo "refusing to overwrite foreign helper: $SS_ROOT_DST" >&2
          exit 1
        fi
      fi
      if [ -L "$SS_ROOT_CONFIG" ] ||
         { [ -f "$SS_ROOT_CONFIG" ] &&
           ! grep -q '^INSTALL_USER=' "$SS_ROOT_CONFIG"; }; then
        echo "refusing to overwrite foreign root config: $SS_ROOT_CONFIG" >&2
        exit 1
      fi
      if [ -L "$SS_EXPIRY_PLIST_DST" ] ||
         { [ -f "$SS_EXPIRY_PLIST_DST" ] &&
           ! grep -q '<string>com.remote-agent-stack.screen-sharing-expiry</string>' "$SS_EXPIRY_PLIST_DST"; }; then
        echo "refusing to overwrite foreign LaunchDaemon: $SS_EXPIRY_PLIST_DST" >&2
        exit 1
      fi
      if [ -L "$SS_SUDOERS_DST" ] ||
         { [ -f "$SS_SUDOERS_DST" ] &&
           ! grep -q '/usr/local/libexec/ss-on-demand' "$SS_SUDOERS_DST"; }; then
        echo "refusing to overwrite foreign sudoers rule: $SS_SUDOERS_DST" >&2
        exit 1
      fi

      old_port=15900
      if [ -f "$SS_ROOT_CONFIG" ]; then
        configured_old_port="$(awk -F= '$1=="SCREEN_SHARING_PORT" {
          gsub(/\047/, "", $2)
          print $2
          exit
        }' "$SS_ROOT_CONFIG" 2>/dev/null || true)"
        case "$configured_old_port" in
          *[!0-9]*|"") ;;
          *) old_port="$configured_old_port" ;;
        esac
      fi
      old_target="$(/usr/bin/sudo -n -u "$INSTALL_USER" -- "$TAILSCALE_BIN" serve status --json 2>/dev/null |
        /usr/bin/python3 -c '
import json, sys
port = sys.argv[1]
try:
    entry = (json.load(sys.stdin).get("TCP") or {}).get(port) or {}
    print(entry.get("TCPForward") or "")
except Exception:
    pass
' "$old_port" || true)"
      if [ "$old_target" = "localhost:5900" ] || [ "$old_target" = "tcp://localhost:5900" ]; then
        /usr/bin/sudo -n -u "$INSTALL_USER" -- "$TAILSCALE_BIN" \
          serve --yes --tcp "$old_port" off >/dev/null 2>&1 || true
      fi

      # Retire only the exact legacy sleep-based lease process. A reused PID
      # with any other command is left untouched.
      if [ -f /tmp/ss-lease.pid ]; then
        legacy_pid="$(cat /tmp/ss-lease.pid 2>/dev/null || true)"
        case "$legacy_pid" in
          *[!0-9]*|"") ;;
          *)
            legacy_command="$(ps -p "$legacy_pid" -o command= 2>/dev/null || true)"
            if printf '%s' "$legacy_command" | grep -Eq 'sleep [0-9]+.*ss off'; then
              kill "$legacy_pid" 2>/dev/null || true
            fi
            ;;
        esac
        rm -f /tmp/ss-lease.pid
      fi
      rm -f /tmp/ss-auto-off.log

      install -d -o root -g wheel -m 0755 /usr/local/libexec
      install -d -o root -g wheel -m 0755 /usr/local/etc/remote-agent-stack
      install -d -o root -g wheel -m 0755 /var/db/remote-agent-stack
      validate_privileged_dir /usr/local/libexec
      validate_privileged_dir /usr/local/etc
      validate_privileged_dir /usr/local/etc/remote-agent-stack
      validate_privileged_dir /var/db/remote-agent-stack
      install -o root -g wheel -m 0755 "$SS_ROOT_SRC" "$SS_ROOT_DST"

      root_config_tmp="$(mktemp)"
      printf "INSTALL_USER='%s'\nTAILSCALE_BIN='%s'\nSCREEN_SHARING_PORT='%s'\n" \
        "$INSTALL_USER" "$TAILSCALE_BIN" "$SCREEN_SHARING_PORT" > "$root_config_tmp"
      install -o root -g wheel -m 0644 "$root_config_tmp" "$SS_ROOT_CONFIG"
      rm -f "$root_config_tmp"

      install -o root -g wheel -m 0644 "$SS_EXPIRY_PLIST_SRC" "$SS_EXPIRY_PLIST_DST"

      sudoers_tmp="$(mktemp)"
      {
        printf 'Defaults!%s secure_path=/usr/bin:/bin:/usr/sbin:/sbin\n' "$SS_ROOT_DST"
        printf '%s ALL=(root) NOPASSWD:' "$INSTALL_USER"
        separator=' '
        for hours in 1 2 3 4 5 6 7 8; do
          printf '%s%s on %s' "$separator" "$SS_ROOT_DST" "$hours"
          separator=', '
        done
        printf ', %s off\n' "$SS_ROOT_DST"
      } > "$sudoers_tmp"
      chmod 0440 "$sudoers_tmp"
      /usr/sbin/visudo -c -f "$sudoers_tmp" >/dev/null
      install -o root -g wheel -m 0440 "$sudoers_tmp" "$SS_SUDOERS_DST"
      rm -f "$sudoers_tmp"

      launchctl bootout "system/$SS_EXPIRY_LABEL" 2>/dev/null || true
      launchctl bootstrap system "$SS_EXPIRY_PLIST_DST"
    fi
    if [ "$NEED_SYMLINK" = "true" ]; then
      bash "$COMMAND_LINK_MANAGER" \
        --mode install \
        --wrapper "$WRAPPER_SRC" \
        --screen-wrapper "$SCREEN_SHARING_SRC" \
        --bin-dir /usr/local/bin

      # vncfix retains its standalone collision-avoidance rule.
      for _pair in "$VNCFIX_SRC:$VNCFIX_DST"; do
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
  $NEED_SYMLINK            && ok "agent command links reconciled" || true
  $NEED_SYMLINK            && [ -L /usr/local/bin/agent-screen ] && [ "$(readlink /usr/local/bin/agent-screen)" = "$SCREEN_SHARING_SRC" ] && ok "/usr/local/bin/agent-screen -> $SCREEN_SHARING_SRC" || true
  $NEED_SYMLINK            && [ -L "$VNCFIX_DST" ] && [ "$(readlink "$VNCFIX_DST")" = "$VNCFIX_SRC" ] && ok "$VNCFIX_DST -> $VNCFIX_SRC" || true
  $NEED_SCREEN_SHARING_INSTALL && ok "bounded Screen Sharing helper installed" || true
else
  ok "nothing to do (system already configured)"
fi

# ---- workspace bases + config file (no sudo) ------------------------------
#
# Each backend has its own workspace root. Inside each root, agents live in
# AGENT_DIR_PREFIX-prefixed subdirs (default `agent-`):
#   copilot: $COPILOT_WORKSPACE_BASE/agent-<name>
#   claude : $CLAUDE_WORKSPACE_BASE/agent-<name>
#   codex  : $CODEX_WORKSPACE_BASE/agent-<name>

bold "Workspace bases"

# Read existing values from the config file (if any) so re-runs don't pester.
_read_config_var() {
  local var="$1"
  [ -f "$CONFIG_DIR/config" ] || return 0
  awk -v v="$var" -F'=' '$1 ~ "^[[:space:]]*" v "$" {
    sub("^[[:space:]]*" v "=", "", $0)
    gsub(/^"|"$/, "", $0)
    print
    exit
  }' "$CONFIG_DIR/config" 2>/dev/null || true
}

EXISTING_COPILOT_WORKSPACE_BASE="$(_read_config_var COPILOT_WORKSPACE_BASE)"
EXISTING_CLAUDE_WORKSPACE_BASE="$(_read_config_var CLAUDE_WORKSPACE_BASE)"
EXISTING_CODEX_WORKSPACE_BASE="$(_read_config_var CODEX_WORKSPACE_BASE)"
EXISTING_LEGACY_WORKSPACE_BASE="$(_read_config_var WORKSPACE_BASE)"

if [ -z "$EXISTING_COPILOT_WORKSPACE_BASE" ] && [ -n "$EXISTING_LEGACY_WORKSPACE_BASE" ]; then
  EXISTING_COPILOT_WORKSPACE_BASE="$EXISTING_LEGACY_WORKSPACE_BASE"
  ok "migrating existing Copilot workspace config: $EXISTING_COPILOT_WORKSPACE_BASE"
fi

if [ -d "$HOME/Library/CloudStorage/Dropbox" ]; then
  COPILOT_SMART_DEFAULT="$HOME/Library/CloudStorage/Dropbox/copilot-workspace"
  CLAUDE_SMART_DEFAULT="$HOME/Library/CloudStorage/Dropbox/claude-workspace"
  CODEX_SMART_DEFAULT="$HOME/Library/CloudStorage/Dropbox/codex-workspace"
  SMART_DEFAULT_REASON="Dropbox detected — workspaces will sync across Macs"
else
  COPILOT_SMART_DEFAULT="$HOME/copilot-workspace"
  CLAUDE_SMART_DEFAULT="$HOME/claude-workspace"
  CODEX_SMART_DEFAULT="$HOME/codex-workspace"
  SMART_DEFAULT_REASON="no Dropbox found"
fi

# Resolve one workspace base. Sets the global $RESOLVED_WS as the result;
# all status output goes to stdout (kept out of a capture path).
# Args: <backend-label> <arg-value> <existing-value> <smart-default>
_resolve_workspace_base() {
  local label="$1" arg="$2" existing="$3" default="$4"
  RESOLVED_WS=""
  if [ -n "$arg" ]; then
    RESOLVED_WS="$arg"
    ok "using --${label}-workspace-base: $RESOLVED_WS"
  elif [ -n "$existing" ]; then
    RESOLVED_WS="$existing"
    ok "keeping existing $label config: $RESOLVED_WS"
  elif [ -t 0 ] && [ -t 1 ]; then
    echo "    Where should $label agent workspaces live? (parent dir for agent-<name>/)"
    echo "    Default: $default"
    echo "             ($SMART_DEFAULT_REASON)"
    printf "    Path [%s]: " "$default"
    local input=""
    read -r input || input=""
    if [ -z "$input" ]; then
      RESOLVED_WS="$default"
    else
      RESOLVED_WS="$(eval echo "$input")"
    fi
    ok "$label workspace base: $RESOLVED_WS"
  else
    RESOLVED_WS="$default"
    warn "non-interactive shell — using $RESOLVED_WS for $label ($SMART_DEFAULT_REASON)"
    todo "override later with: $0 --${label}-workspace-base PATH"
  fi
}

_resolve_workspace_base copilot "$COPILOT_WORKSPACE_BASE_ARG" \
  "$EXISTING_COPILOT_WORKSPACE_BASE" "$COPILOT_SMART_DEFAULT"
COPILOT_WORKSPACE_BASE_RESOLVED="$RESOLVED_WS"

_resolve_workspace_base claude "$CLAUDE_WORKSPACE_BASE_ARG" \
  "$EXISTING_CLAUDE_WORKSPACE_BASE" "$CLAUDE_SMART_DEFAULT"
CLAUDE_WORKSPACE_BASE_RESOLVED="$RESOLVED_WS"

_resolve_workspace_base codex "$CODEX_WORKSPACE_BASE_ARG" \
  "$EXISTING_CODEX_WORKSPACE_BASE" "$CODEX_SMART_DEFAULT"
CODEX_WORKSPACE_BASE_RESOLVED="$RESOLVED_WS"

# ---- mailbox integration prompt -------------------------------------------
#
# The optional dfrysinger-skills `mailbox` skill lets one named agent send
# messages/files to another (e.g., handoffs). When enabled, the agent wrapper
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
  echo "    Enable mailbox integration in the agent wrapper?"
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
# When enabled, the wrapper passes the backend-specific allow-all flag
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
  echo "    Skip permission prompts on every agent launch?"
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

# Always (re-)write the config so all workspace bases match what we resolved.
# COPILOT_BIN and AGENT_DIR_PREFIX stay as commented defaults — the wrapper
# falls back to its own defaults if they're absent.
cat > "$CONFIG_DIR/config" <<EOF
# remote-agent-stack — agent wrapper config
# Re-generated by install.sh; safe to edit by hand.
#
# One wrapper (bin/agent) serves three backends:
#   agent-stack copilot <Name> or copilot-agent <Name>
#   agent-stack claude  <Name> or claude-agent <Name>
#   agent-stack codex   <Name> or codex-agent <Name>

# Where each backend's agent working directories live.
COPILOT_WORKSPACE_BASE="$COPILOT_WORKSPACE_BASE_RESOLVED"
CLAUDE_WORKSPACE_BASE="$CLAUDE_WORKSPACE_BASE_RESOLVED"
CODEX_WORKSPACE_BASE="$CODEX_WORKSPACE_BASE_RESOLVED"

# Backend CLI binaries (must be in PATH). Uncomment to override.
# COPILOT_BIN="copilot"
# CLAUDE_BIN="claude"
# CODEX_BIN="codex"

# AGENT_DIR_PREFIX: prefix for per-agent working directories under each
# backend's workspace root. Uncomment to override.
# AGENT_DIR_PREFIX="agent-"

# MAILBOX_INTEGRATION: enable cross-session message/file handoff via the
# optional dfrysinger-skills \`mailbox\` skill. When "true", the wrapper
# pokes the recipient's tmux pane on attach + new-session if pending mail
# exists.
MAILBOX_INTEGRATION="$MAILBOX_INTEGRATION_RESOLVED"

# ALLOW_ALL: when "true", the wrapper skips permission prompts on
# new-session launch (copilot: --allow-all; claude:
# --dangerously-skip-permissions; codex:
# --dangerously-bypass-approvals-and-sandbox).
# Personal-machine convenience; do NOT enable in shared environments.
ALLOW_ALL="$ALLOW_ALL_RESOLVED"

# Agent-to-owner help MCP. The recipient itself is stored separately in
# agent-help/config.json (mode 0600), never in this regenerated wrapper file.
AGENT_HELP_CLIS="${AGENT_HELP_CLIS_RESOLVED:-none}"
SKILLS_CLIS="${SKILLS_CLIS_RESOLVED:-none}"
DREAMING_ENABLED="$DREAMING_ENABLED_RESOLVED"
DREAMING_REPO_ROOT="$DREAMING_REPO_ROOT_RESOLVED"
SCREEN_SHARING_PORT="$SCREEN_SHARING_PORT_RESOLVED"
DESK_DISPLAY_COUNT="$DESK_DISPLAY_COUNT_RESOLVED"
SCREEN_SHARING_HOURS="$SCREEN_SHARING_HOURS_RESOLVED"
EOF
ok "wrote $CONFIG_DIR/config"

# ---- shared agent-help MCP + selected CLI configuration -------------------

bold "Agent help installation"

mkdir -p "$MCP_DST"
chmod 0700 "$CONFIG_DIR" "$CONFIG_DIR/agent-help" "$MCP_DST"
for file in package.json package-lock.json core.mjs core.test.mjs server.mjs \
  server.test.mjs configure.mjs send-imessage.applescript; do
  install -m 0600 "$MCP_SRC/$file" "$MCP_DST/$file"
done
chmod 0700 "$MCP_DST/server.mjs" "$MCP_DST/configure.mjs"

(
  cd "$MCP_DST"
  npm ci --omit=dev --ignore-scripts --quiet
)
ok "installed shared MCP server at $MCP_DST"

if [ -n "$AGENT_HELP_RECIPIENT_RESOLVED" ]; then
  REMOTE_AGENT_STACK_CONFIG_DIR="$CONFIG_DIR" \
    node "$MCP_DST/configure.mjs" \
      --recipient "$AGENT_HELP_RECIPIENT_RESOLVED" \
      --desk-display-count "$DESK_DISPLAY_COUNT_RESOLVED" \
      --screen-sharing-hours "$SCREEN_SHARING_HOURS_RESOLVED" \
      --screen-sharing-port "$SCREEN_SHARING_PORT_RESOLVED" >/dev/null
  ok "updated private recipient and presence configuration without printing it"
fi

node "$MANAGE_AGENT_HELP" \
  --mode reconcile \
  --clis "$AGENT_HELP_CLIS_RESOLVED" \
  --node "$(command -v node)" \
  --server "$MCP_SERVER"
if [ -n "$AGENT_HELP_CLIS_RESOLVED" ]; then
  ok "configured request_help for $AGENT_HELP_CLIS_RESOLVED"
  todo "restart active CLI sessions so they load the new MCP server and instructions"
else
  ok "removed owned request_help entries and instructions from all CLIs"
fi

LEGACY_AGENT_HELP_SERVER="$HOME/.copilot/mcp-servers/agent-help"
if [ -d "$LEGACY_AGENT_HELP_SERVER" ] ||
   [ -f "$HOME/.copilot/agent-help.json" ] ||
   [ -f "$HOME/.copilot/agent-help-state.json" ]; then
  rm -rf "$LEGACY_AGENT_HELP_SERVER"
  rm -f "$HOME/.copilot/agent-help.json" "$HOME/.copilot/agent-help-state.json"
  ok "removed migrated Copilot-only agent-help files"
fi

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
  echo "    Without this, the first \`agent-stack <backend> <name>\` after a reboot bootstraps the"
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
    echo "      3. Re-attach your named agents: agent-stack copilot alpha, agent-stack claude bravo, ..."
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
# All backends are optional at install time — the wrapper enforces
# "backend binary must be in PATH" at launch. Install only the ones you
# actually plan to use.

bold "Backend CLIs"

if have copilot; then
  ok "copilot CLI found ($(copilot --version 2>&1 | head -1))"
else
  warn "copilot CLI not found in PATH — 'agent-stack copilot' / 'copilot-agent' will error until installed."
  echo "    Install per https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli"
fi

if have claude; then
  ok "claude CLI found ($(claude --version 2>&1 | head -1))"
else
  warn "claude CLI not found in PATH — 'agent-stack claude' / 'claude-agent' will error until installed."
  echo "    Install per https://docs.claude.com/en/docs/claude-code/quickstart"
fi

if have codex; then
  ok "codex CLI found ($(codex --version 2>&1 | head -1))"
else
  warn "codex CLI not found in PATH — 'agent-stack codex' / 'codex-agent' will error until installed."
fi

# ---- shared skills plugin --------------------------------------------------

bold "dfrysinger skills plugin"

node "$MANAGE_SKILLS_PLUGIN" \
  --mode reconcile \
  --clis "$SKILLS_CLIS_RESOLVED" \
  --explicit-clis "$SKILLS_EXPLICIT_CLIS"
if [ -n "$SKILLS_CLIS_RESOLVED" ]; then
  ok "configured dfrysinger-skills for $SKILLS_CLIS_RESOLVED"
  todo "restart active CLI sessions so they load the updated skills"
else
  ok "removed owned dfrysinger-skills plugins and marketplaces"
fi

# ---- headless Dreaming service --------------------------------------------

bold "Dreaming service"

node "$MANAGE_DREAMING" \
  --mode reconcile \
  --enabled "$DREAMING_ENABLED_RESOLVED" \
  --explicit "$DREAMING_EXPLICIT" \
  --repo "$DREAMING_REPO_ROOT_RESOLVED"
if [ "$DREAMING_ENABLED_RESOLVED" = "true" ]; then
  ok "installed, self-tested, and enabled headless Dreaming"
else
  ok "removed the owned Dreaming runtime, if present"
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
       agent-stack copilot alpha
       agent-stack claude alpha
       agent-stack codex alpha
       agent-screen on 1     # prints a clickable Screens URL; no password prompt

     Restart each CLI selected for agent help, then ask it to list MCP
     tools. It should expose \`request_help\`. The first real send may
     trigger a macOS Automation prompt allowing the terminal host to
     control Messages; approve it on the Mac.

     Restart each CLI selected for dfrysinger-skills, then inspect its plugin
     list. It should report \`dfrysinger-skills\`.

  5. (Optional) In Termius, set each agent's snippet to a single line:
       agent-stack copilot alpha
       agent-stack claude bravo
       ...

  See README.md for the full Termius walkthrough (iOS hosts + Mac
  desktop workspace setup with screenshots).

MANUAL

bold "Install complete."
