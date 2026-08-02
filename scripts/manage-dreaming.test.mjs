import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  readState,
  reconcileDreaming,
} from "./manage-dreaming.mjs";

function fixture() {
  const home = mkdtempSync(join(tmpdir(), "dreaming-manager-"));
  const repoPath = join(home, "code", "dreaming");
  const statePath = join(home, ".local", "state", "remote-agent-stack", "dreaming.json");
  const model = {
    available: new Set(["copilot", "git"]),
    repoExists: false,
    remote: "https://github.com/dfrysinger/dreaming.git",
    branch: "main",
    dirty: false,
    head: "upstream",
    upstream: "upstream",
    localSkillsRemote: false,
    runtimePresent: false,
    lifecycleCalls: [],
    failLifecycle: null,
    calls: [],
  };

  function result(stdout = "") {
    return { status: 0, stdout, stderr: "", error: undefined };
  }

  function materializeRepo() {
    mkdirSync(join(repoPath, ".git"), { recursive: true });
    mkdirSync(join(repoPath, "scripts"), { recursive: true });
    writeFileSync(join(repoPath, "scripts", "install.sh"), "#!/bin/sh\n");
    model.repoExists = true;
  }

  function run(command, args, { allowFailure = false, env } = {}) {
    const signature = [command, ...args].join(" ");
    model.calls.push(signature);
    if (args[0] === "--version") {
      if (model.available.has(command)) return result(`${command} test\n`);
      return {
        status: null,
        stdout: "",
        stderr: "",
        error: Object.assign(new Error("missing"), { code: "ENOENT" }),
      };
    }
    if (command === "git" && args[0] === "init") {
      mkdirSync(join(args[1], ".git"), { recursive: true });
      return result();
    }
    if (command === "git" && args[0] === "clone") {
      materializeRepo();
      return result();
    }
    if (command === "git" && args.includes("get-url")) return result(`${model.remote}\n`);
    if (command === "git" && args.includes("--porcelain")) {
      return result(model.dirty ? " M README.md\n" : "");
    }
    if (command === "git" && args.includes("--show-current")) {
      return result(`${model.branch}\n`);
    }
    if (command === "git" && args.at(-1) === "HEAD") {
      return result(`${model.head}\n`);
    }
    if (command === "git" && args.at(-1) === "origin/main") {
      return result(`${model.upstream}\n`);
    }
    if (command === "git" && args.at(-1) === "remote") {
      return result(model.localSkillsRemote ? "origin\n" : "");
    }
    if (command.endsWith("/scripts/install.sh")) {
      const operation = args[0];
      model.lifecycleCalls.push({ operation, env });
      if (model.failLifecycle === operation) {
        if (allowFailure) return { status: 1, stdout: "", stderr: "injected failure" };
        throw new Error(`${operation} failed`);
      }
      if (operation === "install") model.runtimePresent = true;
      if (operation === "uninstall") model.runtimePresent = false;
      return result();
    }
    return result();
  }

  return {
    home,
    repoPath,
    statePath,
    model,
    run,
    materializeRepo,
  };
}

test("installs, self-tests, and enables without syncing the plugin", () => {
  const context = fixture();
  reconcileDreaming({ enabled: true, explicit: true, ...context });

  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["install", "selftest", "enable"],
  );
  assert.equal(
    context.model.lifecycleCalls.every(
      (call) =>
        call.env.DREAMING_SKIP_PLUGIN_SYNC === "1" &&
        call.env.DREAMING_REPO_ROOT === context.repoPath &&
        call.env.DREAMING_SELFTEST_WAIT_SECS === "900",
    ),
    true,
  );
  assert.equal(readState(context.statePath).runtimeOwned, true);
  assert.equal(existsSync(join(context.home, ".copilot", "skills", ".git")), true);
});

test("rerun updates an exact clean main checkout", () => {
  const context = fixture();
  context.materializeRepo();
  mkdirSync(join(context.home, ".copilot", "skills", ".git"), { recursive: true });

  reconcileDreaming({ enabled: true, ...context });
  assert.equal(
    context.model.calls.includes(`git -C ${context.repoPath} fetch origin main`),
    true,
  );
  assert.equal(
    context.model.calls.includes(`git -C ${context.repoPath} merge --ff-only origin/main`),
    true,
  );
});

