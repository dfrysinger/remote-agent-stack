# Optional Dreaming installation

## Objective

Let `remote-agent-stack` install and operate
[`dfrysinger/dreaming`](https://github.com/dfrysinger/dreaming) as an optional,
Copilot-only headless service.

## Non-goals

- Installing Dreaming skills into interactive Copilot sessions.
- Reimplementing Dreaming dependency materialization, launchd jobs, self-test,
  enablement, rollback, or instruction ownership.
- Removing a Dreaming runtime that this installer has not adopted.
- Deleting the Dreaming source checkout during uninstall.

## Contract

`--dreaming` and `--no-dreaming` select a desired state independently of
`--skills-clis`. Interactive installs default to the existing saved choice, or
to enabled when a Dreaming launchd job is already present. Noninteractive
installs default to disabled unless a saved choice exists.

The source checkout defaults to `~/code/dreaming`. The installer clones it when
absent and otherwise updates only an exact, clean `dfrysinger/dreaming` checkout
on `main` using a fast-forward merge.

Installation delegates in order to:

1. `scripts/install.sh install`
2. `scripts/install.sh selftest`
3. `scripts/install.sh enable`

Every command receives `DREAMING_SKIP_PLUGIN_SYNC=1`. The service gets its own
repo and immutable shared dependency bundle through headless `--plugin-dir`
arguments; normal Copilot sessions do not gain the five Dreaming orchestration
skills.

The local `~/.copilot/skills` root is initialized as a no-remote Git repository
when absent. Existing non-Git or remote-backed roots are rejected.

## Ownership and failure model

`scripts/manage-dreaming.mjs` records only runtime ownership under
`${XDG_STATE_HOME:-~/.local/state}/remote-agent-stack/dreaming.json`.
Pre-existing runtimes remain untouched until the user explicitly or
interactively selects Dreaming and a complete install/self-test/enable sequence
succeeds.

The journal records an install before lifecycle mutation. A failed self-test
therefore cannot enable Dreaming. If a runtime existed before an attempted
adoption, failure or interruption invokes Dreaming's rollback path rather than
uninstalling that runtime. A newly created partial runtime remains journaled so
a later deselection can run Dreaming's own uninstall path. Uninstall removes
only a runtime recorded as owned and preserves the source checkout and Dreaming
recovery state.

Both current `com.<user>.dreaming.*` jobs and legacy
`com.<user>.skills.*` jobs count as a pre-existing runtime. A mixed state with
both self-test jobs fails before mutation because Dreaming's rollback contract
requires exactly one backed-up self-test job.

Missing Copilot is fatal for an explicit `--dreaming` selection. A saved
selection is retained with a warning so a temporarily unavailable CLI does not
silently erase intent.

## Definition of Done

- Selection is persisted and independent of shared-skills installation.
- Fresh install, safe update, failed self-test, deselection, and uninstall are
  deterministic tests.
- A live install uses the real Dreaming lifecycle and leaves no globally
  installed `dfrysinger-dreaming` plugin.
- A rerun and the repository uninstaller preserve ownership boundaries.
