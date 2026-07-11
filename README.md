# wezterm-session-restore

Restart your machine without losing your terminal. 

This WezTerm plugin
restores your **windows, tabs, panes, working directories and scrollback**
after a restart — and **auto-resumes the Claude Code session** each pane was
running, so `claude` comes back exactly where you left off.

Layout persistence is powered by the excellent
[resurrect.wezterm](https://github.com/MLFlexer/resurrect.wezterm). This
plugin adds the missing piece: knowing *which Claude session lived in which
pane* and resuming it automatically.

## What you get

- Layout snapshots every 60 seconds (configurable), plus save-on-demand with
  `Ctrl+Opt+S` (see [Saving](#saving)).
- On WezTerm startup, your windows/tabs/splits come back with their working
  directories; plain shell panes get their scrollback re-injected.
- Panes that were running Claude Code re-run `claude --resume <session-id>`
  automatically — including sessions started through wrapper scripts, and
  sessions whose working directory was a git worktree.
- `--dangerously-skip-permissions` is preserved if the original session used it.

## Installation

**1. WezTerm config** — in `~/.config/wezterm/wezterm.lua` (or `~/.wezterm.lua`):

```lua
local session_restore = wezterm.plugin.require 'https://github.com/neerajsingh0101/wezterm-session-restore'
session_restore.setup(config)
```

**2. Claude Code hook** — clone this repo and run:

```sh
./install.sh
```

(or copy `hooks/wezterm-session-restore.sh` to `~/.claude/hooks/` yourself and
make it executable), then register it in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/wezterm-session-restore.sh"
          }
        ]
      }
    ]
  }
}
```

That's it. Sessions started from now on are tracked; after your next restart,
reopen WezTerm and watch everything come back.

## Saving

Saving is automatic: every 60 seconds the plugin snapshots your full layout
and which Claude session each pane is running. If your machine restarts
unexpectedly (a crash, a forced update), you lose at most the last minute of
layout changes — session ids are recorded the moment a session starts, so
those are never stale.

Because of that interval, the latest automatic snapshot can be up to a minute
old — a tab you opened or a Claude session you started 30 seconds ago may not
be in it yet. That's what save-on-demand is for: before a *planned* restart,
press `Ctrl+Opt+S`. It takes the same snapshot immediately and confirms with a
"Session saved" notification, so the restore reflects the exact moment you
left. The save interval and keybinding are configurable:
`session_restore.setup(config, { save_interval_seconds = 60, save_key = false })`.

## How it works

1. The `SessionStart` hook records `{session_id, cwd, command}` per WezTerm
   pane under `~/.local/state/wezterm-session-restore/claude/` — event-driven,
   so it is always current.
2. Every save interval, resurrect.wezterm snapshots the layout, and this
   plugin writes a manifest of panes whose foreground process (or one of its
   descendants) is `claude`, joined with the recorded session ids.
3. On `gui-startup`, the layout is rebuilt; panes with a manifest entry run
   `cd <session-cwd> && claude --resume <id>` instead of the default process
   relaunch, so you resume the conversation rather than starting a fresh one.

## Caveats

- An unplanned restart loses at most the last save interval of *layout*
  changes; session ids are recorded the moment a session starts.
- Resuming restores the conversation, not in-flight work — anything that was
  mid-tool-call restarts from the conversation point.
- Claude Code runs on the alternate screen, so Claude panes come back without
  scrollback (Claude redraws on resume); plain shell panes keep theirs.
- Two Claude panes at the same position in the same directory may swap
  sessions on restore (both still resume).
- Running `claude -p ...` inside a pane that also hosts an interactive Claude
  temporarily points that pane's registry entry at the one-off session.

## Roadmap

- Codex CLI support (`codex resume <id>`) via Codex hooks.

## Credits

Layout save/restore by
[MLFlexer/resurrect.wezterm](https://github.com/MLFlexer/resurrect.wezterm).
Since the upstream repo is archived, this plugin depends on a
[fork](https://github.com/neerajsingh0101/resurrect.wezterm) to guarantee the
dependency stays available — all credit for it belongs to MLFlexer.

## License

[MIT](LICENSE)
