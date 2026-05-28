# Termius snippets

After `install.sh` puts `copilot-agent` on your PATH, each Termius snippet
shrinks to a single line. Create six snippets (one per agent) — paste the
line below into the snippet body, set the name to match.

| Snippet name | Body |
|--------------|------|
| Agent alpha   | `copilot-agent alpha`   |
| Agent bravo   | `copilot-agent bravo`   |
| Agent charlie | `copilot-agent charlie` |
| Agent delta   | `copilot-agent delta`   |
| Agent echo    | `copilot-agent echo`    |
| Agent foxtrot | `copilot-agent foxtrot` |

Names are case-sensitive end-to-end (tmux session, workspace directory,
Copilot session name). Pick a casing convention and stick with it.

## Behavior

- First run for an agent: creates `~/Library/CloudStorage/Dropbox/copilot-workspace/agent-<name>/`,
  starts a new tmux session named `<name>`, launches Copilot CLI inside
  with `--name=<name> --remote`.
- Subsequent runs: attaches to the existing tmux session if it's still
  alive, otherwise resumes the most recent Copilot CLI session matching
  `<name>` by `--session-id=<uuid>`.

## Detaching vs. exiting

- **Detach** (leave the session running, drop back to shell): `Ctrl-b d`
  inside tmux.
- **Kill** the agent session entirely: exit Copilot CLI, then `exit` the
  shell tmux gave you — or from outside: `tmux kill-session -t alpha`.

## Why named tmux sessions?

So you can reattach from any device. Open Termius on your phone, run the
alpha snippet, and you'll land back in the same Copilot CLI conversation
your laptop left mid-thought — provided the Mac hasn't rebooted.

## Adding more agents

`copilot-agent` accepts any name; the NATO list is convention, not a hard
requirement. `copilot-agent coordinator` would Just Work and live at
`~/Library/CloudStorage/Dropbox/copilot-workspace/agent-coordinator`.

## Using Termius locally on the Mac

Termius doesn't support per-host "local terminal" entries the way it
does for SSH — you can't make an `alpha-local` host that double-clicks
into `copilot-agent alpha`. A couple of things to know:

- **Mac App Store Termius is sandboxed** and has no local terminal at
  all. To get any local-terminal feature, install the direct-download
  build from <https://termius.com/download>.
- Even in the direct-download build, the local terminal is a single
  pane opened with `Cmd+L`. It doesn't auto-run snippets. You'd
  manually trigger a snippet from the snippet picker after it opens.

If you want one-click access to each agent from Termius on the Mac
itself, your two realistic options:

1. **Cmd+L → run snippet** — open local terminal, hit your snippet
   picker shortcut, choose "Agent alpha". Two-step but uses Termius's
   own UI and saved snippets.
2. **Re-enable macOS Remote Login** and SSH from Termius to
   `localhost`/`127.0.0.1`. Same Termius UX as your phone (one-click
   host with startup snippet), but you're routing through OpenSSH
   instead of just spawning a shell — wasted hop, and you're back to
   needing Remote Login on. Not recommended unless you really want the
   same flow everywhere.

If a true one-click "double-click to land in agent alpha" matters more
than staying inside Termius, the simplest answer is `Terminal.app` with
a `.command` file per agent — drag them into the Dock and click. A
one-liner script per agent:

```bash
#!/bin/bash
exec /usr/local/bin/copilot-agent alpha
```

Save as `~/Applications/Agent Alpha.command`, `chmod +x`, drag to Dock.

If `copilot-agent` isn't found inside Termius's local shell, your
non-login shell PATH is missing `/usr/local/bin`. Easiest fix:

```bash
echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.zshrc
```

(`install.sh` symlinks `copilot-agent` into `/usr/local/bin`, which most
macOS shells already have on PATH.)

