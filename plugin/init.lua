local wezterm = require 'wezterm'
local mux = wezterm.mux

-- wezterm-session-restore
--
-- Restores your WezTerm windows, tabs and panes after a restart — and
-- auto-resumes the Claude Code session each pane was running.
--
-- Layout save/restore is powered by MLFlexer/resurrect.wezterm. On top of
-- that, this plugin periodically snapshots which panes are running Claude
-- Code (joined with the per-pane session ids recorded by the SessionStart
-- hook shipped in hooks/wezterm-session-restore.sh) and, on gui-startup,
-- runs `claude --resume <id>` in the panes that had a session.

local M = {}

local state_dir = wezterm.home_dir .. '/.local/state/wezterm-session-restore/'
local manifest_path = state_dir .. 'claude-manifest.json'
local registry_dir = state_dir .. 'claude/'

local function basename(s)
  return string.gsub(s, '(.*[/\\])(.*)', '%2')
end

local function read_json(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local data = f:read '*a'
  f:close()
  local ok, parsed = pcall(wezterm.json_parse, data)
  if ok then
    return parsed
  end
  return nil
end

local function process_is_claude(info)
  if basename(info.name or '') == 'claude' then
    return true
  end
  for _, arg in ipairs(info.argv or {}) do
    if basename(arg) == 'claude' then
      return true
    end
  end
  -- claude may run as a descendant of a wrapper script that execs it under
  -- a waiting parent process
  for _, child in pairs(info.children or {}) do
    if process_is_claude(child) then
      return true
    end
  end
  return false
end

local function is_claude_pane(pane)
  local ok, info = pcall(function()
    return pane:get_foreground_process_info()
  end)
  if not ok or not info then
    return false
  end
  return process_is_claude(info)
end

-- Snapshot panes currently running Claude, keyed by the same coordinates and
-- cwd that resurrect.wezterm stores in its pane tree, so restored panes can
-- be matched back to their session.
local function build_manifest()
  local entries = {}
  local workspace = mux.get_active_workspace()
  for _, win in ipairs(mux.all_windows()) do
    if win:get_workspace() == workspace then
      for _, tab in ipairs(win:tabs()) do
        for _, p in ipairs(tab:panes_with_info()) do
          if is_claude_pane(p.pane) then
            local reg = read_json(registry_dir .. 'pane-' .. p.pane:pane_id() .. '.json')
            if reg and reg.session_id then
              local cwd = p.pane:get_current_working_dir()
              table.insert(entries, {
                left = p.left,
                top = p.top,
                cwd = cwd and cwd.file_path or '',
                session_id = reg.session_id,
                -- claude's own cwd can differ from the pane cwd (e.g.
                -- worktree sessions); restore cds there first
                session_cwd = reg.cwd,
                command = reg.command,
              })
            end
          end
        end
      end
    end
  end
  local f = io.open(manifest_path, 'w+')
  if f then
    f:write(wezterm.json_encode(entries))
    f:close()
  end
end

-- Exact match on saved position + cwd first; fall back to cwd alone so a
-- slightly shifted layout still resumes its sessions. Entries are consumed
-- so two panes never resume the same session.
local function claim_manifest_entry(manifest, pane_tree)
  for i, e in ipairs(manifest) do
    if e.left == pane_tree.left and e.top == pane_tree.top and e.cwd == pane_tree.cwd then
      table.remove(manifest, i)
      return e
    end
  end
  for i, e in ipairs(manifest) do
    if e.cwd == pane_tree.cwd then
      table.remove(manifest, i)
      return e
    end
  end
end

local function restore_last_session(resurrect)
  local f = io.open(state_dir .. 'state/current_state', 'r')
  if not f then
    return
  end
  local name = f:read '*line'
  local state_type = f:read '*line'
  f:close()
  if state_type ~= 'workspace' or not name then
    return
  end

  local state = resurrect.state_manager.load_state(name, 'workspace')
  if not state or not state.window_states then
    return
  end

  local manifest = read_json(manifest_path) or {}

  resurrect.workspace_state.restore_workspace(state, {
    spawn_in_workspace = true,
    relative = true,
    restore_text = true,
    on_pane_restore = function(pane_tree)
      local entry = claim_manifest_entry(manifest, pane_tree)
      if not entry then
        resurrect.tab_state.default_on_pane_restore(pane_tree)
        return
      end
      -- Claude runs on the alt screen, so the default restore would relaunch
      -- its saved argv as a fresh session (or re-run a wrapper script, with
      -- whatever side effects that has); resume the recorded session instead.
      if pane_tree.text then
        pane_tree.pane:inject_output(pane_tree.text:gsub('%s+$', ''))
      end
      local cmd = 'claude'
      if entry.command and entry.command:find('--dangerously-skip-permissions', 1, true) then
        cmd = cmd .. ' --dangerously-skip-permissions'
      end
      cmd = cmd .. ' --resume ' .. entry.session_id
      if entry.session_cwd and entry.session_cwd ~= '' and entry.session_cwd ~= pane_tree.cwd then
        cmd = "cd '" .. entry.session_cwd .. "' && " .. cmd
      end
      pane_tree.pane:send_text(cmd .. '\r')
    end,
  })
  mux.set_active_workspace(name)
end

---@param config table wezterm config builder
---@param opts? { save_interval_seconds?: integer, save_key?: {key: string, mods: string}|false }
function M.setup(config, opts)
  opts = opts or {}

  local resurrect = wezterm.plugin.require 'https://github.com/MLFlexer/resurrect.wezterm'

  resurrect.state_manager.change_state_save_dir(state_dir .. 'state/')
  resurrect.state_manager.periodic_save {
    interval_seconds = opts.save_interval_seconds or 60,
    save_workspaces = true,
  }

  wezterm.on('resurrect.state_manager.periodic_save.finished', function()
    resurrect.state_manager.write_current_state(mux.get_active_workspace(), 'workspace')
    pcall(build_manifest)
  end)

  -- Save on demand, e.g. right before a planned restart. Pass
  -- `save_key = false` to disable, or your own `{key, mods}` to rebind.
  local save_key = opts.save_key
  if save_key == nil then
    save_key = { key = 's', mods = 'CTRL|OPT' }
  end
  if save_key then
    config.keys = config.keys or {}
    table.insert(config.keys, {
      key = save_key.key,
      mods = save_key.mods,
      action = wezterm.action_callback(function(window, pane)
        resurrect.state_manager.save_state(resurrect.workspace_state.get_workspace_state())
        resurrect.state_manager.write_current_state(mux.get_active_workspace(), 'workspace')
        pcall(build_manifest)
        window:toast_notification('wezterm', 'Session saved', nil, 2000)
      end),
    })
  end

  wezterm.on('gui-startup', function()
    local ok, err = pcall(restore_last_session, resurrect)
    if not ok then
      wezterm.log_error('wezterm-session-restore: restore failed: ' .. tostring(err))
    end
    if #mux.all_windows() == 0 then
      mux.spawn_window {}
    end
  end)
end

return M
