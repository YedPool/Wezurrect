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

-- Identifies this WezTerm process in pane-session file names. Set by setup()
-- from the instance id, and exported to child processes as RESURRECT_INSTANCE so
-- Claude Code's hook can build the same key.
--
-- Pane ids restart from 0 in every WezTerm process, so without this a fresh
-- pane 0 reads the session file left behind by a previous run's pane 0 and gets
-- saved as a Claude pane running a conversation from days ago. It also keeps two
-- WezTerm processes running side by side from overwriting each other's files.
pub.pane_session_prefix = nil

-- Used when no prefix has been set, on both sides of the boundary, so the Lua
-- and the shell hook still agree on the key.
local NO_INSTANCE = "noinstance"

--- The pane-session key for a pane in a local domain.
---@param pane_id number|string
---@return string
function pub.local_pane_session_key(pane_id)
	return (pub.pane_session_prefix or NO_INSTANCE) .. "-" .. tostring(pane_id)
end

--- The shell expression Claude Code's hook uses to build the same key.
---@return string
function pub.local_pane_session_key_expr()
	return "${RESURRECT_INSTANCE:-" .. NO_INSTANCE .. "}-${WEZTERM_PANE:-unknown}"
end

-- Read session data from Claude Code's pane-sessions directory.
-- The SessionStart hook writes JSON to ~/.claude/pane-sessions/<key>.json
-- containing { session_id, transcript_path, cwd, hook_event_name, source }.
--
-- The key is WezTerm's numeric pane id for local panes, or the per-shell UUID
-- published by the WSL shell integration for panes inside a WSL distro (see
-- resurrect.wsl_integration for why WEZTERM_PANE cannot be used there).
---@param pane_id number|string WezTerm pane ID or WSL shell id
---@return table|nil session_data parsed JSON or nil on failure
function pub.read_pane_session(pane_id)
	if not pane_id then
		return nil
	end
	-- Restrict the key to alphanumerics, dashes and underscores so it cannot
	-- escape the pane-sessions directory via path traversal.
	local id_str = tostring(pane_id)
	if #id_str > 64 or not id_str:match("^[%w][%w%-_]*$") then
		wezterm.log_error("resurrect: read_pane_session rejected malformed key: " .. id_str)
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

--- Build the Claude Code hook command that records a pane's session.
---
--- Claude Code sends the session JSON on stdin for every hook event; we write it
--- to a file named after whichever environment variable identifies the pane.
--- The key is validated against a strict character class so a crafted value
--- (e.g. "../../.bashrc") cannot escape the pane-sessions directory.
--- All Claude instances write to the same directory so the restore logic finds
--- session data regardless of which binary, or which distro, ran.
---@param pane_sessions_dir string directory to write session files into
---@param key_expr string shell expression producing the pane key
---@return string hook_command
function pub.build_pane_session_hook_command(pane_sessions_dir, key_expr)
	local safe_dir = pane_sessions_dir:gsub("\\", "/"):gsub("'", "'\\''")
	return "bash -c '"
		.. 'key="' .. key_expr .. '"; '
		.. 'if [[ "$key" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then '
		.. 'cat > "' .. safe_dir .. '/${key}.json"; '
		.. 'else echo "resurrect: invalid pane session key: $key" >&2; cat > /dev/null; fi\''
end

--- Build the Claude Code hook command that forgets a pane's session.
---
--- Without this a pane stays marked as a Claude pane for as long as it lives:
--- the session file is written when Claude starts and never removed, so a pane
--- where Claude was closed hours ago is still saved as `claude --resume <old>`
--- and comes back running Claude, its real scrollback discarded.
---@param pane_sessions_dir string
---@param key_expr string shell expression producing the pane key
---@return string hook_command
function pub.build_pane_session_cleanup_command(pane_sessions_dir, key_expr)
	local safe_dir = pane_sessions_dir:gsub("\\", "/"):gsub("'", "'\\''")
	return "bash -c '"
		.. 'key="' .. key_expr .. '"; '
		.. "cat > /dev/null; "
		.. 'if [[ "$key" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then '
		.. 'rm -f "' .. safe_dir .. '/${key}.json"; fi\''
