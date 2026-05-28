# remote-agent-stack

A small macOS bootstrap that turns a fresh Mac into a remote-accessible host
for running named AI agent sessions (currently GitHub Copilot CLI, with
hooks for adding Claude / Codex later) over Tailscale SSH and tmux.

## What you get

- A `copilot-agent <name>` wrapper (also installed as the short alias
  `ca`) that launches or reattaches to a named agent session — keychain
  unlock, tmux session management, and `copilot --resume / --name
  / --remote` plumbing all handled.
- A one-shot installer for the OS-level prerequisites: Homebrew, tmux,
  Tailscale, and the MagicDNS resolver fix that Homebrew's Tailscale
  formula leaves out.
- A symmetric uninstaller.

## Quick start

```bash
git clone <this-repo> ~/code/remote-agent-stack
cd ~/code/remote-agent-stack
./install.sh
```

If you're driving the install **over VNC / Screens / Termius** (anywhere
the sudo prompt might be hard to see), use the GUI launcher instead —
it opens a fresh Terminal.app window where the password prompt is
obvious:

```bash
open ~/code/remote-agent-stack/install-gui.command
```

(Or double-click `install-gui.command` in Finder.)

The installer is idempotent — safe to re-run. It prints a checklist of the
manual GUI / interactive steps it can't perform (Full Disk Access grants,
`tailscale up --ssh`, first Copilot CLI auth prompt).

Once the manual steps are done, in any shell on the Mac (including over
Tailscale SSH, via Termius, etc.):

```bash
copilot-agent alpha     # or just: ca alpha
```

Substitute `bravo`, `charlie`, etc. for your other agents. Each name maps
to a workspace directory under `$WORKSPACE_BASE/agent-<name>`
(default: `~/Library/CloudStorage/Dropbox/copilot-workspace/agent-alpha`,
etc.) and a tmux session of the same name.

Names are case-sensitive end-to-end (workspace dir, tmux session, and
Copilot session name all match exactly what you type), so pick a casing
convention and stick with it. Lowercase is what we use.

## How `copilot-agent <name>` (or `ca <name>`) behaves

1. If a tmux session named `<name>` exists → attach to it.
2. Otherwise:
   - Unlock the login keychain (so `git`, `gh`, etc. inside the session
     can read their stored credentials).
   - Create a new tmux session in the agent's workspace directory.
   - Run `copilot --resume='<name>' --name='<name>' --remote` inside, or
     fall back to a fresh named session if no prior session matches.

## Configuration

Defaults live in `~/.config/remote-agent-stack/config` (created on first
install). Override any of:

```sh
WORKSPACE_BASE="$HOME/Library/CloudStorage/Dropbox/copilot-workspace"
COPILOT_BIN="copilot"
AGENT_DIR_PREFIX="agent-"
```

## Docs

- [docs/termius-snippets.md](docs/termius-snippets.md) — ready-to-paste
  Termius snippets for six NATO-named agents.
- [docs/fda-grants.md](docs/fda-grants.md) — exactly which binaries need
  Full Disk Access on macOS Ventura+ and why.
- [docs/troubleshooting.md](docs/troubleshooting.md) — every macOS /
  Tailscale / Copilot CLI gotcha we hit getting this working.

## Uninstall

```bash
~/code/remote-agent-stack/uninstall.sh           # removes wrapper + resolver
~/code/remote-agent-stack/uninstall.sh --purge   # also drops the config dir
```

Homebrew packages, FDA grants, and Tailscale network state are left in
place — see the uninstaller output for the manual cleanup commands.

## Why a wrapper instead of a shell snippet?

Because debugging that snippet across six Termius profiles, on a phone,
over a flaky LTE connection, in tmux, with a Copilot CLI that's still
asking about keychain storage was a bad time. One file, one place to fix.

## Status

Single-machine, single-user, macOS arm64. Tested on macOS Tahoe.
Linux support and other agent backends (Claude Code, Codex) are open
issues — patches welcome.
