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
  MARKETPLACE_NAME,
  PLUGIN_NAME,
  parseCliList,
  readState,
  reconcile,
  writeState,
} from "./manage-skills-plugin.mjs";

function fixture() {
  const home = mkdtempSync(join(tmpdir(), "skills-plugin-manager-"));
  const statePath = join(home, ".local", "state", "remote-agent-stack", "skills-plugin.json");
  const model = {
    available: new Set(["copilot", "claude", "codex"]),
    plugin: {},
    marketplace: {},
    calls: [],
    fail: new Set(),
  };

  function installCopilotManifest(exact = true) {
    const directory = exact ? "dfrysinger--skills" : "someone--foreign";
    const path = join(
      home,
      ".copilot",
      "installed-plugins",
      "_direct",
      directory,
      ".claude-plugin",
    );
    mkdirSync(path, { recursive: true });
    writeFileSync(
      join(path, "plugin.json"),
      `${JSON.stringify({ name: PLUGIN_NAME })}\n`,
    );
  }

  function result(stdout = "") {
    return { status: 0, stdout, stderr: "", error: undefined };
  }

  function run(command, args, { allowFailure = false } = {}) {
    model.calls.push([command, ...args].join(" "));
    if (args[0] === "--version") {
      if (model.available.has(command)) return result(`${command} test\n`);
      return {
        status: null,
        stdout: "",
        stderr: "",
        error: Object.assign(new Error("missing"), { code: "ENOENT" }),
      };
    }
    const signature = [command, ...args].join(" ");
    if (model.fail.has(signature)) {
      const failed = { status: 1, stdout: "", stderr: "injected failure" };
      if (allowFailure) return failed;
      throw new Error(`${signature} failed: injected failure`);
    }

    if (command === "copilot" && args.join(" ") === "plugin list") {
      return result(
        model.plugin.copilot
          ? `Installed plugins:\n  • ${PLUGIN_NAME} (v0.26.0)\n`
          : "No plugins installed.\n",
      );
    }
    if (command === "claude" && args.join(" ") === "plugin marketplace list --json") {
      return result(JSON.stringify(
        model.marketplace.claude
          ? [{
            name: MARKETPLACE_NAME,
            source: "github",
            repo: model.marketplace.claude,
          }]
          : [],
      ));
    }
    if (command === "claude" && args.join(" ") === "plugin list --json") {
      return result(JSON.stringify(
        model.plugin.claude
          ? [{ id: `${PLUGIN_NAME}@${MARKETPLACE_NAME}` }]
          : [],
      ));
    }
    if (command === "codex" && args.join(" ") === "plugin marketplace list --json") {
      return result(JSON.stringify({
        marketplaces: model.marketplace.codex
          ? [{
            name: MARKETPLACE_NAME,
            marketplaceSource: {
              sourceType: "git",
              source: model.marketplace.codex,
            },
          }]
          : [],
      }));
    }
    if (command === "codex" && args.join(" ") === "plugin list --json") {
      return result(JSON.stringify({
        installed: model.plugin.codex
          ? [{
            pluginId: `${PLUGIN_NAME}@${MARKETPLACE_NAME}`,
            marketplaceSource: {
              sourceType: "git",
              source: model.plugin.codex,
            },
          }]
          : [],
      }));
    }

    if (command === "copilot" && args[1] === "install") {
      model.plugin.copilot = "dfrysinger/skills";
      installCopilotManifest(true);
    } else if (command === "copilot" && args[1] === "uninstall") {
      model.plugin.copilot = null;
    } else if (command === "claude" && args[2] === "add") {
      model.marketplace.claude = "dfrysinger/skills";
    } else if (command === "claude" && args[1] === "install") {
      model.plugin.claude = "dfrysinger/skills";
    } else if (command === "claude" && args[1] === "uninstall") {
      model.plugin.claude = null;
    } else if (command === "claude" && args[2] === "remove") {
      model.marketplace.claude = null;
    } else if (command === "codex" && args[2] === "add") {
      model.marketplace.codex = "https://github.com/dfrysinger/skills.git";
    } else if (command === "codex" && args[1] === "add") {
      model.plugin.codex = "https://github.com/dfrysinger/skills.git";
    } else if (command === "codex" && args[1] === "remove") {
      model.plugin.codex = null;
    } else if (command === "codex" && args[2] === "remove") {
      model.marketplace.codex = null;
    }
    return result("{}");
  }

  return { home, statePath, model, run, installCopilotManifest };
}

