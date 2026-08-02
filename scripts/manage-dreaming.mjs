#!/usr/bin/env node

import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const SOURCE_REPO = "dfrysinger/dreaming";

function defaultStatePath(home = homedir()) {
  return join(
    process.env.XDG_STATE_HOME ?? join(home, ".local", "state"),
    "remote-agent-stack",
    "dreaming.json",
  );
}

function emptyState() {
  return {
    version: 1,
    runtimeOwned: false,
    pending: null,
    repoPath: null,
  };
}

export function readState(path = defaultStatePath()) {
  if (!existsSync(path)) return emptyState();
  const state = JSON.parse(readFileSync(path, "utf8"));
  if (
    state?.version !== 1 ||
    typeof state.runtimeOwned !== "boolean" ||
    !["install", "uninstall", null].includes(state.pending) ||
    ![null, "string"].includes(state.repoPath === null ? null : typeof state.repoPath)
  ) {
    throw new Error(`invalid Dreaming state at ${path}`);
  }
  return state;
}

export function writeState(path, state) {
  if (!state.runtimeOwned && !state.pending) {
    rmSync(path, { force: true });
    return;
  }
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

function runDefault(command, args, { allowFailure = false, env } = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: env ?? process.env,
    timeout: 600_000,
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

function commandAvailable(command, run) {
  const result = run(command, ["--version"], { allowFailure: true });
  return !result.error && result.status === 0;
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

function output(result) {
  return String(result.stdout ?? "").trim();
}

function validateCheckout(repoPath, run) {
  if (!existsSync(join(repoPath, ".git"))) {
    throw new Error(`${repoPath} exists but is not a Git checkout`);
  }
  const remote = output(run("git", ["-C", repoPath, "remote", "get-url", "origin"]));
  if (!expectedGitSource(remote)) {
    throw new Error(`${repoPath} has a foreign origin: ${remote || "(missing)"}`);
  }
  if (output(run("git", ["-C", repoPath, "status", "--porcelain"]))) {
    throw new Error(`${repoPath} has local changes; refusing to update it`);
  }
  const branch = output(run("git", ["-C", repoPath, "branch", "--show-current"]));
  if (branch !== "main") {
    throw new Error(`${repoPath} is on ${branch || "a detached HEAD"}, not main`);
  }
  const lifecycle = join(repoPath, "scripts", "install.sh");
  if (!existsSync(lifecycle)) {
    throw new Error(`${repoPath} is missing scripts/install.sh`);
  }
  return lifecycle;
}

function validateLocalSkillsRoot(home, run, { create }) {
  const root = join(home, ".copilot", "skills");
  if (!existsSync(root)) {
    if (!create) return;
    mkdirSync(root, { recursive: true, mode: 0o700 });
    run("git", ["init", root]);
  }
  if (!existsSync(join(root, ".git"))) {
    throw new Error(`${root} must be a Git repository`);
  }
  const remotes = output(run("git", ["-C", root, "remote"]));
  if (remotes) {
    throw new Error(`${root} must not have a Git remote`);
  }
}

function ensureCheckout(repoPath, run) {
  if (!existsSync(repoPath)) {
    mkdirSync(dirname(repoPath), { recursive: true });
    run("git", ["clone", `https://github.com/${SOURCE_REPO}.git`, repoPath]);
  }
  const lifecycle = validateCheckout(repoPath, run);
  run("git", ["-C", repoPath, "fetch", "origin", "main"]);
  run("git", ["-C", repoPath, "merge", "--ff-only", "origin/main"]);
  return lifecycle;
}

function runLifecycle(lifecycle, operation, repoPath, run) {
  run(lifecycle, [operation], {
    env: {
      ...process.env,
      DREAMING_REPO_ROOT: repoPath,
      DREAMING_SKIP_PLUGIN_SYNC: "1",
    },
  });
}

export function reconcileDreaming({
  enabled,
  explicit = false,
  home = homedir(),
  repoPath = join(home, "code", "dreaming"),
  statePath = defaultStatePath(home),
  run = runDefault,
  persist = writeState,
  checkOnly = false,
  warn = (message) => process.stderr.write(`warning: ${message}\n`),
}) {
  const state = readState(statePath);
  const managed = Boolean(state.runtimeOwned || state.pending);
  const selectedRepoPath = state.repoPath ?? repoPath;

  if (!enabled) {
    if (!managed) return { residual: false, state };
    let lifecycle;
    try {
      lifecycle = validateCheckout(selectedRepoPath, run);
    } catch (error) {
      if (checkOnly) throw error;
      warn(`Dreaming removal is blocked: ${error.message}`);
      return { residual: true, state };
    }
    if (checkOnly) return { residual: false, state };

    state.pending = "uninstall";
    state.repoPath = selectedRepoPath;
    persist(statePath, state);
    runLifecycle(lifecycle, "uninstall", selectedRepoPath, run);
    state.runtimeOwned = false;
    state.pending = null;
    state.repoPath = null;
    persist(statePath, state);
    return { residual: false, state };
  }

  if (!commandAvailable("copilot", run)) {
    if (explicit) throw new Error("copilot was explicitly selected for Dreaming but is not installed");
    warn("copilot is unavailable; keeping the saved Dreaming selection");
    return { residual: managed, state };
  }
  if (!commandAvailable("git", run)) {
    throw new Error("git is required to install Dreaming");
  }

  validateLocalSkillsRoot(home, run, { create: !checkOnly });
  if (existsSync(repoPath)) validateCheckout(repoPath, run);
  if (checkOnly) return { residual: false, state };

  const lifecycle = ensureCheckout(repoPath, run);
  state.pending = "install";
  state.repoPath = repoPath;
  persist(statePath, state);
  runLifecycle(lifecycle, "install", repoPath, run);
  runLifecycle(lifecycle, "selftest", repoPath, run);
  runLifecycle(lifecycle, "enable", repoPath, run);
  state.runtimeOwned = true;
  state.pending = null;
  persist(statePath, state);
  return { residual: false, state };
}

function parseBoolean(value, label) {
  if (value === "true") return true;
  if (value === "false") return false;
  throw new Error(`${label} must be true or false`);
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
  if (!["check", "reconcile"].includes(args.mode)) {
    throw new Error("--mode must be check or reconcile");
  }
  const result = reconcileDreaming({
    enabled: parseBoolean(args.enabled ?? "false", "--enabled"),
    explicit: parseBoolean(args.explicit ?? "false", "--explicit"),
    repoPath: args.repo || join(homedir(), "code", "dreaming"),
    statePath: args.state || defaultStatePath(),
    checkOnly: args.mode === "check",
  });
  if (result.residual && args["fail-on-residual"] === "true") {
    process.stderr.write("owned Dreaming runtime could not be reconciled\n");
    process.exitCode = 1;
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
