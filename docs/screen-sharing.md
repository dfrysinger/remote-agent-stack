# Screen Sharing (GUI access)

Tailscale SSH + `tmux` gets you the terminal agents. Sometimes you also
need the **graphical** desktop — to seed a permission grant, click a GUI
the agent can't reach, or watch a dev app live from your phone. This is
the macOS Screen Sharing path (the built-in VNC server the **Screens**
app and Finder's "Screen Sharing" connect to), tunnelled over Tailscale.

Two small scripts live in [`bin/`](../bin):

- **`ss`** — toggle Screen Sharing on/off with an auto-off lease, and
  forward it over the tailnet with `tailscale serve`.
- **`vncfix`** — recover the "connected, but black screen + cursor"
  symptom.

## Install onto PATH

The installer symlinks `copilot-agent`/`ca` but not these. Symlink them
yourself (or copy into `~/bin`):

```bash
ln -sf "$PWD/bin/ss"     /usr/local/bin/ss
ln -sf "$PWD/bin/vncfix" /usr/local/bin/vncfix
```

Both resolve their own path at runtime, so either location works.

## `ss` — toggle Screen Sharing

```
ss on [HOURS]   # default 1 hour; turns Screen Sharing ON, schedules auto-off
ss off          # turn OFF now + cancel any pending auto-off
ss status       # daemon state, port 5900 listener, serve mapping, capture-grant check
```

`ss on` does four things:

1. Stops Remote Management (ARD) — it shares port 5900 and breaks Screens auth.
2. Bootstraps + enables the `com.apple.screensharing` LaunchDaemon.
3. Maps `tailnet:15900 → localhost:5900` via `tailscale serve`.
4. Arms a background lease that runs `ss off` after `HOURS`, so access
   never silently stays open.

It auto-disables Screen Sharing again at the lease deadline. Re-run
`ss on` to extend.

### Connect from Screens

`ss on` prints the connect target — this host's MagicDNS name on port
`15900`. On a host whose inbound IPv4 is blackholed (see below), use the
IPv6 form it also prints:

```
vnc://[fd7a:115c:a1e0::xxxx:xxxx]:15900
```

## Black screen + cursor → `vncfix`

You connect, see the **cursor** move, but the rest is **black**. Two causes:

1. **Daemon/clamshell glitch** — the screen-sharing daemon + per-user
   `ScreensharingAgent` need a kick. `vncfix` restarts both; Screens
   refreshes in a couple seconds.
2. **Missing Screen Recording grant** — macOS 14+ captures the
   framebuffer via ScreenCaptureKit, which needs the screen-sharing
   agent to hold a ScreenCapture (Screen Recording) TCC grant. Without
   it the agent logs `Cannot get shareable content` and you get
   cursor-over-black. **This cannot be fixed from a shell** (SIP blocks
   all writes to `TCC.db`, and the grant needs interactive admin auth).

`vncfix` does the daemon/agent restart, then scans the agent log; if it
finds the Screen-Recording denial it explains the manual fix and opens
System Settings → Sharing for you:

> System Settings → General → Sharing → toggle **Screen Sharing** OFF,
> wait 2s, toggle it back ON (authenticate when asked).

On a **fresh Mac** this grant has never been seeded, so the first
Screens connect is almost always black until you do this once. After
that it persists. If you're fully remote with no way to authenticate,
power on the JetKVM and do it through that.

## Gotcha: inbound IPv4 blackhole on managed Macs

On some Jamf/MDM-managed Macs, inbound Tailscale **IPv4**
(`100.64.0.0/10`) is silently dropped — ping and TCP both time out —
while **IPv6** works fully. This persists across `tailscaled` restarts
and reboots; it's an enforced packet filter, not wedged daemon state.

Symptom: you can SSH/connect **out** fine, and other nodes are
reachable, but nothing can reach **this** host on its `100.x` address.

Workaround: reach the host over its `fd7a:…` IPv6 address (Screens,
SSH, `tailscale serve` all work over v6). A real fix needs an IT/MDM
exception for the tailnet CIDR.

## Going dark without locking or breaking screenshots

If you keep the Mac awake (e.g. Amphetamine) so agents can screenshot
dev apps for you, but want the physical displays **off** for privacy:

- **Don't** let the display sleep or the screensaver fire — an MDM
  policy may lock immediately on display-off, and a locked screen is all
  the agents would capture.
- **Don't** lower the requirement to "all displays off" — if the
  framebuffer tears down (every display powered off/disconnected with no
  internal panel), captures go genuinely black.

The clean setup uses the **JetKVM as an always-on virtual display**:

- The JetKVM is an HDMI capture device with EDID, so macOS always sees
  it as a real attached display. Keep it plugged in.
- Leave it in **Mirror** mode (not Extended). Mirror means remote
  control through the JetKVM shows your real desktop, and when you power
  off the external monitors the mirror set collapses onto the
  JetKVM — a display is still attached, so the Mac never hits
  "all displays off" (no lock) and the framebuffer stays alive
  (screenshots keep working).
- Agent screenshots are taken **per-window**
  (`screencapture -x -o -l<winid>`), which reads the WindowServer
  backing store and is display-agnostic — it works regardless of which
  display a window is on, or whether any monitor is powered.

Net: power the external monitors off on a timer; keep the JetKVM
connected in Mirror; keep Amphetamine suppressing display-sleep so the
JetKVM display itself never sleeps.
