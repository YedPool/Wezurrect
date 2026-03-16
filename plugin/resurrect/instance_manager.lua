-- instance_manager.lua -- Per-instance state management
--
-- Each WezTerm process gets a unique instance ID (time + random) and saves
-- independently to state/instances/. On startup or Alt+R, an InputSelector
-- shows all saved instances for restore/delete/rename.
--
-- This module owns all instance lifecycle logic. state_manager.lua stays
-- focused on named workspace/window/tab saves.

local wezterm = require("wezterm") --[[@as Wezterm]]
local file_io = require("resurrect.file_io")
local utils = require("resurrect.utils")

local pub = {}

-- Generated once per WezTerm process at setup() time
pub.instance_id = nil

-- Persistent display name for this instance (carries over on restore)
pub.display_name = nil

-- Configuration (set via setup())
pub.retention_days = 7
pub.auto_restore_prompt = true

-- Cached reference to state_manager (avoids re-requiring on every call)
local _state_manager = nil
local function get_state_manager()
	if not _state_manager then
		_state_manager = require("resurrect.state_manager")
	end
	return _state_manager
end

-- ---------------------------------------------------------------------------
-- Instance ID
-- ---------------------------------------------------------------------------

--- Generate a unique instance ID: epoch seconds + underscore + 5-digit random.
--- Called once during setup(). Uses os.clock() for sub-second entropy to reduce
--- collision risk when multiple WezTerm processes start in the same second.
function pub.init_instance_id()
	math.randomseed(os.time() * 1000 + math.floor(os.clock() * 1000000))
	pub.instance_id = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
	return pub.instance_id
end

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

--- Return the absolute path to the instances directory.
---@return string
function pub.get_instances_dir()
	return get_state_manager().save_state_dir .. utils.separator .. "instances"
end

