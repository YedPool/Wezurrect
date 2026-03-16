local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local file_io = require("resurrect.file_io")
local utils = require("resurrect.utils")

local pub = {}

---@param file_name string
---@param type string
---@param opt_name string?
---@return string
local function get_file_path(file_name, type, opt_name)
	if opt_name then
		file_name = opt_name
	end
	return string.format(
		"%s" .. utils.separator .. "%s" .. utils.separator .. "%s.json",
		pub.save_state_dir,
		type,
		file_name:gsub("[" .. utils.separator .. ":%[%]?/*~!{}()&|;<>$`\"' \0]", "+")
	)
end

---save state to a file
---@param state workspace_state | window_state | tab_state
---@param opt_name? string
function pub.save_state(state, opt_name)
	if state.window_states then
		file_io.write_state(get_file_path(state.workspace, "workspace", opt_name), state, "workspace")
		-- Always update current_state when saving a workspace so that
		-- resurrect_on_gui_startup knows what to restore.
		pub.write_current_state(state.workspace, "workspace")
	elseif state.tabs then
		file_io.write_state(get_file_path(state.title, "window", opt_name), state, "window")
	elseif state.pane_tree then
		file_io.write_state(get_file_path(state.title, "tab", opt_name), state, "tab")
	end
end

--- Full workspace save: saves workspace state, current_state, and instance state.
--- Single entry point for the complete save operation, used by periodic_save,
--- event_driven_save, and the Alt+S keybinding to avoid duplication.
function pub.save_workspace_full()
	local workspace_state = require("resurrect.workspace_state").get_workspace_state()
	pub.save_state(workspace_state)

	-- Save per-instance state if instance manager is active
	local im = require("resurrect.instance_manager")
	if im.instance_id then
		im.save_instance(workspace_state)
	end
end

---Reads a file with the state
---@param name string
---@param type string
---@return table
function pub.load_state(name, type)
	wezterm.emit("resurrect.state_manager.load_state.start", name, type)
	local json = file_io.load_json(get_file_path(name, type))
	if not json then
		wezterm.emit("resurrect.error", "Invalid json: " .. get_file_path(name, type))
		return {}
	end
	wezterm.emit("resurrect.state_manager.load_state.finished", name, type)
	return json
end

---Saves the stater after interval in seconds
---@param opts? { interval_seconds: integer?, save_workspaces: boolean?, save_windows: boolean?, save_tabs: boolean? }
function pub.periodic_save(opts)
	if opts == nil then
		opts = { save_workspaces = true }
	end
	if opts.interval_seconds == nil then
		opts.interval_seconds = 60 * 15
	end
	wezterm.time.call_after(opts.interval_seconds, function()
		local ok, err = pcall(function()
			wezterm.emit("resurrect.state_manager.periodic_save.start", opts)
			if opts.save_workspaces then
				pub.save_workspace_full()
			end

			if opts.save_windows then
				for _, gui_win in ipairs(wezterm.gui.gui_windows()) do
					local mux_win = gui_win:mux_window()
					local title = mux_win:get_title()
					if title and title ~= "" then
						pub.save_state(require("resurrect.window_state").get_window_state(mux_win))
					end
				end
			end

			if opts.save_tabs then
				for _, gui_win in ipairs(wezterm.gui.gui_windows()) do
					local mux_win = gui_win:mux_window()
					for _, mux_tab in ipairs(mux_win:tabs()) do
						local title = mux_tab:get_title()
						if title and title ~= "" then
							pub.save_state(require("resurrect.tab_state").get_tab_state(mux_tab))
						end
					end
				end
			end

			wezterm.emit("resurrect.state_manager.periodic_save.finished", opts)
		end)
		if not ok then
			wezterm.log_error("resurrect: periodic_save failed: " .. tostring(err))
			wezterm.emit("resurrect.error", "periodic_save failed: " .. tostring(err))
		end
		-- Always re-schedule, even after errors
		pub.periodic_save(opts)
	end)
end

