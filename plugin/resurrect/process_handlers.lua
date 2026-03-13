-- Extensible process handler registry for restoring TUI applications.
-- Each handler detects a specific process type and generates the
-- correct restore command, replacing the default argv replay.
--
-- Users can register custom handlers in their wezterm.lua:
--   resurrect.process_handlers.register({
--       name = "lazygit",
--       detect = function(info) return info.name == "lazygit" end,
--       get_restore_cmd = function(info, _) return "lazygit" end,
--   })
local wezterm = require("wezterm") --[[@as Wezterm]]

local pub = {}

-- Registry of process handlers.
-- Each handler has:
--   name: string          -- identifier for logging
--   detect(process_info)  -- returns true if this handler should handle the process
--   get_restore_cmd(process_info, pane_tree) -- returns the shell command string to restore
--   sanitize(process_info) -- optional: clean up process_info at save time
pub.handlers = {}

--- Register a new process handler
---@param handler table { name: string, detect: function, get_restore_cmd: function, sanitize: function? }
function pub.register(handler)
	if not handler.name or not handler.detect or not handler.get_restore_cmd then
		wezterm.log_error("resurrect: process_handler missing required fields (name, detect, get_restore_cmd)")
		return
	end
	table.insert(pub.handlers, handler)
end

--- Find the matching handler for a process, or nil if none match
---@param process_info table
---@return table|nil handler
function pub.find_handler(process_info)
	if not process_info then
		return nil
	end
	for _, handler in ipairs(pub.handlers) do
		local ok, match = pcall(handler.detect, process_info)
		if ok and match then
			return handler
		end
	end
	return nil
end

--- Get the restore command for a process, or nil if no handler matches
---@param process_info table
---@param pane_tree table
---@return string|nil
function pub.get_restore_command(process_info, pane_tree)
	local handler = pub.find_handler(process_info)
	if handler then
		local ok, cmd = pcall(handler.get_restore_cmd, process_info, pane_tree)
		if ok and cmd then
			return cmd
		end
	end
	return nil
end

--- Sanitize process_info at save time if a handler provides a sanitize function.
--- This cleans up argv for portable restoration (e.g., stripping full node paths).
--- The optional pane_id allows handlers to look up external state (e.g., session files).
---@param process_info table
---@param pane_id number|string|nil WezTerm pane ID for external state lookup
---@return table process_info (possibly modified in place)
function pub.sanitize_for_save(process_info, pane_id)
	local handler = pub.find_handler(process_info)
	if handler and handler.sanitize then
		local ok, err = pcall(handler.sanitize, process_info, pane_id)
		if not ok then
			wezterm.log_error("resurrect: process_handler sanitize failed: " .. tostring(err))
		end
	end
	return process_info
end

