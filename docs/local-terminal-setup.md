# Running many agent sessions at once

The expected workflow with `copilot-agent` is "one terminal window per
agent, 6-10 of them open at once across dual monitors, switching
between them to chat and approve actions." This doc covers the local
terminal-emulator setups that handle that workflow well — and the one
critical tmux config change that makes the difference between *finding*
the agent that needs your attention and *cycling through all of them
looking* for it.

The remote-from-phone case is covered separately in
[termius-snippets.md](termius-snippets.md). This doc is the desk setup.

## The one thing to turn on regardless of terminal

Add to `~/.tmux.conf` on the Mac that hosts the agents:

```
setw -g monitor-activity on
set  -g visual-activity  on
set  -g status-interval  2
```

What this does: when output appears in a backgrounded tmux window
(i.e. an agent you're not currently looking at), tmux flags that
window's tab in its status line *and* fires the terminal's bell. Every
mature terminal emulator below can then show that bell as a per-tab
indicator. You glance at the tab strip and immediately know which
agent is asking for approval.

Pick it up by either reattaching all your sessions or running
`tmux source-file ~/.tmux.conf` inside one of them — the setting is
server-wide.

## Recommended: iTerm2

```bash
brew install --cask iterm2
```

Why this is the well-trodden path: iTerm2 has tabs, split panes, native
tab-strip activity indicators, idle notifications, keyboard
tab-switching, and has had all of it for a decade.

Settings to flip (iTerm2 → Settings):

- **Profiles → Terminal → Silence bell** *off* (so tmux activity shows up)
- **Profiles → Terminal → Send notification when idle** *on* (macOS
  notification when an agent stops emitting output — i.e. has settled
  into "waiting for input")
- **Appearance → Tabs → Show activity indicator** *on*

Layout: one iTerm2 window per monitor, 5 tabs per window. `Cmd+1` …
`Cmd+9` jump tabs instantly. Each tab runs an SSH session that ends in
`copilot-agent <name>` — same mechanic Termius uses on your phone.

For the tall-thin-column visual you currently get with N Termius
windows, use **Cmd-D** (split right) inside one iTerm2 window to make
vertical columns instead of tabs. Activity indicators still work on
splits.

## Also good: WezTerm

```bash
brew install --cask wezterm
```

Native (Rust, not Electron), Lua config, slightly better font
rendering. Same tab + activity-indicator feature set as iTerm2. Pick
this if you prefer config-as-code over GUI preferences.

## Stay-in-Termius option

Termius does support tab groups and per-tab activity indicators in
recent versions. Easiest "smallest change" upgrade from N stand-alone
Termius windows:

1. Open all six agents as **tabs in one Termius window** instead of
   six separate windows.
2. Termius → Settings → Terminal → enable "Show activity indicator on
   inactive tabs" (exact label varies by version).
3. `Ctrl+Tab` / `Cmd+1..9` to switch.

You keep the Termius UI you already know, gain the tab strip, and lose
nothing.

## Less recommended

- **Pure tmux splits** (one tmux window split into 6 columns). Works,
  but window management is keyboard-only and you lose the
  "click-on-the-one-blinking" affordance you want for monitoring.
- **Warp**. AI-native terminal with a block UI. Looks cool but its
  AI features overlap awkwardly with Copilot CLI and the block UI eats
  vertical space you need for agent output.
- **Mission Control / Stage Manager grouping of N Termius windows**.
  Works up to ~4 windows, breaks down past that.

## iPad / phone

- **iOS / iPadOS**: Termius is fine; Blink Shell is better
  (Mosh-quality reconnects, more keyboard-first design) if you spend a
  lot of time on iPad.
- Either way, you're connecting back to the same tmux sessions on the
  Mac, so the activity-monitor config above benefits you on mobile too.