end

-- Which SessionEnd reasons mean the pane has stopped running Claude. The
-- reasons left out -- clear, resume -- end one session only to start another
-- immediately, and deleting the file on those would race the SessionStart that
-- follows.
local SESSION_END_MATCHER = "prompt_input_exit|logout|bypass_permissions_disabled|other"

--- Strip the pane-session hooks this plugin previously installed, leaving every
--- other hook the user has configured untouched.
---
--- Removing and re-adding, rather than adding only when absent, is what lets the
--- hook command change between plugin versions. The key expression is part of
--- the command, so a stale hook writing under an old key would silently stop
--- matching what the save path looks for.
--- Every pane-session hook currently configured, as a sorted, comparable list.
--- Used to skip the write when nothing would change: setup() runs on every
--- WezTerm launch and config reload, and rewriting settings.json each time would
--- eventually clobber an edit Claude Code made to it in the meantime.
---@param settings table parsed settings.json
---@return string[] sorted signatures
local function pane_session_hook_signatures(settings)
	local found = {}
	if type(settings.hooks) == "table" then
		for event_name, entries in pairs(settings.hooks) do
			if type(entries) == "table" then
				for _, entry in ipairs(entries) do
					for _, hook in ipairs(entry.hooks or {}) do
						if hook.command and hook.command:find("pane%-sessions") then
							table.insert(found, event_name .. "\0" .. tostring(entry.matcher) .. "\0" .. hook.command)
						end
					end
				end
			end
		end
	end
	table.sort(found)
	return found
end

---@param settings table parsed settings.json, mutated in place
local function strip_pane_session_hooks(settings)
	if type(settings.hooks) ~= "table" then
		return
	end
	for event_name, entries in pairs(settings.hooks) do
		if type(entries) == "table" then
			local kept_entries = {}
			for _, entry in ipairs(entries) do
				local kept_hooks = {}
				for _, hook in ipairs(entry.hooks or {}) do
					if not (hook.command and hook.command:find("pane%-sessions")) then
						table.insert(kept_hooks, hook)
					end
				end
				-- Drop entries we emptied; keep ones that never had our hooks
				-- (entry.hooks absent) exactly as they were.
				if entry.hooks == nil then
					table.insert(kept_entries, entry)
				elseif #kept_hooks > 0 then
					entry.hooks = kept_hooks
					table.insert(kept_entries, entry)
				end
			end
			settings.hooks[event_name] = kept_entries
		end
	end
end

