import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  BLOCK_BEGIN,
  BLOCK_END,
  parseCliList,
  reconcile,
  replaceManagedBlock,
} from "./manage-agent-help.mjs";

test("parses and deduplicates supported CLI lists", () => {
  assert.deepEqual(parseCliList("copilot,claude,copilot,codex"), [
    "copilot",
    "claude",
    "codex",
  ]);
  assert.deepEqual(parseCliList("none"), []);
  assert.throws(() => parseCliList("copilot,other"));
});

test("adds, replaces, and removes only the managed instruction block", () => {
  const original = "# Existing instructions\n\nKeep this.\n";
  const installed = replaceManagedBlock(original, true);
  assert.match(installed, /# Existing instructions/);
  assert.equal(installed.includes(BLOCK_BEGIN), true);
  const replaced = replaceManagedBlock(installed, true);
  assert.equal(replaced, installed);
  assert.equal(replaceManagedBlock(installed, false), original);
  const spaced = "\n# Existing\n\n\n";
  assert.equal(replaceManagedBlock(replaceManagedBlock(spaced, true), false), "\n# Existing\n");
});

test("refuses malformed or duplicate managed instruction markers", () => {
  assert.throws(() => replaceManagedBlock(`${BLOCK_BEGIN}\ntext\n`, true));
  assert.throws(() => replaceManagedBlock(`${BLOCK_END}\n${BLOCK_BEGIN}\n`, true));
  assert.throws(() =>
    replaceManagedBlock(
      `${BLOCK_BEGIN}\na\n${BLOCK_END}\n${BLOCK_BEGIN}\nb\n${BLOCK_END}\n`,
      true,
    ),
  );
});

test("removes owned entries directly when a previously selected CLI is unavailable", () => {
  const home = mkdtempSync(join(tmpdir(), "agent-help-platforms-"));
  const serverPath = join(home, ".config", "remote-agent-stack", "agent-help", "server", "server.mjs");
  const nodePath = "/opt/homebrew/bin/node-new";
  const installedNodePath = "/opt/homebrew/bin/node-old";
  mkdirSync(join(home, ".copilot"), { recursive: true });
  mkdirSync(join(home, ".claude"), { recursive: true });
  mkdirSync(join(home, ".codex"), { recursive: true });
  writeFileSync(
    join(home, ".copilot", "mcp-config.json"),
    JSON.stringify({
      mcpServers: {
        "agent-help": { command: installedNodePath, args: [serverPath] },
        keep: { command: "keep", args: [] },
      },
    }),
  );
  writeFileSync(
    join(home, ".claude.json"),
    JSON.stringify({
      mcpServers: {
        "agent-help": { command: installedNodePath, args: [serverPath] },
        keep: { command: "keep", args: [] },
      },
    }),
  );
  writeFileSync(
    join(home, ".codex", "config.toml"),
    `model = "test"\n\n[mcp_servers.agent-help]\n    command = "${installedNodePath}"\nargs = ["${serverPath}"]\n\n[mcp_servers.keep]\ncommand = "keep"\nargs = []\n`,
  );
  for (const path of [
    join(home, ".copilot", "copilot-instructions.md"),
    join(home, ".claude", "CLAUDE.md"),
    join(home, ".codex", "AGENTS.md"),
  ]) {
    writeFileSync(path, replaceManagedBlock("# Keep\n", true));
  }

  const originalPath = process.env.PATH;
  process.env.PATH = join(home, "empty-bin");
  try {
    reconcile({ selected: [], nodePath, serverPath, home });
  } finally {
    process.env.PATH = originalPath;
  }

  assert.equal(
    JSON.parse(readFileSync(join(home, ".copilot", "mcp-config.json"))).mcpServers[
      "agent-help"
    ],
    undefined,
  );
  assert.equal(
    JSON.parse(readFileSync(join(home, ".claude.json"))).mcpServers["agent-help"],
    undefined,
  );
  assert.doesNotMatch(
    readFileSync(join(home, ".codex", "config.toml"), "utf8"),
    /mcp_servers\.agent-help/,
  );
  assert.match(
    readFileSync(join(home, ".codex", "config.toml"), "utf8"),
    /mcp_servers\.keep/,
  );
});