test("parses supported CLI sets", () => {
  assert.deepEqual(parseCliList("copilot,claude,copilot,codex"), [
    "copilot",
    "claude",
    "codex",
  ]);
  assert.deepEqual(parseCliList("none"), []);
  assert.throws(() => parseCliList("other"));
});

test("reconciles owned all to copilot to none", () => {
  const context = fixture();
  reconcile({
    selected: ["copilot", "claude", "codex"],
    explicitSelected: ["copilot", "claude", "codex"],
    ...context,
  });
  let state = readState(context.statePath);
  assert.equal(state.clis.copilot.pluginOwned, true);
  assert.equal(state.clis.claude.marketplaceOwned, true);
  assert.equal(state.clis.codex.pluginOwned, true);

  context.model.calls.length = 0;
  reconcile({ selected: ["copilot", "claude", "codex"], ...context });
  assert.equal(
    context.model.calls.includes(`copilot plugin update ${PLUGIN_NAME}`),
    true,
  );
  assert.equal(
    context.model.calls.includes(
      `claude plugin marketplace update ${MARKETPLACE_NAME}`,
    ),
    true,
  );
  assert.equal(
    context.model.calls.includes(
      `claude plugin update --scope user ${PLUGIN_NAME}@${MARKETPLACE_NAME}`,
    ),
    true,
  );
  assert.equal(
    context.model.calls.includes(
      `codex plugin marketplace upgrade ${MARKETPLACE_NAME} --json`,
    ),
    true,
  );

  reconcile({ selected: ["copilot"], ...context });
  state = readState(context.statePath);
  assert.deepEqual(Object.keys(state.clis), ["copilot"]);

  reconcile({ selected: [], ...context });
  assert.equal(existsSync(context.statePath), false);
});

test("preserves exact pre-existing plugins and marketplaces", () => {
  const context = fixture();
  context.model.plugin = {
    copilot: "dfrysinger/skills",
    claude: "dfrysinger/skills",
    codex: "https://github.com/dfrysinger/skills.git",
  };
  context.model.marketplace = {
    claude: "dfrysinger/skills",
    codex: "https://github.com/dfrysinger/skills.git",
  };
  context.installCopilotManifest(true);

  reconcile({ selected: ["copilot", "claude", "codex"], ...context });
  reconcile({ selected: [], ...context });
  assert.equal(existsSync(context.statePath), false);
  assert.equal(
    context.model.calls.some((call) =>
      /\b(install|uninstall|update|add|remove|upgrade)\b/.test(call) &&
      !call.endsWith("--version")
    ),
    false,
  );
});

test("fails selected foreign collisions but preserves them during uninstall", () => {
  const context = fixture();
  context.model.plugin.copilot = "foreign";
  context.installCopilotManifest(false);
  context.model.marketplace.claude = "someone/fork";

  const selected = reconcile({
    selected: ["copilot", "claude"],
    explicitSelected: ["copilot", "claude"],
    ...context,
  });
  assert.equal(selected.errors.length, 2);
  context.model.calls.length = 0;
  const removed = reconcile({ selected: [], ...context });
  assert.deepEqual(removed.errors, []);
  assert.equal(
    context.model.calls.some((call) => /\b(uninstall|remove)\b/.test(call)),
    false,
  );
});

test("ambiguous pending add becomes foreign", () => {
  const context = fixture();
  context.model.marketplace.claude = "dfrysinger/skills";
  context.model.plugin.claude = "dfrysinger/skills";
  writeState(context.statePath, {
    version: 1,
    clis: {
      claude: {
        pluginOwned: false,
        marketplaceOwned: true,
        pending: { operation: "plugin:add", startedAt: 1 },
      },
    },
  });

  reconcile({ selected: ["claude"], ...context });
  const state = readState(context.statePath);
  assert.equal(state.clis.claude.pluginOwned, false);
  assert.equal(state.clis.claude.pending, null);
  context.model.calls.length = 0;
  reconcile({ selected: [], ...context });
  assert.equal(context.model.plugin.claude, "dfrysinger/skills");
  assert.equal(
    context.model.calls.some((call) => call.includes("plugin uninstall")),
    false,
  );
});