--- Validate that an instance ID matches the expected format.
--- Rejects anything that could be a path traversal attempt.
---@param id string
---@return boolean
local function is_valid_instance_id(id)
	return type(id) == "string" and id:match("^%d+_%d+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Sanitization helpers
-- ---------------------------------------------------------------------------

--- Strip control characters (ASCII 0-31) and ANSI escape sequences from a
--- string. Used to sanitize display_name and tab_summaries before rendering
--- in the UI, preventing terminal escape injection from tampered .meta files.
---@param str string
---@return string
local function sanitize_display_string(str)
	if not str or type(str) ~= "string" then
		return ""
	end
	-- Strip ANSI escape sequences (ESC [ ... m and similar)
	str = str:gsub(string.char(27) .. "%[[^m]*m", "")
	-- Strip all remaining control characters (ASCII 0-31 except tab/newline)
	str = str:gsub("[\0-\8\11-\12\14-\31]", "")
	-- Replace tabs and newlines with spaces
	str = str:gsub("[\9\10\13]", " ")
	return str
end

-- ---------------------------------------------------------------------------
-- Meta helpers
-- ---------------------------------------------------------------------------

--- Build the .meta file path for a given instance ID.
---@param instance_id string
---@return string
local function meta_path(instance_id)
	return pub.get_instances_dir() .. utils.separator .. instance_id .. ".meta"
end

--- Build the .json state file path for a given instance ID.
---@param instance_id string
---@return string
local function state_path(instance_id)
	return pub.get_instances_dir() .. utils.separator .. instance_id .. ".json"
end

--- Read and parse a .meta file. Returns nil on any failure.
---@param instance_id string
---@return table|nil
local function read_meta(instance_id)
	local path = meta_path(instance_id)
	local ok, content = file_io.read_file(path)
	if not ok or not content then
		return nil
	end
	local success, parsed = pcall(wezterm.json_parse, content)
	if not success then
		return nil
	end
	return parsed
end

--- Write a .meta file as JSON.
---@param instance_id string
---@param meta table
local function write_meta(instance_id, meta)
	local path = meta_path(instance_id)
	local json = wezterm.json_encode(meta)
	local ok, err = file_io.write_file(path, json)
	if not ok then
		wezterm.log_error("resurrect: failed to write instance meta: " .. tostring(err))
	end
end

--- Build tab summaries from workspace state for display in the selector.
--- Returns an array of short strings like "Claude Code", "PowerShell".
---@param workspace_state table
---@return string[]
local function build_tab_summaries(workspace_state)
	local summaries = {}
	if not workspace_state or not workspace_state.window_states then
		return summaries
	end
	for _, win_state in ipairs(workspace_state.window_states) do
		if win_state.tabs then
			for _, tab in ipairs(win_state.tabs) do
				local title = tab.title or ""
				if title ~= "" then
					table.insert(summaries, title)
				end
			end
		end
	end
	return summaries
end

--- Count tabs across all windows in a workspace state.
---@param workspace_state table
---@return number
local function count_tabs(workspace_state)
	local count = 0
	if not workspace_state or not workspace_state.window_states then
		return count
	end
	for _, win_state in ipairs(workspace_state.window_states) do
		if win_state.tabs then
			count = count + #win_state.tabs
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- Core CRUD
-- ---------------------------------------------------------------------------

--- Save the current instance state and metadata.
--- Wraps workspace_state with instance_id, writes both .json and .meta files.
---@param workspace_state table
function pub.save_instance(workspace_state)
	if not pub.instance_id then
		return
	end

	-- Wrap state with instance ID
	local instance_state = {
		instance_id = pub.instance_id,
		workspace_state = workspace_state,
	}

	-- Write state JSON
	local json = wezterm.json_encode(instance_state)
	local ok, err = file_io.write_file(state_path(pub.instance_id), json)
	if not ok then
		wezterm.log_error("resurrect: failed to write instance state: " .. tostring(err))
		wezterm.emit("resurrect.error", "Failed to save instance state: " .. tostring(err))
		return
	end

	-- Write metadata (lightweight, for fast listing)
	local tab_summaries = build_tab_summaries(workspace_state)
	local meta = {
		instance_id = pub.instance_id,
		display_name = pub.display_name,
		last_save_epoch = os.time(),
		last_save = os.date("%Y-%m-%dT%H:%M:%S"),
		tab_count = count_tabs(workspace_state),
		tab_summaries = tab_summaries,
	}
	write_meta(pub.instance_id, meta)

	wezterm.emit("resurrect.instance_manager.save_instance.finished", pub.instance_id)
end

--- Load an instance's workspace state from disk.
--- Returns the workspace_state portion, or nil on failure.
--- Validates basic schema (workspace_state must be a table with window_states).
---@param instance_id string
---@return table|nil
function pub.load_instance(instance_id)
	if not is_valid_instance_id(instance_id) then
		wezterm.log_error("resurrect: load_instance rejected invalid ID: " .. tostring(instance_id))
		wezterm.emit("resurrect.error", "Invalid instance ID")
		return nil
	end

	local path = state_path(instance_id)
	local ok, content = file_io.read_file(path)
	if not ok or not content then
		wezterm.log_error("resurrect: could not read instance state: " .. path)
		return nil
	end

	local success, parsed = pcall(wezterm.json_parse, content)
	if not success or not parsed then
		wezterm.log_error("resurrect: invalid JSON in instance state: " .. path)
		return nil
	end

	-- Schema validation: workspace_state must be a table with window_states
	local ws = parsed.workspace_state
	if type(ws) ~= "table" or type(ws.window_states) ~= "table" then
		wezterm.log_error("resurrect: malformed instance state (missing workspace_state.window_states): " .. path)
		return nil
	end

	return ws
end

--- List all saved instances, newest first.
--- Reads only .meta files for speed, falls back gracefully if meta is missing.
---@return table[] array of { instance_id: string, meta: table }
function pub.list_instances()
	local instances_dir = pub.get_instances_dir()
	local results = {}

	-- Scan for .json files to find instance IDs, then read their .meta
	-- Use platform-appropriate directory listing
	local stdout
	if utils.is_windows then
		local success, output = wezterm.run_child_process({
			"powershell.exe", "-NoProfile", "-NoLogo", "-Command",
			string.format(
				"Get-ChildItem -Path '%s' -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }",
				instances_dir:gsub("'", "''")
			),
		})
		if success then
			stdout = output
		end
	else
		-- Use single-quote escaping (safe against $(), backticks, etc.)
		local safe_dir = instances_dir:gsub("'", "'\\''")
		local success, output = wezterm.run_child_process({
			"sh", "-c",
			"ls '" .. safe_dir .. "'/*.json 2>/dev/null | xargs -I{} basename {} .json",
		})
		if success then
			stdout = output
		end
	end

	if not stdout then
		return results
	end

	for id in stdout:gmatch("[^\r\n]+") do
		id = id:match("^%s*(.-)%s*$") -- trim whitespace
		if is_valid_instance_id(id) then
			local meta = read_meta(id) or {
				instance_id = id,
				last_save_epoch = 0,
				tab_count = 0,
				tab_summaries = {},
			}
			table.insert(results, { instance_id = id, meta = meta })
		end
	end

	-- Sort newest first by last_save_epoch
	table.sort(results, function(a, b)
		return (a.meta.last_save_epoch or 0) > (b.meta.last_save_epoch or 0)
	end)

	return results
end

--- Delete an instance's .json and .meta files.
---@param instance_id string
---@return boolean
function pub.delete_instance(instance_id)
	if not is_valid_instance_id(instance_id) then
		wezterm.log_error("resurrect: delete_instance rejected invalid ID: " .. tostring(instance_id))
		wezterm.emit("resurrect.error", "Invalid instance ID: path traversal rejected")
		return false
	end

	local json_path = state_path(instance_id)
	local meta_file = meta_path(instance_id)

	os.remove(json_path)
	os.remove(meta_file)

	wezterm.log_info("resurrect: deleted instance " .. instance_id)
	wezterm.emit("resurrect.instance_manager.delete_instance.finished", instance_id)
	return true
end

--- Remove instances older than retention_days.
function pub.cleanup_old_instances()
	local cutoff = os.time() - (pub.retention_days * 86400)
	local instances = pub.list_instances()
	for _, entry in ipairs(instances) do
		if (entry.meta.last_save_epoch or 0) < cutoff then
			pub.delete_instance(entry.instance_id)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Display formatting
-- ---------------------------------------------------------------------------

--- Deduplicate an array of strings and format with counts.
--- {"A", "B", "A"} -> {"A x2", "B"}. Preserves first-seen order.
---@param items string[]
---@return string[]
local function deduplicate_with_counts(items)
	local counts = {}
	local order = {}
	for _, s in ipairs(items) do
		if not counts[s] then
			counts[s] = 0
			table.insert(order, s)
		end
		counts[s] = counts[s] + 1
	end
	local parts = {}
	for _, name in ipairs(order) do
		if counts[name] > 1 then
			table.insert(parts, name .. " x" .. counts[name])
		else
			table.insert(parts, name)
		end
	end
	return parts
end

--- Format an instance summary line for the InputSelector.
--- Named:   "Orahvision Dev -- Claude Code, PowerShell [2 tabs]"
--- Unnamed: "Mar 13 16:45 -- Claude Code, PowerShell [2 tabs]"
---@param meta table
---@return string
function pub.format_instance_summary(meta)
	-- Sanitize tab summaries to prevent terminal escape injection
	local summaries = {}
	for _, s in ipairs(meta.tab_summaries or {}) do
		table.insert(summaries, sanitize_display_string(s))
	end

	local parts = deduplicate_with_counts(summaries)
	local tab_str = table.concat(parts, ", ")
	if tab_str == "" then
		tab_str = "(empty)"
	end

	local tab_count = meta.tab_count or 0
	local tab_label = tab_count == 1 and "1 tab" or (tab_count .. " tabs")

	-- Prefix: display_name or formatted date (sanitized)
	local prefix
	if meta.display_name and meta.display_name ~= "" then
		prefix = sanitize_display_string(meta.display_name)
	else
		local epoch = meta.last_save_epoch or 0
		if epoch > 0 then
			prefix = os.date("%b %d %H:%M", epoch)
		else
			prefix = "Unknown"
		end
	end

	return prefix .. " -- " .. tab_str .. " [" .. tab_label .. "]"
end

--- Rename an instance by updating its .meta display_name field.
--- Strips control characters from the name to prevent terminal escape injection.
---@param instance_id string
---@param new_name string
function pub.rename_instance(instance_id, new_name)
	if not is_valid_instance_id(instance_id) then
		return
	end

	-- Sanitize display name before storing
	new_name = sanitize_display_string(new_name)

	local meta = read_meta(instance_id)
	if not meta then
		meta = { instance_id = instance_id }
	end
	meta.display_name = new_name
	write_meta(instance_id, meta)

	-- If this is the current instance, update in memory too
	if instance_id == pub.instance_id then
		pub.display_name = new_name
	end
end

-- ---------------------------------------------------------------------------
-- Shared fuzzy-load restore callback
-- ---------------------------------------------------------------------------

--- Create a callback for fuzzy_loader.fuzzy_load that dispatches restore
--- based on state type (workspace/window/tab). Extracted to avoid duplication
--- between the "no instances" path and the "[Browse named saves]" action.
---@param restore_opts table
---@param fallback_pane table Pane to use for window/tab restore
---@return fun(id: string, label: string)
local function make_fuzzy_restore_callback(restore_opts, fallback_pane)
	return function(id, label)
		local state_type = id:match("^([^/\\]+)")
		local name = id:match("[/\\](.+)$")
		if name then
			name = name:gsub("%.json$", "")
		end
		local sm = get_state_manager()
		if state_type == "workspace" then
			local state = sm.load_state(name, "workspace")
			require("resurrect.workspace_state").restore_workspace(state, restore_opts)
		elseif state_type == "window" then
			local state = sm.load_state(name, "window")
			require("resurrect.window_state").restore_window(fallback_pane:window(), state, restore_opts)
		elseif state_type == "tab" then
			local state = sm.load_state(name, "tab")
			require("resurrect.tab_state").restore_tab(fallback_pane:tab(), state, restore_opts)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Selector UI
-- ---------------------------------------------------------------------------

--- Restore one or more instances. The first instance reuses the existing
--- window (via restore_opts.window) to avoid spawning an extra blank window.
--- Subsequent instances get their own new windows.
---@param instance_ids string[] array of instance IDs to restore
---@param window table GuiWindow whose MuxWindow to reuse for the first restore
---@param pane table Pane in that window
---@param restore_opts table options passed to restore_workspace
local function restore_instances(instance_ids, window, pane, restore_opts)
	for i, id in ipairs(instance_ids) do
		local old_meta = read_meta(id)
		local workspace_state = pub.load_instance(id)
		if workspace_state then
			-- First instance reuses the current window to avoid extra blank shell
			local opts = utils.tbl_deep_extend("force", restore_opts, {})
			if i == 1 then
				opts.window = pane:window()
				opts.pane = pane
			end

			require("resurrect.workspace_state").restore_workspace(workspace_state, opts)

			-- Carry over display_name from first restored instance
			if i == 1 and old_meta and old_meta.display_name and old_meta.display_name ~= "" then
				pub.display_name = old_meta.display_name
			end

			-- Auto-delete old instance after restore (it now has a new ID)
			pub.delete_instance(id)
		end
	end
end

--- Show the main instance selector with multi-select support.
--- Space (Enter) toggles selection, then pick "Restore selected" to restore all.
--- Esc dismisses to start a fresh terminal session.
---@param window table GuiWindow
---@param pane table Pane
---@param restore_opts table options passed to restore_workspace
---@param selected? table set of already-selected instance IDs (for re-showing after toggle)
function pub.show_instance_selector(window, pane, restore_opts, selected)
	selected = selected or {}
	local instances = pub.list_instances()

	-- If no instances, fall through to fuzzy_load for named saves
	if #instances == 0 then
		local fuzzy_loader = require("resurrect.fuzzy_loader")
		fuzzy_loader.fuzzy_load(window, pane, make_fuzzy_restore_callback(restore_opts, pane))
		return
	end

	-- Build choices with selection markers
	local choices = {}

	-- Count selections
	local sel_count = 0
	for _ in pairs(selected) do sel_count = sel_count + 1 end

	-- "Restore selected" at the top when there are selections
	if sel_count > 0 then
		table.insert(choices, {
			id = "__RESTORE_SELECTED__",
			label = ">>> Restore " .. sel_count .. " selected instance" .. (sel_count > 1 and "s" or "") .. " <<<",
		})
	end

	-- Instance entries with [x] / [ ] markers
	for _, entry in ipairs(instances) do
		local marker = selected[entry.instance_id] and "[x] " or "[ ] "
		table.insert(choices, {
			id = entry.instance_id,
			label = marker .. pub.format_instance_summary(entry.meta),
		})
	end

	-- Action entries at the bottom
	table.insert(choices, { id = "__BROWSE_NAMED__", label = "[Browse named saves]" })
	table.insert(choices, { id = "__RENAME_MODE__", label = "[Rename an instance]" })
	table.insert(choices, { id = "__DELETE_MODE__", label = "[Delete saved instances]" })

	window:perform_action(
		wezterm.action.InputSelector({
			action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
				if not id then
					-- Esc pressed: start fresh terminal (do nothing)
					return
				end

				if id == "__RESTORE_SELECTED__" then
					-- Restore all selected instances
					local ids = {}
					for _, entry in ipairs(instances) do
						if selected[entry.instance_id] then
							table.insert(ids, entry.instance_id)
						end
					end
					restore_instances(ids, inner_win, inner_pane, restore_opts)
					return
				end

				if id == "__BROWSE_NAMED__" then
					local fuzzy_loader = require("resurrect.fuzzy_loader")
					fuzzy_loader.fuzzy_load(
						inner_win, inner_pane,
						make_fuzzy_restore_callback(restore_opts, inner_pane),
						{ ignore_instances = true }
					)
					return
				end

				if id == "__RENAME_MODE__" then
					pub.show_rename_selector(inner_win, inner_pane, restore_opts)
					return
				end

				if id == "__DELETE_MODE__" then
					pub.show_delete_selector(inner_win, inner_pane, restore_opts)
					return
				end

				-- Toggle selection on this instance and re-show the selector
				if selected[id] then
					selected[id] = nil
				else
					selected[id] = true
				end
				pub.show_instance_selector(inner_win, inner_pane, restore_opts, selected)
			end),
			title = "Restore Instances",
			description = "Enter = toggle selection, then pick 'Restore selected'. Esc = start fresh terminal",
			choices = choices,
			fuzzy = false,
		}),
		pane
	)
end

--- Show the rename selector: pick an instance, then enter a name.
---@param window table
---@param pane table
---@param restore_opts table
function pub.show_rename_selector(window, pane, restore_opts)
	local instances = pub.list_instances()
	if #instances == 0 then
		return
	end

	local choices = {}
	for _, entry in ipairs(instances) do
		table.insert(choices, {
			id = entry.instance_id,
			label = pub.format_instance_summary(entry.meta),
		})
	end

	window:perform_action(
		wezterm.action.InputSelector({
			action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
				if not id then
					return
				end

				-- Prompt for a name using InputSelector with a text entry
				inner_win:perform_action(
					wezterm.action.PromptInputLine({
						description = "Enter a name for this instance:",
						action = wezterm.action_callback(function(name_win, name_pane, name)
							if name and name ~= "" then
								pub.rename_instance(id, name)
							end
							-- Re-show main selector after rename
							pub.show_instance_selector(name_win, name_pane, restore_opts)
						end),
					}),
					inner_pane
				)
			end),
			title = "Rename Instance",
			description = "Select an instance to rename",
			choices = choices,
			fuzzy = false,
		}),
		pane
	)
