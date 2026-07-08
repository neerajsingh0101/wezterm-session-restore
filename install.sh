#!/usr/bin/env bash
# Installs the Claude Code SessionStart hook for wezterm-session-restore.
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required (brew install jq)." >&2
  exit 1
}

HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"
cp "$(cd "$(dirname "$0")" && pwd)/hooks/wezterm-session-restore.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/wezterm-session-restore.sh"

cat <<'EOF'
Hook installed to ~/.claude/hooks/wezterm-session-restore.sh

Two manual steps remain:

1) Register the hook in ~/.claude/settings.json:

   "hooks": {
     "SessionStart": [
       { "hooks": [ { "type": "command",
           "command": "$HOME/.claude/hooks/wezterm-session-restore.sh" } ] }
     ]
   }

2) Add the plugin to your wezterm.lua:

   local session_restore = wezterm.plugin.require 'https://github.com/neerajsingh0101/wezterm-session-restore'
   session_restore.setup(config)

Layout saves every 60s; Ctrl+Opt+S saves on demand.
EOF
