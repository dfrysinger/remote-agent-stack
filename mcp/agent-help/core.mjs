import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const MAX_SENDS_PER_HOUR = 3;
export const DEDUPLICATION_MS = 10 * 60 * 1000;

const REASONS = {
  login_required: "I need a login",
  decision_required: "I need a decision",
  permission_required: "I need permission to continue",
  blocked: "I am blocked and need help",
  other: "I need help",
};

function defaultConfigRoot() {
  return (
    process.env.REMOTE_AGENT_STACK_CONFIG_DIR ??
    join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "remote-agent-stack")
  );
}

export function agentHelpPaths(configRoot = defaultConfigRoot()) {
  const directory = join(configRoot, "agent-help");
  return {
    directory,
    config: join(directory, "config.json"),
    state: join(directory, "state.json"),
    lock: join(directory, "operation.lock"),
  };
}

function privateWrite(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

function validateLabel(value, { fallback, maximum, field }) {
  if (value === undefined || value === null || value === "") {
    if (fallback !== undefined) return fallback;
    return null;
  }
  if (typeof value !== "string") throw new Error(`${field} must be a string`);
  const trimmed = value.trim();
  if (/[\r\n\t]/.test(trimmed)) {
    throw new Error(`${field} must not contain control characters`);
  }
  if (
    /(?:[a-z][a-z0-9+.-]*:\/\/|[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,63}|\b(?:token|password|passwd|secret|api[_ -]?key)\b)/i.test(
      trimmed,
    )
  ) {
    throw new Error(`${field} must not contain URLs, domains, or credential labels`);
  }
  if (!/^[A-Za-z0-9 _()./-]+$/.test(trimmed)) {
    throw new Error(`${field} contains unsupported characters`);
  }
  const normalized = trimmed.replace(/\s+/g, " ").slice(0, maximum);
  if (!normalized) throw new Error(`${field} must contain a short label`);
  return normalized;
}

export function normalizeAgentName(value, fallback = "CLI agent") {
  return validateLabel(value, {
    fallback,
    maximum: 40,
    field: "agent_name",
  });
}

export function normalizeContext(value) {
  return validateLabel(value, {
    maximum: 80,
    field: "context",
  });
}

export function buildMessage({
  agentName,
  reason,
  context,
  remoteAccessUrl = null,
}) {
  const reasonText = REASONS[reason];
  if (!reasonText) throw new Error(`unsupported reason: ${reason}`);
  const agent = normalizeAgentName(agentName);
  const safeContext = normalizeContext(context);
  const remoteAccess = remoteAccessUrl
    ? ` Screens is available temporarily: ${remoteAccessUrl}`
    : "";
  return `Agent ${agent}: ${reasonText}${safeContext ? ` for ${safeContext}` : ""}. Open the Mac when available.${remoteAccess}`;
}

export function countOnlineDisplays(profile) {
  if (!profile || typeof profile !== "object") return null;
  const adapters = profile.SPDisplaysDataType;
  if (!Array.isArray(adapters)) return null;
  const displayArrays = adapters
    .map((adapter) => adapter?.spdisplays_ndrvs)
    .filter(Array.isArray);
  if (displayArrays.length === 0) return null;
  return displayArrays
    .flat()
    .filter((display) => display?.spdisplays_online === "spdisplays_yes").length;
}

export function shouldEnableRemoteAccess(displayCount, deskDisplayCount) {
  return (
    Number.isInteger(displayCount) &&
    Number.isInteger(deskDisplayCount) &&
    displayCount > 0 &&
    deskDisplayCount > 0 &&
    displayCount < deskDisplayCount
  );
}

export function tailscaleHostname(status) {
  const raw = status?.Self?.DNSName;
  if (typeof raw !== "string") return null;
  const dnsName = raw.trim().replace(/\.$/, "");
  if (
    dnsName.length === 0 ||
    dnsName.length > 253 ||
    !/^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(
      dnsName,
    )
  ) {
    return null;
  }
  return dnsName.split(".", 1)[0];
}

export function screensUrl(status, port) {
  const hostname = tailscaleHostname(status);
  if (!hostname || !Number.isInteger(port) || port < 1 || port > 65535) {
    return null;
  }
  return `screens://${hostname}:${port}`;
}

export function readConfig(path = agentHelpPaths().config) {
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  if (
    parsed?.version !== 1 ||
    typeof parsed.recipient !== "string" ||
    parsed.recipient.trim().length === 0
  ) {
    throw new Error(`invalid agent-help configuration at ${path}`);
  }
  const port = parsed.screenSharingPort;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`invalid screenSharingPort at ${path}`);
  }
  return {
    recipient: parsed.recipient.trim(),
    deskDisplayCount:
      Number.isInteger(parsed.deskDisplayCount) && parsed.deskDisplayCount > 0
        ? parsed.deskDisplayCount
        : 3,
    screenSharingHours:
      Number.isInteger(parsed.screenSharingHours) &&
      parsed.screenSharingHours > 0 &&
      parsed.screenSharingHours <= 8
        ? parsed.screenSharingHours
        : 1,
    screenSharingPort: port,
  };
}

