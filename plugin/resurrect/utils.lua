local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

local utils = {}

utils.is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
utils.is_mac = (wezterm.target_triple == "x86_64-apple-darwin" or wezterm.target_triple == "aarch64-apple-darwin")
utils.separator = utils.is_windows and "\\" or "/"

-- Helper function to remove formatting esc sequences in the string
---@param str string
---@return string
function utils.strip_format_esc_seq(str)
	local clean_str, _ = str:gsub(string.char(27) .. "%[[^m]*m", "")
	return clean_str
end

-- getting screen dimensions
---@return number
function utils.get_current_window_width()
	local windows = wezterm.gui.gui_windows()
	for _, window in ipairs(windows) do
		if window:is_focused() then
			return window:active_tab():get_size().cols
		end
	end
	return 80
end

-- replace the center of a string with another string
---@param str string string to be modified
---@param len number length to be removed from the middle of str
---@param pad string string that must be inserted in place of the missing part of str
function utils.replace_center(str, len, pad)
	local mid = #str // 2
	local start = mid - (len // 2)
	return str:sub(1, start) .. pad .. str:sub(start + len + 1)
end

-- returns the length of a utf8 string
---@param str string
---@return number
function utils.utf8len(str)
	local _, len = str:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
	return len
end

-- Execute a command array and return its stdout.
-- Uses wezterm.run_child_process to avoid shell injection and cmd.exe flashes.
---@param cmd_args string[] array of command and arguments
---@return boolean success result
---@return string|nil output
function utils.exec(cmd_args)
	local success, stdout, stderr = wezterm.run_child_process(cmd_args)
	if success then
		return true, stdout
	else
		return false, stderr or "Command failed"
	end
end

-- Legacy wrapper: execute a shell command string via sh -c (Unix) or cmd /c (Windows).
-- Prefer utils.exec() with argument arrays for new code.
---@param cmd string command
---@return boolean success result
---@return string|nil error
function utils.execute(cmd)
	if utils.is_windows then
		return utils.exec({ "cmd.exe", "/c", cmd })
	else
		return utils.exec({ "sh", "-c", cmd })
	end
end

-- Shell-safe wrapper around mkdir for a single already-assembled path segment.
-- Uses os.execute because this runs during plugin init where
-- wezterm.run_child_process is forbidden (yields across C-call boundary).
local function shell_mkdir(path)
	if utils.is_windows then
		if path:find('"') then
			return false
		end
		-- Use os.execute; the >nul suppresses output. A brief cmd.exe flash
		-- may occur on first run only (dirs persist across restarts).
		os.execute('cmd /c mkdir "' .. path .. '" >nul 2>nul')
		return true
	else
		if path:find('["%$`\n;|&()]') then
			return false
		end
		os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
		return true
	end
end

-- Probe-write check: attempts to create and immediately remove a temp file
-- inside path. Used to detect "directory exists and is writable" — sufficient
-- for the leaf state directories we own under AppData / ~/.claude. We do NOT
-- probe ancestor directories (see ensure_folder_exists for why).
local function dir_is_accessible(path)
	local probe = path .. utils.separator .. ".resurrect_probe_" .. tostring({}):gsub("[^%w]", "")
	local f = io.open(probe, "w")
	if f then
		f:close()
		os.remove(probe)
		return true
	end
	return false
end

-- Create the folder if it does not exist.
-- Issue #125: previously this walked every ancestor and probe-wrote each one,
-- which fired shell_mkdir (a cmd.exe spawn → visible window flash) on every
-- launch for ancestors that exist but aren't writable to the current user
-- (e.g. C:\Users on a non-admin Windows account). Now we only check the
-- target itself; cmd's mkdir and `mkdir -p` both create intermediates
-- automatically, so the walk was pure overhead AND the source of the flicker.
---@param path string
---@return boolean success
function utils.ensure_folder_exists(path)
	if utils.is_windows then
		path = path:gsub("/", "\\")
		-- Normalise drive-relative paths (C:foo) to absolute (C:\foo). cmd's
		-- mkdir would otherwise interpret them relative to the current dir on
		-- drive C:, which is rarely what the caller intended.
		local drive = path:match("^(%a:)[^\\]")
		if drive then
			path = drive .. "\\" .. path:sub(3)
		end
	end
	path = path:gsub("[/\\]+$", "")
	if path == "" then
		return true
	end
	if dir_is_accessible(path) then
		return true
	end
	if shell_mkdir(path) then
		return dir_is_accessible(path)
	end
	return false
end

-- Characters that could enable command injection when a CWD is embedded in
-- a shell command via send_text(). Blocks shell metacharacters plus \r\n
-- (a newline in a path from a tampered state file could inject commands).
utils.UNSAFE_CWD_PATTERN = "[;&|`$%(%)%{%}\r\n]"

-- Validate that a CWD path is safe to embed in a shell command.
---@param cwd string
---@return boolean
function utils.is_safe_cwd(cwd)
	if not cwd or cwd == "" then
		return false
	end
	if cwd:find(utils.UNSAFE_CWD_PATTERN) then
		return false
	end
	return true
end

-- deep copy
---@param original table
---@return any copy
function utils.deepcopy(original)
	local copy
	if type(original) == "table" then
		copy = {}
		for k, v in pairs(original) do
			copy[k] = utils.deepcopy(v)
		end
	else
		copy = original
	end
	return copy
end

-- extend table
---@alias behavior
---| 'error' # Raises an error if a kye exists in multiple tables
---| 'keep'  # Uses the value from the leftmost table (first occurrence)
---| 'force' # Uses the value from the rightmost table (last occurrence)
---
---@param behavior behavior
---@param ... table
---@return table|nil
function utils.tbl_deep_extend(behavior, ...)
	local tables = { ... }
	if #tables == 0 then
		return {}
	end

	local result = {}
	for k, v in pairs(tables[1]) do
		if type(v) == "table" then
			result[k] = utils.deepcopy(v)
		else
			result[k] = v
		end
	end

	for i = 2, #tables do
		for k, v in pairs(tables[i]) do
			if type(result[k]) == "table" and type(v) == "table" then
				-- For nested tables, we recurse with the same behavior
				result[k] = utils.tbl_deep_extend(behavior, result[k], v)
			elseif result[k] ~= nil then
				-- Key exists in the result already
				if behavior == "error" then
					error("Key '" .. tostring(k) .. "' exists in multiple tables")
				elseif behavior == "force" then
					-- "force" uses value from rightmost table
					if type(v) == "table" then
						result[k] = utils.deepcopy(v)
					else
						result[k] = v
					end
				end
			-- "keep" keeps the leftmost value, which is already in result
			else
				-- Key doesn't exist in result yet, add it
				if type(v) == "table" then
					result[k] = utils.deepcopy(v)
				else
					result[k] = v
				end
			end
		end
	end

	return result
end

return utils
