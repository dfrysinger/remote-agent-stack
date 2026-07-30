import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { writeConfig } from "./core.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

function executable(path, body) {
  writeFileSync(path, `#!/bin/bash\nset -e\n${body}\n`, "utf8");
  chmodSync(path, 0o700);
}

async function withServer(
  { displays = 1, createdLease = true, sendFails = false, tmuxName = null },
  callback,
) {
  const directory = mkdtempSync(join(tmpdir(), "agent-help-server-"));
  const log = join(directory, "commands.log");
  const configRoot = join(directory, "config");
  writeConfig(
    {
      recipient: "owner@example.test",
      deskDisplayCount: 3,
      screenSharingHours: 1,
      screenSharingPort: 15900,
    },
    join(configRoot, "agent-help", "config.json"),
  );
  const profiler = join(directory, "system-profiler");
  const ss = join(directory, "ss");
  const osascript = join(directory, "osascript");
  const tmux = join(directory, "tmux");
  const body = join(directory, "message-body");
  executable(
    profiler,
    `printf '%s\\n' '{"SPDisplaysDataType":[{"spdisplays_ndrvs":[${Array.from(
      { length: displays },
      () => '{"spdisplays_online":"spdisplays_yes"}',
    ).join(",")}]}]}'`,
  );
  executable(
    ss,
    `printf 'ss %s\\n' "$*" >> ${JSON.stringify(log)}
if [ "\${1:-}" = on ]; then
  printf '%s\\n' '{"enabled":true,"createdLease":${createdLease},"url":"screens://test-mac.example.ts.net:15900"}'
else
  printf '%s\\n' '{"enabled":false}'
fi`,
  );
  executable(
    osascript,
    `printf 'message\\n' >> ${JSON.stringify(log)}
printf '%s' "\${3:-}" > ${JSON.stringify(body)}
${sendFails ? "exit 1" : "exit 0"}`,
  );
  if (tmuxName !== null) {
    executable(tmux, `printf '%s\\n' ${JSON.stringify(tmuxName)}`);
  }

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(HERE, "server.mjs")],
    env: {
      ...process.env,
      REMOTE_AGENT_STACK_CONFIG_DIR: configRoot,
      AGENT_HELP_SYSTEM_PROFILER_COMMAND: profiler,
      AGENT_HELP_SS_COMMAND: ss,
      AGENT_HELP_OSASCRIPT_COMMAND: osascript,
      ...(tmuxName === null
        ? {}
        : { TMUX: "test", AGENT_HELP_TMUX_COMMAND: tmux }),
    },
    stderr: "pipe",
  });
  const client = new Client({ name: "agent-help-test", version: "1.0.0" });
  await client.connect(transport);
  try {
    await callback({ client, log, body });
  } finally {
    await client.close();
  }
}

test("lists request_help and advertises remote access after successful enablement", async () => {
  await withServer({}, async ({ client, log }) => {
    const tools = await client.listTools();
    assert.deepEqual(tools.tools.map((tool) => tool.name), ["request_help"]);
    const result = await client.callTool({
      name: "request_help",
      arguments: { reason: "login_required", context: "Stafftools" },
    });
    assert.match(result.content[0].text, /temporary Screen Sharing is available/);
    assert.deepEqual(readFileSync(log, "utf8").trim().split("\n"), [
      "ss on 1 --json",
      "message",
    ]);
  });
});

test("failed send tears down only a lease created by that request", async () => {
  await withServer(
    { createdLease: true, sendFails: true },
    async ({ client, log }) => {
      await assert.rejects(() =>
        client.callTool({
          name: "request_help",
          arguments: { reason: "blocked", context: "Approval" },
        }),
      );
      assert.deepEqual(readFileSync(log, "utf8").trim().split("\n"), [
        "ss on 1 --json",
        "message",
        "ss off --json",
      ]);
    },
  );
  await withServer(
    { createdLease: false, sendFails: true },
    async ({ client, log }) => {
      await assert.rejects(() =>
        client.callTool({
          name: "request_help",
          arguments: { reason: "blocked", context: "Approval" },
        }),
      );
      assert.deepEqual(readFileSync(log, "utf8").trim().split("\n"), [
        "ss on 1 --json",
        "message",
      ]);
    },
  );
});

test("zero displays sends help without opening Screen Sharing", async () => {
  await withServer({ displays: 0 }, async ({ client, log }) => {
    const result = await client.callTool({
      name: "request_help",
      arguments: { reason: "decision_required", context: "Release approval" },
    });
    assert.equal(
      result.content[0].text,
      "The local Messages app accepted the help request.",
    );
    assert.deepEqual(readFileSync(log, "utf8").trim().split("\n"), ["message"]);
  });
});

test("unsupported tmux session characters fall back without blocking help", async () => {
  await withServer({ displays: 3, tmuxName: "agent+1" }, async ({ client, body }) => {
    await client.callTool({
      name: "request_help",
      arguments: { reason: "blocked", context: "Approval" },
    });
    assert.match(readFileSync(body, "utf8"), /^Agent CLI agent:/);
  });
});
