#!/usr/bin/env node

import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const PLUGIN_NAME = "dfrysinger-skills";
export const MARKETPLACE_NAME = "dfrysinger-skills";
export const SOURCE_REPO = "dfrysinger/skills";

function defaultStatePath(home = homedir()) {
  return join(
    process.env.XDG_STATE_HOME ?? join(home, ".local", "state"),
    "remote-agent-stack",
    "skills-plugin.json",
  );
}

function emptyCliState() {
  return {
    pluginOwned: false,
    marketplaceOwned: false,
    pending: null,
  };
}

function emptyState() {
  return { version: 1, clis: {} };
}

export function readState(path = defaultStatePath()) {
  if (!existsSync(path)) return emptyState();
  const state = JSON.parse(readFileSync(path, "utf8"));
  if (state?.version !== 1 || typeof state.clis !== "object" || !state.clis) {
    throw new Error(`invalid skills plugin state at ${path}`);
  }
  for (const cli of Object.keys(state.clis)) {
    if (!["copilot", "claude", "codex"].includes(cli)) {
      throw new Error(`invalid CLI in skills plugin state: ${cli}`);
    }
  }
  return state;
}

export function writeState(path, state) {
  const active = Object.fromEntries(
    Object.entries(state.clis).filter(([, entry]) =>
      entry.pluginOwned || entry.marketplaceOwned || entry.pending
    ),
  );
  if (Object.keys(active).length === 0) {
    rmSync(path, { force: true });
    return;
  }
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(
    temporary,
    `${JSON.stringify({ version: 1, clis: active }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

function runDefault(command, args, { allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: process.env,
    timeout: 60_000,
  });
  if (result.error?.code === "ENOENT") {
    if (allowFailure) return result;
    throw new Error(`${command} is not installed`);
  }
  if (result.error?.code === "ETIMEDOUT") {
    if (allowFailure) return result;
    throw new Error(`${command} ${args.join(" ")} timed out`);
  }
  if (result.status !== 0 && !allowFailure) {
    throw new Error(
      `${command} ${args.join(" ")} failed: ${
        result.stderr?.trim() || result.stdout?.trim() || `exit ${result.status}`
      }`,
    );
  }
  return result;
}

function commandAvailable(cli, run) {
  const result = run(cli, ["--version"], { allowFailure: true });
  return !result.error && result.status === 0;
}

function hasManagedState(entry) {
  return Boolean(entry.pluginOwned || entry.marketplaceOwned || entry.pending);
}

export function parseCliList(value) {
  if (!value || value === "none") return [];
  const result = [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
  for (const cli of result) {
    if (!["copilot", "claude", "codex"].includes(cli)) {
      throw new Error(`unsupported skills CLI: ${cli}`);
    }
  }
  return result;
}

function parseJson(result, label) {
  try {
    return JSON.parse(result.stdout);
  } catch {
    throw new Error(`${label} returned invalid JSON`);
  }
}

function normalizeGitSource(value) {
  return String(value ?? "")
    .trim()
    .replace(/^git@github\.com:/, "https://github.com/")
    .replace(/^github:/, "https://github.com/")
    .replace(/\.git$/, "")
    .replace(/\/$/, "")
    .toLowerCase();
}

function expectedGitSource(value) {
  const normalized = normalizeGitSource(value);
  return (
    normalized === SOURCE_REPO ||
    normalized === `https://github.com/${SOURCE_REPO}`
  );
}

function copilotPlugin(home, run) {
  const result = run("copilot", ["plugin", "list"]);
  const present = new RegExp(
    `^\\s*•\\s+${PLUGIN_NAME.replaceAll("-", "\\-")}\\s+\\(v[^)]+\\)\\s*$`,
    "m",
  ).test(result.stdout);
  if (!present) return null;
  const root = process.env.COPILOT_HOME ?? join(home, ".copilot");
  const expected = join(
    root,
    "installed-plugins",
    "_direct",
    "dfrysinger--skills",
    ".claude-plugin",
    "plugin.json",
  );
  if (existsSync(expected)) {
    const manifest = JSON.parse(readFileSync(expected, "utf8"));
    if (manifest?.name === PLUGIN_NAME) return { exactSource: true };
  }
  const directRoot = join(root, "installed-plugins", "_direct");
  if (existsSync(directRoot)) {
    for (const directory of readdirSync(directRoot)) {
      const manifestPath = join(directRoot, directory, ".claude-plugin", "plugin.json");
      if (!existsSync(manifestPath)) continue;
      try {
        if (JSON.parse(readFileSync(manifestPath, "utf8"))?.name === PLUGIN_NAME) {
          return { exactSource: false };
        }
      } catch {
        // A malformed same-name installation is foreign.
      }
    }
  }
  return { exactSource: false };
}

