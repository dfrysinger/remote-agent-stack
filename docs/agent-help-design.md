# Cross-CLI agent help design

## Objective

Let a local Copilot CLI, Claude Code, or Codex CLI agent send one bounded
iMessage when it needs the Mac owner's login, permission, decision, or other
human action. Temporarily expose macOS Screen Sharing over Tailscale and include
a clickable Screens URL derived from the machine's actual Tailscale hostname
and configured port.

## Non-goals

- Reading Messages, accepting replies, or remotely executing message content.
- Sending URLs, credentials, repository content, raw errors, or personal data
  supplied by an agent.
- Keeping Screen Sharing enabled permanently.
- Replacing the CLIs' own authentication or permission systems.
- Overwriting an unrelated MCP server or instruction block with the same name.
- Adding Codex as a named-session backend to `bin/agent`.

## Reuse contract

- Keep one shared MCP implementation under
  `${XDG_CONFIG_HOME:-$HOME/.config}/remote-agent-stack/agent-help/`.
- Use each CLI's supported user-level MCP command instead of hand-editing its
  private configuration format.
- Reuse the existing `ss` command for Tailscale forwarding and lease handling.
- Preserve existing global instruction files by replacing only a marked
  `remote-agent-stack` block.
- Keep privileged operations in the installer's existing single-sudo phase.

## Installation and configuration flow

1. The installer detects `copilot`, `claude`, and `codex`.
2. Interactive installs ask which detected CLIs should receive agent help.
   `--agent-help-clis` provides an explicit comma-separated noninteractive
   selection; `none` disables the feature. The selection is the complete
   desired managed set: rerunning with a reduced set removes owned entries and
   instruction blocks from deselected CLIs. An explicitly selected unavailable
   CLI is an error.
3. A selected install requires an iMessage recipient. It is read from the
   existing private config, an explicit installer option, or a no-echo
   interactive prompt. The installer never prints it.
4. The MCP source and locked dependencies are copied to the neutral config
   directory and installed with private directory and file permissions.
   During the privileged migration, the installer also removes the exact
   legacy `/tmp/ss-lease.pid` and `/tmp/ss-auto-off.log` artifacts. It kills a
   PID from the old file only when the current process command matches the
   legacy `sleep ... ss off` lease shape, avoiding PID-reuse termination.
5. The installer configures an `agent-help` user MCP entry through each
   selected CLI. Scope is explicit: Copilot's user source, Claude's `user`
   scope, and Codex's global user configuration. Before adding or removing an
   entry, it inspects that exact scope and verifies that an existing entry is
   either absent or points at the managed server path. Workspace, project,
   plugin, and built-in entries do not establish ownership. A narrow migration
   recognizes the previous private Copilot path
   `~/.copilot/mcp-servers/agent-help/server.mjs`.
6. The installer adds an equivalent managed instruction block to:
   - Copilot CLI: `~/.copilot/copilot-instructions.md`
   - Claude Code: `~/.claude/CLAUDE.md`
   - Codex CLI: `~/.codex/AGENTS.md`
7. Managed instruction editing requires either no markers or exactly one
   balanced, correctly ordered marker pair. Malformed or duplicate markers
   fail without modifying the file. Writes use a same-directory temporary file
   and atomic rename.
8. Uninstall removes only MCP entries that still point at the managed or
   recognized legacy server and only balanced marked instruction blocks.
   Private recipient/state files are kept unless `--purge` is supplied.

## Screen Sharing privilege boundary

The user-facing `ss` script owns:

- validating the requested lease duration and configured port;
- deriving the current Tailscale DNS hostname and Screens URL;
- reporting status.

The root-owned `/usr/local/libexec/ss-on-demand` helper accepts `on` with one
integer duration from one through eight, `off`, and an internal `expire`
operation. A generated `/etc/sudoers.d/ss-on-demand` rule grants the installing
user passwordless access only to the eight exact `on N` commands and exact
`off`; it does not authorize `expire`. The helper reads a root-owned config
containing the installing user, Tailscale binary, and port. Its `on` operation
performs one fail-closed transaction:

1. atomically read the current root-owned expiry and report whether a managed
   lease was already active;
2. reject an existing Tailscale TCP handler on that port unless it already
   forwards to `localhost:5900`;
3. deactivate Remote Management and bootstrap Screen Sharing;
4. establish and verify the exact Tailscale TCP forward;
5. atomically persist a root-owned absolute expiry timestamp.

Any failure rolls back the mapping and disables Screen Sharing when no prior
managed lease was active. `off` removes the mapping, disables Screen Sharing,
and clears the expiry. `expire` atomically reads the deadline and is a no-op
before it; at or after the deadline it performs the same teardown as `off`.
The helper cannot run arbitrary user-supplied commands.

A root-owned LaunchDaemon invokes `expire` at startup and every 60 seconds.
This makes the absolute deadline survive helper-process failure, logout,
sleep, reboot, and auto-update. A missed interval is enforced at the next
wake/start. Uninstall invokes `off` and verifies teardown before removing the
LaunchDaemon, helper, sudoers rule, or PATH symlink.

The helper, config, LaunchDaemon, state directory, and all path ancestors from
`/usr/local/libexec` downward are root-owned and not group/other-writable. The
installer refuses foreign files at managed paths, stages the sudoers rule,
validates it with `visudo -c -f`, then installs it as root:wheel mode `0440`.
Callers use `sudo -n` so a missing rule cannot hang. The helper never executes
Homebrew code as root: it invokes the fixed root-owned `/usr/bin/sudo` with
`-u <installing-user>` before executing the configured Tailscale CLI, so a
user-owned Homebrew binary remains confined to that user.

