-- WezTerm — WINDOWS variant.            install → %USERPROFILE%\.wezterm.lua
--
-- The Linux config is chezmoi/dot_wezterm.lua. This is a SEPARATE file, not a
-- template, because the two diverge on the things that matter (shell, window
-- system, process spawning) and a template would bury that behind conditionals.
--
-- Everything agent-related is IDENTICAL to the Linux config on purpose: same
-- Leader+a layer, same keys, same quick-select. Muscle memory carries across
-- machines; only the plumbing underneath differs.
--
-- Windows deltas vs Linux:
--   shell         pwsh          (Linux: /bin/zsh --login)
--   agent spawn   pwsh -NoExit  (Linux: zsh -lc '...; exec zsh -l')
--   no enable_wayland / Flatpak handling — both are Linux-only concerns
--   launch menu   PowerShell / Git Bash / Python  (no zsh, no bash --login)

local wezterm = require("wezterm")
local act = wezterm.action

-- Session persistence across restarts/reboots. Same plugin as Linux; the first
-- load fetches from GitHub then caches locally. pcall so a failed fetch never
-- stops WezTerm from starting.
--
-- ⚠ KNOWN WINDOWS ISSUE, measured not guessed: loading this plugin prints
--   "The syntax of the command is incorrect." 3× on every launch. Isolated to
--   the plugin itself — a bare config prints 0, this plugin alone prints 3. It
--   is archived and shells out with POSIX syntax that cmd.exe rejects.
--   WezTerm still starts fine (exit 0) and the rest of the config is unaffected,
--   but SAVE/RESTORE (Leader+Shift+S / R) is UNVERIFIED on Windows — the failing
--   calls are likely how it enumerates its state directory. Treat Windows
--   session restore as "probably broken until you test it", and set
--   ok_resurrect = false below to silence the noise if you don't use it.
local ok_resurrect, resurrect = pcall(function()
  return wezterm.plugin.require("https://github.com/MLFlexer/resurrect.wezterm")
end)
if ok_resurrect then
  resurrect.state_manager.periodic_save({
    interval_seconds = 5 * 60,
    save_workspaces = true,
    save_windows = true,
    save_tabs = true,
  })
  -- No dedicated "window-closed" GUI event exists, but a window always loses
  -- focus as it closes — so saving on unfocus captures the layout right before
  -- it disappears.
  wezterm.on("window-focus-changed", function(window)
    if window and not window:is_focused() and ok_resurrect then
      resurrect.state_manager.save_state(resurrect.workspace_state.get_workspace_state())
    end
  end)
  wezterm.on("resurrect.error", function(err)
    wezterm.log_error("resurrect error: " .. tostring(err))
  end)
end

local config = wezterm.config_builder()

-- Performance
config.front_end = "WebGpu"
config.max_fps = 120
config.animation_fps = 120

-- Font. NOTE: this machine has "JetBrains Mono" but NOT the Nerd Font build, so
-- the Nerd Font family is listed first for other machines and falls through
-- here. Nerd glyphs still render: WezTerm ships a built-in "Symbols Nerd Font
-- Mono" and resolves icons like the robot glyph through it automatically.
-- Install JetBrainsMono Nerd Font if you want the icons metrically matched.
config.font = wezterm.font_with_fallback({
  { family = "JetBrainsMono Nerd Font", weight = "Medium" },
  { family = "JetBrains Mono", weight = "Medium" },
  "Cascadia Code",
  "Consolas",
})
config.font_size = 12.5
config.line_height = 1.15
config.harfbuzz_features = { "calt=1", "liga=1", "clig=1" }

-- Catppuccin Mocha
config.color_scheme = "Catppuccin Mocha"
config.window_background_opacity = 0.92
config.text_background_opacity = 0.9

config.window_background_gradient = {
  orientation = "Vertical",
  colors = { "#1e1e2e", "#181825", "#11111b" },
  interpolation = "Linear",
  blend = "Rgb",
}

-- Window
config.window_padding = { left = 8, right = 8, top = 6, bottom = 6 }
-- Window buttons drawn INSIDE the tab bar instead of a separate title bar.
-- Works the same on Windows as on GNOME. Drag empty tab-bar space to move.
config.window_decorations = "INTEGRATED_BUTTONS|RESIZE"
config.window_close_confirmation = "NeverPrompt"
config.initial_cols = 140
config.initial_rows = 38

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
local function is_claude(pt)
  local p = pt and pt.process
  if not p then return false end
  local argv = table.concat(p.argv or {}, " "):lower()
  return (p.name or ""):lower():match("^claude") ~= nil or argv:match("claude") ~= nil or argv:match("mcp") ~= nil
end

local function count_claude(pt)
  if not pt then return 0 end
  return (is_claude(pt) and 1 or 0) + count_claude(pt.right) + count_claude(pt.bottom)
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

local function restore_pane(pt)
  if is_claude(pt) then
    pt.pane:inject_output(CLAUDE_NOTE)
  else
    resurrect.tab_state.default_on_pane_restore(pt)
  end