-- Helper: parse argv for a flag and return its value.
-- Supports both "--flag value" and "--flag=value" forms.
---@param argv string[]
---@param flag string the flag to look for (e.g., "--resume")
---@param short string? optional short form (e.g., "-r")
---@return string|nil value
local function parse_flag_value(argv, flag, short)
	if not argv then
		return nil
	end
	for i, arg in ipairs(argv) do
		-- --flag=value form
		if arg:find("^" .. flag .. "=") then
			return arg:sub(#flag + 2)
		end
		-- --flag value form
		if arg == flag or (short and arg == short) then
			if argv[i + 1] and not argv[i + 1]:find("^%-") then
				return argv[i + 1]
			end
		end
	end
	return nil
end

-- Helper: check if a flag exists in argv
---@param argv string[]
---@param flag string
---@return boolean
local function has_flag(argv, flag)
	if not argv then
		return false
	end
	for _, arg in ipairs(argv) do
		if arg == flag then
			return true
		end
	end
	return false
end

-- Read session data from Claude Code's pane-sessions directory.
-- The SessionStart hook writes JSON to ~/.claude/pane-sessions/<pane_id>.json
-- containing { session_id, transcript_path, cwd, hook_event_name, source }.
---@param pane_id number|string WezTerm pane ID
---@return table|nil session_data parsed JSON or nil on failure
local function read_pane_session(pane_id)
	if not pane_id then
		return nil
	end
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	if not home then
		return nil
	end
	local sep = package.config:sub(1, 1)
	local path = home .. sep .. ".claude" .. sep .. "pane-sessions" .. sep .. tostring(pane_id) .. ".json"
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	if not content or content == "" then
		return nil
	end
	local ok, data = pcall(wezterm.json_parse, content)
	if ok and data then
		return data
	end
	return nil
end

---------------------------------------------------------------
-- Built-in handler: Claude Code
---------------------------------------------------------------
pub.register({
	name = "claude_code",

	-- Claude Code appears as "claude" or "claude.exe" in process name,
	-- or as "node" with claude-code/cli.js in argv.
	detect = function(process_info)
		if not process_info or not process_info.name then
			return false
		end
		local name = (process_info.name or ""):lower():gsub("%.exe$", "")
		-- Match "claude", "claude2", "claude-dev", etc.
		if name:match("^claude%d*$") or name:match("^claude%-") then
			return true
		end
		-- When running via node, check argv for claude-code markers
		if name == "node" and process_info.argv then
			for _, arg in ipairs(process_info.argv) do
				if arg:find("claude%-code") or arg:find("@anthropic%-ai") or arg:find("cli%.js") then
					return true
				end
			end
		end
		return false
	end,

	-- Build the restore command from saved process info.
	-- Prioritizes --resume <session-id> over --continue.
	-- Preserves --dangerously-skip-permissions if it was present.
	get_restore_cmd = function(process_info, pane_tree)
		local argv = process_info.argv or {}
		-- Use the saved executable name (e.g., "claude", "claude2") so
		-- multi-account setups restore with the correct binary.
		local bin = process_info.name or process_info.executable or "claude"
		local parts = { bin }

		-- Session ID: check --resume, -r, --session-id
		local session_id = parse_flag_value(argv, "--resume", "-r")
			or parse_flag_value(argv, "--session-id")
		if session_id then
			table.insert(parts, "--resume")
			table.insert(parts, session_id)
		else
			-- No explicit session ID captured; use --continue to resume
			-- the most recent session in this CWD
			table.insert(parts, "--continue")
		end

		-- Preserve dangerous permissions flag
		if has_flag(argv, "--dangerously-skip-permissions") then
			table.insert(parts, "--dangerously-skip-permissions")
		end

		return wezterm.shell_join_args(parts)
	end,

	-- At save time, clean up the raw node argv into a portable form.
	-- The raw argv looks like:
	--   {"node", "C:/Users/.../cli.js", "--dangerously-skip-permissions", "--resume", "uuid"}
	-- We normalize to:
	--   {"claude", "--resume", "uuid", "--dangerously-skip-permissions"}
	--
	-- If the session ID is not in argv (common for fresh sessions that were not
	-- started with --resume), we look it up from the pane-sessions file written
	-- by Claude Code's SessionStart hook. This ensures every Claude Code pane
	-- gets its exact session ID saved, even when running 6-8 sessions at once.
	sanitize = function(process_info, pane_id)
		local argv = process_info.argv or {}
		-- Preserve the original binary name (e.g., "claude2") for multi-account setups
		local bin = (process_info.name or ""):lower():gsub("%.exe$", "")
		if not bin:match("^claude") then
			bin = "claude"
		end
		local clean = { bin }

		-- Extract session ID from argv first (explicit --resume or --session-id)
		local session_id = parse_flag_value(argv, "--resume", "-r")
			or parse_flag_value(argv, "--session-id")

		-- Fall back to the pane-sessions file written by the SessionStart hook.
		-- This covers fresh sessions that were started without --resume.
		if not session_id and pane_id then
			local session_data = read_pane_session(pane_id)
			if session_data and session_data.session_id then
				session_id = session_data.session_id
			end
		end

		if session_id then
			table.insert(clean, "--resume")
			table.insert(clean, session_id)
		end

		-- Extract permission flags
		if has_flag(argv, "--dangerously-skip-permissions") then
			table.insert(clean, "--dangerously-skip-permissions")
		end

		process_info.executable = bin
		process_info.name = bin
		process_info.argv = clean
	end,
})

--- Ensure Claude Code's SessionStart hook is configured to capture session IDs
--- per WezTerm pane. This is idempotent -- safe to call on every WezTerm startup.
---
--- What it does:
---   1. Creates ~/.claude/pane-sessions/ directory (where session data is stored)
---   2. Reads ~/.claude/settings.json (or creates it if missing)
---   3. Adds a SessionStart hook that writes session metadata to
---      ~/.claude/pane-sessions/<WEZTERM_PANE>.json
---   4. Writes the updated settings back atomically
---
--- Usage in wezterm.lua:
---   local resurrect = wezterm.plugin.require("...")
---   resurrect.process_handlers.setup_claude_session_hooks()
---
---@param settings_path string|nil optional override for Claude settings file path
---@return boolean success
function pub.setup_claude_session_hooks(settings_path)
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	if not home then
		wezterm.log_error("resurrect: cannot determine home directory for Claude hook setup")
		return false
	end

	local sep = package.config:sub(1, 1)
	local claude_dir = home .. sep .. ".claude"
	local pane_sessions_dir = claude_dir .. sep .. "pane-sessions"

	-- Ensure pane-sessions directory exists.
	-- Use os.execute because this may run during plugin init where
	-- wezterm.run_child_process is forbidden (yields across C-call boundary).
	if sep == "\\" then
		os.execute('cmd /c if not exist "' .. pane_sessions_dir .. '" mkdir "' .. pane_sessions_dir .. '" >nul 2>nul')
	else
		os.execute('mkdir -p "' .. pane_sessions_dir .. '" 2>/dev/null')
	end

	-- Resolve settings path
	if not settings_path then
		settings_path = claude_dir .. sep .. "settings.json"
	end

	-- Read existing settings (or start fresh)
	local settings = {}
	local f = io.open(settings_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		if content and content ~= "" then
			local ok, parsed = pcall(wezterm.json_parse, content)
			if ok and parsed then
				settings = parsed
			else
				wezterm.log_warn("resurrect: could not parse " .. settings_path .. ", will add hooks to fresh object")
			end
		end
	end

	-- Check if our hook is already present (idempotency check).
	-- We look for any SessionStart hook whose command references "pane-sessions".
	if settings.hooks and settings.hooks.SessionStart then
		for _, entry in ipairs(settings.hooks.SessionStart) do
			if entry.hooks then
				for _, hook in ipairs(entry.hooks) do
					if hook.command and hook.command:find("pane%-sessions") then
						-- Already configured -- nothing to do
						return true
					end
				end
			end
		end
	end

	-- Build the hook structure
	if not settings.hooks then
		settings.hooks = {}
	end
	if not settings.hooks.SessionStart then
		settings.hooks.SessionStart = {}
	end

	-- The hook command: Claude Code sends session JSON on stdin via the
	-- SessionStart hook. We write it to a file keyed by WEZTERM_PANE env var.
	-- WEZTERM_PANE is set by WezTerm in child shells and inherited by Claude.
	local hook_command = "bash -c 'cat > \"$HOME/.claude/pane-sessions/${WEZTERM_PANE:-unknown}.json\"'"

	table.insert(settings.hooks.SessionStart, {
		matcher = "",
		hooks = {
			{
				type = "command",
				command = hook_command,
			},
		},
	})

	-- Write back atomically (write to .tmp then rename)
	local json_str = wezterm.json_encode(settings)
	local tmp_path = settings_path .. ".tmp"
	local wf = io.open(tmp_path, "w")
	if not wf then
		wezterm.log_error("resurrect: cannot write Claude settings to " .. tmp_path)
		return false
	end
	wf:write(json_str)
	wf:close()
	local rename_ok, rename_err = os.rename(tmp_path, settings_path)
	if not rename_ok then
		wezterm.log_error("resurrect: failed to rename " .. tmp_path .. " -> " .. settings_path .. ": " .. tostring(rename_err))
		return false
	end

	wezterm.log_info("resurrect: Claude Code SessionStart hook configured at " .. settings_path)
	return true
end

return pub