The configured Tailscale serve port defaults to `15900`, must be in
`1..65535`, and is stamped into both root and user configuration by the
installer. Changing it through a rerun first tears down the prior owned
mapping. The Screens URL is calculated at request time from the short hostname
(the first label of `Self.DNSName`) in `tailscale status --json`; no hostname is
hard-coded and no local hostname substitutes for a missing Tailscale identity.
A missing or invalid Tailscale DNS name omits remote-access advertising.

## MCP behavior and failure model

- The only tool is `request_help`.
- Inputs are a fixed reason enum and an optional 80-character context label.
  The agent identity comes only from the NATO-alphabet tmux session name and
  cannot be supplied by the caller. The free-text context uses a strict ASCII
  label allowlist and reject URL schemes, domain-shaped tokens, control
  characters, and common credential prefixes. This materially limits the
  channel but cannot prove semantic absence of every possible secret; the
  managed instructions remain part of that policy.
- The current tmux session must resolve to a NATO agent name. The known
  `claude-` backend prefix is removed before the name is reported. Missing,
  invalid, or non-NATO sessions are rejected before any side effect.
- Identical messages deduplicate for ten minutes; at most three sends are
  reserved per hour. All MCP processes share an exclusive lock covering
  the complete reservation, presence check, enablement, send, and compensation
  transaction. State writes are atomic. Corrupt state fails closed. A failed
  send consumes its reservation to prevent retry storms.
- Every accepted request opens a bounded Screen Sharing lease so the message
  always includes an actionable Screens link.
- Deduplicated or rate-limited requests perform neither message nor
  Screen Sharing side effects.
- Screen Sharing enablement or URL-validation failure prevents the message from
  being sent and consumes the reservation so repeated helper failures remain
  rate-limited. If Messages rejects a message after access was enabled, the
  server invokes `ss off` only when this request created the lease. If a prior
  managed/manual lease was already active, it leaves that lease to its
  root-enforced deadline.
- Every external command has a bounded timeout. Enablement and Messages
  timeouts are reported as failed tool calls.
- Messages are sent through a fixed two-argument AppleScript. Agents cannot
  select the recipient, transport, command, or remote-access URL.
- A successful result means the local Messages app accepted the send. It does
  not claim delivery or that the owner read it.

## Hard invariants

1. Recipient configuration and send state are mode `0600`; their directory is
   mode `0700`.
2. The agent cannot provide a URL, recipient, shell command, or arbitrary
   message body.
3. Agent identity is derived from the tmux session and cannot be overridden.
4. Every helper-enabled Screen Sharing session has a root-enforced absolute
   lease of one to eight hours; direct invocation cannot bypass the deadline.
5. Passwordless sudo permits only the exact root helper `on` and `off`
   invocations.
6. Installer reruns are idempotent and preserve unrelated CLI configuration
   and instruction text.
7. Uninstall never removes a foreign same-name MCP entry or unmarked
   instructions.
8. The Screens hostname and port match the current Tailscale machine identity
   and configured serve port.
9. The managed Tailscale mapping exists only for the active lease and is
   removed on off, expiry, rollback, port change, and uninstall.

## Deterministic checks

- Core tests cover input sanitization including scheme-less domains and common
  credential prefixes, message construction, dynamic Screens URLs, private
  configuration, corrupt-state failure, deduplication, concurrent rate limits,
  and send-failure semantics.
- Server tests use injected command runners to prove the tmux identity cannot
  be replaced by caller input, remote access is advertised only after `ss on`
  succeeds, a failed send tears down only a newly created lease, and a daemon
  tick before the expiry leaves the lease active.
- Shell tests exercise CLI-list parsing and desired-set transitions, malformed
  managed-block refusal, ownership/scope recognition including legacy
  migration, legacy `/tmp` cleanup with PID-reuse refusal, port
  validation/change cleanup, helper rollback, expiry/no-op ticks after process
  loss/reboot simulation, active-lease uninstall, privilege drop before the
  Homebrew Tailscale binary, path ownership, and generated sudoers
  validation/content in temporary directories.
- An isolated `HOME` proof configures and removes the MCP through all three
  installed CLIs without touching the operator's real configuration.
- A real stdio handshake lists `request_help` from the installed shared server.

## Rollback

`uninstall.sh` first disables Screen Sharing, removes the owned Tailscale
mapping, clears the expiry, and verifies teardown. It then removes owned CLI
MCP entries, managed instruction blocks, the expiry LaunchDaemon, root helper,
sudoers rule, and PATH symlinks. Without `--purge`, it leaves the private
recipient and rate-limit state so a reinstall restores behavior. `--purge`
removes the complete XDG-aware `remote-agent-stack` config directory and exits
successfully.

## Definition of Done

- All three installed CLIs can be selected interactively or explicitly.
- Each selected CLI exposes `request_help` and receives durable usage
  instructions without losing existing content.
- Away-mode messages use the actual Tailscale hostname and configured port.
- The least-privilege Screen Sharing helper and bounded lease are installed.
- Rerun and uninstall behavior are proven in isolated configuration homes.
- Focused tests and a real MCP handshake pass.
- Independent review has no unresolved material finding.