end

local function offer_restore(window)
  if not ok_resurrect then return end
  local ws = wezterm.mux.get_active_workspace()
  local ok, state = pcall(resurrect.state_manager.load_state, ws, "workspace")
  if not ok or not state or not state.window_states then return end
  local names, claude = {}, 0
  for _, w in ipairs(state.window_states) do
    for _, t in ipairs(w.tabs or {}) do
      local cwd = t.pane_tree and t.pane_tree.cwd or ""
      table.insert(names, (cwd:gsub("[/\\]+$", ""):match("([^/\\]+)$")) or "~")
      claude = claude + count_claude(t.pane_tree)
    end
  end
  if #names == 0 then return end
  local gui, pane = window:gui_window(), window:active_pane()
  if not gui or not pane then return end
  local label = "Restore " .. #names .. " tab" .. (#names == 1 and "" or "s") .. " — " .. table.concat(names, ", ")
  if claude > 0 then label = label .. "  (Claude resume commands shown in " .. claude .. ")" end
  gui:perform_action(act.InputSelector({
    title = "Restore last session?",
    choices = { { id = "restore", label = label }, { id = "fresh", label = "Start fresh" } },
    action = wezterm.action_callback(function(_, _, id)
      if id ~= "restore" then return end
      resurrect.workspace_state.restore_workspace(state, {
        window = window,
        relative = true,
        restore_text = true,
        on_pane_restore = restore_pane,
      })
    end),
  }), pane)
end

wezterm.on("gui-startup", function(cmd)
  local _, _, window = wezterm.mux.spawn_window(cmd or {})
  window:gui_window():maximize()
  if not (cmd and cmd.args) then pcall(offer_restore, window) end
end)

-- Window management: snap to screen halves, maximize, restore.
local function active_screen()
  local screens = wezterm.gui.screens()
  return screens.active or screens.main
end

local function snap_half(window, side)
  local s = active_screen()
  if not s then return end
  local gw = window:gui_window()
  local half = math.floor(s.width / 2)
  gw:set_inner_size(half, s.height)
  if side == "left" then
    gw:set_position(s.x, s.y)
  else
    gw:set_position(s.x + half, s.y)
  end
end

wezterm.on("snap-left", function(window) snap_half(window, "left") end)
wezterm.on("snap-right", function(window) snap_half(window, "right") end)
wezterm.on("snap-center", function(window)
  local s = active_screen()
  if not s then return end
  local gw = window:gui_window()
  local w = math.floor(s.width * 0.6)
  local h = math.floor(s.height * 0.7)
  gw:set_inner_size(w, h)
  gw:set_position(s.x + math.floor((s.width - w) / 2), s.y + math.floor((s.height - h) / 2))
end)
wezterm.on("win-maximize", function(window) window:gui_window():maximize() end)
wezterm.on("win-restore", function(window) window:gui_window():restore() end)

wezterm.on("toggle-tab-bar", function(window)
  local overrides = window:get_config_overrides() or {}
  overrides.enable_tab_bar = not (overrides.enable_tab_bar == false) and false or true
  window:set_config_overrides(overrides)
end)

wezterm.on("toggle-opacity", function(window)
  local overrides = window:get_config_overrides() or {}
  if overrides.window_background_opacity == 1.0 then
    overrides.window_background_opacity = nil
  else
    overrides.window_background_opacity = 1.0
  end
  window:set_config_overrides(overrides)
end)

-- Tab titles: index + process icon + title, active tab in Mauve, [Z] when zoomed.
local PROC_ICONS = {
  ["nvim"] = " ",
  ["vim"] = " ",
  ["git"] = " ",
  ["lazygit"] = " ",
  ["python"] = " ",
  ["python3"] = " ",
  ["node"] = " ",
  ["docker"] = " ",
  ["ssh"] = " ",
  ["btop"] = " ",
  ["zellij"] = " ",
  ["pwsh"] = " ",
  ["powershell"] = " ",
  ["bash"] = " ",
  ["cmd"] = " ",
  ["claude"] = "󰚩 ",
  ["herdr"] = "󰕰 ",
}

local function tab_title(tab)
  local title = tab.tab_title
  if title and #title > 0 then return title end
  return tab.active_pane.title
end

wezterm.on("format-tab-title", function(tab, _tabs, _panes, _cfg, _hover, max_width)
  -- Windows process names carry a .exe suffix and a backslash path; strip both
  -- so the icon table (which keys on bare names) matches.
  local proc = (tab.active_pane.foreground_process_name or "")
    :gsub(".*[/\\]", ""):gsub("%.exe$", "")
  local icon = PROC_ICONS[proc] or " "
  local zoom = tab.active_pane.is_zoomed and " [Z]" or ""
  local title = tab_title(tab)
  -- Claude Code is a Node wrapper, so it usually reports as "node" and the
  -- lookup above misses it. Fall back to the pane title, which carries "claude".
  if not PROC_ICONS[proc] and title:lower():find("claude", 1, true) then
    icon = PROC_ICONS["claude"]
  end
  local budget = max_width - 8
  if #title > budget and budget > 1 then
    title = title:sub(1, budget - 1) .. "…"
  end
  local label = string.format(" %d %s%s%s ", tab.tab_index + 1, icon, title, zoom)
  if tab.is_active then
    return {
      { Background = { Color = "#313244" } },
      { Foreground = { Color = "#cba6f7" } },
      { Attribute = { Intensity = "Bold" } },
      { Text = label },
    }
  end
  return {
    { Background = { Color = "#181825" } },
    { Foreground = { Color = "#6c7086" } },
    { Text = label },
  }
end)

