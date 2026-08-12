import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  agentHelpPaths,
  buildMessage,
  checkSendAllowed,
  countOnlineDisplays,
  DEDUPLICATION_MS,
  MAX_SENDS_PER_HOUR,
  readConfig,
  recordSend,
  screensUrl,
  shouldEnableRemoteAccess,
  withOperationLock,
  writeConfig,
} from "./core.mjs";

test("builds an agent-identified bounded message", () => {
  assert.equal(
    buildMessage({
      agentName: "hotel",
      reason: "login_required",
      context: "Stafftools",
    }),
    "Agent hotel: I need a login for Stafftools. Open the Mac when available.",
  );
});

test("adds only a server-derived remote URL", () => {
  assert.equal(
    buildMessage({
      agentName: "hotel",
      reason: "login_required",
      context: "Stafftools",
      remoteAccessUrl: "screens://agent-mac.example.ts.net:15900",
    }),
    "Agent hotel: I need a login for Stafftools. Open the Mac when available. Screens is available temporarily: screens://agent-mac.example.ts.net:15900",
  );
});

test("rejects URLs, domains, credentials, controls, and unsupported characters", () => {
  for (const context of [
    "https://example.com",
    "example.com login",
    "(evil.com)",
    "see/evil.com",
    "tap (bit.ly/abcd)",
    "password abc",
    "secret value",
    "line\nbreak",
    "unicode \u2603",
  ]) {
    assert.throws(() =>
      buildMessage({ agentName: "hotel", reason: "blocked", context }),
    );
  }
});

test("detects only positively observed away displays", () => {
  const profile = {
    SPDisplaysDataType: [
      {
        spdisplays_ndrvs: [
          { spdisplays_online: "spdisplays_yes" },
          { spdisplays_online: "spdisplays_no" },
        ],
      },
    ],
  };
  assert.equal(countOnlineDisplays(profile), 1);
  assert.equal(countOnlineDisplays({ SPDisplaysDataType: [{}] }), null);
  assert.equal(
    countOnlineDisplays({
      SPDisplaysDataType: [{ spdisplays_ndrvs: [] }],
    }),
    0,
  );
  assert.equal(shouldEnableRemoteAccess(1, 3), true);
  assert.equal(shouldEnableRemoteAccess(3, 3), false);
  assert.equal(shouldEnableRemoteAccess(0, 3), false);
  assert.equal(shouldEnableRemoteAccess(null, 3), false);
});

test("derives Screens URL from the Self.DNSName short name and configured port", () => {
  assert.equal(
    screensUrl(
      { Self: { DNSName: "agent-mac.example.ts.net." } },
      15900,
    ),
    "screens://agent-mac:15900",
  );
  assert.equal(screensUrl({ Self: { DNSName: "" } }, 15900), null);
  assert.equal(screensUrl({ Peer: { DNSName: "peer.ts.net." } }, 15900), null);
  assert.equal(
    screensUrl({ Self: { DNSName: "agent-mac.example.ts.net." } }, 70000),
    null,
  );
});

test("writes recipient configuration privately", () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-help-config-"));
  const path = join(directory, "agent-help", "config.json");
  writeConfig({ recipient: "owner@example.test", screenSharingPort: 15900 }, path);
  assert.deepEqual(readConfig(path), {
    recipient: "owner@example.test",
    deskDisplayCount: 3,
    screenSharingHours: 1,
    screenSharingPort: 15900,
  });
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.equal(statSync(join(directory, "agent-help")).mode & 0o777, 0o700);
});

test("deduplicates and rate limits sends", () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-help-state-"));
  const path = join(directory, "state.json");
  const start = 1_000_000;
  assert.deepEqual(checkSendAllowed("one", start, path), { allowed: true });
  recordSend("one", start, path);
  assert.deepEqual(checkSendAllowed("one", start + DEDUPLICATION_MS - 1, path), {
    allowed: false,
    reason: "duplicate",
  });
  for (let index = 1; index < MAX_SENDS_PER_HOUR; index += 1) {
    assert.deepEqual(checkSendAllowed(`message-${index}`, start + index, path), {
      allowed: true,
    });
    recordSend(`message-${index}`, start + index, path);
  }
  assert.deepEqual(checkSendAllowed("too-many", start + 100, path), {
    allowed: false,
    reason: "rate_limited",
  });
  assert.equal(JSON.parse(readFileSync(path, "utf8")).sends.length, MAX_SENDS_PER_HOUR);
});

test("corrupt state fails closed", () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-help-state-"));
  const path = join(directory, "state.json");
  writeFileSync(path, "{broken", "utf8");
  assert.throws(() => checkSendAllowed("one", Date.now(), path));
});

test("operation lock serializes concurrent sends", async () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-help-lock-"));
  const paths = agentHelpPaths(directory);
  mkdirSync(paths.directory, { recursive: true });
  const results = await Promise.all(
    Array.from({ length: 8 }, (_, index) =>
      withOperationLock(
        async () => {
          const message = `message-${index}`;
          const now = 1_000_000 + index;
          const result = checkSendAllowed(message, now, paths.state);
          if (result.allowed) recordSend(message, now, paths.state);
          return result;
        },
        { lockPath: paths.lock },
      ),
    ),
  );
  assert.equal(results.filter((result) => result.allowed).length, MAX_SENDS_PER_HOUR);
});

test("stale-lock reclamation has a single reclaimer", async () => {
  const directory = mkdtempSync(join(tmpdir(), "agent-help-stale-lock-"));
  const paths = agentHelpPaths(directory);
  mkdirSync(paths.directory, { recursive: true });
  writeFileSync(paths.lock, "999999\n");
  let active = 0;
  let maximumActive = 0;

  await Promise.all(
    Array.from({ length: 4 }, () =>
      withOperationLock(
        async () => {
          active += 1;
          maximumActive = Math.max(maximumActive, active);
          await new Promise((resolve) => setTimeout(resolve, 25));
          active -= 1;
        },
        { lockPath: paths.lock },
      ),
    ),
  );

  assert.equal(maximumActive, 1);
});
