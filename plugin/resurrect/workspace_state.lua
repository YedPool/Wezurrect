local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local window_state_mod = require("resurrect.window_state")
local utils = require("resurrect.utils")

local pub = {}

-- Whether restoring a window resizes it to the size it was saved at. This is
-- WezTerm-side sizing that has always happened, independently of
-- restore_window_geometry; set resize_window = false in setup() to leave the
-- window alone entirely. A per-call opts.resize_window still wins.
pub.resize_window_default = true

---restore workspace state
---@param workspace_state workspace_state
---@param opts? restore_opts
function pub.restore_workspace(workspace_state, opts)
	if workspace_state == nil then
		return
	end

	wezterm.emit("resurrect.workspace_state.restore_workspace.start")
	if opts == nil then
		opts = {}
	end

	for i, window_state in ipairs(workspace_state.window_states) do
		if i == 1 and opts.window then
			-- Geometry first, and before any tab is restored: scrollback is
			-- injected to fill the pane it lands in, so the window has to be the
			-- size it will end up at before that happens.
			local geometry = window_state.geometry
			local resize = opts.resize_window
			if resize == nil then
				resize = pub.resize_window_default
			end
			-- inner size is in pixels. Skipped entirely when we have geometry:
			-- that restores the outer rect the window actually had, so letting
			-- this run first would only resize it twice.
			if resize and not geometry then
				opts.window:gui_window():set_inner_size(window_state.size.pixel_width, window_state.size.pixel_height)
			end
			require("resurrect.window_geometry").apply(opts.window:gui_window(), geometry)
			if not opts.close_open_tabs then
				opts.tab = opts.window:active_tab()
				if not opts.close_open_panes then
					opts.pane = opts.window:active_pane()
				end
			end
		else
			local first_pane_tree = window_state.tabs[1].pane_tree
			local spawn_window_args = {
				width = window_state.size.cols,
				height = window_state.size.rows,
			}
			-- The window's initial pane is spawned in the default domain, so a
			-- WSL tab's POSIX cwd is meaningless (and unresolvable) here. That
			-- tab is respawned in its own domain by restore_window, which puts
			-- it in the right directory.
			if not utils.is_wsl_domain(first_pane_tree.domain) then
				spawn_window_args.cwd = first_pane_tree.cwd
			end
			if opts.spawn_in_workspace then
				spawn_window_args.workspace = workspace_state.workspace
			end
			opts.tab, opts.pane, opts.window = wezterm.mux.spawn_window(spawn_window_args)
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
---@param opts? {capture_geometry: boolean?} forwarded to get_window_state
---@return workspace_state
function pub.get_workspace_state(opts)
	local workspace_state = {
		workspace = wezterm.mux.get_active_workspace(),
		window_states = {},
	}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		if mux_win:get_workspace() == workspace_state.workspace then
			table.insert(workspace_state.window_states, window_state_mod.get_window_state(mux_win, opts))
		end
	end
	return workspace_state
end

return pub