function claudeMarketplace(run) {
  const result = run("claude", ["plugin", "marketplace", "list", "--json"]);
  const entry = parseJson(result, "claude marketplace list").find(
    (item) => item?.name === MARKETPLACE_NAME,
  );
  if (!entry) return null;
  return {
    exactSource:
      entry.source === "github" &&
      expectedGitSource(entry.repo),
  };
}

function claudePlugin(run) {
  const result = run("claude", ["plugin", "list", "--json"]);
  const entries = parseJson(result, "claude plugin list");
  const entry = entries.find(
    (item) =>
      item?.id === `${PLUGIN_NAME}@${MARKETPLACE_NAME}` ||
      item?.pluginId === `${PLUGIN_NAME}@${MARKETPLACE_NAME}` ||
      (item?.name === PLUGIN_NAME && item?.marketplaceName === MARKETPLACE_NAME),
  );
  if (!entry) return null;
  return { exactSource: true };
}

function codexMarketplace(run) {
  const result = run("codex", ["plugin", "marketplace", "list", "--json"]);
  const entry = parseJson(result, "codex marketplace list").marketplaces?.find(
    (item) => item?.name === MARKETPLACE_NAME,
  );
  if (!entry) return null;
  const source = entry.marketplaceSource;
  return {
    exactSource:
      source?.sourceType === "git" &&
      expectedGitSource(source.source),
  };
}

function codexPlugin(run) {
  const result = run("codex", ["plugin", "list", "--json"]);
  const entry = parseJson(result, "codex plugin list").installed?.find(
    (item) => item?.pluginId === `${PLUGIN_NAME}@${MARKETPLACE_NAME}`,
  );
  if (!entry) return null;
  const source = entry.marketplaceSource;
  return {
    exactSource:
      source?.sourceType === "git" &&
      expectedGitSource(source.source),
  };
}

function inventory(cli, home, run) {
  if (cli === "copilot") {
    return { plugin: copilotPlugin(home, run), marketplace: null };
  }
  if (cli === "claude") {
    return {
      plugin: claudePlugin(run),
      marketplace: claudeMarketplace(run),
    };
  }
  return {
    plugin: codexPlugin(run),
    marketplace: codexMarketplace(run),
  };
}

function commandFor(cli, operation) {
  const pluginId = `${PLUGIN_NAME}@${MARKETPLACE_NAME}`;
  const commands = {
    copilot: {
      "plugin:add": ["copilot", ["plugin", "install", SOURCE_REPO]],
      "plugin:update": ["copilot", ["plugin", "update", PLUGIN_NAME]],
      "plugin:remove": ["copilot", ["plugin", "uninstall", PLUGIN_NAME]],
    },
    claude: {
      "marketplace:add": [
        "claude",
        ["plugin", "marketplace", "add", "--scope", "user", SOURCE_REPO],
      ],
      "marketplace:update": [
        "claude",
        ["plugin", "marketplace", "update", MARKETPLACE_NAME],
      ],
      "marketplace:remove": [
        "claude",
        ["plugin", "marketplace", "remove", "--scope", "user", MARKETPLACE_NAME],
      ],
      "plugin:add": [
        "claude",
        ["plugin", "install", "--scope", "user", pluginId],
      ],
      "plugin:update": [
        "claude",
        ["plugin", "update", "--scope", "user", pluginId],
      ],
      "plugin:remove": [
        "claude",
        ["plugin", "uninstall", "--scope", "user", pluginId],
      ],
    },
    codex: {
      "marketplace:add": [
        "codex",
        ["plugin", "marketplace", "add", SOURCE_REPO, "--json"],
      ],
      "marketplace:update": [
        "codex",
        ["plugin", "marketplace", "upgrade", MARKETPLACE_NAME, "--json"],
      ],
      "marketplace:remove": [
        "codex",
        ["plugin", "marketplace", "remove", MARKETPLACE_NAME, "--json"],
      ],
      "plugin:add": [
        "codex",
        ["plugin", "add", pluginId, "--json"],
      ],
      "plugin:remove": [
        "codex",
        ["plugin", "remove", pluginId, "--json"],
      ],
    },
  };
  return commands[cli]?.[operation] ?? null;
}

function persistEntry(state, cli, entry, statePath, persist) {
  state.clis[cli] = entry;
  persist(statePath, state);
}

