local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local pane_tree_mod = require("resurrect.pane_tree")
local state_manager_mod = require("resurrect.state_manager")
local process_handlers = require("resurrect.process_handlers")
local restore_guard = require("resurrect.restore_guard")
local utils = require("resurrect.utils")
local pub = {}

-- Use shared CWD validation from utils to prevent command injection
-- when sending cd commands via send_text().
local is_safe_cwd = utils.is_safe_cwd

---Function used to split panes when mapping over the pane_tree
---@param opts restore_opts
---@return fun(acc: {active_pane: Pane, is_zoomed: boolean}, pane_tree: pane_tree): {active_pane: Pane, is_zoomed: boolean}
local function make_splits(opts)
	if opts == nil then
		opts = {}
	end

	return function(acc, pane_tree)
		local pane = pane_tree.pane

		if opts.on_pane_restore then
			opts.on_pane_restore(pane_tree)
		end

		local bottom = pane_tree.bottom
		if bottom then
			local split_args = { direction = "Bottom", cwd = bottom.cwd }
			if opts.relative then
				split_args.size = bottom.height / (pane_tree.height + bottom.height)
			elseif opts.absolute then
				split_args.size = bottom.height
			end

			bottom.pane = pane:split(split_args)
		end

		local right = pane_tree.right
		if right then
			local split_args = { direction = "Right", cwd = right.cwd }
			if opts.relative then
				split_args.size = right.width / (pane_tree.width + right.width)
			elseif opts.absolute then
				split_args.size = right.width
			end

			right.pane = pane:split(split_args)
		end

		if pane_tree.is_active then
			acc.active_pane = pane_tree.pane
		end

		if pane_tree.is_zoomed then
			acc.is_zoomed = true
		end

		return acc
	end
end

---creates and returns the state of the tab
---@param tab MuxTab
---@return tab_state
function pub.get_tab_state(tab)
	local panes = tab:panes_with_info()

	local function is_zoomed()
		for _, pane in ipairs(panes) do
			if pane.is_zoomed then
				return true
			end
		end
		return false
	end

	local tab_state = {
		title = tab:get_title(),
		is_zoomed = is_zoomed(),
		pane_tree = pane_tree_mod.create_pane_tree(panes),
	}

	return tab_state
end

---Force closes all other tabs in the window but one
---@param tab MuxTab
---@param pane_to_keep Pane
local function close_all_other_panes(tab, pane_to_keep)
	for _, pane in ipairs(tab:panes()) do
		if pane:pane_id() ~= pane_to_keep:pane_id() then
			pane:activate()
			tab:window():gui_window():perform_action(wezterm.action.CloseCurrentPane({ confirm = false }), pane)
		end
	end
end

