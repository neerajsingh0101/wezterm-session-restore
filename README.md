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

**1. Install `jq`**

The Claude Code hook in step 3 depends on it; without it, sessions are
silently not tracked:

```sh
brew install jq   # or your distro's package manager
```

**2. Add the plugin to your WezTerm config**

Check if you have `~/.config/wezterm/wezterm.lua` or `~/.wezterm.lua`. If you
have both, use the first one — that's the one WezTerm will choose. If you have
neither, create `~/.config/wezterm/wezterm.lua`.

If you are creating the file from scratch, add all of the following lines. If
you already have a config file, just add the two `session_restore` lines
before `return config`:

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

local session_restore = wezterm.plugin.require 'https://github.com/neerajsingh0101/wezterm-session-restore'
session_restore.setup(config)

return config
```

**3. Add the Claude Code hook**

This is what the `wezterm-session-restore` script does. Each time a Claude Code session starts, this script
records the session id and working directory against the WezTerm pane it is
running in — after a restart, the plugin reads those records to resume the
right session in the right pane.

First, let's download this script.

```sh
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/neerajsingh0101/wezterm-session-restore/main/hooks/wezterm-session-restore.sh \
  -o ~/.claude/hooks/wezterm-session-restore.sh
```

Downloading alone does nothing yet. Claude Code only runs hooks that are
registered in `~/.claude/settings.json`. The next command registers it. It is safe to run the next command more than once.

```sh
[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
grep -q wezterm-session-restore ~/.claude/settings.json || {
  jq '.hooks.SessionStart = (.hooks.SessionStart // []) + [{"hooks":[{"type":"command","command":"bash $HOME/.claude/hooks/wezterm-session-restore.sh"}]}]' \
    ~/.claude/settings.json > ~/.claude/settings.json.tmp && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
}
```

Now let's check whether things are looking good.
Execute the next command and ensure that it prints the hook line you just
registered.

```sh
grep wezterm-session-restore ~/.claude/settings.json
```

Prefer editing by hand? The command above simply adds this entry to the
`hooks.SessionStart` array:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash $HOME/.claude/hooks/wezterm-session-restore.sh"
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

There are three moving parts: a hook that records which Claude session lives
in which pane, a periodic snapshot of your layout, and a restore step that
puts the two back together after a restart.

### 1. Recording sessions (the hook, event-driven)

WezTerm sets a `WEZTERM_PANE` environment variable in every pane, and every
process started in that pane inherits it — including Claude Code and,
crucially, the hook scripts Claude Code runs.

Claude Code fires the `SessionStart` hook every time a session begins — a
fresh `claude`, a `claude --resume`, or a `/clear`. When it fires, the hook
script knows two things at once: which session just started (Claude passes
the session id and working directory on stdin) and which pane it happened in
(`$WEZTERM_PANE`). It writes them to one small file per pane:

```json
// ~/.local/state/wezterm-session-restore/claude/pane-42.json
{
  "session_id": "3f9c2a71-...",
  "cwd": "/Users/you/code/my-project",
  "command": "claude --dangerously-skip-permissions"
}
```

The `session_id` is what `claude --resume` needs later. The `cwd` is Claude's
own working directory, which is not always the pane's directory (worktree
sessions, for example). The `command` preserves flags like
`--dangerously-skip-permissions`. Because the hook fires on every session
start, these files are always current — nothing polls, nothing goes stale.

### 2. Snapshotting the layout (the plugin, every 60 seconds)

On a timer, resurrect.wezterm walks all your windows, tabs and panes and
saves their arrangement — split geometry, working directories, scrollback —
to JSON state files.

Right after each snapshot, this plugin walks the same panes and asks WezTerm
what each one is running. A pane counts as a Claude pane if its foreground
process — or any descendant of it — is `claude` (the descendant check is what
makes sessions started through wrapper scripts work). For every Claude pane
it finds, it reads that pane's file from step 1 and writes everything into
one manifest: pane position, pane directory, session id, session directory,
and command line.

Why store positions and directories instead of pane ids? Because pane ids do
not survive a restart — WezTerm hands out fresh ids on every launch. The
manifest therefore describes panes by the things that *do* survive: where the
pane was and what directory it was in.

### 3. Restoring (on WezTerm startup)

When WezTerm starts, the plugin reads the last snapshot and rebuilds it:
windows, tabs, splits, working directories. Plain shell panes get their
scrollback re-injected.

Then each restored pane is matched against the manifest — exact position +
directory first, directory alone as a fallback, and each manifest entry is
used at most once. For a matched pane, the plugin does *not* do what
resurrect.wezterm would do by default (relaunch the saved command, which
would start a brand-new Claude session). Instead it types
`cd <session-cwd> && claude --resume <session-id>` into the pane — the `cd`
covers worktree sessions — so Claude reopens the exact conversation that was
there before the restart. Panes with no manifest entry get the default
restore behaviour.

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