function performMutation({
  cli,
  operation,
  entry,
  state,
  statePath,
  persist,
  run,
  finalize,
}) {
  entry.pending = { operation, startedAt: Date.now() };
  persistEntry(state, cli, entry, statePath, persist);
  const pendingEntry = structuredClone(entry);
  const command = commandFor(cli, operation);
  if (!command) throw new Error(`unsupported ${cli} operation: ${operation}`);
  run(command[0], command[1]);
  try {
    finalize();
    entry.pending = null;
    persistEntry(state, cli, entry, statePath, persist);
  } catch (error) {
    state.clis[cli] = pendingEntry;
    throw error;
  }
}

function recoverPending({ cli, entry, live, state, statePath, persist, warn }) {
  const operation = entry.pending?.operation;
  if (!operation) return;
  const [artifact, action] = operation.split(":");
  const present = Boolean(live[artifact]);
  if (action === "add") {
    if (present) {
      entry[`${artifact}Owned`] = false;
      entry.pending = null;
      warn(
        `${cli} ${artifact} add was interrupted and ownership is ambiguous; preserving it as user-managed`,
      );
      persistEntry(state, cli, entry, statePath, persist);
    } else {
      entry.pending = null;
      persistEntry(state, cli, entry, statePath, persist);
    }
    return;
  }
  if (action === "update") {
    entry.pending = null;
    persistEntry(state, cli, entry, statePath, persist);
    return;
  }
  if (action === "remove" && !present) {
    entry[`${artifact}Owned`] = false;
    entry.pending = null;
    persistEntry(state, cli, entry, statePath, persist);
    return;
  }
  if (action === "remove" && present && !live[artifact].exactSource) {
    entry[`${artifact}Owned`] = false;
    entry.pending = null;
    warn(
      `${cli} ${artifact} changed source during interrupted removal; preserving it as user-managed`,
    );
    persistEntry(state, cli, entry, statePath, persist);
  }
}

function assertSelectedIdentity(cli, live) {
  if (live.marketplace && !live.marketplace.exactSource) {
    throw new Error(
      `${cli} has a foreign marketplace named ${MARKETPLACE_NAME}; refusing to use it`,
    );
  }
  if (live.plugin && !live.plugin.exactSource) {
    throw new Error(
      `${cli} has a foreign plugin named ${PLUGIN_NAME}; refusing to overwrite it`,
    );
  }
}

function reconcileSelected({
  cli,
  entry,
  state,
  statePath,
  persist,
  run,
  home,
  warn,
}) {
  let live = inventory(cli, home, run);
  recoverPending({ cli, entry, live, state, statePath, persist, warn });
  live = inventory(cli, home, run);
  assertSelectedIdentity(cli, live);

  if (cli !== "copilot") {
    if (!live.marketplace) {
      performMutation({
        cli,
        operation: "marketplace:add",
        entry,
        state,
        statePath,
        persist,
        run,
        finalize: () => {
          entry.marketplaceOwned = true;
        },
      });
    } else if (entry.marketplaceOwned) {
      performMutation({
        cli,
        operation: "marketplace:update",
        entry,
        state,
        statePath,
        persist,
        run,
        finalize: () => {},
      });
    }
    live = inventory(cli, home, run);
    assertSelectedIdentity(cli, live);
  }

  if (!live.plugin) {
    performMutation({
      cli,
      operation: "plugin:add",
      entry,
      state,
      statePath,
      persist,
      run,
      finalize: () => {
        entry.pluginOwned = true;
      },
    });
    return;
  }
  if (!entry.pluginOwned) return;
  if (cli === "codex") {
    performMutation({
      cli,
      operation: "plugin:remove",
      entry,
      state,
      statePath,
      persist,
      run,
      finalize: () => {
        entry.pluginOwned = false;
      },
    });
    performMutation({
      cli,
      operation: "plugin:add",
      entry,
      state,
      statePath,
      persist,
      run,
      finalize: () => {
        entry.pluginOwned = true;
      },
    });
    return;
  }
  performMutation({
    cli,
    operation: "plugin:update",
    entry,
    state,
    statePath,
    persist,
    run,
    finalize: () => {},
  });
}

