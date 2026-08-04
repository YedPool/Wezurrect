-- Automatic setup of the pieces a WSL pane needs before it can be restored.
--
-- Windows can read a local process's working directory and argv straight from
-- the OS. It cannot do that for a process inside the WSL VM: WezTerm only sees
-- wsl.exe, and the cwd it reports is the Windows directory wsl.exe was launched
-- from. Two things close that gap, and both are installed here so that the user
-- only ever has to install the plugin:
--
--   1. A shell snippet inside the distro that emits OSC 7 on every prompt, which
--      is how a shell tells the terminal its real working directory.
--   2. A Claude Code hook inside the distro that records the session id of a
--      Claude running there, so it can be resumed with --resume.
--
-- Both are keyed by a per-shell id rather than WEZTERM_PANE, because WezTerm's
-- WSLENV list forwards only TERM/COLORTERM/TERM_PROGRAM/TERM_PROGRAM_VERSION
-- into the distro -- WEZTERM_PANE does not cross the boundary. The snippet
-- generates that id, exports it (so Claude inherits it) and publishes it to
-- WezTerm as the "resurrect_shell_id" user var, which is what pane_tree reads
-- back when deciding which pane-session file belongs to a pane.
local wezterm = require("wezterm") --[[@as Wezterm]]
local utils = require("resurrect.utils")
local process_handlers = require("resurrect.process_handlers")

local pub = {}

-- Bump when the installed snippet changes so existing distros are upgraded.
pub.integration_version = 1

-- Where the snippet lives inside the distro, relative to $HOME.
local INTEGRATION_REL_PATH = "/.config/wezterm-resurrect/integration.sh"

-- Marker lines used to find (and re-find) our block in the user's rc file.
local RC_BEGIN = "# >>> wezterm-resurrect >>>"
local RC_END = "# <<< wezterm-resurrect <<<"

---------------------------------------------------------------
-- The shell snippet
---------------------------------------------------------------

-- Written verbatim into the distro. Kept POSIX-ish at the top so that sourcing
-- it from a non-interactive or non-bash shell is harmless; the prompt hook
-- itself is bash, which is what WezTerm's WSL domains launch by default.
local INTEGRATION_SCRIPT = [==[
# wezterm-resurrect shell integration -- managed file, edits will be overwritten.
#
# Publishes two things to WezTerm on every prompt:
#   * OSC 7: this shell's working directory. Windows cannot read the cwd of a
#     process inside the WSL VM, so without this WezTerm records the Windows
#     directory wsl.exe was launched from and session restore lands in the
#     wrong place (or fails outright on a path that has no Linux equivalent).
#   * resurrect_shell_id: a stable per-shell id, also exported so that child
#     processes such as Claude Code inherit it. WEZTERM_PANE is not forwarded
#     into WSL, so this is what identifies the pane on the Linux side.

case $- in
	*i*) ;;
	*) return 0 ;;
esac

if [ -z "${WEZTERM_RESURRECT_SHELL_ID:-}" ]; then
	if [ -r /proc/sys/kernel/random/uuid ]; then
		WEZTERM_RESURRECT_SHELL_ID=$(tr -d '\n' < /proc/sys/kernel/random/uuid)
	else
		WEZTERM_RESURRECT_SHELL_ID="shell-$$"
	fi
	export WEZTERM_RESURRECT_SHELL_ID
fi

# Encoded once at startup: the id never changes, and this keeps the prompt hook
# free of subprocesses.
if [ -z "${WEZTERM_RESURRECT_SHELL_ID_B64:-}" ]; then
	WEZTERM_RESURRECT_SHELL_ID_B64=$(printf '%s' "$WEZTERM_RESURRECT_SHELL_ID" | base64 | tr -d '\n')
fi

__wezterm_resurrect_urlencode() {
	local LC_ALL=C
	local str="$1"
	local out=""
	local i char
	for (( i = 0; i < ${#str}; i++ )); do
		char="${str:i:1}"
		case "$char" in
			[-_.~/a-zA-Z0-9]) out="$out$char" ;;
			*)
				printf -v char '%%%02X' "'$char"
				out="$out$char"
				;;
		esac
	done
	printf '%s' "$out"
}

__wezterm_resurrect_prompt() {
	local __wezterm_resurrect_status=$?
	printf '\033]7;file://%s%s\033\\' \
		"${HOSTNAME:-}" "$(__wezterm_resurrect_urlencode "$PWD")"
	printf '\033]1337;SetUserVar=resurrect_shell_id=%s\007' \
		"$WEZTERM_RESURRECT_SHELL_ID_B64"
	return $__wezterm_resurrect_status
}

case "${PROMPT_COMMAND:-}" in
	*__wezterm_resurrect_prompt*) ;;
	"") PROMPT_COMMAND="__wezterm_resurrect_prompt" ;;
	*) PROMPT_COMMAND="__wezterm_resurrect_prompt;${PROMPT_COMMAND}" ;;
