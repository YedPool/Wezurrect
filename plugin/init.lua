local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local dev = wezterm.plugin.require("https://github.com/chrisgve/dev.wezterm")

local pub = {}

-- Set once the command event handlers have been registered with wezterm.on, so
-- a second setup() call does not stack duplicate handlers on the same events.
local _commands_registered = false

local function init()
	-- enable_sub_modules()
	local opts = {
		auto = true,
		-- Substring(s) present in the encoded plugin path. wezterm caches by the
		-- URL the user supplied (NOT the redirect target), so paths can be
		-- "...sZsYedPoolsZsWezurrect" (canonical URL) OR
		-- "...sZsYedPoolsZsresurrectsDswezterm" (README's redirected URL).
		-- "YedPool" is the only substring common to both forms; it also
		-- correctly excludes the upstream MLFlexer fork.
		keywords = { "YedPool" },
	}
	local plugin_path = dev.setup(opts)

	local sep = require("resurrect.utils").separator
	require("resurrect.state_manager").change_state_save_dir(plugin_path .. sep .. "state" .. sep)

	-- Export submodules
	pub.workspace_state = require("resurrect.workspace_state")
	pub.window_state = require("resurrect.window_state")
	pub.tab_state = require("resurrect.tab_state")
	pub.fuzzy_loader = require("resurrect.fuzzy_loader")
	pub.state_manager = require("resurrect.state_manager")
	pub.process_handlers = require("resurrect.process_handlers")
	pub.instance_manager = require("resurrect.instance_manager")
	pub.wsl_integration = require("resurrect.wsl_integration")
	pub.powershell_integration = require("resurrect.powershell_integration")
	pub.window_geometry = require("resurrect.window_geometry")
end

init()

--- One-call setup that configures everything for session persistence
--- and Claude Code restoration. Users call this from their wezterm.lua:
---
---   local resurrect = wezterm.plugin.require("https://github.com/YedPool/resurrect.wezterm")
---   resurrect.setup(config)  -- or resurrect.setup(config, opts)
---
--- Options (all optional):
---   periodic_interval    = 300    -- seconds between periodic saves
---   restore_delay        = 3      -- seconds to wait before sending restore commands
---   scroll_to_history    = true   -- park restored panes on their restored scrollback
---   restore_window_geometry = false -- save/restore window position + maximized (Windows)
---   save_workspaces      = true
---   save_windows         = true
---   save_tabs            = true
---   keybindings          = true   -- add Alt+S/R/W/Shift+W/Shift+T + Ctrl+Shift+B bindings
---   status_bar           = true   -- show save time + tab titles in right status
---   claude_hooks         = true   -- auto-configure Claude Code SessionStart hook
---   auto_restore         = "prompt" -- "prompt" | "latest" | false, see below
---   auto_restore_prompt  = true   -- older spelling of auto_restore = false
---   retention_days       = 7      -- auto-delete instance states older than this
---   powershell_integration = true -- auto-install cwd reporting into PowerShell profiles
---   wsl_integration      = true   -- auto-install cwd + Claude session reporting into WSL distros
---   wsl_integration_delay = 10    -- seconds to wait after startup before either
---
---@param config table wezterm config_builder object
---@param opts? table optional overrides
function pub.setup(config, opts)
	opts = opts or {}
	local save_workspaces = opts.save_workspaces ~= false
	local save_windows = opts.save_windows ~= false
	local save_tabs = opts.save_tabs ~= false

	-- Initialize per-instance state management
	pub.instance_manager.init_instance_id()
	pub.instance_manager.retention_days = opts.retention_days or 7

	-- auto_restore: what the first window does when saved instances exist.
	-- auto_restore_prompt = false is the older spelling of auto_restore = false.
	local auto_restore = opts.auto_restore
	if auto_restore == nil then
		auto_restore = (opts.auto_restore_prompt == false) and false or "prompt"
	end
	pub.instance_manager.auto_restore_mode = auto_restore
	pub.instance_manager.auto_restore_prompt = auto_restore ~= false

	-- Claude Code session hook setup (idempotent)
	if opts.claude_hooks ~= false then
		-- Namespace this process's pane-session files. Pane ids restart from 0
		-- in every WezTerm process, so without this a fresh pane 0 reads the
		-- file left by a previous run's pane 0 and is saved -- and restored --
		-- as a Claude pane running a conversation from days ago.
		pub.process_handlers.pane_session_prefix = pub.instance_manager.instance_id
		config.set_environment_variables = config.set_environment_variables or {}
		config.set_environment_variables.RESURRECT_INSTANCE = pub.instance_manager.instance_id

		pub.process_handlers.setup_claude_session_hooks()
	end

	-- Window position and maximized state. Off by default: WezTerm can set both
	-- but read neither, so capturing them costs a subprocess, and it only works
	-- on Windows with a single window open.
	local state_dir = pub.state_manager.save_state_dir:gsub("[/\\]+$", "")
	pub.window_geometry.enabled = opts.restore_window_geometry == true
	pub.window_geometry.cache_dir = state_dir .. require("resurrect.utils").separator .. "window-geometry"

	-- Deferred housekeeping. Both of these shell out, so they must stay off the
	-- config-evaluation path (run_child_process yields), and the WSL install can
	-- take seconds when the distro is not already running.
	local retention_days = pub.instance_manager.retention_days
	local marker_dir = state_dir .. require("resurrect.utils").separator .. "wsl-integration"
	wezterm.time.call_after(opts.wsl_integration_delay or 10, function()
		-- SessionEnd clears a pane's session file when Claude exits cleanly, but
		-- a crash strands one. The directory is shared by every WezTerm process,
		-- so age is the only safe thing to delete by.
		if opts.claude_hooks ~= false then
			pcall(pub.process_handlers.sweep_pane_sessions, retention_days)
		end

		-- Neither PowerShell nor a WSL shell reports its working directory to
		-- WezTerm on its own, so a pane the user has cd'd around in is saved as
		-- still sitting where its shell started. Install the shell integration
		-- that closes that. Both are idempotent, and marker files mean they only
		-- actually run once per profile or distro.
		if opts.powershell_integration ~= false then
			local ok, err = pcall(pub.powershell_integration.ensure_installed, marker_dir)
			if not ok then
				wezterm.log_error("resurrect: PowerShell integration setup failed: " .. tostring(err))
			end
		end

		if opts.wsl_integration ~= false then
			local ok, err = pcall(pub.wsl_integration.ensure_installed, marker_dir)
			if not ok then
				wezterm.log_error("resurrect: WSL integration setup failed: " .. tostring(err))
			end
		end
	end)

	-- Event-driven save: fires on pane/tab structure changes
	pub.state_manager.event_driven_save({
		save_workspaces = save_workspaces,
		save_windows = save_windows,
		save_tabs = save_tabs,
	})

	-- Periodic save as a safety net
	pub.state_manager.periodic_save({
		interval_seconds = opts.periodic_interval or 300,
		save_workspaces = save_workspaces,
		save_windows = save_windows,
		save_tabs = save_tabs,
	})

	-- Restore delay for process commands (shells need time to init)
	if opts.restore_delay then
		pub.tab_state.process_restore_delay_seconds = opts.restore_delay
	end

	-- Park restored panes on their restored history rather than at a prompt that
	-- looks like nothing happened.
	if opts.scroll_to_history ~= nil then
		pub.tab_state.scroll_to_restored_history = opts.scroll_to_history
	end

	-- Restore on startup: show instance selector if saved instances exist,
	-- otherwise fall back to current_state mechanism for backward compat
	wezterm.on("gui-startup", function()
		pub.instance_manager.auto_restore_on_startup()
	end)

	-- Status bar: show save time + tab titles
	if opts.status_bar ~= false then
		local last_save_time = nil

		-- Listen to all save-finished events for status bar updates
		wezterm.on("resurrect.state_manager.event_driven_save.finished", function()
			last_save_time = os.date("%H:%M:%S")
		end)

		wezterm.on("resurrect.state_manager.periodic_save.finished", function()
			last_save_time = os.date("%H:%M:%S")
		end)

		wezterm.on("resurrect.save.finished", function()
			last_save_time = os.date("%H:%M:%S")
		end)

		wezterm.on("update-right-status", function(window, pane)
			local titles = {}
			local mux_win = window:mux_window()
			for _, tab in ipairs(mux_win:tabs()) do
				local title = tab:get_title() or ""
				if title ~= "" then
					titles[title] = (titles[title] or 0) + 1
				end
			end

			local parts = {}
			for title, count in pairs(titles) do
				if count > 1 then
					table.insert(parts, title .. " x" .. count)
				else
					table.insert(parts, title)
				end
			end
			table.sort(parts)
			local title_str = table.concat(parts, ", ")

			local status = ""
			if last_save_time then
				status = "saved " .. last_save_time .. " | " .. title_str
			elseif title_str ~= "" then
				status = title_str
			end

			window:set_right_status(wezterm.format({
				{ Foreground = { AnsiColor = "Green" } },
				{ Text = status },
			}))
		end)
	end

	-- Keybindings and command palette entries for manual save/restore
	if opts.keybindings ~= false then
		local restore_opts = {
			relative = true,
			restore_text = true,
			on_pane_restore = pub.tab_state.default_on_pane_restore,
		}

		-- The event name IS the command palette label, because WezTerm gives us
		-- no other way to write one.
		--
		-- The palette derives an entry from every key assignment, labelled from
		-- its action. For a wezterm.action_callback that reads "Emit event
		-- `user-defined-3`" -- a number that depends on registration order and
		-- says nothing about what the command does. For EmitEvent it reads
		-- "Emit event `<name>`", so a descriptive name is the whole fix.
		--
		-- augment-command-palette can contribute a properly labelled entry, but
		-- it cannot replace the derived one (both appear) and entries added that
		-- way never show their key binding. One readable entry that shows its
		-- shortcut beats two entries where only the redundant one does.
		local commands = {
			{
				event = "Resurrect: Save workspace",
				key = "w",
				mods = "ALT",
				run = function()
					pub.state_manager.save_state(pub.workspace_state.get_workspace_state())
				end,
			},
			{
				event = "Resurrect: Save window under a name",
				key = "W",
				mods = "ALT|SHIFT",
				run = function(win, pane)
					win:perform_action(pub.window_state.save_window_action(), pane)
				end,
			},
			{
				event = "Resurrect: Save tab under a name",
				key = "T",
				mods = "ALT|SHIFT",
				run = function(win, pane)
					win:perform_action(pub.tab_state.save_tab_action(), pane)
				end,
			},
			{
				event = "Resurrect: Save everything now",
				key = "s",
				mods = "ALT",
				run = function()
					-- Deliberate, so it is worth the subprocess that reads the
					-- window's position.
					pub.state_manager.save_workspace_full({ capture_geometry = true })
					wezterm.emit("resurrect.save.finished")
				end,
			},
			{
				event = "Resurrect: Restore a saved session",
				key = "r",
				mods = "ALT",
				run = function(win, pane)
					pub.instance_manager.show_instance_selector(win, pane, restore_opts)
				end,
			},
			{
				event = "Resurrect: Move pane into its own window",
				key = "b",
				mods = "CTRL|SHIFT",
				run = function(_, pane)
					pane:move_to_new_window()
				end,
			},
		}

		config.keys = config.keys or {}
		for _, command in ipairs(commands) do
			table.insert(config.keys, {
				key = command.key,
				mods = command.mods,
				action = wezterm.action.EmitEvent(command.event),
			})
		end

		-- Guarded like event_driven_save: handlers registered here would
		-- otherwise stack up if setup() runs more than once, and every keypress
		-- would fire the command once per registration.
		if not _commands_registered then
			_commands_registered = true
			for _, command in ipairs(commands) do
				wezterm.on(command.event, command.run)
			end
		end
	end
end

return pub