function reconcileDeselected({
  cli,
  entry,
  state,
  statePath,
  persist,
  run,
  home,
  warn,
}) {
  let live = inventory(cli, home, run);
  recoverPending({ cli, entry, live, state, statePath, persist, warn });
  live = inventory(cli, home, run);

  if (entry.pluginOwned && live.plugin && !live.plugin.exactSource) {
    entry.pluginOwned = false;
    warn(`${cli} plugin source changed; preserving it as user-managed`);
    persistEntry(state, cli, entry, statePath, persist);
  }
  if (entry.pluginOwned) {
    if (!live.plugin) {
      entry.pluginOwned = false;
      persistEntry(state, cli, entry, statePath, persist);
    } else {
      performMutation({
        cli,
        operation: "plugin:remove",
        entry,
        state,
        statePath,
        persist,
        run,
        finalize: () => {
          entry.pluginOwned = false;
        },
      });
    }
  }

  live = inventory(cli, home, run);
  if (
    entry.marketplaceOwned &&
    live.marketplace &&
    !live.marketplace.exactSource
  ) {
    entry.marketplaceOwned = false;
    warn(`${cli} marketplace source changed; preserving it as user-managed`);
    persistEntry(state, cli, entry, statePath, persist);
  }
  if (entry.marketplaceOwned) {
    if (live.plugin) {
      warn(
        `${cli} marketplace remains because a user-managed ${PLUGIN_NAME} plugin still depends on it`,
      );
      return;
    }
    if (!live.marketplace) {
      entry.marketplaceOwned = false;
      persistEntry(state, cli, entry, statePath, persist);
    } else {
      performMutation({
        cli,
        operation: "marketplace:remove",
        entry,
        state,
        statePath,
        persist,
        run,
        finalize: () => {
          entry.marketplaceOwned = false;
        },
      });
    }
  }
}

export function reconcile({
  selected,
  explicitSelected = [],
  home = homedir(),
  statePath = defaultStatePath(home),
  run = runDefault,
  persist = writeState,
  checkOnly = false,
  warn = (message) => process.stderr.write(`warning: ${message}\n`),
}) {
  const state = readState(statePath);
  const errors = [];
  const residual = [];
  const availability = Object.fromEntries(
    ["copilot", "claude", "codex"].map((cli) => [cli, commandAvailable(cli, run)]),
  );

  for (const cli of explicitSelected) {
    if (!availability[cli]) {
      throw new Error(`${cli} was explicitly selected for skills but is not installed`);
    }
  }

  for (const cli of ["copilot", "claude", "codex"]) {
    const enabled = selected.includes(cli);
    const entry = { ...emptyCliState(), ...(state.clis[cli] ?? {}) };
    const tracked = hasManagedState(entry);
    state.clis[cli] = entry;
    if (!availability[cli]) {
      if (enabled) {
        warn(`${cli} is no longer installed; keeping its saved skills selection`);
      }
      if (entry.pluginOwned || entry.marketplaceOwned || entry.pending) {
        residual.push(cli);
        warn(`${cli} is unavailable; owned skills artifacts could not be reconciled`);
      }
      continue;
    }
    if (!enabled && !tracked) continue;

    let live;
    try {
      live = inventory(cli, home, run);
    } catch (error) {
      if (enabled && explicitSelected.includes(cli)) {
        errors.push(`${cli}: ${error.message}`);
        warn(`${cli} skills reconciliation failed: ${error.message}`);
      } else {
        warn(`${cli} skills inventory is unavailable; preserving its current state`);
        if (tracked) residual.push(cli);
      }
      continue;
    }

    try {
      if (enabled) assertSelectedIdentity(cli, live);
      if (checkOnly) continue;
      if (enabled) {
        reconcileSelected({
          cli,
          entry,
          state,
          statePath,
          persist,
          run,
          home,
          warn,
        });
      } else {
        reconcileDeselected({
          cli,
          entry,
          state,
          statePath,
          persist,
          run,
          home,
          warn,
        });
      }
    } catch (error) {
      errors.push(`${cli}: ${error.message}`);
      warn(`${cli} skills reconciliation failed: ${error.message}`);
    }
  }

  if (!checkOnly) persist(statePath, state);
  return { errors, residual, state };
}

function main() {
  const args = {};
  for (let index = 2; index < process.argv.length; index += 2) {
    const key = process.argv[index];
    const value = process.argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error("expected --key value arguments");
    }
    args[key.slice(2)] = value;
  }
  const result = reconcile({
    selected: parseCliList(args.clis ?? ""),
    explicitSelected: parseCliList(args["explicit-clis"] ?? ""),
    statePath: args.state || defaultStatePath(),
    checkOnly: args.mode === "check",
  });
  if (result.errors.length > 0) {
    process.stderr.write(`${result.errors.join("\n")}\n`);
    process.exitCode = 1;
  }
  if (result.residual.length > 0) {
    process.stderr.write(
      `skills artifacts remain for unavailable CLIs: ${result.residual.join(",")}\n`,
    );
    if (args["fail-on-residual"] === "true") process.exitCode = 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