-- ── herdr agent state in the status bar ─────────────────────────────────────
-- Shows how many agents are working/blocked without switching to their tabs.
--
-- WHY A POLLER AND NOT A DIRECT CALL: update-status fires several times per
-- second, and wezterm has no async subprocess API in the config — every
-- run_child_process blocks the event loop. So a timer refreshes a cache and
-- update-status only ever READS that cache. One subprocess every few seconds
-- instead of hundreds a minute. Matters more on Windows, where spawning a
-- process is markedly slower than on Linux.
--
-- `herdr agent list` emits a single line of JSON (it has no --json flag; that
-- errors). Verified shape on herdr 0.7.5-preview:
--   {"result":{"agents":[{"agent":"claude","agent_status":"idle",...}],...}}
-- We COUNT agent_status occurrences rather than parsing JSON: no dependency,
-- and an upstream schema change degrades to "no pill" instead of a broken config.
local HERDR_POLL_SECONDS = 3
local HERDR_MAX_FAILURES = 3
local herdr_state = { working = 0, blocked = 0, total = 0 }
local herdr_failures = 0

-- Plain (non-pattern) substring count, so JSON punctuation needs no escaping.
local function count_substr(s, needle)
  local n, pos = 0, 1
  while true do
    local i = string.find(s, needle, pos, true)
    if not i then break end
    n, pos = n + 1, i + 1
  end
  return n
end

local function herdr_poll()
  local ok, success, stdout = pcall(wezterm.run_child_process, { "herdr", "agent", "list" })
  if ok and success and stdout then
    herdr_failures = 0
    herdr_state.working = count_substr(stdout, '"agent_status":"working"')
    herdr_state.blocked = count_substr(stdout, '"agent_status":"blocked"')
    herdr_state.total = count_substr(stdout, '"agent_status":"')
  else
    herdr_failures = herdr_failures + 1
    herdr_state.working, herdr_state.blocked, herdr_state.total = 0, 0, 0
    -- Give up permanently rather than spawning a doomed process every 3s for the
    -- rest of the session when herdr isn't installed or no server is running.
    if herdr_failures >= HERDR_MAX_FAILURES then
      wezterm.log_info("herdr status polling stopped: " .. HERDR_MAX_FAILURES ..
        " consecutive failures (herdr missing or no server). Restart WezTerm to retry.")
      return
    end
  end
  wezterm.time.call_after(HERDR_POLL_SECONDS, herdr_poll)
end

-- Start after a short delay so it never competes with GUI startup.
wezterm.time.call_after(1, herdr_poll)

-- Status bar: workspace pill left; leader + active key-table right.
wezterm.on("update-status", function(window, _pane)
  window:set_left_status(wezterm.format({
    { Background = { Color = "#cba6f7" } },
    { Foreground = { Color = "#1e1e2e" } },
    { Attribute = { Intensity = "Bold" } },
    { Text = "  " .. window:active_workspace() .. " " },
    { Background = { Color = "#1e1e2e" } },
    { Foreground = { Color = "#cba6f7" } },
    { Text = " " },
  }))

  local cells = {}

  -- Agent pill, read from the cache the poller above maintains. Hidden entirely
  -- when no agents are running, so a non-agent session gains no extra chrome.
  -- Red the moment anything is blocked — that's the state needing you.
  if herdr_state.total > 0 then
    local blocked = herdr_state.blocked > 0
    table.insert(cells, { Background = { Color = blocked and "#f38ba8" or "#a6e3a1" } })
    table.insert(cells, { Foreground = { Color = "#1e1e2e" } })
    table.insert(cells, { Attribute = { Intensity = "Bold" } })
    local label = "  󰚩 " .. herdr_state.total
    if herdr_state.working > 0 then
      label = label .. "  ● " .. herdr_state.working .. " working"
    end
    if blocked then
      label = label .. "  ▲ " .. herdr_state.blocked .. " blocked"
    end
    table.insert(cells, { Text = label .. " " })
    table.insert(cells, { Background = { Color = "#1e1e2e" } })
    table.insert(cells, { Text = " " })
  end

  if window:leader_is_active() then
    table.insert(cells, { Background = { Color = "#f9e2af" } })
    table.insert(cells, { Foreground = { Color = "#1e1e2e" } })
    table.insert(cells, { Attribute = { Intensity = "Bold" } })
    table.insert(cells, { Text = "  LEADER " })
    table.insert(cells, { Background = { Color = "#1e1e2e" } })
  end
  local kt = window:active_key_table()
  if kt then
    table.insert(cells, { Background = { Color = "#fab387" } })
    table.insert(cells, { Foreground = { Color = "#1e1e2e" } })
    table.insert(cells, { Attribute = { Intensity = "Bold" } })
    table.insert(cells, { Text = "  " .. kt:upper() .. " " })
  end
  table.insert(cells, { Background = { Color = "#1e1e2e" } })
  table.insert(cells, { Text = " " })
  window:set_right_status(wezterm.format(cells))
end)

