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
  countOnlineDisplays,
  normalizeAgentName,
  readConfig,
  reserveSend,
  shouldEnableRemoteAccess,
  withOperationLock,
} from "./core.mjs";

const SCRIPT_PATH = fileURLToPath(
  new URL("./send-imessage.applescript", import.meta.url),
);
const SCREEN_SHARING_COMMAND =
  process.env.AGENT_HELP_SS_COMMAND ?? "/usr/local/bin/ss";
const TMUX_COMMAND = process.env.AGENT_HELP_TMUX_COMMAND ?? "/opt/homebrew/bin/tmux";
const SYSTEM_PROFILER_COMMAND =
  process.env.AGENT_HELP_SYSTEM_PROFILER_COMMAND ?? "/usr/sbin/system_profiler";
const OSASCRIPT_COMMAND =
  process.env.AGENT_HELP_OSASCRIPT_COMMAND ?? "/usr/bin/osascript";

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
  if (!process.env.TMUX) return "CLI agent";
  const result = run(
    TMUX_COMMAND,
    ["display-message", "-p", "#{session_name}"],
    2_000,
  );
  if (result.status !== 0) return "CLI agent";
  try {
    return normalizeAgentName(result.stdout.trim());
  } catch {
    return "CLI agent";
  }
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

function onlineDisplayCount() {
  const result = run(
    SYSTEM_PROFILER_COMMAND,
    ["SPDisplaysDataType", "-json"],
    15_000,
  );
  if (result.status !== 0) return null;
  try {
    return countOnlineDisplays(JSON.parse(result.stdout));
  } catch {
    return null;
  }
}

function enableScreenSharing(hours) {
  const result = run(
    SCREEN_SHARING_COMMAND,
    ["on", String(hours), "--json"],
    30_000,
  );
  if (result.status !== 0) return null;
  try {
    const parsed = JSON.parse(result.stdout);
    return parsed?.enabled === true &&
      typeof parsed.url === "string" &&
      /^screens:\/\/[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$/.test(parsed.url)
      ? { createdLease: parsed.createdLease === true, url: parsed.url }
      : null;
  } catch {
    return null;
  }
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
        "Send the owner one bounded help message when this CLI agent needs a login, permission, decision, or other human action. Use only a short non-secret context label.",
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
          agent_name: {
            type: "string",
            maxLength: 40,
            description:
              "Optional agent name. The current tmux session name is used when omitted.",
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
    const agentName = args.agent_name ?? currentAgentName();
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
    const displayCount = onlineDisplayCount();
    let remote = null;
    if (shouldEnableRemoteAccess(displayCount, config.deskDisplayCount)) {
      remote = enableScreenSharing(config.screenSharingHours);
    }

    const message = buildMessage({
      agentName,
      reason: args.reason,
      context: args.context,
      remoteAccessUrl: remote?.url,
    });
    try {
      sendMessage(config.recipient, message);
    } catch (error) {
      if (remote?.createdLease) disableScreenSharing();
      throw error;
    }
    return {
      content: [{
        type: "text",
        text: remote
          ? "The local Messages app accepted the help request, and temporary Screen Sharing is available."
          : "The local Messages app accepted the help request.",
      }],
    };
  });
});

await server.connect(new StdioServerTransport());
