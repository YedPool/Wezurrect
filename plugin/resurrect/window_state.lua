local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local tab_state_mod = require("resurrect.tab_state")
local state_manager_mod = require("resurrect.state_manager")
local pub = {}


---Returns the state of the window
---@param window MuxWindow
---@param opts? {capture_geometry: boolean?} capture_geometry costs a subprocess,
---       so only the periodic and manual saves ask for it
---@return window_state
function pub.get_window_state(window, opts)
	local window_state = {
		title = window:get_title(),
		tabs = {},
	}

	-- Every save carries geometry, but only the ones that ask for it pay to read
	-- it fresh. The rest reuse the last value seen, so a save triggered by
	-- opening a tab does not erase the position a periodic save recorded.
	local window_geometry = require("resurrect.window_geometry")
	if opts and opts.capture_geometry then
		window_state.geometry = window_geometry.capture()
	else
		window_state.geometry = window_geometry.last_known()
	end

	local tabs = window:tabs_with_info()

	for i, tab in ipairs(tabs) do
		local tab_state = tab_state_mod.get_tab_state(tab.tab)
		tab_state.is_active = tab.is_active
		window_state.tabs[i] = tab_state
	end

	window_state.size = tabs[1].tab:get_size()

	return window_state
end

---Force closes all other tabs in the window but one
---@param window MuxWindow
---@param tab_to_keep MuxTab
local function close_all_other_tabs(window, tab_to_keep)
	for _, tab in ipairs(window:tabs()) do
		if tab:tab_id() ~= tab_to_keep:tab_id() then
			tab:activate()
			window
				:gui_window()
				:perform_action(wezterm.action.CloseCurrentTab({ confirm = false }), window:active_pane())
		end
	end
end

--- Can the tab we were handed stand in for this saved tab?
---
--- Only if it is already in the right domain. The window a restore starts from
--- was spawned before anything was known about what it would hold, so it runs
--- whatever default_prog says -- cmd or PowerShell on Windows. Reusing it for a
--- saved WSL tab produces a pane that is not the shell it claims to be: the
--- restore then sends it a POSIX cd, and anything else the tab was running, in a
--- shell that cannot make sense of either.
---@param pane Pane|nil the tab's existing pane
---@param pane_tree pane_tree the saved pane to restore into it
---@return boolean
local function can_reuse_tab(pane, pane_tree)
	local wanted = pane_tree and pane_tree.domain
	if not wanted or not pane then
		-- Nothing recorded to contradict; reuse as before.
		return true
	end
	local ok, actual = pcall(pane.get_domain_name, pane)
	if not ok then
		return true
	end
	return actual == wanted
end

--- Close a tab we ended up not needing.
---@param window MuxWindow
---@param tab MuxTab
local function close_tab(window, tab)
	pcall(function()
		tab:activate()
		window:gui_window():perform_action(wezterm.action.CloseCurrentTab({ confirm = false }), tab:active_pane())
	end)
end

---restore window state
---@param window MuxWindow
---@param window_state window_state
---@param opts? restore_opts
function pub.restore_window(window, window_state, opts)
	wezterm.emit("resurrect.window_state.restore_window.start")
	if opts == nil then
		opts = {}
	end

	if window_state.title then
		window:set_title(window_state.title)
	end

	local active_tab
	-- The tab we were handed but could not use, closed once the restore is done
	-- rather than left behind as a stray shell.
	local unusable_tab
	for i, tab_state in ipairs(window_state.tabs) do
		local tab
		if i == 1 and opts.tab and can_reuse_tab(opts.pane, tab_state.pane_tree) then
			tab = opts.tab
		else
			if i == 1 and opts.tab then
				unusable_tab = opts.tab
			end
			local spawn_tab_args = tab_state_mod.apply_spawn_target({}, tab_state.pane_tree)
			tab, opts.pane, _ = window:spawn_tab(spawn_tab_args)
		end

		if i == 1 and opts.close_open_tabs then
			close_all_other_tabs(window, tab)
		end

		tab_state_mod.restore_tab(tab, tab_state, opts)
		if tab_state.is_active then
			active_tab = tab
		end

		if tab_state.is_zoomed then
			tab:set_zoomed(true)
		end
	end

	-- Before activating, so closing it cannot steal focus from the tab that
	-- should end up in front.
	if unusable_tab then
		close_tab(window, unusable_tab)
	end

	if active_tab then
		active_tab:activate()
	end
	wezterm.emit("resurrect.window_state.restore_window.finished")
end

function pub.save_window_action()
	return wezterm.action_callback(function(win, pane)
		local mux_win = win:mux_window()
		if mux_win:get_title() == "" then
			win:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter new window title",
					action = wezterm.action_callback(function(window, _, title)
						if title then
							window:mux_window():set_title(title)
							local state = pub.get_window_state(mux_win)
							state_manager_mod.save_state(state)
						end
					end),
				}),
				pane
			)
		elseif mux_win:get_title() then
			local state = pub.get_window_state(mux_win)
			state_manager_mod.save_state(state)
		end
	end)
end

-- Expose internals for unit testing only
pub._test = {
	can_reuse_tab = can_reuse_tab,
}

return pub
