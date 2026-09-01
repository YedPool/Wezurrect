local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local pane_tree_mod = require("resurrect.pane_tree")
local state_manager_mod = require("resurrect.state_manager")
local process_handlers = require("resurrect.process_handlers")
local utils = require("resurrect.utils")
local pub = {}

-- Use shared CWD validation from utils to prevent command injection
-- when sending cd commands via send_text().
local is_safe_cwd = utils.is_safe_cwd

-- What "press Enter" is when typing into a pane: a bare carriage return.
--
-- Not "\r\n". PSReadLine submits the line on CR and then takes the LF as a
-- second keypress meaning "insert a newline in the buffer", which leaves
-- PowerShell sitting at its `>>` continuation prompt. The command does run, but
-- the shell is left mid-command, and the next thing typed there is swallowed
-- into that continuation instead of being executed.
local SUBMIT = "\r"

--- Fill in the domain and cwd of spawn/split arguments for a pane.
---
--- WSL panes deliberately omit cwd. WezTerm resolves a spawn cwd in Windows
--- terms before handing it to wsl.exe, so a POSIX path such as /home/you either
--- fails that check or lands somewhere unintended. Those panes cd themselves
--- once their shell is up (see build_cd_command), which is also the only way to
--- reach a path that has no Windows spelling.
---@param args table spawn or split arguments, mutated in place
---@param pane_tree pane_tree
---@return table args
function pub.apply_spawn_target(args, pane_tree)
	if pane_tree.domain then
		args.domain = { DomainName = pane_tree.domain }
	end
	if utils.is_wsl_domain(pane_tree.domain) then
		pane_tree.restore_cwd = true
	else
		args.cwd = pane_tree.cwd
		pane_tree.restore_cwd = false
	end
	return args
end
local apply_spawn_target = pub.apply_spawn_target

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
			local split_args = apply_spawn_target({ direction = "Bottom" }, bottom)
			if opts.relative then
				split_args.size = bottom.height / (pane_tree.height + bottom.height)
			elseif opts.absolute then
				split_args.size = bottom.height
			end

			bottom.pane = pane:split(split_args)
		end

		local right = pane_tree.right
		if right then
			local split_args = apply_spawn_target({ direction = "Right" }, right)
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
	if opts.pane then
		tab_state.pane_tree.pane = opts.pane
		-- A reused pane we did not spawn ourselves started in whatever directory
		-- the caller happened to be in, so it has to cd itself. That is done
		-- from default_on_pane_restore, so every write into the pane goes
		-- through the same delayed, correctly ordered code path. When the caller
		-- did spawn the pane, apply_spawn_target has already recorded whether
		-- the cwd was handed to the spawn.
		if tab_state.pane_tree.restore_cwd == nil then
			tab_state.pane_tree.restore_cwd = true
		end
	else
		local split_args = apply_spawn_target({}, tab_state.pane_tree)
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
	claude = true,
	nano = true,
	tmux = true, screen = true,
}

-- Delay in seconds before sending keystrokes into a restored pane.
-- Shell interpreters (especially PowerShell on Windows) need time to initialize
-- before they can accept input. Without this delay, commands sent during
-- gui-startup get swallowed by the shell's init sequence.
pub.process_restore_delay_seconds = 3