-- Tab bar. Fancy bar required for INTEGRATED_BUTTONS, and it only renders at
-- the top — so bottom placement is off and the bar stays visible with one tab
-- (otherwise the window buttons would vanish).
config.enable_tab_bar = true
config.use_fancy_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.tab_bar_at_bottom = false
config.tab_max_width = 28

config.colors = {
  selection_fg = "#1e1e2e",
  selection_bg = "#f5e0dc",
  cursor_bg = "#f5e0dc",
  cursor_fg = "#1e1e2e",
  cursor_border = "#f5e0dc",
  scrollbar_thumb = "#585b70",
  split = "#585b70",
  compose_cursor = "#fab387",
  tab_bar = {
    background = "#11111b",
    active_tab = { bg_color = "#313244", fg_color = "#cdd6f4" },
    inactive_tab = { bg_color = "#181825", fg_color = "#6c7086" },
    inactive_tab_hover = { bg_color = "#1e1e2e", fg_color = "#cdd6f4" },
    new_tab = { bg_color = "#181825", fg_color = "#6c7086" },
    new_tab_hover = { bg_color = "#313244", fg_color = "#cdd6f4" },
  },
}

config.window_frame = {
  active_titlebar_bg = "#11111b",
  inactive_titlebar_bg = "#11111b",
  font = wezterm.font({ family = "JetBrains Mono", weight = "Bold" }),
  font_size = 11.0,
}

-- Cursor
config.default_cursor_style = "BlinkingBlock"
config.cursor_blink_rate = 600
config.cursor_blink_ease_in = "EaseOut"
config.cursor_blink_ease_out = "EaseIn"

-- Visual depth / clarity
config.inactive_pane_hsb = { saturation = 0.9, brightness = 0.7 }
config.enable_scroll_bar = true
config.visual_bell = {
  fade_in_duration_ms = 75,
  fade_out_duration_ms = 75,
  fade_in_function = "EaseIn",
  fade_out_function = "EaseOut",
  target = "CursorColor",
}

config.scrollback_lines = 10000

-- Kitty keyboard protocol. Lets TUIs receive key events the legacy encoding
-- cannot express — notably SHIFT+ENTER as distinct from Enter, which is how
-- Claude Code inserts a newline in its prompt instead of submitting it.
-- Revert this line if an older TUI starts mis-reading keys.
config.enable_kitty_keyboard = true

-- Shell. PowerShell 7 (pwsh), not Windows PowerShell 5 — pipeline chain
-- operators, ternary and null-coalescing all live in 7+.
config.default_prog = { "pwsh", "-NoLogo" }

-- Persistent local sessions. On Windows the mux domain is backed by a named
-- pipe rather than a unix socket, but the behaviour is the same: panes survive
-- closing/crashing the GUI. Attach with Leader+u.
config.unix_domains = { { name = "unix" } }

-- Agent launchers (Claude Code, herdr).
--
-- `-NoExit` is the Windows counterpart to Linux's `exec zsh -l` trick: it keeps
-- the pane alive after the agent exits, so the session's scrollback survives and
-- a "command not found" stays readable instead of the tab vanishing instantly
-- (window_close_confirmation is NeverPrompt and panes close on exit).
local function agent_cmd(cmd)
  return { "pwsh", "-NoLogo", "-NoExit", "-Command", cmd }
end

-- Current pane's cwd, so a spawned agent starts in the repo you're looking at.
-- get_current_working_dir() returns a Url object on current WezTerm and a plain
-- string on older builds; handle both, and return nil rather than a bad path so
-- the spawn just falls back to the default.
local function pane_cwd(pane)
  local ok, cwd = pcall(function() return pane:get_current_working_dir() end)
  if not ok or not cwd then return nil end
  if type(cwd) == "string" then
    return (cwd:gsub("^file://[^/]*", ""))
  end
  return cwd.file_path
end

-- Spawn an agent in a new tab, or in a 50/50 split beside the current pane.
local function spawn_agent(cmd, split)
  return wezterm.action_callback(function(window, pane)
    local spawn = { args = agent_cmd(cmd), cwd = pane_cwd(pane) }
    if split then
      window:perform_action(act.SplitPane({
        direction = "Right", command = spawn, size = { Percent = 50 },
      }), pane)
    else
      window:perform_action(act.SpawnCommandInNewTab(spawn), pane)
    end
  end)
end

