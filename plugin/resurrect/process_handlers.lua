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
local utils = require("resurrect.utils")

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

-- Validate that a string looks like a UUID/hex-dash identifier.
-- Used to sanitize session IDs before embedding them in shell commands.
---@param s string
---@return boolean
local function is_valid_session_id(s)
	return s and s:match("^[%x%-]+$") ~= nil
end

-- Validate that a binary name is a known Claude Code executable.
-- Prevents command injection via tampered process_info.name in state files.
---@param name string
---@return boolean
local function is_valid_claude_binary(name)
	return name and (name:match("^claude%d*$") or name:match("^claude%-[%w%-]+$")) ~= nil
end

-- Use shared CWD validation from utils to prevent command injection.
local is_safe_cwd = utils.is_safe_cwd

-- Read session data from Claude Code's pane-sessions directory.
-- The SessionStart hook writes JSON to ~/.claude/pane-sessions/<pane_id>.json
-- containing { session_id, transcript_path, cwd, hook_event_name, source }.
---@param pane_id number|string WezTerm pane ID
---@return table|nil session_data parsed JSON or nil on failure
function pub.read_pane_session(pane_id)
	if not pane_id then
		return nil
	end
	-- Validate pane_id is numeric to prevent path traversal
	local id_str = tostring(pane_id)
	if not id_str:match("^%d+$") then
		wezterm.log_error("resurrect: read_pane_session rejected non-numeric pane_id: " .. id_str)
		return nil
	end
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	if not home then
		return nil
	end
	local sep = utils.separator
	local path = home .. sep .. ".claude" .. sep .. "pane-sessions" .. sep .. id_str .. ".json"
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
	-- All values from state files are validated before use to prevent
	-- command injection via tampered JSON (input sanitization).
	get_restore_cmd = function(process_info, pane_tree)
		local argv = process_info.argv or {}
		-- Use the saved executable name (e.g., "claude", "claude2") so
		-- multi-account setups restore with the correct binary.
		-- Validate the name is actually a claude binary to prevent injection.
		local bin = process_info.name or process_info.executable or "claude"
		if not is_valid_claude_binary(bin) then
			wezterm.log_warn("resurrect: rejected invalid claude binary name: " .. tostring(bin))
			bin = "claude"
		end
		local parts = { bin }

		-- Session ID: check --resume, -r, --session-id
		local session_id = parse_flag_value(argv, "--resume", "-r")
			or parse_flag_value(argv, "--session-id")
		-- Validate session ID is a hex/dash string (UUID format)
		if session_id and not is_valid_session_id(session_id) then
			wezterm.log_warn("resurrect: rejected invalid session_id: " .. tostring(session_id))
			session_id = nil
		end
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

		local cmd = wezterm.shell_join_args(parts)

		-- Claude Code must be started from the original working directory
		-- for proper context loading and session restoration. Prepend a cd
		-- command as a separate line so the shell changes directory before
		-- launching Claude. Using \r\n between commands instead of && for
		-- cross-shell compatibility (PowerShell 5.x does not support &&).
		local cwd = process_info.cwd or (pane_tree and pane_tree.cwd)
		if cwd and is_safe_cwd(cwd) then
			cmd = "cd " .. wezterm.shell_join_args({ cwd }) .. "\r\n" .. cmd
		elseif cwd then
			wezterm.log_warn("resurrect: rejected unsafe CWD for Claude restore: " .. tostring(cwd))
		end

		return cmd
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

		-- Read the pane-session file first -- it has the most recent session ID,
		-- kept fresh by the Stop hook that fires after every Claude response.
		-- This is critical because the session ID can change mid-conversation
		-- (e.g., during context compaction), making the argv value stale.
		local session_id = nil
		if pane_id then
			local session_data = pub.read_pane_session(pane_id)
			if session_data and session_data.session_id then
				session_id = session_data.session_id
			end
		end

		-- Fall back to argv if pane-session file is unavailable (e.g., hook
		-- not yet configured, or WEZTERM_PANE env var not set).
		if not session_id then
			session_id = parse_flag_value(argv, "--resume", "-r")
				or parse_flag_value(argv, "--session-id")
		end

		-- Validate session ID format before embedding in argv
		if session_id and not is_valid_session_id(session_id) then
			wezterm.log_warn("resurrect: sanitize rejected invalid session_id: " .. tostring(session_id))
			session_id = nil
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

-- errno for "No such file or directory" (the same value in POSIX libc and the
-- Windows CRT). It is the only io.open failure that means "there is nothing
-- to preserve"; any other failure means the file may exist.
local ENOENT = 2

-- UTF-8 byte-order mark. Windows PowerShell 5.1 "Set-Content -Encoding utf8"
-- writes one, and WezTerm's json_parse rejects it (measured: "expected value
-- at line 1 column 1").
local UTF8_BOM = "\239\187\191"

