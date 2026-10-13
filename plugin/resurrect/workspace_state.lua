local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local window_state_mod = require("resurrect.window_state")
local utils = require("resurrect.utils")

local pub = {}

---restore workspace state
---@param workspace_state workspace_state
---@param opts? restore_opts
function pub.restore_workspace(workspace_state, opts)
	if workspace_state == nil then
		return
	end

	wezterm.emit("resurrect.workspace_state.restore_workspace.start")
	opts = utils.shallow_copy(opts)

	for i, window_state in ipairs(workspace_state.window_states) do
		if i == 1 and opts.window then
			-- inner size is in pixels
			if opts.resize_window == true or opts.resize_window == nil then
				opts.window:gui_window():set_inner_size(window_state.size.pixel_width, window_state.size.pixel_height)
			end
			if not opts.close_open_tabs then
				-- The window's active tab and pane are reused for the first
				-- restored tab only when the caller vouches that the pane is a
				-- blank shell of its own (opts.pane_is_new). Otherwise the pane
				-- may hold a running program, so nothing is typed into it and
				-- the restored tabs are added to the window as new tabs.
				local active_pane = opts.window:active_pane()
				if opts.pane_is_new and opts.pane and opts.pane:pane_id() == active_pane:pane_id() then
					opts.tab = opts.window:active_tab()
				else
					opts.tab = nil
					opts.pane = nil
					opts.pane_is_new = nil
				end
			end
		else
			local spawn_window_args = {
				width = window_state.size.cols,
				height = window_state.size.rows,
				cwd = window_state.tabs[1].pane_tree.cwd,
			}
			if opts.spawn_in_workspace then
				spawn_window_args.workspace = workspace_state.workspace
			end
			opts.tab, opts.pane, opts.window = wezterm.mux.spawn_window(spawn_window_args)
			-- A pane this restore just created: restore_tab may type into it.
			opts.pane_is_new = true
		end

		window_state_mod.restore_window(opts.window, window_state, opts)
	end
	if opts.spawn_in_workspace then
		wezterm.mux.set_active_workspace(workspace_state.workspace)
	else
		wezterm.mux.rename_workspace(wezterm.mux.get_active_workspace(), workspace_state.workspace)
	end
	wezterm.emit("resurrect.workspace_state.restore_workspace.finished")
end

---Returns the state of the current workspace
---@return workspace_state
function pub.get_workspace_state()
	local workspace_state = {
		workspace = wezterm.mux.get_active_workspace(),
		window_states = {},
	}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		if mux_win:get_workspace() == workspace_state.workspace then
			table.insert(workspace_state.window_states, window_state_mod.get_window_state(mux_win))
		end
	end
	return workspace_state
end

return pub
