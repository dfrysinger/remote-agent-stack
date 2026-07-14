# Full Disk Access grants

macOS Ventura and later sandbox most processes from reading user data
unless the binary's bundle ID is on the Full Disk Access (FDA) allow-list.
For this stack, two binaries need the grant — `tailscaled` and `tmux`.

## Why each one needs it

### `tailscaled`

The Homebrew Tailscale daemon needs FDA to:
- Write its state file under `/Library/Tailscale/` (Homebrew variant).
- Read system DNS configuration when MagicDNS is in mixed-mode with the
  system resolver.

Symptom if missing: `tailscale up` succeeds but `tailscale status` lists
the node as offline shortly after, or MagicDNS lookups intermittently
fail.

### `tmux`

Once you SSH in over Tailscale and exec into a tmux session, every
process running inside that tmux inherits tmux's sandbox profile. If tmux
itself doesn't have FDA, then `git`, `gh`, Copilot CLI, Claude Code
CLI, etc. will all be quietly blocked from reading files in protected
locations (Desktop,
Documents, Downloads, iCloud Drive, Dropbox under
`~/Library/CloudStorage/`).

Symptom if missing: `ls ~/Library/CloudStorage/Dropbox/...` works in a
plain SSH shell but returns "Operation not permitted" inside tmux.

## How to grant

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click **+**.
3. Press **⌘⇧G** in the file picker and paste the *real* binary path
   (the Cellar path, not the symlink under `bin/`). On Apple silicon:

   ```text
   /opt/homebrew/Cellar/tailscale/<version>/bin/tailscaled
   /opt/homebrew/Cellar/tmux/<version>/bin/tmux
   ```

   To get the exact current paths:

   ```bash
   readlink -f "$(brew --prefix tailscale)/bin/tailscaled"
   readlink -f "$(brew --prefix tmux)/bin/tmux"
   ```

4. Toggle each entry **on**.

## After upgrades

`brew upgrade tmux` (or tailscale) installs into a new Cellar version
directory, which has a different binary the FDA list doesn't know about.
You'll need to:

1. Add the new path to the FDA list using the steps above.
2. Optionally remove the stale (old-version) entry — it does no harm,
   just clutter.

This is the only meaningful piece of operational toil with this stack.
There's no API to do it programmatically without an MDM profile.
