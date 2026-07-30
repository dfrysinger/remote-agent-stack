# Cross-CLI skills plugin installation

## Objective

Make `remote-agent-stack/install.sh` install the curated
[`dfrysinger/skills`](https://github.com/dfrysinger/skills) collection for
GitHub Copilot CLI, Claude Code, and Codex CLI through each product's supported
user-scoped plugin mechanism.

The installer must be safe to rerun, update installations it created, preserve
pre-existing installations, and remove only artifacts it owns.

## Non-goals

- Installing or managing the private mutable `~/.copilot/skills/` root.
- Installing the optional autonomous skill-review LaunchAgents.
- Translating or rewriting individual skills per CLI.
- Publishing to a public marketplace or universal plugin directory.
- Managing project-scoped or repository-scoped plugin configuration.
- Removing plugins or marketplaces that predate `remote-agent-stack`.

## Source and compatibility contract

`dfrysinger/skills` remains the source of truth. Its existing
`.claude-plugin/plugin.json` explicitly lists the curated skill directories for
Copilot and Claude.

The repository adds:

- `.claude-plugin/marketplace.json` so Claude can register
  `dfrysinger/skills` as a user marketplace and install
  `dfrysinger-skills@dfrysinger-skills`.
- `.codex-plugin/plugin.json` so Codex recognizes the repository root as a
  plugin and loads `./skills/`.
- `.agents/plugins/marketplace.json` so Codex can register the same repository
  as a marketplace and install the same plugin identity.

The plugin name and version must match across the Claude and Codex plugin
manifests. Marketplace entries refer to the repository root and use the same
stable plugin identity.

## CLI-specific installation

| CLI | Supported user-scoped flow |
| --- | --- |
| Copilot CLI | `copilot plugin install dfrysinger/skills`, then `copilot plugin update dfrysinger-skills` on owned reruns |
| Claude Code | use `--scope user` on marketplace add/remove and plugin install/update/uninstall; marketplace update has no scope option and refreshes the registered snapshot; install once, then refresh the marketplace and update the plugin on owned reruns |
| Codex CLI | add or upgrade the marketplace snapshot, install once, then remove and re-add the owned plugin after an owned marketplace upgrade |

The installer exposes `--skills-clis copilot,claude,codex|none`. When no saved
selection or explicit flag exists, an interactive run defaults to all detected
CLIs. A noninteractive run defaults to all detected CLIs. A CLI explicitly
selected by the current command line but unavailable or lacking plugin support
is a hard preflight failure. A CLI present only in a saved selection but no
longer installed, or whose installed version lacks plugin inventory support, is
warned and skipped without blocking unrelated installation work; its ownership
state is retained.

The saved desired set is independent from `AGENT_HELP_CLIS`; a user can install
the skills without configuring the private help MCP, or vice versa.

## Ownership and state

`scripts/manage-skills-plugin.mjs` owns reconciliation. It stores a private
versioned ledger at:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/remote-agent-stack/skills-plugin.json
```

The ledger is state, not configuration, so `uninstall.sh --purge` does not
delete unresolved ownership or pending recovery records.

For each CLI, the ledger records:

- whether the plugin was installed by `remote-agent-stack`;
- whether a marketplace registration was added by `remote-agent-stack`;
- the plugin and marketplace identities.
- any pending add, update, or remove mutation.

Before the first mutation, the reconciler inspects the CLI's installed plugin
and marketplace lists:

- A pre-existing plugin is usable but not owned. It is preserved on deselect
  and uninstall.
- A pre-existing marketplace is reused but not owned. It is preserved on
  deselect and uninstall.
- An artifact created successfully by the reconciler is recorded as owned only
  after the corresponding command succeeds.
- A same-name Claude or Codex marketplace is reused only when its normalized
  source is exactly `dfrysinger/skills`. A same-name marketplace pointing to a
  fork, local path, different repository, or pinned foreign ref is a hard
  collision when that CLI is selected for install or update. During deselect
  or uninstall it is foreign: warn, preserve it, and continue.
- Copilot's text inventory does not expose source metadata. A pre-existing
  `dfrysinger-skills` installation is accepted only when its direct-install
  cache path and manifest match the expected `dfrysinger/skills` identity; it
  remains foreign and is preserved.
- A same-name Copilot plugin whose direct-install cache path or manifest does
  not match `dfrysinger/skills` is a hard collision when Copilot is selected.
  Reconciliation fails before update or install. During deselect or uninstall,
  the mismatched plugin is foreign: warn, leave it untouched, and continue
  unrelated cleanup.

Owned selected installations are updated on rerun. Claude refreshes its
marketplace before plugin update. Codex upgrades its marketplace snapshot and
reinstalls the owned plugin because its CLI has no separate plugin-update
command. Deselecting a CLI removes the owned plugin first, then its owned
marketplace. Foreign artifacts remain.

Each external mutation is journaled as pending in an atomic mode-`0600` state
write before the CLI command runs. After success, another atomic write
finalizes ownership. If the command succeeds but final persistence fails, the
pending record survives. Recovery is deliberately conservative:

- pending remove plus an absent artifact finalizes removal;
- pending update retains the prior ownership state;
- pending add plus an absent artifact retries;
- pending add plus a present artifact is ownership-ambiguous and is preserved
  as foreign rather than claimed, even when the installer probably created it.

This can leave a rare interrupted install unmanaged, but it never authorizes
the future removal of a plugin the user may have installed manually after the
failed command. If an owned artifact was removed manually, reconciliation
clears the stale ownership entry instead of failing its removal.

During deselection or full uninstall, an unavailable CLI leaves its owned
ledger entry intact and emits a residual-artifact warning, but does not block
cleanup for available CLIs or unrelated `remote-agent-stack` artifacts.
Removal failures from an available CLI are handled the same way: retain the
pending/owned state, collect the error, continue reconciling every other CLI
and unrelated stack component, then report an aggregate nonzero result after
cleanup completes.

## Failure model

- **Repository or network unavailable:** the affected CLI command fails;
  ownership is not claimed, and rerunning retries.
- **CLI not installed or plugin inventory unsupported:** explicit selection
  fails before mutation. Saved or deselected state is preserved and warned
  without blocking unrelated installation work. An owned installation cannot
  be removed until a plugin-capable CLI is restored.
- **Manifest incompatibility:** isolated real-CLI validation must reject the
  change before landing.
- **Partial multi-CLI success:** successful earlier CLIs remain correctly
  recorded; the installer exits nonzero and a rerun continues reconciliation.
- **Mutation succeeds, final state write fails:** the prewritten pending record
  remains. Remove and update operations recover without losing prior ownership.
  An ambiguous present result after add is preserved as foreign, favoring
  non-destruction over ownership recovery.
- **User-installed plugin:** it is detected as foreign and never removed.
- **Same-name foreign marketplace:** reconciliation fails before installing a
  plugin from an untrusted source. Deselect and uninstall preserve it and
  continue.
- **Same-name foreign Copilot plugin:** reconciliation fails before any plugin
  install or update when Copilot is selected. Deselect and uninstall preserve
  it and continue.
- **Owned artifact removed outside the installer:** the stale ledger entry is
  cleared without issuing a second destructive command.
- **CLI output changes:** strict JSON parsing is used where available. Copilot's
  text-only list is parsed narrowly by exact plugin name and covered by tests.

## Deterministic check contract

1. **Manifest consistency**
   - Setup: read both plugin manifests and both marketplace catalogs.
   - Pass: names, versions, source roots, and listed skill roots agree.
   - Failure proves: one CLI would install a different package identity or
     version.

2. **Owned lifecycle**
   - Setup: fake all three CLIs with empty inventories.
   - Transition: all selected, rerun all, select Copilot only, then none.
   - Pass: each install occurs once, Claude and Codex marketplace refreshes
     precede owned updates, deselection removes only owned artifacts, and the
     final ledger is empty.
   - Failure proves: reconciliation is not idempotent or symmetric.

3. **Foreign preservation**
   - Setup: inventories already contain the plugin and marketplaces.
   - Transition: select all, then none.
   - Pass: no install, update, plugin removal, or marketplace removal command
     mutates the pre-existing artifacts.
   - Failure proves: uninstall can destroy user-managed configuration.
   - The Claude fixture also seeds project- and local-scope declarations with
     the same marketplace name and proves user-scope removal leaves them
     untouched.

4. **Failure accounting**
   - Setup: make one install command fail; separately make the final state
     persistence fail after a successful fake CLI mutation.
   - Pass: command failure does not claim ownership; persistence failure leaves
     a pending record; pending remove and update recover safely; ambiguous
     pending add plus present inventory is preserved as foreign.
   - Failure proves: the ledger can become success-shaped or lose ownership
     after a partial transaction.

5. **Collision and external-removal handling**
   - Setup: expose a same-name marketplace with a different source, expose a
     same-name Copilot plugin with a mismatched direct-install path, and
     separately seed owned ledger entries whose live artifacts are absent.
   - Pass: both collisions fail without mutation when selected, while deselect
     and uninstall preserve them and continue; absent owned artifacts clear
     cleanly.
   - Failure proves: the installer can consume an impersonating marketplace or
     make manual cleanup unrecoverable.

6. **Unavailable-CLI uninstall**
   - Setup: seed one unavailable owned CLI and one available owned CLI.
   - Pass: the available installation is removed, the unavailable entry remains
     recorded and warned, and reconciliation reports residual ownership without
     preventing broader uninstall.
   - Failure proves: removing one CLI can wedge all stack cleanup.
   - A second case reruns install with a saved selection containing the
     unavailable CLI and proves unrelated installation continues.
   - A third case exposes a same-name foreign Copilot plugin during full
     uninstall and proves it is preserved without blocking broader cleanup.
   - A fourth case makes one available CLI removal fail and proves every other
     CLI plus unrelated stack cleanup still runs before an aggregate failure is
     reported.

7. **Real isolated host compatibility**
   - Setup: temporary HOME/config roots and the local `dfrysinger/skills`
     checkout.
   - Transition: Claude and Codex add the local marketplace, install the
     plugin, list it, remove it, and remove the marketplace.
   - Pass: both CLIs expose the expected plugin identity without touching the
     user's real configuration.
   - Failure proves: the published manifests do not match a supported host
     format.
   - The isolated Claude fixture includes user, project, and local marketplace
     declarations with the same name and proves user-scope cleanup preserves
     the other scopes.

8. **Copilot compatibility**
   - Setup: an isolated HOME and Copilot configuration root.
   - Transition: install `dfrysinger/skills`, list it, update it, and uninstall
     it without touching the user's real plugin installation.
   - Pass: the isolated inventory reports `dfrysinger-skills` for the complete
     lifecycle.
   - Failure proves: the installer uses an unsupported Copilot plugin identity
     or command.

## Rollback

`uninstall.sh` invokes the reconciler with an empty desired set and
best-effort-unavailable mode. Only ledger-owned plugins and marketplaces are
removed. The ledger is removed when no owned or pending entries remain. If an
owned CLI is no longer installed, the uninstaller reports the residual plugin
state and continues removing unrelated stack components. The source
`dfrysinger/skills` repository and all pre-existing CLI configuration are
untouched.

The `dfrysinger/skills` compatibility-manifest change must merge and be
published on its default branch before the `remote-agent-stack` installer can
merge. After that merge, the release gate repeats the isolated Claude and Codex
lifecycle using remote source `dfrysinger/skills`, not the local checkout.
This proves the exact production fetch path.

If a release must be reverted, revert the `remote-agent-stack` installer
changes first. The compatibility manifests in `dfrysinger/skills` are additive
and can remain without changing existing Copilot behavior.

## Definition of done

- All three CLIs install the same curated skill collection through supported
  user-scoped plugin mechanisms.
- Explicit and interactive desired-set selection works.
- Reruns update owned installations without duplicating them.
- Deselect and uninstall remove only owned artifacts.
- Manifest consistency, fake lifecycle, foreign preservation, failure
  accounting, collision handling, unavailable-CLI cleanup, and real isolated
  three-CLI lifecycle checks pass.
- The final Claude and Codex lifecycle resolves remote source
  `dfrysinger/skills` after the skills manifests are published.
- Documentation explains install, update, selection, and ownership behavior.