-- Launch menu. Bare names resolve via PATH (scoop shims, WindowsApps, mise).
config.launch_menu = {
  { label = " PowerShell", args = { "pwsh", "-NoLogo" } },
  { label = " Windows PowerShell", args = { "powershell.exe", "-NoLogo" } },
  { label = " Git Bash", args = { "C:\\Program Files\\Git\\bin\\bash.exe", "-i", "-l" } },
  { label = " Command Prompt", args = { "cmd.exe" } },
  { label = " Python REPL", args = { "python" } },
  { label = " Zellij", args = { "zellij" } },
  { label = " lazygit", args = { "lazygit" } },
  -- Agents. pwsh -NoExit wrapped so the pane survives the session ending.
  { label = "󰚩 Claude Code", args = agent_cmd("claude") },
  { label = "󰚩 Claude Code (resume)", args = agent_cmd("claude --resume") },
  { label = "󰕰 Herdr (agent multiplexer)", args = agent_cmd("herdr") },
}

-- Leader key (tmux-style). Ctrl+a then a second key.
config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }

-- Quick-select copy: Leader+Space, then a letter, copies any match.
config.quick_select_patterns = {
  -- file:line[:col] FIRST — agent, compiler and stack-trace output is full of
  -- these, and it must beat the generic path rules below, or "src/main.py:42"
  -- gets grabbed without the line number that made it worth copying.
  "[\\w./~+-]+\\.[A-Za-z0-9_]+:\\d+(?::\\d+)?",
  -- Windows absolute paths (C:\Users\... ), which the POSIX rule below misses.
  "[A-Za-z]:\\\\[\\w\\\\.@%+-]+",
  "[0-9a-f]{7,40}",                     -- git commit SHAs
  "(?:[0-9]{1,3}\\.){3}[0-9]{1,3}",     -- IPv4 addresses
  "0x[0-9a-fA-F]+",                     -- hex literals
  "[~./][\\w./@%+-]+",                  -- POSIX-style file paths
  "[\\w.+-]+@[\\w.-]+\\.[A-Za-z]{2,}",  -- email addresses
}

