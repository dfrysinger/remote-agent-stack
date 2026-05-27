# Termius snippets

After `install.sh` puts `copilot-agent` on your PATH, each Termius snippet
shrinks to a single line. Create six snippets (one per agent) — paste the
line below into the snippet body, set the name to match.

| Snippet name | Body |
|--------------|------|
| Agent Alpha   | `copilot-agent Alpha`   |
| Agent Bravo   | `copilot-agent Bravo`   |
| Agent Charlie | `copilot-agent Charlie` |
| Agent Delta   | `copilot-agent Delta`   |
| Agent Echo    | `copilot-agent Echo`    |
| Agent Foxtrot | `copilot-agent Foxtrot` |

## Behavior

- First run for an agent: creates `~/Library/CloudStorage/Dropbox/copilot-workspace/agent-<name>/`,
  starts a new tmux session named `<Name>`, launches Copilot CLI inside
  with `--name=<Name> --remote`.
- Subsequent runs: attaches to the existing tmux session if it's still
  alive, otherwise resumes Copilot CLI via `--resume=<Name>`.

## Detaching vs. exiting

- **Detach** (leave the session running, drop back to shell): `Ctrl-b d`
  inside tmux.
- **Kill** the agent session entirely: exit Copilot CLI, then `exit` the
  shell tmux gave you — or from outside: `tmux kill-session -t Alpha`.

## Why named tmux sessions?

So you can reattach from any device. Open Termius on your phone, run the
Alpha snippet, and you'll land back in the same Copilot CLI conversation
your laptop left mid-thought — provided the Mac hasn't rebooted.

## Adding more agents

`copilot-agent` accepts any name; the NATO list is convention, not a hard
requirement. `copilot-agent Coordinator` would Just Work and live at
`~/Library/CloudStorage/Dropbox/copilot-workspace/agent-Coordinator`.
