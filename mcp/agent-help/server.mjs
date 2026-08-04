#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import {
  agentHelpPaths,
  buildMessage,
  normalizeAgentName,
  readConfig,
  reserveSend,
  withOperationLock,
} from "./core.mjs";

const SCRIPT_PATH = fileURLToPath(
  new URL("./send-imessage.applescript", import.meta.url),
);
const SCREEN_SHARING_COMMAND =
  process.env.AGENT_HELP_SCREEN_SHARING_COMMAND ??
  process.env.AGENT_HELP_SS_COMMAND ??
  "/usr/local/bin/agent-screen";
const SCREEN_SHARING_TIMEOUT = 30_000;
const TMUX_COMMAND = process.env.AGENT_HELP_TMUX_COMMAND ?? "/opt/homebrew/bin/tmux";
const OSASCRIPT_COMMAND =
  process.env.AGENT_HELP_OSASCRIPT_COMMAND ?? "/usr/bin/osascript";
const NATO_AGENT_NAMES = new Set([
  "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
  "india", "juliett", "kilo", "lima", "mike", "november", "oscar", "papa",
  "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
  "x-ray", "yankee", "zulu",
]);

function run(command, args, timeout) {
  return spawnSync(command, args, {
    encoding: "utf8",
    timeout,
    env: {
      ...process.env,
      PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
  });
}

function currentAgentName() {
  if (!process.env.TMUX) {
    throw new Error("request_help requires a NATO-named tmux agent session");
  }
  const result = run(
    TMUX_COMMAND,
    ["display-message", "-p", "#{session_name}"],
    2_000,
  );
  if (result.status !== 0) {
    throw new Error("request_help could not identify the tmux agent session");
  }
  try {
    const sessionName = normalizeAgentName(result.stdout.trim()).toLowerCase();
    const name = sessionName.replace(/^(?:copilot|claude|codex)-/, "");
    if (NATO_AGENT_NAMES.has(name)) return name;
  } catch {
    // Normalize all invalid session-name failures below.
  }
  throw new Error("request_help requires a NATO-named tmux agent session");
}

function sendMessage(recipient, message) {
  const result = run(
    OSASCRIPT_COMMAND,
    [SCRIPT_PATH, recipient, message],
    15_000,
  );
  if (result.status !== 0) {
    throw new Error(
      result.error?.code === "ETIMEDOUT"
        ? "Messages timed out"
        : result.stderr.trim() || `Messages exited with status ${result.status}`,
    );
  }
}

function enableScreenSharing(hours) {
  const result = run(
    SCREEN_SHARING_COMMAND,
    ["on", String(hours), "--json"],
    SCREEN_SHARING_TIMEOUT,
  );
  if (result.status !== 0) return null;
  try {
    const parsed = JSON.parse(result.stdout);
    if (
      parsed?.enabled === true &&
      typeof parsed.url === "string" &&
      /^screens:\/\/[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$/.test(parsed.url)
    ) {
      return { createdLease: parsed.createdLease === true, url: parsed.url };
    }
  } catch {
    const legacy = result.stdout.match(
      /Connect with Screens to:\s+([A-Za-z0-9.-]+)\s+port\s+([1-9][0-9]{0,4})/,
    );
    if (legacy) {
      return {
        createdLease: false,
        url: `screens://${legacy[1]}:${legacy[2]}`,
      };
    }
  }
  return null;
}

function disableScreenSharing() {
  run(SCREEN_SHARING_COMMAND, ["off", "--json"], 30_000);
}

const server = new Server(
  { name: "agent-help", version: "1.0.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "request_help",
      description:
        "Send the owner one bounded help message when this CLI agent needs a login, permission, decision, or other human action and the owner may not be at the machine. Use only a short non-secret context label. Send once per blocker and keep working on anything that does not depend on it; never send a second message for the same blocker.",
      inputSchema: {
        type: "object",
        additionalProperties: false,
        properties: {
          reason: {
            type: "string",
            enum: [
              "login_required",
              "decision_required",
              "permission_required",
              "blocked",
              "other",
            ],
          },
          context: {
            type: "string",
            maxLength: 80,
            description:
              "Optional short label such as Stafftools or release approval. No URLs, domains, credentials, errors, repository content, or personal data.",
          },
        },
        required: ["reason"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== "request_help") {
    throw new Error(`unknown tool: ${request.params.name}`);
  }
  return withOperationLock(async () => {
    const args = request.params.arguments ?? {};
    const agentName = currentAgentName();
    const baseMessage = buildMessage({
      agentName,
      reason: args.reason,
      context: args.context,
    });
    const paths = agentHelpPaths();
    const reservation = reserveSend(baseMessage, Date.now(), paths.state);
    if (!reservation.allowed) {
      return {
        content: [{
          type: "text",
          text:
            reservation.reason === "duplicate"
              ? "An identical help request was sent recently; no duplicate was sent."
              : "The owner notification rate limit has been reached; no message was sent.",
        }],
        isError: true,
      };
    }

    const config = readConfig(paths.config);
    const remote = enableScreenSharing(config.screenSharingHours);
    if (!remote) {
      throw new Error(
        "Temporary Screen Sharing could not be enabled; no help message was sent.",
      );
    }

    const message = buildMessage({
      agentName,
      reason: args.reason,
      context: args.context,
      remoteAccessUrl: remote.url,
    });
    try {
      sendMessage(config.recipient, message);
    } catch (error) {
      if (remote.createdLease) disableScreenSharing();
      throw error;
    }
    return {
      content: [{
        type: "text",
        text:
          "The local Messages app accepted the help request, and temporary Screen Sharing is available.",
      }],
    };
  });
});

await server.connect(new StdioServerTransport());
