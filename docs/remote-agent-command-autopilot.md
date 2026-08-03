# Remote Agent Command Autopilot Charter

Keep building against the reviewed plan at
`docs/remote-agent-command-design.md` in
`/Users/dfrysinger/code/remote-agent-stack`. Follow the required process
skills below. Use rubber-duck to brainstorm solutions and align on paths
forward whenever you get stuck. Keep the design's implementation baton current
so a future agent can pick it up. Use subagents when independent work genuinely
benefits from a separate context. Do not push; keep working locally for this
run. Decide every reversible question yourself with rubber-duck rather than
asking the user. Stay on this course until the objective's Definition of Done
(the "Definition of Done" section in `docs/remote-agent-command-design.md`) is
met.

## Required process skills

- **Governing:** `/dfrysinger-skills:development-loop` - owns the run's phase
  order, live-proof gate, review, validation, and completion process. Invoke it
  at run start and after compaction when it is no longer active.
- **Execution:** `/deep:tuistory` for real PTY acceptance and
  `/dfrysinger-skills:dual-review` for implementation review. Invoke each only
  when the governing workflow reaches the phase it owns.
- **Context:** `/dfrysinger-skills:self-compact` - at the governing workflow's
  compaction points, or when context becomes noisy or repetitive, persist the
  complete baton and invoke and follow this skill as the final action. Do not
  compact merely because the hourly reminder fired or while active live proof
  is in progress.

## Objective

Achieve the Definition of Done in `docs/remote-agent-command-design.md`, the
"Definition of Done" section: ship the collision-safe `remote-agent` command,
three descriptive backend aliases, Codex support, ownership-safe
installation/removal, documentation, deterministic tests, and real PTY
acceptance. Keep working through the plan; finish only once every item in the
"Definition of Done" section is verifiably met.
