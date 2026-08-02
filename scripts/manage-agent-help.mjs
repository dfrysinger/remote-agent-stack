#!/usr/bin/env node

import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const BLOCK_BEGIN = "<!-- >>> remote-agent-stack agent-help (managed) >>> -->";
export const BLOCK_END = "<!-- <<< remote-agent-stack agent-help (managed) <<< -->";

const INSTRUCTION_BODY = `${BLOCK_BEGIN}
## Request help when the owner may be away

When progress requires the owner's login, permission, decision, or other human
action and they may not be at the Mac, call the user-level \`agent-help\` MCP
tool \`request_help\` once for that blocker. Include only a short, non-secret
context label. Never include URLs, domains, credentials, repository content,
raw errors, or personal data. Continue independent work when possible and do
not repeatedly notify for the same blocker. The tool identifies the agent from
its NATO-alphabet tmux session name and opens a bounded Screens link.
${BLOCK_END}`;

// The guidance above now lives in the request_help tool description, which is
// already in context whenever the tool is available. Managing a second copy in
// the per-turn instruction files duplicated it at a cost paid every turn, so
// the block is only ever removed now. INSTRUCTION_BODY is retained so an
// existing block keeps a canonical form to be recognized and stripped.
const MANAGE_INSTRUCTION_BLOCK = false;

function atomicWrite(path, content, mode = 0o600) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, content, { encoding: "utf8", mode });
  renameSync(temporary, path);
  chmodSync(path, mode);
}

function resolvedPath(path) {
  try {
    return lstatSync(path).isSymbolicLink() ? realpathSync(path) : path;
  } catch (error) {
    if (error?.code === "ENOENT") return path;
    throw error;
  }
}

export function replaceManagedBlock(content, enabled) {
  const occurrences = (needle) => {
    const indexes = [];
    let offset = 0;
    while ((offset = content.indexOf(needle, offset)) !== -1) {
      indexes.push(offset);
      offset += needle.length;
    }
    return indexes;
  };
  const beginMatches = occurrences(BLOCK_BEGIN);
  const endMatches = occurrences(BLOCK_END);
  if (beginMatches.length !== endMatches.length || beginMatches.length > 1) {
    throw new Error("agent-help instruction markers are malformed or duplicated");
  }
  if (
    beginMatches.length === 1 &&
    beginMatches[0] >= endMatches[0]
  ) {
    throw new Error("agent-help instruction markers are reversed");
  }
  if (beginMatches.length === 0) {
    if (!enabled) return content;
    if (!content) return `${INSTRUCTION_BODY}\n`;
    return `${content}${content.endsWith("\n") ? "" : "\n"}\n${INSTRUCTION_BODY}\n`;
  }
  const before = content.slice(0, beginMatches[0]).replace(/\n*$/, "");
  const after = content
    .slice(endMatches[0] + BLOCK_END.length)
    .replace(/^\n*/, "");
  const remaining =
    before && after ? `${before}\n\n${after}` : before || after;
  if (!enabled) return remaining ? `${remaining.replace(/\n*$/, "")}\n` : "";
  return remaining
    ? `${remaining.replace(/\n*$/, "")}\n\n${INSTRUCTION_BODY}\n`
    : `${INSTRUCTION_BODY}\n`;
}

function manageInstruction(path, enabled) {
  const target = resolvedPath(path);
  const content = existsSync(target) ? readFileSync(target, "utf8") : "";
  const updated = replaceManagedBlock(content, enabled);
  if (updated === content) return;
  const mode = existsSync(target) ? statSync(target).mode & 0o777 : 0o600;
  atomicWrite(target, updated, mode);
}

function validateInstruction(path, enabled) {
  const target = resolvedPath(path);
  const content = existsSync(target) ? readFileSync(target, "utf8") : "";
  replaceManagedBlock(content, enabled);
}

function run(command, args, { allowFailure = false } = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    env: process.env,
    timeout: 30_000,
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
      `${command} ${args.join(" ")} failed: ${result.stderr.trim() || result.stdout.trim()}`,
    );
  }
  return result;
}

function parseJsonFile(path) {
  if (!existsSync(path)) return {};
  return JSON.parse(readFileSync(path, "utf8"));
}

function codexConfigPath(home) {
  return join(process.env.CODEX_HOME ?? join(home, ".codex"), "config.toml");
}

function codexManagedSection(content) {
  const header = /^\[mcp_servers\.agent-help\]\s*$/m;
  const match = header.exec(content);
  if (!match) return null;
  const start = match.index;
  const bodyStart = start + match[0].length;
  const nextHeader = /^\[/m.exec(content.slice(bodyStart));
  const end = nextHeader ? bodyStart + nextHeader.index : content.length;
  const body = content.slice(bodyStart, end);
  const commandMatch = body.match(/^\s*command\s*=\s*"([^"]+)"\s*$/m);
  const argsMatch = body.match(/^\s*args\s*=\s*(\[[^\n]*\])\s*$/m);
  if (!commandMatch || !argsMatch) return { start, end, command: null, args: [] };
  let args = [];
  try {
    args = JSON.parse(argsMatch[1]);
  } catch {
    // A malformed section is foreign and must not be removed.
  }
  return { start, end, command: commandMatch[1], args };
}

