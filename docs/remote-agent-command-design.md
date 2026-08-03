# Remote Agent Command

## Objective

Provide one collision-resistant command for launching named Copilot, Claude,
and Codex sessions:

```text
remote-agent copilot <name>
remote-agent claude <name>
remote-agent codex <name>
```

Keep `copilot-agent`, `claude-agent`, and `codex-agent` as equivalent long
aliases. Stop installing the short `ca`, `cc`, and `co` names because they
collide with existing system and user commands.

## Lane

Systemic.

The change modifies the installed command contract, adds the Codex named-session
backend, and removes previously owned aliases during upgrade and uninstall.

## Non-goals

- Rename the separate `ss` Screen Sharing helper. Its command collision is a
  separate user-facing migration.
- Preserve `ca`, `cc`, or `co` as supported compatibility commands.
- Install Copilot, Claude, or Codex itself.
- Change existing workspace layouts, live tmux session names, session rotation,
  mailbox behavior, or permission defaults. New Copilot tmux sessions move to
  the backend-prefixed namespace; matching live legacy sessions remain in
  place and reattach without renaming.
- Add shell aliases, shell startup-file edits, or command abbreviations.
- Generalize the wrapper into a plugin system for unknown future CLIs.

## Reuse

Keep one multi-call wrapper at `bin/agent`. The canonical command and all three
aliases point to that file.

Port the Codex session discovery and `codex resume --last` behavior from the
existing `codex-support` commit `a64c6b8`. Transplant only the Codex behavior;
do not merge its older copies of the wrapper, installer, README, or
uninstaller. Preserve the current wrapper's tmux safety, mailbox, keychain,
Copilot rotation, and session-reattachment behavior.

## Command contract

`remote-agent` requires a backend and session name:

```text
remote-agent <copilot|claude|codex> <name>
```

The long aliases select their backend from the invoked filename:

```text
copilot-agent <name>
claude-agent <name>
codex-agent <name>
```

Unknown backends, unknown invocation names, missing names, extra arguments, and
option-shaped names other than `-h` or `--help` fail with usage and status 2.
`remote-agent -h|--help`, `remote-agent <backend> -h|--help`, and each long
alias with `-h|--help` print the relevant usage and exit 0. Direct development
invocation through `bin/agent` uses the same backend-first form as
`remote-agent`.

Each backend retains a separate workspace and tmux namespace:

| Backend | Workspace | tmux session |
|---|---|---|
| Copilot | `$COPILOT_WORKSPACE_BASE/agent-<name>` | `copilot-<name>` |
| Claude | `$CLAUDE_WORKSPACE_BASE/agent-<name>` | `claude-<name>` |
| Codex | `$CODEX_WORKSPACE_BASE/agent-<name>` | `codex-<name>` |

New sessions use an explicit backend prefix, so every user-supplied name is
safe in every backend. For Copilot compatibility, the wrapper first checks for
an existing legacy unprefixed `<name>` tmux session. It attaches to that legacy
session only when its physical session path matches the expected Copilot
workspace. Otherwise it uses `copilot-<name>`. The wrapper never creates a new
unprefixed Copilot tmux session.

Before attaching to an existing tmux session, the wrapper reads that session's
stable `#{session_path}` value, not the active pane's current directory. It
resolves both the session path and expected backend workspace to physical
paths before comparing them, so symlinks, trailing slashes, and macOS path
aliases such as `/tmp` and `/private/tmp` do not cause false mismatches. A
genuine mismatch fails without switching or attaching, reports both paths,
and tells the user to choose another name or explicitly remove or rename the
conflicting tmux session.

## Installation and migration

The installer manages these links:

```text
/usr/local/bin/remote-agent
/usr/local/bin/copilot-agent
/usr/local/bin/claude-agent
/usr/local/bin/codex-agent
```

It creates or replaces a link only when the path is absent or already points to
this checkout's wrapper. A foreign file or foreign symlink fails preflight
instead of being overwritten.

During upgrade, the installer removes `ca`, `cc`, or `co` only when the path is
a symlink to this checkout's wrapper. Foreign paths remain untouched. The
uninstaller applies the same exact-target ownership check to every canonical,
alias, and retired name.

The configuration adds `CODEX_WORKSPACE_BASE` and optional `CODEX_BIN`.
Existing Copilot and Claude workspace settings remain unchanged.

## Invariants and acceptance criteria

- The canonical command always requires an explicit backend; direct invocation
  never silently selects Copilot.
- Each long alias is behaviorally identical to its canonical subcommand.
- A backend can neither attach to nor create another backend's tmux session or
  workspace.
- Installation and removal mutate only exact links owned by this checkout.
- Upgrade removes an owned retired alias but never a foreign path.
- Codex starts fresh when no matching workspace session exists and resumes only
  when matching history exists.
- Existing Copilot and Claude named sessions resume exactly as before.
- Missing backend binaries fail at that backend's launch, not during
  installation of another backend.

## Failure model