-- Load a Claude settings file for modification.
--
-- The caller rewrites the WHOLE file from the table returned here, so this
-- must only return a table that holds everything the file holds. It returns
-- nil -- and the caller must not write -- whenever the file exists but
-- cannot be opened, read, or parsed as a JSON object. Starting from {} in
-- that case (the previous behaviour) overwrote a user's entire settings.json
-- with just our hooks whenever it had a syntax error or was locked.
-- A leading UTF-8 BOM is set aside before parsing and returned separately,
-- so the caller can write it back and leave the encoding as it found it.
---@param path string
---@return table|nil settings
---@return string bom UTF8_BOM or ""
local function load_settings_for_update(path)
	local f, open_err, errno = io.open(path, "r")
	if not f then
		if errno == ENOENT then
			return {}, "" -- no file yet: nothing to lose
		end
		wezterm.log_warn("resurrect: cannot open " .. path .. " (" .. tostring(open_err)
			.. "); leaving it untouched, Claude hooks not configured")
		return nil
	end
	local content = f:read("*a")
	f:close()
	if content == nil then
		wezterm.log_warn("resurrect: cannot read " .. path .. "; leaving it untouched, Claude hooks not configured")
		return nil
	end
	local bom = ""
	if content:sub(1, #UTF8_BOM) == UTF8_BOM then
		bom = UTF8_BOM
		content = content:sub(#UTF8_BOM + 1)
	end
	if content == "" then
		return {}, bom -- empty file: nothing to lose
	end
	-- Only a JSON object is a settings file. An array parses to a Lua table
	-- too, and "[]" is then indistinguishable from "{}", so decide on the
	-- text: the first non-whitespace byte must open an object.
	if not content:find("^%s*{") then
		wezterm.log_warn("resurrect: " .. path .. " is not a JSON object"
			.. "; leaving it untouched, Claude hooks not configured")
		return nil
	end
	local ok, parsed = pcall(wezterm.json_parse, content)
	if not ok or type(parsed) ~= "table" then
		wezterm.log_warn("resurrect: could not parse " .. path .. " as a JSON object ("
			.. tostring(ok and type(parsed) or parsed)
			.. "); leaving it untouched, Claude hooks not configured")
		return nil
	end
	return parsed, bom
end

-- True when t is a table decoded from a JSON array (or an empty table,
-- which could have been either). JSON object keys are always strings.
local function is_list(t)
	if type(t) ~= "table" then
		return false
	end
	for k in pairs(t) do
		if type(k) ~= "number" then
			return false
		end
	end
	return true
end

-- True when t is a table decoded from a JSON object (or an empty table).
local function is_object(t)
	if type(t) ~= "table" then
		return false
	end
	for k in pairs(t) do
		if type(k) ~= "string" then
			return false
		end
	end
	return true
end

-- Look for our pane-sessions hook under hooks.SessionStart and hooks.Stop,
-- checking the type of everything on the way.
-- Returns has_session_start, has_stop, or nil, nil, <what is wrong>.
---@param settings table
---@return boolean|nil has_session_start
---@return boolean|nil has_stop
---@return string|nil shape_err
local function find_pane_session_hooks(settings)
	if not is_object(settings) then
		return nil, nil, "a top level that is not a JSON object"
	end
	local hooks = settings.hooks
	if hooks == nil then
		return false, false
	end
	if not is_object(hooks) then
		return nil, nil, '"hooks" that is not a JSON object'
	end
	local found = {}
	for _, event_name in ipairs({ "SessionStart", "Stop" }) do
		local entries = hooks[event_name]
		if entries ~= nil then
			if not is_list(entries) then
				return nil, nil, '"hooks.' .. event_name .. '" that is not a JSON array'
			end
			for _, entry in ipairs(entries) do
				if not is_object(entry) or (entry.hooks ~= nil and not is_list(entry.hooks)) then
					return nil, nil, 'a malformed entry in "hooks.' .. event_name .. '"'
				end
				for _, hook in ipairs(entry.hooks or {}) do
					if not is_object(hook) or (hook.command ~= nil and type(hook.command) ~= "string") then
						return nil, nil, 'a malformed hook in "hooks.' .. event_name .. '"'
					end
					if hook.command and hook.command:find("pane%-sessions") then
						found[event_name] = true
					end
				end
			end
		end
	end
	return found.SessionStart == true, found.Stop == true
end

-- Configure the SessionStart hook in a single Claude Code settings file.
-- Returns true if hook is already present or was successfully added.
-- Returns false, without writing, if the existing file cannot be loaded.
---@param target_settings_path string path to settings.json
---@param pane_sessions_dir string path to pane-sessions directory
---@return boolean success
local function configure_hook_in_settings(target_settings_path, pane_sessions_dir)
	local settings, bom = load_settings_for_update(target_settings_path)
	if not settings then
		return false
	end

	-- Check if our hooks are already present (idempotency check).
	-- We look for pane-sessions hooks on both SessionStart and Stop.
	-- If both exist, nothing to do. A hooks section of the wrong shape is
	-- refused rather than indexed, because indexing it raised out of setup()
	-- and took the user's whole WezTerm config down with it.
	local has_session_start, has_stop, shape_err = find_pane_session_hooks(settings)
	if shape_err then
		wezterm.log_warn("resurrect: " .. target_settings_path .. " has " .. shape_err
			.. "; leaving it untouched, Claude hooks not configured")
		return false
	end
	if has_session_start and has_stop then
		return true
	end

	-- Build the hook structure
	if not settings.hooks then
		settings.hooks = {}
	end

	-- The hook command: Claude Code sends session JSON on stdin for every
	-- hook event. We write it to a file keyed by WEZTERM_PANE env var.
	-- WEZTERM_PANE is set by WezTerm in child shells and inherited by Claude.
	-- The pane ID is validated as numeric to prevent path traversal via
	-- crafted WEZTERM_PANE values (e.g., "../../.bashrc").
	-- All instances write to the same pane-sessions dir (~/.claude/pane-sessions/)
	-- so the restore logic can find session data regardless of which binary ran.
	local safe_dir = pane_sessions_dir:gsub("\\", "/"):gsub("'", "'\\''")
	local hook_command = "bash -c '"
		.. 'pane_id="${WEZTERM_PANE:-unknown}"; '
		.. 'if [[ "$pane_id" =~ ^[0-9]+$ ]]; then '
		.. 'cat > "' .. safe_dir .. '/${pane_id}.json"; '
		.. "else echo \"resurrect: invalid WEZTERM_PANE: $pane_id\" >&2; cat > /dev/null; fi'"

	local hook_entry = {
		matcher = "",
		hooks = {
			{
				type = "command",
				command = hook_command,
			},
		},
	}

	-- SessionStart: captures session ID when Claude starts or resumes.
	if not has_session_start then
		if not settings.hooks.SessionStart then
			settings.hooks.SessionStart = {}
		end
		table.insert(settings.hooks.SessionStart, hook_entry)
	end

	-- Stop: refreshes session ID after every Claude response. This keeps
	-- the pane-session file current even if the session ID changes mid-
	-- conversation (e.g., during context compaction). Every hook event
	-- includes session_id in its stdin payload, so the same command works.
	if not has_stop then
		if not settings.hooks.Stop then
			settings.hooks.Stop = {}
		end
		table.insert(settings.hooks.Stop, hook_entry)
	end

	-- Write directly (not atomic rename -- os.rename fails on Windows
	-- when the target file already exists, causing silent failures).
	local json_str = bom .. wezterm.json_encode(settings)
	local wf = io.open(target_settings_path, "w")
	if not wf then
		wezterm.log_error("resurrect: cannot write Claude settings to " .. target_settings_path)
		return false
	end
	wf:write(json_str)
	wf:flush()
	wf:close()

	wezterm.log_info("resurrect: Claude Code hooks configured at " .. target_settings_path)
	return true
end

-- configure_hook_in_settings, but an unexpected error is logged and turned
-- into false instead of propagating. This runs from setup() while WezTerm is
-- loading the user's config; an error escaping here fails the whole config.
---@param target_settings_path string
---@param pane_sessions_dir string
---@return boolean success
local function safe_configure(target_settings_path, pane_sessions_dir)
	local ok, result = pcall(configure_hook_in_settings, target_settings_path, pane_sessions_dir)
	if not ok then
		wezterm.log_error("resurrect: configuring Claude hooks in " .. target_settings_path
			.. " failed: " .. tostring(result))
		return false
	end
	return result
end

--- Ensure Claude Code hooks are configured to capture session IDs per WezTerm
--- pane. This is idempotent -- safe to call on every WezTerm startup.
---
--- What it does:
---   1. Creates ~/.claude/pane-sessions/ directory (where session data is stored)
---   2. Configures SessionStart + Stop hooks in ~/.claude/settings.json
---      - SessionStart: captures session ID when Claude starts or resumes
---      - Stop: refreshes session ID after every response, keeping it current
---        even if the ID changes mid-conversation (e.g., context compaction)
---   3. Also configures ~/.claude-alt/settings.json if it exists (for claude2
---      multi-account setups that use CLAUDE_CONFIG_DIR)
---   4. All instances write to the same pane-sessions directory so restore
---      logic can find session data regardless of which binary was used
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

	local sep = utils.separator
	local claude_dir = home .. sep .. ".claude"
	local pane_sessions_dir = claude_dir .. sep .. "pane-sessions"

	-- Ensure pane-sessions directory exists.
	if not utils.ensure_folder_exists(pane_sessions_dir) then
		wezterm.log_error("resurrect: failed to create pane-sessions directory: " .. pane_sessions_dir)
		return false
	end

	-- Configure the primary settings file
	if settings_path then
		return safe_configure(settings_path, pane_sessions_dir)
	end

	local primary_path = claude_dir .. sep .. "settings.json"
	local primary_ok = safe_configure(primary_path, pane_sessions_dir)

	-- Also configure alternate Claude config directories (e.g., .claude-alt for
	-- claude2 multi-account setups). Only if the directory already exists --
	-- we don't create new config dirs, just hook into existing ones.
	local alt_dir = home .. sep .. ".claude-alt"
	local alt_settings = alt_dir .. sep .. "settings.json"
	local alt_f = io.open(alt_settings, "r")
	if alt_f then
		alt_f:close()
		safe_configure(alt_settings, pane_sessions_dir)
	end

	return primary_ok
end

return pub