function readEntry(cli, home, available) {
  if (cli === "copilot") {
    return parseJsonFile(
      join(process.env.COPILOT_HOME ?? join(home, ".copilot"), "mcp-config.json"),
    ).mcpServers?.["agent-help"] ?? null;
  }
  if (cli === "claude") {
    return parseJsonFile(join(home, ".claude.json")).mcpServers?.["agent-help"] ?? null;
  }
  if (available) {
    const result = run("codex", ["mcp", "get", "agent-help", "--json"], {
      allowFailure: true,
    });
    if (result.status === 0) return JSON.parse(result.stdout).transport ?? null;
  }
  const path = codexConfigPath(home);
  if (!existsSync(path)) return null;
  return codexManagedSection(readFileSync(path, "utf8"));
}

function entryArgs(entry) {
  return Array.isArray(entry?.args) ? entry.args : [];
}

function entryOwned(entry, { serverPath, legacyServerPath }) {
  if (!entry) return false;
  const args = entryArgs(entry);
  return (
    args.length === 1 &&
    (args[0] === serverPath || args[0] === legacyServerPath)
  );
}

function removeEntry(cli) {
  if (cli === "copilot") run("copilot", ["mcp", "remove", "agent-help"]);
  if (cli === "claude") {
    run("claude", ["mcp", "remove", "--scope", "user", "agent-help"]);
  }
  if (cli === "codex") run("codex", ["mcp", "remove", "agent-help"]);
}

function removeEntryDirect(cli, home) {
  if (cli === "copilot" || cli === "claude") {
    const configuredPath =
      cli === "copilot"
        ? join(
          process.env.COPILOT_HOME ?? join(home, ".copilot"),
          "mcp-config.json",
        )
        : join(home, ".claude.json");
    const path = resolvedPath(configuredPath);
    const config = parseJsonFile(path);
    if (config.mcpServers) {
      delete config.mcpServers["agent-help"];
      const mode = statSync(path).mode & 0o777;
      atomicWrite(path, `${JSON.stringify(config, null, 2)}\n`, mode);
    }
    return;
  }
  const path = resolvedPath(codexConfigPath(home));
  const content = readFileSync(path, "utf8");
  const section = codexManagedSection(content);
  if (!section) return;
  const updated = `${content.slice(0, section.start)}${content.slice(section.end)}`
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  const mode = statSync(path).mode & 0o777;
  atomicWrite(path, updated ? `${updated}\n` : "", mode);
}

function addEntry(cli, nodePath, serverPath) {
  if (cli === "copilot") {
    run("copilot", [
      "mcp",
      "add",
      "agent-help",
      "--tools",
      "request_help",
      "--",
      nodePath,
      serverPath,
    ]);
  }
  if (cli === "claude") {
    run("claude", [
      "mcp",
      "add",
      "--scope",
      "user",
      "agent-help",
      "--",
      nodePath,
      serverPath,
    ]);
  }
  if (cli === "codex") {
    run("codex", ["mcp", "add", "agent-help", "--", nodePath, serverPath]);
  }
}

function cliAvailable(cli) {
  const result = run(cli, ["--version"], { allowFailure: true });
  return !result.error && result.status === 0;
}

function instructionPath(cli, home) {
  if (cli === "copilot") {
    return join(
      process.env.COPILOT_HOME ?? join(home, ".copilot"),
      "copilot-instructions.md",
    );
  }
  if (cli === "claude") return join(home, ".claude", "CLAUDE.md");
  return join(process.env.CODEX_HOME ?? join(home, ".codex"), "AGENTS.md");
}

export function parseCliList(value) {
  if (value === "none" || value === "") return [];
  const result = [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
  for (const cli of result) {
    if (!["copilot", "claude", "codex"].includes(cli)) {
      throw new Error(`unsupported agent-help CLI: ${cli}`);
    }
  }
  return result;
}

export function reconcile({
  selected,
  nodePath,
  serverPath,
  home = homedir(),
  dryRun = false,
}) {
  const legacyServerPath = join(
    home,
    ".copilot",
    "mcp-servers",
    "agent-help",
    "server.mjs",
  );
  for (const cli of ["copilot", "claude", "codex"]) {
    const enabled = selected.includes(cli);
    const available = cliAvailable(cli);
    if (enabled && !available) throw new Error(`${cli} was selected but is not installed`);

    const entry = readEntry(cli, home, available);
    if (
      entry &&
      !entryOwned(entry, { serverPath, legacyServerPath })
    ) {
      if (enabled) {
        throw new Error(
          `${cli} already has a foreign user MCP entry named agent-help; refusing to overwrite it`,
        );
      }
    }
    validateInstruction(instructionPath(cli, home), enabled && MANAGE_INSTRUCTION_BLOCK);
    if (dryRun) continue;
    if (entry && entryOwned(entry, { serverPath, legacyServerPath })) {
      if (available) removeEntry(cli);
      else removeEntryDirect(cli, home);
    }
    if (enabled) addEntry(cli, nodePath, serverPath);
    manageInstruction(instructionPath(cli, home), enabled && MANAGE_INSTRUCTION_BLOCK);
  }
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
  reconcile({
    selected: parseCliList(args.clis ?? ""),
    nodePath: args.node,
    serverPath: args.server,
    dryRun: args.mode === "check",
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
