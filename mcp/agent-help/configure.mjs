#!/usr/bin/env node

import { readConfig, writeConfig } from "./core.mjs";

const options = {};
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith("--") || value === undefined) {
    throw new Error("configure.mjs requires --key value pairs");
  }
  options[key.slice(2)] = value;
}

let existing = {};
try {
  existing = readConfig();
} catch (error) {
  if (!String(error?.message).includes("ENOENT")) throw error;
}

writeConfig({
  recipient: options.recipient ?? existing.recipient,
  deskDisplayCount: Number(options["desk-display-count"] ?? existing.deskDisplayCount ?? 3),
  screenSharingHours: Number(
    options["screen-sharing-hours"] ?? existing.screenSharingHours ?? 1,
  ),
  screenSharingPort: Number(
    options["screen-sharing-port"] ?? existing.screenSharingPort ?? 15900,
  ),
});
process.stdout.write("Agent help private configuration updated.\n");