-- Cheatsheet overlay (Leader+?). WezTerm has no text-overlay API, so this writes
-- the keymap to a temp file and pages it in a new tab. Keep in sync with the
-- binds below when you add/remove keys.
local CHEATSHEET = [[
  WezTerm keybindings (Windows) — Leader = Ctrl+a (then a key within 1s)

  PANES
    Ctrl+Shift+d / e        split horizontal / vertical
    Leader+| / -            split horizontal / vertical
    Ctrl+Shift+h/j/k/l      focus pane left/down/up/right
    Ctrl+Shift+Enter        zoom pane (toggle)   |  Leader+z  zoom
    Ctrl+Shift+x            close pane           |  Leader+x  close
    Leader+p                pick pane by letter
    Leader+r                resize mode (hjkl, Esc exits)

  TABS
    Ctrl+Shift+t            new tab    |  Ctrl+Shift+w / Leader+q  close
    Ctrl+Tab / Ctrl+Shift+Tab   next / prev tab
    Alt+1..9                jump to tab 1..9

  WORKSPACES
    Leader+n                new named workspace
    Leader+w                workspace switcher (fuzzy)
    Ctrl+Shift+Space        fuzzy switcher (apps/tabs/workspaces/commands)

  AGENTS  (Leader+a, then one key)
    Leader+a c              Claude Code in a new tab (inherits cwd)
    Leader+a s              Claude Code in a split beside this pane
    Leader+a r / k          claude --resume / --continue
    Leader+a h              herdr (agent multiplexer)
    Leader+a y              copy last command + its output as a markdown block
    Leader+a Y              copy the whole scrollback

  SCROLLBACK & SEARCH  (needs shell integration)
    Leader+Up / Down        jump to previous / next shell prompt
    Leader+y                copy the LAST command's output
    Leader+[                copy mode (vim motions)
    Ctrl+Shift+f / Leader+f search

  SELECT / COPY
    Leader+Space            quick-select (paths, SHAs, IPs, file:line, emails)
    Leader+o                open a URL on screen in the browser
    Leader+e                char / emoji picker (copies)
    Ctrl+Shift+c / v        copy / paste   |  drag = copy, middle-click = paste

  WINDOW
    Leader+h / l            snap to left / right half
    Leader+m / c            maximize / center
    F11                     fullscreen     |  Leader+Shift+F  fullscreen
    Leader+,                minimize
    Leader+b                toggle tab bar
    Leader+Shift+O          toggle transparency

  LAUNCH
    Ctrl+Shift+p            profile launcher  |  Ctrl+Shift+z  Zellij in new tab
    Ctrl+Shift+Alt+P        command palette
    Leader+u                attach persistent mux session
    Leader+?                this cheatsheet

  SESSION (resurrect — survives close/reboot)
    Leader+Shift+S          save current layout to disk
    Leader+Shift+R          restore a saved layout (fuzzy picker)

  Font: Ctrl+= / Ctrl+- / Ctrl+0   bigger / smaller / reset
]]

local function show_cheatsheet(window, pane)
  local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
  local path = home .. "\\.wezterm-cheatsheet.txt"
  local f = io.open(path, "w")
  if not f then
    window:toast_notification("WezTerm", "Cheatsheet: cannot write " .. path, nil, 3000)
    return
  end
  f:write(CHEATSHEET)
  f:close()
  -- Paged with pwsh's own pager so this works with no extra tooling installed.
  window:perform_action(act.SpawnCommandInNewTab({
    args = { "pwsh", "-NoLogo", "-Command",
      "Get-Content '" .. path .. "' | Out-Host -Paging; Remove-Item '" .. path .. "'" },
  }), pane)
end

-- Keybindings
config.keys = {
  -- Pane splitting
  { key = "d", mods = "CTRL|SHIFT", action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
  { key = "e", mods = "CTRL|SHIFT", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },

  -- Pane navigation (vim-style)
  { key = "h", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Left") },
  { key = "l", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Right") },
  { key = "k", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Up") },
  { key = "j", mods = "CTRL|SHIFT", action = act.ActivatePaneDirection("Down") },

  -- Pane resize
  { key = "H", mods = "CTRL|SHIFT|ALT", action = act.AdjustPaneSize({ "Left", 5 }) },
  { key = "L", mods = "CTRL|SHIFT|ALT", action = act.AdjustPaneSize({ "Right", 5 }) },
  { key = "K", mods = "CTRL|SHIFT|ALT", action = act.AdjustPaneSize({ "Up", 3 }) },
  { key = "J", mods = "CTRL|SHIFT|ALT", action = act.AdjustPaneSize({ "Down", 3 }) },

  -- Pane management
  { key = "Enter", mods = "CTRL|SHIFT", action = act.TogglePaneZoomState },
  { key = "x", mods = "CTRL|SHIFT", action = act.CloseCurrentPane({ confirm = false }) },

  -- Tab management
  { key = "t", mods = "CTRL|SHIFT", action = act.SpawnTab("CurrentPaneDomain") },
  { key = "w", mods = "CTRL|SHIFT", action = act.CloseCurrentTab({ confirm = false }) },
  { key = "Tab", mods = "CTRL", action = act.ActivateTabRelative(1) },
  { key = "Tab", mods = "CTRL|SHIFT", action = act.ActivateTabRelative(-1) },

  -- Direct tab access (Alt+1..9)
  { key = "1", mods = "ALT", action = act.ActivateTab(0) },
  { key = "2", mods = "ALT", action = act.ActivateTab(1) },
  { key = "3", mods = "ALT", action = act.ActivateTab(2) },
  { key = "4", mods = "ALT", action = act.ActivateTab(3) },
  { key = "5", mods = "ALT", action = act.ActivateTab(4) },
  { key = "6", mods = "ALT", action = act.ActivateTab(5) },
  { key = "7", mods = "ALT", action = act.ActivateTab(6) },
  { key = "8", mods = "ALT", action = act.ActivateTab(7) },
  { key = "9", mods = "ALT", action = act.ActivateTab(8) },

  -- Copy/Paste
  { key = "c", mods = "CTRL|SHIFT", action = act.CopyTo("Clipboard") },
  { key = "v", mods = "CTRL|SHIFT", action = act.PasteFrom("Clipboard") },

  -- Font size. `+` is Shift+`=` on US layouts, so bind both forms.
  { key = "=", mods = "CTRL", action = act.IncreaseFontSize },
  { key = "+", mods = "CTRL|SHIFT", action = act.IncreaseFontSize },
  { key = "-", mods = "CTRL", action = act.DecreaseFontSize },
  { key = "0", mods = "CTRL", action = act.ResetFontSize },

  -- Launch menu (profile picker)
  { key = "p", mods = "CTRL|SHIFT", action = act.ShowLauncher },

  -- Quick Zellij in new tab
  { key = "z", mods = "CTRL|SHIFT", action = act.SpawnCommandInNewTab({ args = { "zellij" } }) },

  -- Command palette
  { key = "P", mods = "CTRL|SHIFT|ALT", action = act.ActivateCommandPalette },

  -- Scroll
  { key = "PageUp", mods = "CTRL|SHIFT", action = act.ScrollByPage(-0.5) },
  { key = "PageDown", mods = "CTRL|SHIFT", action = act.ScrollByPage(0.5) },

  -- Search
  { key = "f", mods = "CTRL|SHIFT", action = act.Search("CurrentSelectionOrEmptyString") },

  -- Fullscreen
  { key = "F11", mods = "NONE", action = act.ToggleFullScreen },

  -- NOTE: no SUPER (Windows key) binds. Windows reserves Win+Left/Right/Up/Down
  -- for its own Snap and hands them to the OS before WezTerm sees them, so the
  -- Linux config's Super+Arrow snapping is dropped here. The Leader equivalents
  -- below do the same job.

  -- Leader (Ctrl+a) chords.
  { key = "a", mods = "LEADER|CTRL", action = act.SendKey({ key = "a", mods = "CTRL" }) },
  { key = "|", mods = "LEADER", action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
  { key = "-", mods = "LEADER", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
  { key = "z", mods = "LEADER", action = act.TogglePaneZoomState },
  { key = "x", mods = "LEADER", action = act.CloseCurrentPane({ confirm = false }) },
  { key = "q", mods = "LEADER", action = act.CloseCurrentTab({ confirm = false }) },
  { key = "N", mods = "LEADER|SHIFT", action = act.SpawnWindow },
  { key = "p", mods = "LEADER", action = act.PaneSelect({ alphabet = "asdfghjkl" }) },
  { key = "f", mods = "LEADER", action = act.Search("CurrentSelectionOrEmptyString") },
  { key = "[", mods = "LEADER", action = act.ActivateCopyMode },
  { key = " ", mods = "LEADER", action = act.QuickSelect },
  { key = "e", mods = "LEADER", action = act.CharSelect({ copy_on_select = true }) },
  { key = "LeftArrow", mods = "LEADER", action = act.EmitEvent("snap-left") },
  { key = "RightArrow", mods = "LEADER", action = act.EmitEvent("snap-right") },
  { key = "h", mods = "LEADER", action = act.EmitEvent("snap-left") },
  { key = "l", mods = "LEADER", action = act.EmitEvent("snap-right") },
  { key = "m", mods = "LEADER", action = act.EmitEvent("win-maximize") },
  { key = "c", mods = "LEADER", action = act.EmitEvent("snap-center") },
  { key = "F", mods = "LEADER|SHIFT", action = act.ToggleFullScreen },
  { key = "b", mods = "LEADER", action = act.EmitEvent("toggle-tab-bar") },
  { key = ",", mods = "LEADER", action = act.Hide },
  { key = "u", mods = "LEADER", action = act.AttachDomain("unix") },
  { key = "o", mods = "LEADER", action = act.QuickSelectArgs({
    label = "open url",
    patterns = { "https?://\\S+" },
    action = wezterm.action_callback(function(window, pane)
      local url = window:get_selection_text_for_pane(pane)
      if url and url ~= "" then wezterm.open_with(url) end
    end),
  }) },
  { key = "O", mods = "LEADER|SHIFT", action = act.EmitEvent("toggle-opacity") },
  { key = "r", mods = "LEADER", action = act.ActivateKeyTable({ name = "resize_pane", one_shot = false }) },
  -- Agent layer (status bar shows AGENT). one_shot: fires a single key then
  -- exits, so it never traps you. Leader+a is free — only LEADER|CTRL+a is
  -- taken, for the literal Ctrl+a passthrough above.
  { key = "a", mods = "LEADER", action = act.ActivateKeyTable({
    name = "agent", one_shot = true, timeout_milliseconds = 2000,
  }) },
  { key = "Space", mods = "CTRL|SHIFT", action = act.ShowLauncherArgs({
    flags = "FUZZY|LAUNCH_MENU_ITEMS|TABS|WORKSPACES|COMMANDS",
  }) },
  { key = "Tab", mods = "LEADER", action = act.SwitchWorkspaceRelative(1) },
  { key = "Tab", mods = "LEADER|SHIFT", action = act.SwitchWorkspaceRelative(-1) },
  { key = "]", mods = "LEADER", action = act.SwitchWorkspaceRelative(1) },

  -- Workspaces
  { key = "w", mods = "LEADER", action = act.ShowLauncherArgs({ flags = "FUZZY|WORKSPACES" }) },
  { key = "n", mods = "LEADER", action = act.PromptInputLine({
    description = "New workspace name:",
    action = wezterm.action_callback(function(window, pane, line)
      if line and #line > 0 then
        window:perform_action(act.SwitchToWorkspace({ name = line }), pane)
      end
    end),
  }) },

  -- Cheatsheet overlay
  { key = "?", mods = "LEADER", action = wezterm.action_callback(show_cheatsheet) },

  -- Shell-integration nav (OSC 133).
  { key = "UpArrow", mods = "LEADER", action = act.ScrollToPrompt(-1) },
  { key = "DownArrow", mods = "LEADER", action = act.ScrollToPrompt(1) },
  { key = "y", mods = "LEADER", action = wezterm.action_callback(function(window, pane)
    local zones = pane:get_semantic_zones("Output")
    if not zones or #zones == 0 then
      window:toast_notification("WezTerm", "No command output captured yet", nil, 2000)
      return
    end
    local text = pane:get_text_from_semantic_zone(zones[#zones])
    window:copy_to_clipboard(text or "", "ClipboardAndPrimarySelection")
    window:toast_notification("WezTerm", "Copied last command output", nil, 1500)
  end) },
}

-- Session persistence keybinds (resurrect) — only wired if the plugin loaded.
if ok_resurrect then
  table.insert(config.keys, {
    key = "S", mods = "LEADER|SHIFT",
    action = wezterm.action_callback(function(win, _pane)
      resurrect.state_manager.save_state(resurrect.workspace_state.get_workspace_state())
      win:toast_notification("WezTerm", "Session saved", nil, 1500)
    end),
  })
  table.insert(config.keys, {
    key = "R", mods = "LEADER|SHIFT",
    action = wezterm.action_callback(function(win, pane)
      resurrect.fuzzy_loader.fuzzy_load(win, pane, function(id, _label)
        local kind = string.match(id, "^([^/]+)")
        id = string.match(id, "([^/]+)$")
        id = string.match(id, "(.+)%..+$")
        local opts = { relative = true, restore_text = true }
        if kind == "workspace" then
          resurrect.workspace_state.restore_workspace(
            resurrect.state_manager.load_state(id, "workspace"), opts)
        end
      end)
    end),
  })
end

-- Copy the last command AND its output as a fenced markdown block — the shape
-- you actually want when pasting a failure into an agent. Uses OSC 133 semantic
-- zones. Leader+y still copies output alone.
local function copy_last_exchange(window, pane)
  local inputs = pane:get_semantic_zones("Input")
  local outputs = pane:get_semantic_zones("Output")
  if (not inputs or #inputs == 0) and (not outputs or #outputs == 0) then
    window:toast_notification("WezTerm", "No shell zones captured yet", nil, 2000)
    return
  end
  local function last(zones)
    if not zones or #zones == 0 then return "" end
    return (pane:get_text_from_semantic_zone(zones[#zones]) or ""):gsub("%s+$", "")
  end
  local block = "```console\n$ " .. last(inputs) .. "\n" .. last(outputs) .. "\n```"
  window:copy_to_clipboard(block, "ClipboardAndPrimarySelection")
  window:toast_notification("WezTerm", "Copied last command + output", nil, 1500)
end

-- Whole scrollback to the clipboard — for handing an agent the full context of
-- a long run rather than just the last screenful.
local function copy_scrollback(window, pane)
  local text = pane:get_lines_as_text(pane:get_dimensions().scrollback_rows) or ""
  if text == "" then
    window:toast_notification("WezTerm", "Scrollback is empty", nil, 2000)
    return
  end
  local _, lines = text:gsub("\n", "")
  window:copy_to_clipboard(text, "ClipboardAndPrimarySelection")
  window:toast_notification("WezTerm", "Copied " .. lines .. " lines of scrollback", nil, 1500)
end

-- Modal key-tables. Activated by leader chords above; status bar shows the mode.
config.key_tables = {
  -- Agent layer. Identical to the Linux config so muscle memory carries over.
  agent = {
    { key = "c", action = spawn_agent("claude") },
    { key = "s", action = spawn_agent("claude", true) },
    { key = "r", action = spawn_agent("claude --resume") },
    { key = "k", action = spawn_agent("claude --continue") },
    { key = "h", action = spawn_agent("herdr") },
    { key = "y", action = wezterm.action_callback(copy_last_exchange) },
    { key = "Y", mods = "SHIFT", action = wezterm.action_callback(copy_scrollback) },
    { key = "Escape", action = "PopKeyTable" },
    { key = "q", action = "PopKeyTable" },
  },

  resize_pane = {
    { key = "h", action = act.AdjustPaneSize({ "Left", 3 }) },
    { key = "l", action = act.AdjustPaneSize({ "Right", 3 }) },
    { key = "k", action = act.AdjustPaneSize({ "Up", 2 }) },
    { key = "j", action = act.AdjustPaneSize({ "Down", 2 }) },
    { key = "LeftArrow", action = act.AdjustPaneSize({ "Left", 3 }) },
    { key = "RightArrow", action = act.AdjustPaneSize({ "Right", 3 }) },
    { key = "UpArrow", action = act.AdjustPaneSize({ "Up", 2 }) },
    { key = "DownArrow", action = act.AdjustPaneSize({ "Down", 2 }) },
    { key = "Escape", action = "PopKeyTable" },
    { key = "Enter", action = "PopKeyTable" },
  },
}

-- Mouse bindings
config.mouse_bindings = {
  { event = { Up = { streak = 1, button = "Left" } }, mods = "CTRL", action = act.OpenLinkAtMouseCursor },
  { event = { Up = { streak = 1, button = "Left" } }, mods = "NONE",
    action = act.CompleteSelection("ClipboardAndPrimarySelection") },
  { event = { Down = { streak = 1, button = "Middle" } }, mods = "NONE",
    action = act.PasteFrom("PrimarySelection") },
}

-- Hyperlinks: built-in URL detection plus a GitHub issue/PR shorthand.
config.hyperlink_rules = wezterm.default_hyperlink_rules()
table.insert(config.hyperlink_rules, {
  regex = [[\b([\w.-]+)/([\w.-]+)#(\d+)\b]],
  format = "https://github.com/$1/$2/issues/$3",
})

-- Misc
config.warn_about_missing_glyphs = false
config.check_for_updates = false
config.audible_bell = "Disabled"
config.exit_behavior = "Close"

return config
