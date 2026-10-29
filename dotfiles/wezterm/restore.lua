-- Restore-on-launch for WezTerm on Windows, as a module so it can be tested
-- on its own (a throwaway config can require it and call `restore` directly,
-- without the prompt). Loaded by wezterm-windows.lua; needs the resurrect
-- plugin passed in, so it never fetches it twice.
--
--   M.offer(window)        the startup prompt: Restore … / Start fresh
--   M.restore(window, st)  rebuild a saved workspace into `window`
--   M.is_claude(pane_tree) whether a saved pane was running Claude Code

local wezterm = require("wezterm")
local act = wezterm.action

return function(resurrect)
local M = {}

-- Offer the last session back on launch: "Restore 4 tabs — bujo, portfolio, …"
-- or start fresh. resurrect's periodic_save (above) writes the workspace every
-- 5 minutes and on unfocus, so after a reboot this is at most 5 minutes old.
-- Verified on Windows 2026-10-29: the state file held 4 tabs with their cwds
-- despite the plugin's 3 "syntax of the command" lines at launch.
-- Skipped when WezTerm was started WITH a command (`wezterm start -- …`), so a
-- scripted launch never stops at a prompt.
--
-- A pane that was running CLAUDE CODE comes back in its folder with a note
-- printed in it — the commands to pick up where you left off — and NOTHING
-- run for you: copy one, edit it, or ignore it (owner's call: "give the user
-- more flexibility"). The note is `inject_output`, i.e. drawn, never typed
-- into the shell.
--
-- The saved "process" is the pane's deepest foreground child, which for a
-- Claude pane is one of its MCP servers (measured: `node …chrome-devtools-mcp.js`,
-- `node …shadcn… mcp`) — so a pane counts as Claude when the argv mentions
-- claude OR mcp. That is also why the plugin's default restore is NOT used for
-- those panes: for an alt-screen pane it retypes the saved argv, which here
-- would have started a bare MCP server in the shell. Other alt-screen apps
-- (vim, htop) still get the default; plain shells get their scrollback back.
function M.is_claude(pt)
  local p = pt and pt.process
  if not p then return false end
  local argv = table.concat(p.argv or {}, " "):lower()
  return (p.name or ""):lower():match("^claude") ~= nil or argv:match("claude") ~= nil or argv:match("mcp") ~= nil
end

local function count_claude(pt)
  if not pt then return 0 end
  return (M.is_claude(pt) and 1 or 0) + count_claude(pt.right) + count_claude(pt.bottom)
end

local DIM, BOLD, RESET = "\27[2m", "\27[1m", "\27[0m"
local CLAUDE_NOTE = table.concat({
  "",
  DIM .. "── restored · Claude Code was running here ──" .. RESET,
  "  latest code     " .. BOLD .. "git pull --ff-only" .. RESET,
  "  last session    " .. BOLD .. "claude --continue" .. RESET,
  "  pick a session  " .. BOLD .. "claude --resume" .. RESET,
  DIM .. "  nothing was run — copy what you want" .. RESET,
  "",
}, "\r\n") .. "\r\n"

-- Delayed, because on Windows a new pane's ConPTY clears the screen when the
-- shell starts: injected straight away, the note was drawn and then wiped
-- (validated 2026-10-29 — `wezterm cli get-text` showed only the prompt).
-- Two seconds lets pwsh draw its prompt first; the note lands under it.
local SHELL_SETTLE_S = 2

local function restore_pane(pt)
  wezterm.time.call_after(SHELL_SETTLE_S, function()
    if M.is_claude(pt) then
      pt.pane:inject_output(CLAUDE_NOTE)
    else
      resurrect.tab_state.default_on_pane_restore(pt)
    end
  end)
end

-- Drop tabs with no folder, and windows left empty. A WezTerm "Configuration
-- Error" window is saved like any other but has no cwd, so restoring it only
-- added a stray tab (seen 2026-10-29 as a sixth tab labelled "~").
function M.clean(state)
  local windows = {}
  for _, w in ipairs(state.window_states or {}) do
    local tabs = {}
    for _, t in ipairs(w.tabs or {}) do
      if t.pane_tree and (t.pane_tree.cwd or "") ~= "" then table.insert(tabs, t) end
    end
    if #tabs > 0 then
      w.tabs = tabs
      table.insert(windows, w)
    end
  end
  state.window_states = windows
  return state
end

local HOME = (wezterm.home_dir or ""):gsub("\\", "/"):gsub("/+$", ""):lower()

local function short(cwd)
  local path = cwd:gsub("\\", "/"):gsub("/+$", "")
  if path:lower() == HOME then return "~" end
  return path:match("([^/]+)$") or "~"
end

function M.offer(window)
  local ws = wezterm.mux.get_active_workspace()
  local ok, state = pcall(resurrect.state_manager.load_state, ws, "workspace")
  if not ok or not state or not state.window_states then return end
  state = M.clean(state)
  local names, claude = {}, 0
  for _, w in ipairs(state.window_states) do
    for _, t in ipairs(w.tabs) do
      table.insert(names, short(t.pane_tree.cwd))
      claude = claude + count_claude(t.pane_tree)
    end
  end
  if #names == 0 then return end
  local gui, pane = window:gui_window(), window:active_pane()
  if not gui or not pane then return end
  local label = "Restore " .. #names .. " tab" .. (#names == 1 and "" or "s") .. " — " .. table.concat(names, ", ")
  if claude > 0 then label = label .. "  · Claude notes in " .. claude end
  gui:perform_action(act.InputSelector({
    title = "Restore last session?",
    choices = { { id = "restore", label = label }, { id = "fresh", label = "Start fresh" } },
    action = wezterm.action_callback(function(_, _, id)
      if id ~= "restore" then return end
      M.restore(window, state)
    end),
  }), pane)
end

-- `close_open_tabs`: every saved tab is spawned fresh IN ITS OWN FOLDER and
-- the startup tab is closed. Without it the plugin reuses the startup tab for
-- saved tab 1, which is already open in the launch folder — so the first
-- tab's path was silently lost (validated: it came back in C:/Users/PRANAS).
function M.restore(window, state)
  resurrect.workspace_state.restore_workspace(state, {
    window = window,
    close_open_tabs = true,
    relative = true,
    restore_text = true,
    on_pane_restore = restore_pane,
  })
end

return M
end