--- Write a pane's saved scrollback into it, scrolled up out of the visible
--- screen so that the shell draws its first prompt directly beneath it.
---
--- inject_output is invisible to the process driving the pty, and on Windows
--- both PowerShell and WSL run behind ConPTY, which paints the visible screen at
--- absolute positions of its own choosing. Anything we leave on screen is
--- therefore doomed twice over: ConPTY's first paint overwrites it, and the
--- shell's opening prompt lands at the top of the screen as though the restored
--- history were not there.
---
--- Padding the injected text with exactly enough newlines to push its last row
--- above the top of the viewport moves the whole history into the scrollback
--- buffer, which ConPTY neither knows about nor touches. The shell then gets a
--- blank screen to draw into, and the restored history sits immediately above
--- its prompt in the buffer -- scroll up and it is all there, in order.
---@param pane Pane
---@param text string scrollback, already trimmed of trailing whitespace
local function inject_scrollback(pane, text)
	local ok, dims = pcall(pane.get_dimensions, pane)
	local viewport_rows = (ok and dims and dims.viewport_rows) or 24
	-- Home the cursor afterwards so the shell starts drawing at the top of the
	-- blank screen. Without it a shell that writes relative to the cursor (bash
	-- behind a pty, as opposed to ConPTY's absolute repaints) would start at the
	-- bottom row and scroll blank lines into the scrollback buffer, between the
	-- restored history and the new prompt.
	pane:inject_output(text .. string.rep("\r\n", pub.scrollback_padding_rows(text, viewport_rows)) .. "\27[H")
end

--- Strip trailing whitespace from restored scrollback.
---
--- A byte loop rather than gsub("%s+$", ""). Lua patterns have no anchor
--- optimisation, so `%s+$` is retried at every position in the string, and each
--- retry walks the whitespace run it finds there before discovering it is not at
--- the end. Captured scrollback is the worst possible input for that: every line
--- is padded to the pane width, so it is mostly whitespace runs. Measured on a
--- real 534 KB capture, the pattern took 15.1 seconds and this takes 0 -- for
--- byte-identical output. It ran once per restored pane, on the GUI thread,
--- which is what froze the window for half a minute on startup.
---@param text string
---@return string
function pub.trim_trailing_whitespace(text)
	local last = #text
	while last > 0 do
		local byte = text:byte(last)
		-- space, tab, newline, carriage return, vertical tab, form feed
		if byte == 32 or byte == 9 or byte == 10 or byte == 13 or byte == 11 or byte == 12 then
			last = last - 1
		else
			break
		end
	end
	return text:sub(1, last)
end

--- How many newlines must follow injected scrollback to lift its last row above
--- the top of the viewport.
---
--- Always a full viewport, whatever the size of the history. A terminal only
--- scrolls once the cursor is already on the bottom row, so writing R rows of
--- text and then N newlines scrolls exactly max(0, R + N - viewport) rows. To
--- scroll all R rows of history out of view, N must be the viewport height --
--- padding by the row count instead leaves a short history sitting on screen,
--- where ConPTY's first repaint erases it.
---
--- The count is exact rather than generous on purpose: the padding rows fill the
--- viewport that the shell is about to draw over, so none of them reach the
--- scrollback buffer, and scrolling up from the restored prompt lands directly
--- on the last line of the restored history with no blank gap.
---@param text string
---@param viewport_rows number
---@return number
function pub.scrollback_padding_rows(text, viewport_rows)
	if not text or text == "" then
		return 0
	end
	return viewport_rows
end

--- Build the `cd` line for a pane that could not be spawned in its saved
--- directory, or nil when no cd is needed or the path is unusable.
--- A WSL pane always gets a POSIX path: typing a Windows path into bash is the
--- one thing guaranteed to fail, and WezTerm reports Windows paths for WSL
--- panes until the distro's shell integration starts emitting OSC 7.
---@param pane_tree pane_tree
---@return string|nil
local function build_cd_command(pane_tree)
	if not pane_tree.restore_cwd then
		return nil
	end
	local cwd = pane_tree.cwd
	if not cwd or cwd == "" then
		return nil
	end
	if utils.is_wsl_domain(pane_tree.domain) then
		cwd = utils.to_wsl_path(cwd)
	end
	-- Validate the CWD contains no shell metacharacters to prevent command
	-- injection via tampered state files.
	if not is_safe_cwd(cwd) then
		wezterm.log_error("resurrect: rejected suspicious CWD: " .. tostring(cwd))
		return nil
	end
	return "cd " .. wezterm.shell_join_args({ cwd }) .. SUBMIT
end

-- Scroll a restored pane back so the history it was given is on screen, instead
-- of leaving the user looking at an apparently fresh prompt with no clue that
-- anything was restored. Set to false to keep restored panes at the prompt.
pub.scroll_to_restored_history = true

-- Rows of the live screen to keep in view when parking a pane on its history.
-- Enough for a shell's opening banner and the prompt beneath it, so the pane
-- still shows where typing will go.
local LIVE_ROWS_IN_VIEW = 6

--- How far to scroll a restored pane back, in rows.
---
--- Not a whole page: a page puts the last row of history on the bottom edge of
--- the screen and the live prompt one row past it, out of sight, which reads as
--- a pane with no prompt at all. Stopping LIVE_ROWS_IN_VIEW short leaves the
--- prompt visible under the history.
---
--- Never further than the history is long, either, or a pane restored with only
--- a few lines scrolls past all of them to the top of the buffer.
---@param history_rows number rows of scrollback that were injected
---@param viewport_rows number
---@return number rows to scroll back, 0 for none
function pub.history_scroll_rows(history_rows, viewport_rows)
	local page = viewport_rows - LIVE_ROWS_IN_VIEW
	if page < 1 or history_rows < 1 then
		return 0
	end
	return math.min(page, history_rows)
end

--- Park a restored pane on the last rows of its restored history. Typing
--- scrolls back to the prompt, so this costs nothing.
---
--- Scheduled after the restore keystrokes rather than alongside the injection:
--- output arriving in a scrolled-back pane snaps it to the bottom again, and the
--- shell's reply to the cd lands a moment after we send it.
---@param pane_id number
---@param history_rows number
local function park_pane_on_history(pane_id, history_rows)
	if not pub.scroll_to_restored_history then
		return
	end
	wezterm.time.call_after(pub.process_restore_delay_seconds + 1, function()
		local pane = wezterm.mux.get_pane(pane_id)
		if not pane then
			return
		end
		-- Best effort: a GUI window may not exist yet (or at all, under the
		-- mux server), and a pane can be closed between scheduling and firing.
		pcall(function()
			local dims = pane:get_dimensions()
			local rows = pub.history_scroll_rows(history_rows, (dims and dims.viewport_rows) or 24)
			if rows > 0 then
				pane:window():gui_window():perform_action(wezterm.action.ScrollByLine(-rows), pane)
			end
		end)
	end)
end

--- Resolve the command that re-launches the process a pane was running, or nil
--- when the pane had no restorable process.
---@param pane_tree pane_tree
---@return string|nil
local function build_restore_command(pane_tree)
	if not (pane_tree.process and pane_tree.process.argv) then
		return nil
	end

	-- Check registered process handlers first (e.g., Claude Code)
	local restore_cmd = process_handlers.get_restore_command(pane_tree.process, pane_tree)
	if restore_cmd then
		return restore_cmd
	end

	-- Fall back to allowlist-based argv replay
	local proc_name = pane_tree.process.name or ""
	local base_name = proc_name:match("[/\\]?([^/\\]+)$") or proc_name
	base_name = base_name:gsub("%.exe$", ""):lower()

	if SAFE_RESTORE_PROCESSES[base_name] then
		return wezterm.shell_join_args(pane_tree.process.argv)
	end

	wezterm.log_warn(
		"resurrect: skipping restore of unrecognized process: " .. base_name
			.. " (add to SAFE_RESTORE_PROCESSES or register a process_handler)"
	)
	return nil
end

--- Function to restore text or processes when restoring panes
---@param pane_tree pane_tree
function pub.default_on_pane_restore(pane_tree)
	-- Spawn process if process info was saved (alt screen OR registered handler),
	-- otherwise restore scrollback text. Some TUI apps (e.g., Claude Code) don't
	-- use the alt screen buffer but still need process-based restoration.
	local restore_cmd = build_restore_command(pane_tree)
	-- A process restore command carries its own cd, so don't send a second one.
	local cd_cmd = restore_cmd == nil and build_cd_command(pane_tree) or nil
	local text = (restore_cmd == nil and pane_tree.text) and pub.trim_trailing_whitespace(pane_tree.text) or nil

	if not (restore_cmd or cd_cmd or text) then
		return
	end

	local pane_id = pane_tree.pane:pane_id()

	-- Scrollback goes in immediately, while the pane is still blank, so that the
	-- shell's own opening output lands beneath it. Keystrokes cannot: the shell
	-- is not ready to read them yet.
	if text and text ~= "" then
		inject_scrollback(pane_tree.pane, text)
		local _, newlines = text:gsub("\n", "")
		park_pane_on_history(pane_id, newlines + 1)
	end

	if not (restore_cmd or cd_cmd) then
		return
	end

	-- Everything typed into the pane happens in one delayed callback so it lands
	-- after the shell has drawn its first prompt (see
	-- process_restore_delay_seconds) and in a deterministic order.
	wezterm.time.call_after(pub.process_restore_delay_seconds, function()
		local pane = wezterm.mux.get_pane(pane_id)
		if not pane then
			return
		end

		if cd_cmd then
			pane:send_text(cd_cmd)
		end
		if restore_cmd then
			pane:send_text(restore_cmd .. SUBMIT)
		end
	end)
end

return pub