test("failed self-test never enables and remains recoverable", () => {
  const context = fixture();
  context.model.failLifecycle = "selftest";

  assert.throws(() => reconcileDreaming({ enabled: true, ...context }), /selftest failed/);
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["install", "selftest"],
  );
  assert.equal(readState(context.statePath).pending, "install");

  context.model.failLifecycle = null;
  reconcileDreaming({ enabled: false, ...context });
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["install", "selftest", "uninstall"],
  );
  assert.equal(existsSync(context.statePath), false);
});

test("retry after a partial install rechecks runtime ownership", () => {
  const context = fixture();
  const inspectRuntime = () => ({
    present: context.model.runtimePresent,
    selftestCount: context.model.runtimePresent ? 1 : 0,
  });
  context.model.failLifecycle = "selftest";

  assert.throws(
    () =>
      reconcileDreaming({
        enabled: true,
        inspectRuntime,
        ...context,
      }),
    /selftest failed/,
  );
  assert.equal(readState(context.statePath).preexistingRuntime, false);

  assert.throws(
    () =>
      reconcileDreaming({
        enabled: true,
        inspectRuntime,
        ...context,
      }),
    /selftest failed/,
  );
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["install", "selftest", "uninstall", "install", "selftest"],
  );
  const state = readState(context.statePath);
  assert.equal(state.pending, "install");
  assert.equal(state.preexistingRuntime, false);
});

test("failed adoption restores a pre-existing runtime", () => {
  const context = fixture();
  context.model.failLifecycle = "selftest";

  assert.throws(
    () =>
      reconcileDreaming({
        enabled: true,
        inspectRuntime: () => ({ present: true, selftestCount: 1 }),
        ...context,
      }),
    /selftest failed/,
  );
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["install", "selftest", "rollback"],
  );
  assert.equal(existsSync(context.statePath), false);

  context.model.lifecycleCalls.length = 0;
  reconcileDreaming({ enabled: false, ...context });
  assert.deepEqual(context.model.lifecycleCalls, []);
});

test("interrupted adoption rolls back instead of uninstalling", () => {
  const context = fixture();
  context.materializeRepo();
  mkdirSync(join(context.home, ".local", "state", "remote-agent-stack"), {
    recursive: true,
  });
  writeFileSync(
    context.statePath,
    `${JSON.stringify({
      version: 1,
      runtimeOwned: false,
      pending: "install",
      repoPath: context.repoPath,
      preexistingRuntime: true,
    })}\n`,
  );

  reconcileDreaming({ enabled: false, ...context });
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["rollback"],
  );
  assert.equal(existsSync(context.statePath), false);
});

test("legacy Dreaming jobs are treated as pre-existing", () => {
  const context = fixture();
  const launchAgents = join(context.home, "Library", "LaunchAgents");
  mkdirSync(launchAgents, { recursive: true });
  writeFileSync(
    join(launchAgents, `com.${process.env.USER}.skills.dreaming.plist`),
    "legacy\n",
  );
  context.model.failLifecycle = "selftest";

  assert.throws(
    () => reconcileDreaming({ enabled: true, ...context }),
    /selftest failed/,
  );
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["install", "selftest", "rollback"],
  );
});

test("mixed legacy and current self-test jobs fail before mutation", () => {
  const context = fixture();
  context.materializeRepo();
  mkdirSync(join(context.home, ".copilot", "skills", ".git"), { recursive: true });
  const launchAgents = join(context.home, "Library", "LaunchAgents");
  mkdirSync(launchAgents, { recursive: true });
  for (const prefix of [
    `com.${process.env.USER}.skills`,
    `com.${process.env.USER}.dreaming`,
  ]) {
    writeFileSync(join(launchAgents, `${prefix}.selftest.plist`), "fixture\n");
  }

  assert.throws(
    () => reconcileDreaming({ enabled: true, checkOnly: true, ...context }),
    /both legacy and current/,
  );
  assert.deepEqual(context.model.lifecycleCalls, []);
});