---restore a tab
---@param tab MuxTab
---@param tab_state tab_state
---@param opts restore_opts
function pub.restore_tab(tab, tab_state, opts)
	wezterm.emit("resurrect.tab_state.restore_tab.start")
	opts = utils.shallow_copy(opts)
	-- A restore types into panes (cd, then the program's restore command).
	-- It may only do that to a pane it created itself, flagged by
	-- opts.pane_is_new. Any other pane may hold a running program -- typing
	-- "cd ..." into a live Claude session submits it as a prompt -- so it is
	-- left alone and the tab's first pane becomes a new split instead.
	if opts.pane and opts.pane_is_new then
		tab_state.pane_tree.pane = opts.pane
		-- Set the CWD of the reused pane to match saved state.
		-- Validate the CWD contains no shell metacharacters to prevent
		-- command injection via tampered state files.
		if is_safe_cwd(tab_state.pane_tree.cwd) then
			opts.pane:send_text("cd " .. wezterm.shell_join_args({ tab_state.pane_tree.cwd }) .. "\r\n")
		elseif tab_state.pane_tree.cwd and tab_state.pane_tree.cwd ~= "" then
			wezterm.log_error("resurrect: rejected suspicious CWD: " .. tab_state.pane_tree.cwd)
		end
	else
		local split_args = { cwd = tab_state.pane_tree.cwd }
		if tab_state.pane_tree.domain then
			split_args.domain = { DomainName = tab_state.pane_tree.domain }
		end
		local new_pane = tab:active_pane():split(split_args)
		tab_state.pane_tree.pane = new_pane
	end

	if opts.close_open_panes then
		close_all_other_panes(tab, tab_state.pane_tree.pane)
	end

	if tab_state.title then
		tab:set_title(tab_state.title)
	end

	local acc = pane_tree_mod.fold(tab_state.pane_tree, { is_zoomed = false }, make_splits(opts))
	if acc.active_pane then
		acc.active_pane:activate()
	end
	wezterm.emit("resurrect.tab_state.restore_tab.finished")
end

function pub.save_tab_action()
	return wezterm.action_callback(function(win, pane)
		local tab = pane:tab()
		if tab:get_title() == "" then
			win:perform_action(
				wezterm.action.PromptInputLine({
					description = "Enter new tab title",
					action = wezterm.action_callback(function(_, callback_pane, title)
						if title then
							callback_pane:tab():set_title(title)
							local state = pub.get_tab_state(tab)
							state_manager_mod.save_state(state)
						end
					end),
				}),
				pane
			)
		elseif tab:get_title() then
			local state = pub.get_tab_state(tab)
			state_manager_mod.save_state(state)
		end
	end)
end

-- Known safe executables that can be restored via send_text.
-- Process names not in this set will be logged but not auto-launched,
-- preventing arbitrary command execution from tampered state files.
local SAFE_RESTORE_PROCESSES = {
	vim = true, nvim = true, gvim = true, vi = true,
	htop = true, btop = true, top = true,
	less = true, more = true, man = true,
	nano = true,
	tmux = true, screen = true,
}

-- Delay in seconds before sending process restore commands.
-- Shell interpreters (especially PowerShell on Windows) need time to initialize
-- before they can accept input. Without this delay, commands sent during
-- gui-startup get swallowed by the shell's init sequence.
pub.process_restore_delay_seconds = 3

--- The command a restore would type into a pane to bring its program back,
--- or nil when the pane has no program to restore.
---@param pane_tree pane_tree
---@param quiet boolean? do not log an unrecognized process (used when only looking at a saved state)
---@return string|nil
---@return boolean rejected a handler (e.g. Claude Code) claimed the process but refused its saved command
function pub.get_pane_restore_command(pane_tree, quiet)
	if type(pane_tree.process) ~= "table" or not pane_tree.process.argv then
		return nil, false
	end
	-- Check registered process handlers first (e.g., Claude Code)
	local restore_cmd, rejected = process_handlers.get_restore_command(pane_tree.process, pane_tree)
	if rejected then
		-- Never fall back to replaying the argv of a process a handler owns.
		return nil, true
	end
	if not restore_cmd then
		-- Fall back to allowlist-based argv replay
		local proc_name = pane_tree.process.name or ""
		local base_name = proc_name:match("[/\\]?([^/\\]+)$") or proc_name
		base_name = base_name:gsub("%.exe$", ""):lower()

		if SAFE_RESTORE_PROCESSES[base_name] then
			restore_cmd = wezterm.shell_join_args(pane_tree.process.argv)
		elseif not quiet then
			wezterm.log_warn(
				"resurrect: skipping restore of unrecognized process: " .. base_name
					.. " (add to SAFE_RESTORE_PROCESSES or register a process_handler)"
			)
		end
	end
	return restore_cmd, false
end

--- Function to restore text or processes when restoring panes
---@param pane_tree pane_tree
function pub.default_on_pane_restore(pane_tree)
	local pane = pane_tree.pane

	-- Spawn process if process info was saved (alt screen OR registered handler),
	-- otherwise restore scrollback text. Some TUI apps (e.g., Claude Code) don't
	-- use the alt screen buffer but still need process-based restoration.
	if pane_tree.process and pane_tree.process.argv then
		local restore_cmd, rejected = pub.get_pane_restore_command(pane_tree)

		if rejected then
			-- The saved command was refused before any line was built.
			restore_guard.note_skipped({
				state = "unknown",
				reason = "the saved command is not exactly 'claude --resume <session id>', so it is not typed",
			}, pane:pane_id())
			restore_guard.schedule_report(pub.process_restore_delay_seconds + 1)
		elseif restore_cmd then
			local pane_id = pane:pane_id()
			-- THE ONLY PLACE A RESTORE COMMAND IS SENT. Ask the guard first: a
			-- command that would resume a Claude session which is already
			-- running (or whose state cannot be established) is not sent, and
			-- the pane stays the plain shell it was created as.
			local cwd = pane_tree.process.cwd
			if cwd == nil or cwd == "" then
				cwd = pane_tree.cwd
			end
			local verdict = restore_guard.check_command(restore_cmd, cwd)
			if verdict.allow and verdict.target then
				-- A Claude resume line is never typed as the state file gave
				-- it. The guard has checked its shape and rebuilt it from
				-- fixed parts; the directory has passed is_safe_cwd.
				restore_cmd = verdict.target.line
				if cwd ~= nil and cwd ~= "" then
					restore_cmd = "cd " .. wezterm.shell_join_args({ cwd }) .. "\r\n" .. restore_cmd
				end
			end
			if not verdict.allow then
				restore_guard.note_skipped(verdict, pane_id)
			else
				-- Delay sending the command so the shell has time to initialize.
				-- pane:send_text() during gui-startup fires before the shell is ready,
				-- causing the command to be lost (especially on Windows with PowerShell).
				wezterm.time.call_after(pub.process_restore_delay_seconds, function()
					local target_pane = wezterm.mux.get_pane(pane_id)
					if target_pane then
						target_pane:send_text(restore_cmd .. "\r\n")
						if verdict.target then
							restore_guard.note_resumed()
						end
					end
				end)
			end
			-- One summary line after the last pane's command has gone out.
			restore_guard.schedule_report(pub.process_restore_delay_seconds + 1)
		end
	elseif pane_tree.text then
		pane:inject_output(pane_tree.text:gsub("%s+$", ""))
		-- Send newline to trigger a fresh shell prompt at the correct position
		pane:send_text("\r\n")
	end
end

return pub