test("successful mutation plus failed final state write stays pending", () => {
  const context = fixture();
  let writes = 0;
  const persist = (path, state) => {
    writes += 1;
    if (writes === 2) throw new Error("injected state write failure");
    writeState(path, state);
  };

  const first = reconcile({
    selected: ["copilot"],
    explicitSelected: ["copilot"],
    persist,
    ...context,
  });
  assert.equal(first.errors.length, 1);
  assert.equal(
    readState(context.statePath).clis.copilot.pending.operation,
    "plugin:add",
  );

  reconcile({ selected: ["copilot"], ...context });
  const state = readState(context.statePath);
  assert.equal(state.clis.copilot, undefined);
});

test("continues removals and retains failed ownership", () => {
  const context = fixture();
  context.model.plugin.claude = "dfrysinger/skills";
  context.model.marketplace.claude = "dfrysinger/skills";
  context.model.plugin.codex = "https://github.com/dfrysinger/skills.git";
  context.model.marketplace.codex = "https://github.com/dfrysinger/skills.git";
  writeState(context.statePath, {
    version: 1,
    clis: {
      claude: {
        pluginOwned: true,
        marketplaceOwned: true,
        pending: null,
      },
      codex: {
        pluginOwned: true,
        marketplaceOwned: true,
        pending: null,
      },
    },
  });
  context.model.fail.add(
    `claude plugin uninstall --scope user ${PLUGIN_NAME}@${MARKETPLACE_NAME}`,
  );

  const result = reconcile({ selected: [], ...context });
  assert.equal(result.errors.length, 1);
  assert.equal(context.model.plugin.codex, null);
  const state = readState(context.statePath);
  assert.equal(state.clis.claude.pending.operation, "plugin:remove");
  assert.equal(state.clis.codex, undefined);
});

test("skips unavailable saved CLI while cleaning available entries", () => {
  const context = fixture();
  context.model.available.delete("codex");
  context.model.plugin.claude = "dfrysinger/skills";
  context.model.marketplace.claude = "dfrysinger/skills";
  writeState(context.statePath, {
    version: 1,
    clis: {
      claude: {
        pluginOwned: true,
        marketplaceOwned: true,
        pending: null,
      },
      codex: {
        pluginOwned: true,
        marketplaceOwned: true,
        pending: null,
      },
    },
  });

  const result = reconcile({ selected: ["codex"], ...context });
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.residual, ["codex"]);
  assert.equal(context.model.plugin.claude, null);
  assert.equal(readState(context.statePath).clis.codex.pluginOwned, true);
  assert.throws(() =>
    reconcile({
      selected: ["codex"],
      explicitSelected: ["codex"],
      ...context,
    }),
  );
});

test("ignores incapable deselected CLIs without state", () => {
  const context = fixture();
  context.model.fail.add("claude plugin list --json");
  const result = reconcile({ selected: [], checkOnly: true, ...context });
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.residual, []);
  assert.equal(
    context.model.calls.some((call) => call.startsWith("claude plugin")),
    false,
  );
});

test("preserves tracked state when a deselected CLI inventory fails", () => {
  const context = fixture();
  context.model.fail.add("claude plugin list --json");
  writeState(context.statePath, {
    version: 1,
    clis: {
      claude: {
        pluginOwned: true,
        marketplaceOwned: true,
        pending: null,
      },
    },
  });

  const result = reconcile({ selected: [], ...context });
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.residual, ["claude"]);
  assert.equal(readState(context.statePath).clis.claude.pluginOwned, true);
});

test("requires plugin support only for explicitly selected CLIs", () => {
  const context = fixture();
  context.model.fail.add("claude plugin list --json");

  const saved = reconcile({ selected: ["claude"], ...context });
  assert.deepEqual(saved.errors, []);

  const explicit = reconcile({
    selected: ["claude"],
    explicitSelected: ["claude"],
    ...context,
  });
  assert.equal(explicit.errors.length, 1);
});
