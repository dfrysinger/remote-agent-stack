# Tailscale setup

This stack uses [Tailscale](https://tailscale.com) for the network layer
and [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) as the
SSH server (replacing macOS's built-in Remote Login). Tailscale SSH is
identity-based, so on a managed Mac where MDM keeps disabling Remote
Login, this is the only stable way in.

If you already have a tailnet with Tailscale SSH working from your phone
to your Mac, skip to the [resolver fix](#magicdns-resolver-fix).

## 1. Create a tailnet

If you don't have a Tailscale account yet:

1. Go to <https://login.tailscale.com/start> and sign up. The free
   personal plan covers everything in this stack.
2. Once you're in, you have a tailnet with a name like
   `tail-xxxx.ts.net` (Tailscale picks the name; you can rename it
   under [DNS settings](https://login.tailscale.com/admin/dns)).

<!-- SCREENSHOT: Tailscale admin DNS page showing the tailnet name and
     "Use HTTPS" / "MagicDNS" toggles, both ON. -->

## 2. Verify MagicDNS is on

[MagicDNS](https://tailscale.com/kb/1081/magicdns) is what makes
`macbook-air.tail-xxxx.ts.net` and the short name `macbook-air`
resolve from anywhere in your tailnet. New tailnets ship with MagicDNS
enabled by default — you just need to confirm:

1. Go to <https://login.tailscale.com/admin/dns>.
2. Confirm **MagicDNS** is on. If it's off (rare on a new tailnet),
   toggle it on.
3. (Recommended) Toggle **HTTPS Certificates** on — needed if you ever
   want a real TLS cert for a service on a tailnet host.

## 3. Install Tailscale on the Mac (Homebrew CLI build, not the GUI)

The Mac App Store / direct-download GUI Tailscale build is **sandboxed**
and `tailscale set --ssh` refuses to run inside it ("Tailscale SSH server
does not run in sandboxed Tailscale GUI builds"). You need the
open-source CLI build from Homebrew. The repo's `install.sh` does this
step for you, but if you're doing it by hand:

```bash
# If a GUI build is installed, quit it first, then:
brew install tailscale
sudo brew services start tailscale
```

The Homebrew tailscaled also needs the **MagicDNS resolver fix** (see
below) and **Full Disk Access** (see [`fda-grants.md`](fda-grants.md)).

## 4. Authenticate and enable Tailscale SSH

```bash
sudo tailscale up --ssh
```

This prints an auth URL. Open it in a browser, sign in to your
Tailscale account, and the Mac joins the tailnet. The `--ssh` flag is
what tells `tailscaled` to bind a Tailscale SSH server on `:22`.

## 5. Configure the ACL to allow SSH

Tailscale SSH **only** binds `:22` if the control-plane policy contains
at least one SSH rule that could apply to the node. Out of the box,
new tailnets have **zero** SSH rules — `tailscaled` will start, log
nothing about SSH, and `:22` will refuse connections.

Edit your ACL at <https://login.tailscale.com/admin/acls/file>. The
minimum rule that lets you (the tailnet owner) SSH into your own nodes
as any non-root user:

```json
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["autogroup:nonroot"]
    }
  ]
}
```

`tailscaled` picks up the new policy within seconds — no restart
needed. Verify it landed:

```bash
sudo tailscale debug netmap | python3 -c \
  'import json,sys; d=json.load(sys.stdin); p=d.get("SSHPolicy") or {}; \
   print("rules:", len(p.get("Rules",[])))'
```

`rules: 1` (or higher) means you're good.

## 6. MagicDNS resolver fix

Homebrew's `tailscaled` doesn't install a resolver entry for the
`ts.net` domain, so FQDNs like `macbook-air.tail-xxxx.ts.net` resolve
from your phone but not from the Mac itself. The repo's `install.sh`
writes `/etc/resolver/ts.net` to fix this.

If you ran `install.sh`, this is already done. To verify:

```bash
sudo cat /etc/resolver/ts.net
# nameserver 100.100.100.100
# search_order 1
# timeout 5

scutil --dns | grep -A4 'domain   : ts.net'
# nameserver[0] : 100.100.100.100
```

`dig` and `host` bypass macOS's resolver — they will still return
NXDOMAIN even when everything is fine. Test with `dscacheutil` instead:

```bash
dscacheutil -q host -a name macbook-air.tail-xxxx.ts.net
```

## 7. Install Tailscale on your iPhone

1. App Store: [Tailscale](https://apps.apple.com/app/tailscale/id1470499037).
2. Sign in with the same account you used for the Mac.
3. Tap the Tailscale toggle in the app to come online.

iOS Tailscale doesn't need any further configuration — once the toggle
is on, `macbook-air.tail-xxxx.ts.net` resolves and Termius can connect
to it.

<!-- SCREENSHOT: iPhone Tailscale app showing the connect toggle ON
     and the Mac listed as an online peer. -->

## Troubleshooting

If anything in this section misbehaves, the [troubleshooting
doc](troubleshooting.md) has the full set of footguns we hit:

- Short hostnames resolve, FQDNs don't (resolver fix)
- "Sandboxed Tailscale GUI build" error on `tailscale set --ssh`
- `Connection refused` on `:22` even with `RunSSH=true` (ACL rules)
- SSH from the host to its own tailnet IP refuses (expected; test from
  a peer)