test("blocked adoption rollback remains a reported residual", () => {
  const context = fixture();
  context.materializeRepo();
  mkdirSync(join(context.home, ".local", "state", "remote-agent-stack"), {
    recursive: true,
  });
  writeFileSync(
    context.statePath,
    `${JSON.stringify({
      version: 1,
      runtimeOwned: false,
      pending: "install",
      repoPath: context.repoPath,
      preexistingRuntime: true,
    })}\n`,
  );
  context.model.failLifecycle = "rollback";
  const warnings = [];

  const result = reconcileDreaming({
    enabled: false,
    warn: (message) => warnings.push(message),
    ...context,
  });
  assert.equal(result.residual, true);
  assert.equal(readState(context.statePath).pending, "install");
  assert.match(warnings[0], /rollback is blocked/);
});

test("deselection preserves an unowned runtime", () => {
  const context = fixture();
  context.materializeRepo();
  reconcileDreaming({ enabled: false, ...context });
  assert.deepEqual(context.model.lifecycleCalls, []);
});

test("owned runtime uninstalls but preserves its checkout", () => {
  const context = fixture();
  reconcileDreaming({ enabled: true, ...context });
  context.model.lifecycleCalls.length = 0;

  reconcileDreaming({ enabled: false, ...context });
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["uninstall"],
  );
  assert.equal(existsSync(context.repoPath), true);
  assert.equal(existsSync(context.statePath), false);
});

test("owned runtime can uninstall from a dirty non-main checkout", () => {
  const context = fixture();
  reconcileDreaming({ enabled: true, ...context });
  context.model.lifecycleCalls.length = 0;
  context.model.dirty = true;
  context.model.branch = "work-in-progress";

  reconcileDreaming({ enabled: false, ...context });
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["uninstall"],
  );
});

test("rejects local commits ahead of origin main", () => {
  const context = fixture();
  context.materializeRepo();
  mkdirSync(join(context.home, ".copilot", "skills", ".git"), { recursive: true });
  context.model.head = "local-ahead";

  assert.throws(
    () => reconcileDreaming({ enabled: true, ...context }),
    /local commits/,
  );
  assert.deepEqual(context.model.lifecycleCalls, []);
});

test("failed owned update rolls back and retains ownership", () => {
  const context = fixture();
  reconcileDreaming({ enabled: true, ...context });
  context.model.lifecycleCalls.length = 0;
  context.model.failLifecycle = "selftest";

  assert.throws(
    () => reconcileDreaming({ enabled: true, ...context }),
    /selftest failed/,
  );
  assert.deepEqual(
    context.model.lifecycleCalls.map((call) => call.operation),
    ["install", "selftest", "rollback"],
  );
  const state = readState(context.statePath);
  assert.equal(state.runtimeOwned, true);
  assert.equal(state.pending, null);
  assert.equal(state.repoPath, context.repoPath);
});

test("rejects dirty, foreign, and remote-backed roots", () => {
  const dirty = fixture();
  dirty.materializeRepo();
  dirty.model.dirty = true;
  mkdirSync(join(dirty.home, ".copilot", "skills", ".git"), { recursive: true });
  assert.throws(
    () => reconcileDreaming({ enabled: true, checkOnly: true, ...dirty }),
    /local changes/,
  );

  const foreign = fixture();
  foreign.materializeRepo();
  foreign.model.remote = "https://github.com/someone/other.git";
  mkdirSync(join(foreign.home, ".copilot", "skills", ".git"), { recursive: true });
  assert.throws(
    () => reconcileDreaming({ enabled: true, checkOnly: true, ...foreign }),
    /foreign origin/,
  );

  const rooted = fixture();
  rooted.materializeRepo();
  mkdirSync(join(rooted.home, ".copilot", "skills", ".git"), { recursive: true });
  rooted.model.localSkillsRemote = true;
  assert.throws(
    () => reconcileDreaming({ enabled: true, checkOnly: true, ...rooted }),
    /must not have a Git remote/,
  );
});

test("explicit missing Copilot fails while a saved selection is retained", () => {
  const explicit = fixture();
  explicit.model.available.delete("copilot");
  assert.throws(
    () => reconcileDreaming({ enabled: true, explicit: true, ...explicit }),
    /explicitly selected/,
  );

  const saved = fixture();
  saved.model.available.delete("copilot");
  const warnings = [];
  const result = reconcileDreaming({
    enabled: true,
    warn: (message) => warnings.push(message),
    ...saved,
  });
  assert.equal(result.residual, false);
  assert.match(warnings[0], /keeping the saved/);
});
