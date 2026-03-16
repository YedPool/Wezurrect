local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local dev = wezterm.plugin.require("https://github.com/chrisgve/dev.wezterm")

local pub = {}

--- checks if the user is on windows
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
local separator = is_windows and "\\" or "/"

local function init()
	-- enable_sub_modules()
	local opts = {
		auto = true,
		keywords = { "resurrect", "wezterm" },
	}
	local plugin_path = dev.setup(opts)

	require("resurrect.state_manager").change_state_save_dir(plugin_path .. separator .. "state" .. separator)

	-- Export submodules
	pub.workspace_state = require("resurrect.workspace_state")
	pub.window_state = require("resurrect.window_state")
	pub.tab_state = require("resurrect.tab_state")
	pub.fuzzy_loader = require("resurrect.fuzzy_loader")
	pub.state_manager = require("resurrect.state_manager")
	pub.process_handlers = require("resurrect.process_handlers")
	pub.instance_manager = require("resurrect.instance_manager")
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
---   save_workspaces      = true
---   save_windows         = true
---   save_tabs            = true
---   keybindings          = true   -- add Alt+W/R/Shift+W/Shift+T bindings
---   status_bar           = true   -- show save time + tab titles in right status
---   claude_hooks         = true   -- auto-configure Claude Code SessionStart hook
---   auto_restore_prompt  = true   -- show instance selector on startup if saved instances exist
---   retention_days       = 7      -- auto-delete instance states older than this
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
	pub.instance_manager.auto_restore_prompt = opts.auto_restore_prompt ~= false

	-- Claude Code session hook setup (idempotent)
	if opts.claude_hooks ~= false then
		pub.process_handlers.setup_claude_session_hooks()
	end

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

	-- Restore on startup: show instance selector if saved instances exist,
	-- otherwise fall back to current_state mechanism for backward compat
	wezterm.on("gui-startup", function()
		pub.instance_manager.auto_restore_on_startup()
	end)

	-- Status bar: show save time + tab titles
	if opts.status_bar ~= false then
		local last_save_time = nil

		wezterm.on("resurrect.state_manager.event_driven_save.finished", function()
			last_save_time = os.date("%H:%M:%S")
		end)

		wezterm.on("resurrect.state_manager.periodic_save.finished", function()
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

	-- Keybindings for manual save/restore
	if opts.keybindings ~= false then
		local restore_opts = {
			relative = true,
			restore_text = true,
			on_pane_restore = pub.tab_state.default_on_pane_restore,
		}

		config.keys = config.keys or {}

		-- Alt+W: save workspace
		table.insert(config.keys, {
			key = "w",
			mods = "ALT",
			action = wezterm.action_callback(function(win, pane)
				pub.state_manager.save_state(
					pub.workspace_state.get_workspace_state()
				)
			end),
		})

		-- Alt+Shift+W: save window
		table.insert(config.keys, {
			key = "W",
			mods = "ALT|SHIFT",
			action = pub.window_state.save_window_action(),
		})

		-- Alt+Shift+T: save tab
		table.insert(config.keys, {
			key = "T",
			mods = "ALT|SHIFT",
			action = pub.tab_state.save_tab_action(),
		})

		-- Alt+S: full save (workspace + instance + status bar update)
		table.insert(config.keys, {
			key = "s",
			mods = "ALT",
			action = wezterm.action_callback(function(win, pane)
				local workspace_state = pub.workspace_state.get_workspace_state()
				pub.state_manager.save_state(workspace_state)
				pub.state_manager.write_current_state(workspace_state.workspace, "workspace")
				if pub.instance_manager.instance_id then
					pub.instance_manager.save_instance(workspace_state)
				end
				wezterm.emit("resurrect.state_manager.event_driven_save.finished")
			end),
		})

		-- Alt+R: show instance selector (with fallthrough to named saves)
		table.insert(config.keys, {
			key = "r",
			mods = "ALT",
			action = wezterm.action_callback(function(win, pane)
				pub.instance_manager.show_instance_selector(win, pane, restore_opts)
			end),
		})
	end
end

return pub
