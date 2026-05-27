# Troubleshooting

Every footgun we hit, with the working fix.

## Tailscale / DNS

### Short hostnames (`macbook-air`) resolve, FQDNs (`macbook-air.<tailnet>.ts.net`) don't

Homebrew's `tailscaled` doesn't install a resolver entry for the `ts.net`
domain. `install.sh` writes `/etc/resolver/ts.net` to fix this. If you've
already run the installer and it's still broken:

```bash
# Confirm the file exists and has the right content
sudo cat /etc/resolver/ts.net
# Expected:
#   nameserver 100.100.100.100
#   search_order 1
#   timeout 5

# Verify macOS sees it
scutil --dns | grep -A4 'domain   : ts.net'
# Should show nameserver[0] : 100.100.100.100

# Force-refresh
sudo dscacheutil -flushcache
```

`dig` and `host` bypass macOS's resolver — they'll still return NXDOMAIN
even when everything is working. Verify with `dscacheutil -q host -a name
<fqdn>` instead.

### Short hostnames broken after manual cleanup

There's a second resolver file, `/etc/resolver/search.tailscale`, that
`tailscaled` generates on startup. It's a 52-byte stub for a pseudo
search domain — it *looks* dead but it's load-bearing for short-name
resolution. **Don't delete it.** If you already did:

```bash
sudo brew services restart tailscale
```

That re-creates it.

### `tailscale set --ssh` says "Tailscale SSH server does not run in
sandboxed Tailscale GUI builds"

You have the App Store or macsys Tailscale build installed. Replace it
with the open-source CLI build:

```bash
# Quit the GUI app first.
brew install tailscale
sudo brew services start tailscale
sudo tailscale up --ssh
```

## tmux

### Files outside ~/ are "Operation not permitted" inside tmux

tmux needs Full Disk Access — see `fda-grants.md`. Symptom is specific
to tmux: `ls ~/Library/CloudStorage/Dropbox` works in a plain SSH shell
and fails inside `tmux new-session`.

### tmux session disappears after Mac reboots

tmux sessions are in-memory; they don't survive reboots. The wrapper
calls `copilot --resume=<Name>` on next launch, which restores the
Copilot CLI conversation, but tmux history (scrollback) is gone.

## Copilot CLI

### Asks "store token in plain text config file?" on every launch

Answer "Yes". Reasoning: the Copilot CLI defaults to the macOS keychain,
which is unreliable over SSH — the keychain prompts the GUI for unlock,
which there's no human to dismiss, and the keychain remains locked. The
plaintext fallback lives at `~/.copilot/config.json` with mode 0600,
inside the FileVault-encrypted home volume. The risk delta over the
keychain is small; the operational benefit is large.

### `copilot --remote` exits immediately with no UI

`--remote` is correct (we tried `--remote on` first; that's a different
mode). The most common cause is the binary not being on PATH inside
tmux. Sanity check from inside an active tmux session:

```bash
which copilot
echo "$PATH"
```

If `which copilot` is empty, either install Copilot CLI to a standard
PATH location or add its install dir to `~/.zshenv` so non-login shells
see it. `~/.zshrc` is *not* enough — tmux launches non-login,
non-interactive shells for `send-keys`.

## Keychain

### Credential prompts inside tmux over SSH

The wrapper calls `security unlock-keychain` once before starting the
new tmux session. That unlocks the login keychain for the whole user
session, so anything launched inside tmux (`gh`, `git`, `ssh-add`, the
AWS CLI, Slack tokens, etc.) can read its stored secrets normally.

If the keychain re-locks later (e.g., the machine sleeps, or you have a
short idle-lock policy), just run `security unlock-keychain` once inside
tmux. Type your login password and you're back in business.

## Termius

### Pasting from phone corrupts multi-line snippets with null bytes

Termius's iOS clipboard handler occasionally injects `^@` (null) bytes
into pasted content. Symptom is commands silently failing or only
running the first line of a heredoc.

This was the original motivation for replacing the multi-line shell
snippet with the single-line `copilot-agent <Name>` wrapper. If you
still need to paste something multi-line from your phone, put it in a
text file (TextEdit, Dropbox-synced) and `cat` it on the Mac instead.

## Managed devices

### macOS keeps disabling Remote Login / Screen Sharing

This was the original reason for the now-removed `watchdog` daemon. If
you see this again on this stack, **don't bring the watchdog back** —
it fought with MDM and lost. Switch to Tailscale SSH (`sudo tailscale up
--ssh`) which is what this stack uses, and let macOS's built-in Remote
Login stay off.