export function writeConfig(
  {
    recipient,
    deskDisplayCount = 3,
    screenSharingHours = 1,
    screenSharingPort = 15900,
  },
  path = agentHelpPaths().config,
) {
  if (typeof recipient !== "string" || recipient.trim().length === 0) {
    throw new Error("recipient is required");
  }
  if (/[\r\n\t]/.test(recipient)) {
    throw new Error("recipient contains control characters");
  }
  if (
    !Number.isInteger(deskDisplayCount) ||
    deskDisplayCount < 1 ||
    !Number.isInteger(screenSharingHours) ||
    screenSharingHours < 1 ||
    screenSharingHours > 8 ||
    !Number.isInteger(screenSharingPort) ||
    screenSharingPort < 1 ||
    screenSharingPort > 65535
  ) {
    throw new Error("invalid agent-help numeric configuration");
  }
  privateWrite(path, {
    version: 1,
    recipient: recipient.trim(),
    deskDisplayCount,
    screenSharingHours,
    screenSharingPort,
  });
}

function readState(path) {
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    if (parsed?.version !== 1 || !Array.isArray(parsed.sends)) {
      throw new Error(`invalid agent-help state at ${path}`);
    }
    return { sends: parsed.sends };
  } catch (error) {
    if (error?.code === "ENOENT") return { sends: [] };
    throw error;
  }
}

export function reserveSend(message, now = Date.now(), path = agentHelpPaths().state) {
  const state = readState(path);
  const sends = state.sends.filter(
    (entry) =>
      Number.isFinite(entry?.sentAt) &&
      typeof entry?.message === "string" &&
      now - entry.sentAt < 60 * 60 * 1000,
  );
  if (
    sends.some(
      (entry) => entry.message === message && now - entry.sentAt < DEDUPLICATION_MS,
    )
  ) {
    return { allowed: false, reason: "duplicate" };
  }
  if (sends.length >= MAX_SENDS_PER_HOUR) {
    return { allowed: false, reason: "rate_limited" };
  }
  sends.push({ message, sentAt: now });
  privateWrite(path, { version: 1, sends });
  return { allowed: true };
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export async function withOperationLock(
  callback,
  {
    lockPath = agentHelpPaths().lock,
    timeoutMs = 10_000,
  } = {},
) {
  const started = Date.now();
  let lockIdentity;
  mkdirSync(dirname(lockPath), { recursive: true, mode: 0o700 });
  chmodSync(dirname(lockPath), 0o700);
  for (;;) {
    try {
      execFileSync(
        "/usr/bin/shlock",
        ["-f", lockPath, "-p", String(process.pid)],
        { stdio: "ignore" },
      );
      chmodSync(lockPath, 0o600);
      lockIdentity = statSync(lockPath);
      break;
    } catch {
      if (Date.now() - started >= timeoutMs) {
        throw new Error("agent-help operation lock timed out");
      }
      await sleep(50);
    }
  }
  try {
    return await callback();
  } finally {
    try {
      const currentIdentity = statSync(lockPath);
      if (
        currentIdentity.dev === lockIdentity.dev &&
        currentIdentity.ino === lockIdentity.ino
      ) {
        unlinkSync(lockPath);
      }
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
}