---Saves the state whenever the pane or tab structure changes.
---@param opts? { save_workspaces: boolean?, save_windows: boolean?, save_tabs: boolean?, user_var: string? }
local _event_driven_save_registered = false
function pub.event_driven_save(opts)
	if _event_driven_save_registered then
		wezterm.log_info("resurrect: event_driven_save already registered, skipping")
		return
	end
	_event_driven_save_registered = true

	opts = opts or {}
	if opts.save_workspaces == nil then
		opts.save_workspaces = true
	end

	local last_structure = {}

	local function do_save(window)
		wezterm.emit("resurrect.state_manager.event_driven_save.start", opts)

		if opts.save_workspaces then
			pub.save_workspace_full()
		end

		if opts.save_windows then
			local mux_win = window:mux_window()
			local title = mux_win:get_title()
			if title ~= "" and title ~= nil then
				pub.save_state(require("resurrect.window_state").get_window_state(mux_win))
			end
		end

		if opts.save_tabs then
			local mux_win = window:mux_window()
			for _, mux_tab in ipairs(mux_win:tabs()) do
				local title = mux_tab:get_title()
				if title ~= "" and title ~= nil then
					pub.save_state(require("resurrect.tab_state").get_tab_state(mux_tab))
				end
			end
		end

		wezterm.emit("resurrect.state_manager.event_driven_save.finished", opts)
	end

	-- Save shortly after startup using update-status, which fires reliably
	-- within seconds of window creation.
	local initial_save_done = false
	wezterm.on("update-status", function(window, pane)
		if not initial_save_done then
			initial_save_done = true
			do_save(window)
		end
	end)

	-- Save when the pane/tab structure changes (new split, new tab, closed pane).
	wezterm.on("pane-focus-changed", function(window, pane)
		local win_id = tostring(window:window_id())
		local tabs = window:mux_window():tabs()
		local pane_count = 0
		for _, tab in ipairs(tabs) do
			pane_count = pane_count + #tab:panes()
		end
		local sig = #tabs .. ":" .. pane_count
		if last_structure[win_id] ~= sig then
			last_structure[win_id] = sig
			do_save(window)
		end
	end)

	-- Optional: also save when the shell reports a user-defined variable change.
	if opts.user_var then
		wezterm.on("user-var-changed", function(window, pane, name, value)
			if name == opts.user_var then
				do_save(window)
			end
		end)
	end
end

---Writes the current state name and type
---@param name string
---@param type string
---@return boolean
---@return string|nil
function pub.write_current_state(name, type)
	local file_path = pub.save_state_dir .. utils.separator .. "current_state"
	local handle = io.open(file_path, "w")
	if not handle then
		wezterm.log_error("resurrect: could not open current_state for writing: " .. file_path)
		return false, "could not open file"
	end
	handle:write(string.format("%s\n%s", name, type))
	handle:flush()
	handle:close()
	return true, nil
end

---callback for resurrecting workspaces on startup
---@return boolean
---@return string|nil
function pub.resurrect_on_gui_startup()
	local file_path = pub.save_state_dir .. utils.separator .. "current_state"
	local suc, err = pcall(function()
		local file = io.open(file_path, "r")
		if not file then
			error("Could not open file: " .. file_path)
		end
		local name = file:read("*line")
		local state_type = file:read("*line")
		file:close()
		if state_type == "workspace" then
			require("resurrect.workspace_state").restore_workspace(pub.load_state(name, state_type), {
				spawn_in_workspace = true,
				relative = true,
				restore_text = true,
				on_pane_restore = require("resurrect.tab_state").default_on_pane_restore,
			})
			wezterm.mux.set_active_workspace(name)
		end
	end)
	if not suc then
		wezterm.log_error("resurrect: gui_startup restore failed: " .. tostring(err))
		wezterm.emit("resurrect.error", "gui_startup restore failed: " .. tostring(err))
	end
	return suc, err
end

---@param file_path string
function pub.delete_state(file_path)
	wezterm.emit("resurrect.state_manager.delete_state.start", file_path)
	-- Path confinement: reject traversal attempts, absolute paths, and
	-- non-JSON files to prevent arbitrary file deletion.
	if file_path:find("%.%.") then
		wezterm.log_error("resurrect: delete_state rejected path with '..': " .. file_path)
		wezterm.emit("resurrect.error", "Invalid path: directory traversal not allowed")
		return
	end
	-- Reject absolute paths (Unix /... or Windows C:\...)
	if file_path:match("^[/\\]") or file_path:match("^%a:") then
		wezterm.log_error("resurrect: delete_state rejected absolute path: " .. file_path)
		wezterm.emit("resurrect.error", "Invalid path: absolute paths not allowed")
		return
	end
	-- Only allow deleting .json state files
	if not file_path:match("%.json$") then
		wezterm.log_error("resurrect: delete_state rejected non-JSON path: " .. file_path)
		wezterm.emit("resurrect.error", "Invalid path: only .json files can be deleted")
		return
	end
	-- Use explicit separator to avoid path join fragility
	local path = pub.save_state_dir .. utils.separator .. file_path
	local success = os.remove(path)
	if not success then
		wezterm.emit("resurrect.error", "Failed to delete state: " .. path)
		wezterm.log_error("Failed to delete state: " .. path)
	end
	wezterm.emit("resurrect.state_manager.delete_state.finished", file_path)
end

--- Merges user-supplied options with default options
--- @param user_opts encryption_opts
function pub.set_encryption(user_opts)
	require("resurrect.file_io").set_encryption(user_opts)
end

---Changes the directory to save the state to
---@param directory string
function pub.change_state_save_dir(directory)
	local types = { "workspace", "window", "tab", "instances" }
	for _, type in ipairs(types) do
		utils.ensure_folder_exists(directory .. utils.separator .. type)
	end
	pub.save_state_dir = directory
end

function pub.set_max_nlines(max_nlines)
	require("resurrect.pane_tree").max_nlines = max_nlines
end

return pub