esac
]==]

---------------------------------------------------------------
-- File helpers
--
-- WSL filesystems are reachable from Windows through the 9p share at
-- \\wsl.localhost\<distro> (\\wsl$\<distro> on older builds). Writing through
-- it keeps the whole installer in Lua instead of quoting a shell script through
-- wsl.exe. All I/O is binary: Lua's text mode would translate \n to \r\n, and
-- a CRLF shell script does not run.
---------------------------------------------------------------

local UNC_PREFIXES = { "\\\\wsl.localhost\\", "\\\\wsl$\\" }

--- Build the Windows path for a file inside a distro, for each UNC spelling.
---@param distro string
---@param posix_path string absolute path inside the distro
---@return string[] candidates
local function unc_candidates(distro, posix_path)
	local tail = posix_path:gsub("^/", ""):gsub("/", "\\")
	local candidates = {}
	for _, prefix in ipairs(UNC_PREFIXES) do
		table.insert(candidates, prefix .. distro .. "\\" .. tail)
	end
	return candidates
end

--- Read a file inside a distro. Returns nil when it does not exist.
---@param distro string
---@param posix_path string
---@return string|nil content
local function read_wsl_file(distro, posix_path)
	for _, path in ipairs(unc_candidates(distro, posix_path)) do
		local f = io.open(path, "rb")
		if f then
			local content = f:read("*a")
			f:close()
			return content
		end
	end
	return nil
end

--- Write a file inside a distro, trying each UNC spelling in turn.
--- Line endings are forced to LF: a shell script with CRLF line endings does
--- not run, and git's autocrlf can hand us a CRLF copy of this very source file.
---@param distro string
---@param posix_path string
---@param content string
---@return boolean success
local function write_wsl_file(distro, posix_path, content)
	content = content:gsub("\r\n", "\n")
	for _, path in ipairs(unc_candidates(distro, posix_path)) do
		local f = io.open(path, "wb")
		if f then
			f:write(content)
			f:flush()
			f:close()
			return true
		end
	end
	wezterm.log_error("resurrect: cannot write " .. posix_path .. " in WSL distro " .. distro)
	return false
end

---------------------------------------------------------------
-- Installation steps
---------------------------------------------------------------

--- Append the source line to the distro's .bashrc unless it is already there.
---@param distro string
---@param home string
---@return boolean success
local function ensure_rc_sources_integration(distro, home)
	local rc_path = home .. "/.bashrc"
	local existing = read_wsl_file(distro, rc_path) or ""
	if existing:find("wezterm%-resurrect/integration%.sh") then
		return true
	end

	local block = table.concat({
		RC_BEGIN,
		'[ -f "$HOME' .. INTEGRATION_REL_PATH .. '" ] && . "$HOME' .. INTEGRATION_REL_PATH .. '"',
		RC_END,
		"",
	}, "\n")

	local separator = (existing == "" or existing:sub(-1) == "\n") and "" or "\n"
	return write_wsl_file(distro, rc_path, existing .. separator .. block)
end

--- Register the pane-session hook with the Claude Code installed in the distro.
--- Session files are written to the Windows-side pane-sessions directory through
--- its /mnt mount so that the Lua running on Windows can read them back.
---@param distro string
---@param home string
---@return boolean success
local function ensure_claude_hook(distro, home)
	local windows_home = os.getenv("USERPROFILE") or os.getenv("HOME")
	if not windows_home then
		return false
	end
	local pane_sessions_dir = utils.to_wsl_path(windows_home .. "\\.claude\\pane-sessions")
	local hook_command =
		process_handlers.build_pane_session_hook_command(pane_sessions_dir, "WEZTERM_RESURRECT_SHELL_ID")

	-- configure_pane_session_hooks does plain io.open on the path it is given,
	-- so hand it whichever UNC spelling actually resolves for this distro.
	local settings_posix = home .. "/.claude/settings.json"
	for _, path in ipairs(unc_candidates(distro, settings_posix)) do
		local probe = io.open(path, "rb")
		if probe then
			probe:close()
			return process_handlers.configure_pane_session_hooks(path, hook_command)
		end
	end

	-- No settings.json yet: create one at the first spelling that accepts a write.
	for _, path in ipairs(unc_candidates(distro, settings_posix)) do
		local probe = io.open(path, "ab")
		if probe then
			probe:close()
			return process_handlers.configure_pane_session_hooks(path, hook_command)
		end
	end

	wezterm.log_warn("resurrect: could not reach Claude settings in WSL distro " .. distro)
	return false