--- Configure the pane-session hooks in a single Claude Code settings file.
--- Returns true if the hooks are already present or were successfully added.
---
--- The hook command is supplied by the caller because it differs per platform:
--- a Windows Claude writes to the pane-sessions directory keyed by WEZTERM_PANE,
--- while a Claude running inside WSL writes to the same directory through its
--- /mnt mount, keyed by the shell id from our WSL shell integration.
---@param target_settings_path string path to settings.json
---@param hook_command string command to run for SessionStart and Stop
---@param cleanup_command string command to run for SessionEnd
---@return boolean success
function pub.configure_pane_session_hooks(target_settings_path, hook_command, cleanup_command)
	-- Read existing settings (or start fresh)
	local settings = {}
	local f = io.open(target_settings_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		if content and content ~= "" then
			local ok, parsed = pcall(wezterm.json_parse, content)
			if ok and parsed then
				settings = parsed
			else
				-- Bail out rather than start from a fresh object: this function
				-- rewrites the whole file, so treating an unparseable settings.json
				-- as empty would silently discard everything in it.
				wezterm.log_error(
					"resurrect: refusing to rewrite unparseable Claude settings at " .. target_settings_path
				)
				return false
			end
		end
	end

	local before = table.concat(pane_session_hook_signatures(settings), "\1")

	-- Replace rather than append: see strip_pane_session_hooks for why.
	strip_pane_session_hooks(settings)

	if not settings.hooks then
		settings.hooks = {}
	end

	local function add(event_name, matcher, command)
		if not settings.hooks[event_name] then
			settings.hooks[event_name] = {}
		end
		table.insert(settings.hooks[event_name], {
			matcher = matcher,
			hooks = { { type = "command", command = command } },
		})
	end

	-- SessionStart: captures session ID when Claude starts or resumes.
	add("SessionStart", "", hook_command)

	-- Stop: refreshes session ID after every Claude response. This keeps
	-- the pane-session file current even if the session ID changes mid-
	-- conversation (e.g., during context compaction). Every hook event
	-- includes session_id in its stdin payload, so the same command works.
	add("Stop", "", hook_command)

	-- SessionEnd: forgets the pane so a closed Claude is not resurrected.
	if cleanup_command then
		add("SessionEnd", SESSION_END_MATCHER, cleanup_command)
	end

	-- Already exactly right: leave the file alone rather than rewrite it on
	-- every launch, where a stale read could undo a change made meanwhile.
	if before == table.concat(pane_session_hook_signatures(settings), "\1") then
		return true
	end

	-- Write directly (not atomic rename -- os.rename fails on Windows
	-- when the target file already exists, causing silent failures).
	local json_str = wezterm.json_encode(settings)
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

	local key_expr = pub.local_pane_session_key_expr()
	local hook_command = pub.build_pane_session_hook_command(pane_sessions_dir, key_expr)
	local cleanup_command = pub.build_pane_session_cleanup_command(pane_sessions_dir, key_expr)

	-- Configure the primary settings file
	if settings_path then
		return pub.configure_pane_session_hooks(settings_path, hook_command, cleanup_command)
	end

	local primary_path = claude_dir .. sep .. "settings.json"
	local primary_ok = pub.configure_pane_session_hooks(primary_path, hook_command, cleanup_command)

	-- Also configure alternate Claude config directories (e.g., .claude-alt for
	-- claude2 multi-account setups). Only if the directory already exists --
	-- we don't create new config dirs, just hook into existing ones.
	local alt_dir = home .. sep .. ".claude-alt"
	local alt_settings = alt_dir .. sep .. "settings.json"
	local alt_f = io.open(alt_settings, "r")
	if alt_f then
		alt_f:close()
		pub.configure_pane_session_hooks(alt_settings, hook_command, cleanup_command)
	end

	return primary_ok
end

--- Delete pane-session files older than `days`.
---
--- SessionEnd removes a pane's file when Claude exits cleanly, and the instance
--- prefix makes leftovers harmless, but a crash still strands one -- and the
--- directory is shared by every WezTerm process, so "not mine" is not a safe
--- thing to delete. Age is.
---
--- Uses run_child_process, so it must not be called during config evaluation.
---@param days number
---@return boolean success
function pub.sweep_pane_sessions(days)
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	if not home or not days or days <= 0 then
		return false
	end
	local dir = home .. utils.separator .. ".claude" .. utils.separator .. "pane-sessions"

	local ok
	if utils.is_windows then
		ok = utils.exec({
			"powershell.exe", "-NoProfile", "-NoLogo", "-Command",
			string.format(
				"Get-ChildItem -Path '%s' -Filter '*.json' -File -ErrorAction SilentlyContinue"
					.. " | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-%d) } | Remove-Item -Force",
				dir:gsub("'", "''"),
				days
			),
		})
	else
		ok = utils.exec({
			"sh", "-c",
			"find '" .. dir:gsub("'", "'\\''") .. "' -maxdepth 1 -name '*.json' -mtime +" .. days .. " -delete 2>/dev/null",
		})
	end
	return ok and true or false
end

return pub