| Failure | Required behavior |
|---|---|
| Unknown backend or invocation name | Print relevant usage and exit 2 |
| Missing or extra session-name argument | Print relevant usage and exit 2 |
| `-h` or `--help` in a supported help position | Print relevant usage and exit 0 |
| Foreign canonical command path | Installer fails before privileged mutation |
| Foreign long-alias path | Installer fails before privileged mutation |
| Foreign retired short name | Preserve it and report that it is not owned |
| Missing selected backend binary | That launch exits with an actionable error |
| Missing backend workspace root | That launch names the required configuration key |
| Codex history scan fails or is unreadable | Start fresh rather than claiming a resumable session exists |
| Existing legacy unprefixed Copilot session has the expected physical workspace | Attach using the current terminal-safety rules |
| Existing legacy unprefixed Copilot session has another physical workspace | Ignore it and use the backend-prefixed Copilot tmux name |
| Existing selected backend-prefixed tmux session has another physical workspace path | Refuse to attach, report both paths, and name the remove/rename-or-choose-another-name recovery |
| Existing tmux session | Attach or switch using the current terminal-safety rules |
| Non-terminal attach or new session | Refuse rather than wedge the tmux server |

## Rollback

No session or workspace data is migrated. Rolling back means inspecting every
command path before mutation, cleaning owned links while this version's
ownership logic is still available, then reinstalling the previous wrapper
links:

1. record the current `CODEX_WORKSPACE_BASE` value outside the generated config;
2. inspect `remote-agent`, `copilot-agent`, `claude-agent`, `codex-agent`, `ca`,
   `cc`, and `co`, and abort before mutation only when a foreign
   `copilot-agent` would be overwritten by the previous installer;
3. run `uninstall.sh --commands-only`, which removes only exact symlinks from
   that seven-name set that target this checkout's wrapper and preserves every
   foreign path;
4. check out the previous release;
5. run its installer, which recreates its supported links, skips foreign
   `ca`/`cc` paths with a warning, and has no interaction with `co`;
6. restore the recorded `CODEX_WORKSPACE_BASE` line after the previous
   installer regenerates the config.

The commands-only mode does not remove MCP configuration, Dreaming, Screen
Sharing, tmux configuration, workspace/session data, or other stack
components. Foreign new links are preserved and reported for manual
resolution. The explicit save-and-restore step is required because the
previous installer truncates and regenerates the config file.

## Codex behavior

The Codex adapter scans `~/.codex/sessions` for a session whose metadata records
the named workspace as its working directory. When one exists, it launches
`codex resume --last`; otherwise it launches `codex`.

`ALLOW_ALL=true` adds
`--dangerously-bypass-approvals-and-sandbox` only to Codex launches.

## Check contract

A wrapper test uses isolated homes, workspaces, fake CLIs, and fake tmux.
Failure is any nonzero expected-success invocation, any zero expected-failure
invocation, or a logged workspace, session, or backend command that differs
from the expected value. It proves:

- canonical subcommands dispatch to all three backends;
- every long alias produces the same backend command as its canonical form;
- session names and workspace paths remain backend-specific;
- new sessions use `copilot-`, `claude-`, or `codex-` tmux namespaces;
- matching legacy unprefixed Copilot sessions still reattach, while new
  unprefixed Copilot sessions are never created;
- Codex starts fresh without history and resumes with matching history;
- an existing tmux name with another backend's workspace is rejected;
- equivalent physical workspace spellings reattach successfully;
- `ALLOW_ALL` adds only the backend's documented permission flag;
- invalid backend, invocation, and argument shapes fail;
- every supported help shape exits 0 with relevant usage;
- `ca`, `cc`, and `co` are not accepted dispatch names.

Baseline fixtures cover the current Copilot and Claude paths before the Codex
transplant. They prove session selection, Copilot rotation state, nested-tmux
switching, non-terminal refusal, mailbox invocation, and keychain handling do
not change. A regression in any baseline fixture fails the change even when
the Codex checks pass.

Installer checks run against temporary path inventories. Failure is an
unexpected planned mutation or failure to report a required mutation. They
prove:

- all four managed links are planned and installed;
- foreign paths are never overwritten;
- owned retired aliases are removed;
- foreign retired aliases are preserved;
- rerunning installation is idempotent.

Uninstall checks use owned and foreign temporary links. Failure is removal of a
foreign path or preservation of an owned path. They prove that only exact links
to this checkout among `remote-agent`, `copilot-agent`, `claude-agent`,
`codex-agent`, `ca`, `cc`, and `co` are removed and that `--commands-only`
leaves every non-command artifact untouched.

The live acceptance flow invokes each canonical command and matching alias
through a real PTY against the same fake backend harness, then confirms the
observable tmux target and CLI command. It also invokes each help path from the
installed candidate links. A passing harness exit without those observed
values is not acceptance evidence.

## Definition of Done

- `remote-agent copilot <name>`, `remote-agent claude <name>`, and
  `remote-agent codex <name>` launch or reattach to the correct named session.
- Omitting `<name>` prints usage and exits 2.
- The three long aliases behave identically.
- The installer no longer installs `ca`, `cc`, or `co` and safely removes only
  retired aliases it owns.
- Codex is a first-class named-session backend.
- Configuration, README examples, installer output, and uninstaller output use
  the new command contract.
- Deterministic tests and the PTY acceptance flow pass.
