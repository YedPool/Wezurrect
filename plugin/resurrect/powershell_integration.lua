-- Teach PowerShell to report its working directory.
--
-- PowerShell's Set-Location moves only its own provider location. The process
-- working directory -- the one Windows reports, and the only thing WezTerm can
-- read without help -- never moves from wherever the shell was launched. So a
-- pane the user has cd'd around in is saved as still sitting at its starting
-- directory, and restoring sends it back there. It is the same gap the WSL
-- integration closes, for the same reason, with the same fix: OSC 7, the escape
-- sequence a shell uses to tell the terminal where it is.
--
-- Panes spawned by a restore are unaffected, because WezTerm launches them in
-- the right directory to begin with. It is the pane a restore reuses -- the
-- first tab -- that visibly snaps back to the default, which is what makes this
-- look like a restore bug rather than a reporting one.
local wezterm = require("wezterm") --[[@as Wezterm]]
local utils = require("resurrect.utils")

local pub = {}

-- Bump when the installed snippet changes so existing profiles are upgraded.
pub.integration_version = 1

-- Marker lines used to find (and re-find) our block in the user's profile.
local PROFILE_BEGIN = "# >>> wezterm-resurrect >>>"
local PROFILE_END = "# <<< wezterm-resurrect <<<"

---------------------------------------------------------------
-- The profile snippet
---------------------------------------------------------------

-- Wraps whatever prompt function is already defined rather than replacing it,
-- and is sourced from the end of the profile so it wraps the final one. A
-- prompt installed later still wins -- oh-my-posh and friends replace `prompt`
-- outright -- but those tools generally emit OSC 7 themselves.
local INTEGRATION_SCRIPT = [==[
# wezterm-resurrect shell integration -- managed file, edits will be overwritten.
#
# Emits OSC 7 on every prompt, which is how a shell tells the terminal its
# working directory. PowerShell's Set-Location moves only its own provider
# location, never the process working directory that Windows reports, so
# without this every pane looks like it is still wherever its shell started --
# and restoring a session sends each tab back there.

if (-not $global:__WeztermResurrectInstalled) {
    $global:__WeztermResurrectInstalled = $true

    $existing = Get-Item Function:\prompt -ErrorAction SilentlyContinue
    if ($existing) {
        Set-Item -Path 'Function:\global:__WeztermResurrectInnerPrompt' -Value $existing.ScriptBlock
    }

    function global:prompt {
        $location = $ExecutionContext.SessionState.Path.CurrentLocation
        if ($location.Provider.Name -eq 'FileSystem') {
            $encoded = [System.Uri]::EscapeUriString($location.ProviderPath.Replace('\', '/'))
            $esc = [char]27
            $Host.UI.Write("$esc]7;file://$env:COMPUTERNAME/$encoded$esc\")
        }
        if (Test-Path Function:\__WeztermResurrectInnerPrompt) {
            & __WeztermResurrectInnerPrompt
        } else {
            "PS $($location.Path)> "
        }
    }
}
]==]

---------------------------------------------------------------
-- File helpers
---------------------------------------------------------------

--- Where the snippet lives. Beside the WSL one's path inside its distro, and
--- outside the plugin cache so a plugin update does not strand the profile
--- line pointing at it.
---@return string|nil
function pub.snippet_path()
	local home = os.getenv("USERPROFILE") or os.getenv("HOME")
	if not home then
		return nil
	end
	return home .. "\\.config\\wezterm-resurrect\\integration.ps1"
end

---@param path string
---@return string|nil
local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

---@param path string
---@param content string
---@return boolean
local function write_file(path, content)
	local f = io.open(path, "wb")
	if not f then
		wezterm.log_error("resurrect: cannot write " .. path)
		return false
	end
	f:write(content)
	f:flush()
	f:close()
	return true
end

---------------------------------------------------------------
-- Installation steps
---------------------------------------------------------------

--- The block appended to a profile to load the snippet.
---@param script_path string
---@return string
function pub.profile_block(script_path)
	-- PowerShell single-quoted strings escape a quote by doubling it.
	local quoted = script_path:gsub("'", "''")
	return table.concat({
		PROFILE_BEGIN,
		". '" .. quoted .. "'",
		PROFILE_END,
		"",
	}, "\n")
end

--- Append the block to a profile unless it is already there.
---@param profile_path string
---@param script_path string
---@return boolean success
function pub.ensure_profile_sources(profile_path, script_path)
	local existing = read_file(profile_path) or ""
	if existing:find(PROFILE_BEGIN, 1, true) then
		return true
	end
	local separator = (existing == "" or existing:sub(-1) == "\n") and "" or "\n"
	return write_file(profile_path, existing .. separator .. pub.profile_block(script_path))
end

--- Install the snippet and wire one profile up to it.
---@param profile_path string
---@return boolean success
function pub.install_profile(profile_path)
	local script_path = pub.snippet_path()
	if not script_path then
		wezterm.log_error("resurrect: cannot determine home directory for PowerShell integration")
		return false
	end

	local script_dir = script_path:gsub("\\[^\\]+$", "")
	if not utils.ensure_folder_exists(script_dir) then
		return false
	end
	if not write_file(script_path, INTEGRATION_SCRIPT) then
		return false
	end

	local profile_dir = profile_path:gsub("\\[^\\]+$", "")
	if not utils.ensure_folder_exists(profile_dir) then
		return false
	end
	return pub.ensure_profile_sources(profile_path, script_path)
end

-- The shells worth asking. Each is queried for its own profile path rather than
-- guessed at, because Documents is routinely relocated (OneDrive, most often).
local SHELLS = { "powershell.exe", "pwsh.exe" }

--- Install the integration for every PowerShell on the system, once per profile
--- per integration version.
---
--- Must not be called while the config is being evaluated: it uses
--- wezterm.run_child_process, which yields. Call it from an event handler.
---@param marker_dir string directory for the "already installed" markers
---@return number installed count of profiles newly installed into
function pub.ensure_installed(marker_dir)
	if not utils.is_windows then
		return 0
	end
	if not utils.ensure_folder_exists(marker_dir) then
		wezterm.log_error("resurrect: cannot create shell integration marker dir: " .. marker_dir)
		return 0
	end

	local installed = 0
	local seen = {}
	for _, shell in ipairs(SHELLS) do
		local ok, out = utils.exec({ shell, "-NoProfile", "-NoLogo", "-Command", "$PROFILE.CurrentUserAllHosts" })
		local profile_path = ok and out and out:match("^%s*(.-)%s*$") or nil
		if profile_path and profile_path ~= "" and not seen[profile_path] then
			seen[profile_path] = true
			local marker = marker_dir
				.. utils.separator
				.. profile_path:gsub("[^%w%-%._]", "_")
				.. ".v"
				.. tostring(pub.integration_version)
			local existing = io.open(marker, "r")
			if existing then
				existing:close()
			else
				local called_ok, result = pcall(pub.install_profile, profile_path)
				if called_ok and result then
					local handle = io.open(marker, "w")
					if handle then
						handle:write(profile_path .. "\n")
						handle:close()
					end
					installed = installed + 1
					wezterm.log_info("resurrect: installed PowerShell integration into " .. profile_path)
				else
					wezterm.log_warn(
						"resurrect: PowerShell integration not installed for "
							.. profile_path
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
	INTEGRATION_SCRIPT = INTEGRATION_SCRIPT,
	PROFILE_BEGIN = PROFILE_BEGIN,
	PROFILE_END = PROFILE_END,
}

return pub
