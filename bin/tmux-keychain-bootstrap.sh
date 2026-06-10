#!/bin/sh
# tmux-keychain-bootstrap.sh
#
# Pre-warm the tmux server inside the user's GUI (Aqua) login session, so
# every session hosted by that server — including ones attached over
# Tailscale-SSH later in the day — inherits full login-keychain access.
#
# Why: macOS gives the login keychain in a process's searchable keychain
# list only to processes spawned inside the user's GUI/Aqua login session.
# A tmux server bootstrapped from a non-GUI context (typically the SSH
# login shell behind the very first `ca <name>` call after a reboot) is
# stuck with the restricted "system keychain only" search list, and every
# shell inside that server inherits the same restriction. The visible
# symptom is that `gh`, the `osxkeychain` git credential helper, and
# anything else that reads the login keychain silently fail inside agent
# shells, even though they work in Terminal.app on the same Mac.
#
# This script is intended to be invoked once at login via the LaunchAgent
# at ~/Library/LaunchAgents/com.dfrysinger.tmux-keychain-bootstrap.plist
# (installed by remote-agent-stack/install.sh). It is idempotent: if a
# tmux server is already running, it exits 0 without touching anything.

set -e

# Pin the tmux socket location to /private/tmp/tmux-<uid>/default so it
# matches the PathState watcher in the plist. The plist's PathState is
# hardcoded to the default tmux socket path at install time; if launchd's
# user environment has TMUX_TMPDIR set (via `launchctl setenv`), tmux
# would otherwise create the socket somewhere else and the watcher would
# fire forever on a path that never appears. Unsetting here keeps the
# script and the watcher in agreement regardless of launchd env.
unset TMUX_TMPDIR

TMUX="$(command -v tmux 2>/dev/null || true)"
[ -x "$TMUX" ] || TMUX=/opt/homebrew/bin/tmux
[ -x "$TMUX" ] || TMUX=/usr/local/bin/tmux
[ -x "$TMUX" ] || {
  echo "tmux-keychain-bootstrap: tmux binary not found" >&2
  # Exit 0 so we don't add to the noise. NOTE: with the new
  # KeepAlive=PathState=false in the plist, launchd will still respawn
  # us every ThrottleInterval (~10s) while the socket path is missing,
  # regardless of our exit code. That's intentional: it means we
  # self-recover automatically once the user reinstalls tmux. The cost
  # is some log noise in /tmp/com.dfrysinger.tmux-keychain-bootstrap.err.log
  # during the broken-tmux window, which is fine.
  exit 0
}

# Server already running? Nothing to do.
if "$TMUX" list-sessions >/dev/null 2>&1; then
  exit 0
fi

# Bootstrap a hidden anchor session that holds the server open. The
# leading underscore is a convention to mark it as infrastructure; tmux
# itself treats it no differently than any other name, but it sorts to
# the top of `tmux ls` and signals "don't kill me" to a human reader.
#
# We use `tail -f /dev/null` (not `sleep infinity`) because macOS BSD
# `sleep` rejects the `infinity` argument — the session would die
# immediately, the server would exit under default `exit-empty on`, and
# the whole bootstrap would be a silent no-op. `tail -f /dev/null` is
# in /usr/bin (always on PATH under launchd) and runs forever.
exec "$TMUX" new-session -d -s _keychain-anchor "exec tail -f /dev/null"