end

--- Install the integration into one distro. Safe to call repeatedly.
---@param distro string distribution name, e.g. "Ubuntu-22.04"
---@param home_override string? skip the wsl.exe probes and use this $HOME
---       (only for tests, which run where run_child_process is unavailable)
---@return boolean success
function pub.install_distro(distro, home_override)
	local home = home_override
	if not home then
		local ok, probed = utils.exec({ "wsl.exe", "-d", distro, "-e", "sh", "-c", 'printf %s "$HOME"' })
		if not ok or not probed or probed == "" then
			wezterm.log_warn("resurrect: could not determine $HOME in WSL distro " .. distro)
			return false
		end
		home = probed:gsub("%s+$", "")

		-- mkdir from inside the distro: the directories may not exist yet, and
		-- creating them through the 9p share is less reliable than mkdir -p.
		utils.exec({
			"wsl.exe", "-d", distro, "-e", "mkdir", "-p",
			home .. "/.config/wezterm-resurrect",
			home .. "/.claude",
		})
	end
	if not home:match("^/") then
		wezterm.log_warn("resurrect: unexpected $HOME in WSL distro " .. distro .. ": " .. home)
		return false
	end

	if not write_wsl_file(distro, home .. INTEGRATION_REL_PATH, INTEGRATION_SCRIPT) then
		return false
	end
	if not ensure_rc_sources_integration(distro, home) then
		return false
	end

	-- A missing Claude Code in the distro is not a failure: the cwd half of the
	-- integration is useful on its own.
	ensure_claude_hook(distro, home)
	return true
end

--- Install the integration into every installed WSL distribution, once per
--- distro per integration version.
---
--- Must not be called while the config is being evaluated: it uses
--- wezterm.run_child_process, which yields. Call it from an event handler.
---@param marker_dir string directory for the "already installed" markers
---@return number installed count of distros newly installed into
function pub.ensure_installed(marker_dir)
	if not utils.is_windows then
		return 0
	end

	local ok, domains = pcall(wezterm.default_wsl_domains)
	if not ok or not domains then
		return 0
	end

	if not utils.ensure_folder_exists(marker_dir) then
		wezterm.log_error("resurrect: cannot create WSL integration marker dir: " .. marker_dir)
		return 0
	end

	local installed = 0
	for _, domain in ipairs(domains) do
		local distro = domain.distribution or utils.wsl_distro(domain.name)
		if distro then
			-- One marker per distro per version; a version bump reinstalls.
			local marker = marker_dir
				.. utils.separator
				.. distro:gsub("[^%w%-%._]", "_")
				.. ".v"
				.. tostring(pub.integration_version)
			local existing = io.open(marker, "r")
			if existing then
				existing:close()
			else
				local called_ok, result = pcall(pub.install_distro, distro)
				if called_ok and result then
					-- Only mark it done once it succeeded, so a distro that was
					-- shut down or unreachable is retried on the next launch.
					local handle = io.open(marker, "w")
					if handle then
						handle:write(distro .. "\n")
						handle:close()
					end
					installed = installed + 1
					wezterm.log_info("resurrect: installed WSL integration into " .. distro)
				else
					wezterm.log_warn(
						"resurrect: WSL integration not installed for "
							.. distro
							.. (called_ok and "" or (": " .. tostring(result)))
					)
				end
			end
		end
	end
	return installed
end

-- Expose internals for unit testing only
pub._test = {
	unc_candidates = unc_candidates,
	INTEGRATION_SCRIPT = INTEGRATION_SCRIPT,
	RC_BEGIN = RC_BEGIN,
	RC_END = RC_END,
}

return pub
