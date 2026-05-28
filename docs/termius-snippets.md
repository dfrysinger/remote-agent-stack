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

## Using Termius locally on the Mac (no SSH)

Termius on macOS can also drive your Mac directly without going through
SSH — handy if you want one Termius UI for both local and remote work.
Create one **Local Terminal** host per agent and let snippets auto-run
on connect:

1. Termius → **New Host** → choose **Local Terminal** (Termius Mac app
   only — the iOS app doesn't have this).
2. **Label**: `alpha-local` (or whatever you want it to show as).
3. **Startup snippet** (or "Run command after connect", depending on
   Termius version): paste your saved `Agent alpha` snippet, or inline
   `copilot-agent alpha`.
4. Save. Double-click the host → Termius spawns a local zsh, runs the
   snippet, drops you in the live agent session.

Repeat per agent. On the Mac itself you now have six entries that go
straight into `copilot-agent <name>` with no SSH hop. On your phone you
still use the SSH host pointed at `macbook-air` and the same snippets.

If `copilot-agent` isn't found inside Termius's local shell, your
non-login shell PATH is missing `/usr/local/bin`. Easiest fix:

```bash
echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.zshrc
```

(`install.sh` symlinks `copilot-agent` into `/usr/local/bin`, which most
macOS shells already have on PATH.)