end

--- Show the delete selector: pick instances to delete, one at a time.
---@param window table
---@param pane table
---@param restore_opts table
function pub.show_delete_selector(window, pane, restore_opts)
	local instances = pub.list_instances()
	if #instances == 0 then
		-- No more instances to delete, return to main selector
		pub.show_instance_selector(window, pane, restore_opts)
		return
	end

	local choices = {}
	for _, entry in ipairs(instances) do
		table.insert(choices, {
			id = entry.instance_id,
			label = pub.format_instance_summary(entry.meta),
		})
	end
	table.insert(choices, { id = "__BACK__", label = "[Back to main selector]" })

	window:perform_action(
		wezterm.action.InputSelector({
			action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
				if not id or id == "__BACK__" then
					pub.show_instance_selector(inner_win, inner_pane, restore_opts)
					return
				end

				pub.delete_instance(id)
				-- Re-show delete selector for deleting multiple
				pub.show_delete_selector(inner_win, inner_pane, restore_opts)
			end),
			title = "Delete Instance",
			description = "Select an instance to DELETE (permanent). Esc = back",
			choices = choices,
			fuzzy = false,
		}),
		pane
	)
end

-- ---------------------------------------------------------------------------
-- Startup integration
-- ---------------------------------------------------------------------------

--- Auto-restore callback for gui-startup.
--- 1. Cleans up old instances
--- 2. If instances exist and auto_restore_prompt: spawns window + shows selector
--- 3. If no instances: falls back to state_manager.resurrect_on_gui_startup()
function pub.auto_restore_on_startup()
	pub.cleanup_old_instances()

	local instances = pub.list_instances()

	if #instances == 0 then
		-- Backward compat: fall back to current_state mechanism
		get_state_manager().resurrect_on_gui_startup()
		return
	end

	if not pub.auto_restore_prompt then
		-- User disabled auto-prompt; they can use Alt+R manually
		return
	end

	-- Spawn a default window for the selector UI. The first restored instance
	-- will reuse this window (via restore_opts.window) so no extra blank
	-- shell window remains.
	wezterm.mux.spawn_window({})

	wezterm.time.call_after(1, function()
		local gui_windows = wezterm.gui.gui_windows()
		if #gui_windows > 0 then
			local gui_win = gui_windows[1]
			local active_pane = gui_win:active_pane()
			local restore_opts = {
				relative = true,
				restore_text = true,
				on_pane_restore = require("resurrect.tab_state").default_on_pane_restore,
			}
			pub.show_instance_selector(gui_win, active_pane, restore_opts)
		end
	end)
end

return pub
