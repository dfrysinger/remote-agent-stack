import assert from "node:assert/strict";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
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
  {
    createdLease = true,
    legacyScreenSharingOutput = false,
    screenSharingFails = false,
    sendFails = false,
    tmuxName = "hotel",
  },
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
  const ss = join(directory, "ss");
  const osascript = join(directory, "osascript");
  const tmux = join(directory, "tmux");
  const body = join(directory, "message-body");
  executable(
    ss,
    `printf 'ss %s\\n' "$*" >> ${JSON.stringify(log)}
if [ "\${1:-}" = on ]; then
  ${screenSharingFails ? "exit 1" : ""}
  ${
    legacyScreenSharingOutput
      ? "printf '%s\\n' 'Connect with Screens to:  test-mac.example.ts.net  port 15900'"
      : `printf '%s\\n' '{"enabled":true,"createdLease":${createdLease},"url":"screens://test-mac.example.ts.net:15900"}'`
  }
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
    await callback({ client, configRoot, log, body });
  } finally {
    await client.close();
  }
}

test("lists request_help and advertises remote access after successful enablement", async () => {
  await withServer({}, async ({ client, log }) => {
    const tools = await client.listTools();
    assert.deepEqual(tools.tools.map((tool) => tool.name), ["request_help"]);
    assert.equal(
      Object.hasOwn(tools.tools[0].inputSchema.properties, "agent_name"),
      false,
    );
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

test("uses the tmux NATO name and exposes no caller-supplied identity", async () => {
  await withServer({ tmuxName: "lima" }, async ({ client, body }) => {
    await client.callTool({
      name: "request_help",
      arguments: {
        reason: "decision_required",
        context: "Concurrent Phase 5 worktree edits",
      },
    });
    assert.match(readFileSync(body, "utf8"), /^Agent lima:/);
    assert.match(
      readFileSync(body, "utf8"),
      /screens:\/\/test-mac\.example\.ts\.net:15900$/,
    );
  });
});

test("normalizes Claude tmux prefixes to the NATO agent name", async () => {
  await withServer({ tmuxName: "claude-lima" }, async ({ client, body }) => {
    await client.callTool({
      name: "request_help",
      arguments: { reason: "blocked", context: "Approval" },
    });
    assert.match(readFileSync(body, "utf8"), /^Agent lima:/);
  });
});

test("supports the legacy Screen Sharing helper output during migration", async () => {
  await withServer(
    { legacyScreenSharingOutput: true },
    async ({ client, body }) => {
      await client.callTool({
        name: "request_help",
        arguments: { reason: "blocked", context: "Approval" },
      });
      assert.match(
        readFileSync(body, "utf8"),
        /screens:\/\/test-mac\.example\.ts\.net:15900$/,
      );
    },
  );
});

test("rejects non-NATO tmux sessions before sending", async () => {
  await withServer({ tmuxName: "agent+1" }, async ({ client, log, body }) => {
    await assert.rejects(() =>
      client.callTool({
        name: "request_help",
        arguments: { reason: "blocked", context: "Approval" },
      }),
    );
    assert.equal(existsSync(log), false);
    assert.equal(existsSync(body), false);
  });
});

test("does not send a linkless message when Screen Sharing fails", async () => {
  await withServer(
    { screenSharingFails: true },
    async ({ client, configRoot, log, body }) => {
      await assert.rejects(() =>
        client.callTool({
          name: "request_help",
          arguments: { reason: "blocked", context: "Approval" },
        }),
      );
      assert.deepEqual(readFileSync(log, "utf8").trim().split("\n"), [
        "ss on 1 --json",
      ]);
      assert.equal(existsSync(body), false);
      assert.equal(
        JSON.parse(
          readFileSync(join(configRoot, "agent-help", "state.json"), "utf8"),
        ).sends.length,
        1,
      );
    },
  );
});
