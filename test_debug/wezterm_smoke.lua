-- Smoke tests that run inside WezTerm's own Lua, for machines with no
-- standalone Lua runtime (see CLAUDE.md: tests normally need bundled tools).
--
--   wezterm --config-file test_debug/wezterm_smoke.lua show-keys
--
-- show-keys evaluates the config and exits, so every module the plugin loads is
-- parsed and the assertions below run. Grep the output for TESTSUMMARY.
--
-- Set RESURRECT_SMOKE_DISTRO (and optionally RESURRECT_SMOKE_HOME, default
-- /home/$USERNAME) to also install the WSL integration into a live distro and
-- verify what landed. Without it, those checks are skipped. From Git Bash,
-- prefix with MSYS_NO_PATHCONV=1 or the POSIX $HOME is rewritten to a Windows
-- path before WezTerm ever sees it:
--
--   MSYS_NO_PATHCONV=1 RESURRECT_SMOKE_DISTRO=Ubuntu-22.04 \
--     wezterm --config-file test_debug/wezterm_smoke.lua show-keys
local wezterm = require("wezterm")
local config = wezterm.config_builder()
local resurrect = wezterm.plugin.require("https://github.com/YedPool/resurrect.wezterm")

local utils = require("resurrect.utils")
local pass, fail, skip = 0, 0, 0

local function check(name, actual, expected)
	if actual == expected then
		pass = pass + 1
		wezterm.log_info("TESTOK   " .. name)
	else
		fail = fail + 1
		wezterm.log_error(
			"TESTFAIL " .. name .. " -- got [" .. tostring(actual) .. "] want [" .. tostring(expected) .. "]"
		)
	end
end

local function truthy(name, actual)
	if actual then
		pass = pass + 1
		wezterm.log_info("TESTOK   " .. name)
	else
		fail = fail + 1
		wezterm.log_error("TESTFAIL " .. name .. " -- got [" .. tostring(actual) .. "]")
	end
end

---------------------------------------------------------------- utils
check("is_wsl_domain wsl", utils.is_wsl_domain("WSL:Ubuntu-22.04"), true)
check("is_wsl_domain local", utils.is_wsl_domain("local"), false)
check("is_wsl_domain nil", utils.is_wsl_domain(nil), false)
check("wsl_distro", utils.wsl_distro("WSL:Ubuntu-22.04"), "Ubuntu-22.04")
check("wsl_distro local", utils.wsl_distro("local"), nil)

check("to_wsl /C:/", utils.to_wsl_path("/C:/Users/me/"), "/mnt/c/Users/me/")
check("to_wsl C:/", utils.to_wsl_path("C:/Users/me"), "/mnt/c/Users/me")
check("to_wsl backslash", utils.to_wsl_path("C:\\Users\\me"), "/mnt/c/Users/me")
check("to_wsl already mnt", utils.to_wsl_path("/mnt/c/Users/me"), "/mnt/c/Users/me")
check("to_wsl posix home", utils.to_wsl_path("/home/me"), "/home/me")
check("to_wsl bare drive", utils.to_wsl_path("C:"), "/mnt/c")

check("to_win mnt", utils.to_windows_path("/mnt/c/Users/me"), "C:\\Users\\me")
check("to_win posix", utils.to_windows_path("/home/me"), "/home/me")

-- Local panes keep the existing Windows spelling; WSL panes become POSIX.
if utils.is_windows then
	check("normalize local", utils.normalize_saved_cwd("/C:/Users/me/", "local"), "C:/Users/me/")
end
check("normalize wsl from win", utils.normalize_saved_cwd("/C:/Users/me/", "WSL:Ubuntu-22.04"), "/mnt/c/Users/me/")
check("normalize wsl osc7", utils.normalize_saved_cwd("/home/me", "WSL:Ubuntu-22.04"), "/home/me")
check("normalize empty", utils.normalize_saved_cwd(nil, "local"), "")

------------------------------------------------------- process_handlers
local ph = resurrect.process_handlers
local hook = ph.build_pane_session_hook_command("/mnt/c/Users/me/.claude/pane-sessions", "WEZTERM_RESURRECT_SHELL_ID")
truthy("hook cmd has dir", hook:find("/mnt/c/Users/me/.claude/pane%-sessions/%${key}%.json") ~= nil)
truthy("hook cmd has env var", hook:find("WEZTERM_RESURRECT_SHELL_ID") ~= nil)
check("read_pane_session traversal", ph.read_pane_session("../../.bashrc"), nil)
check("read_pane_session absent", ph.read_pane_session("definitelynotarealkey"), nil)

------------------------------------------------------------- tab_state
local ts = resurrect.tab_state
local local_node = { domain = "local", cwd = "C:/Users/me" }
local local_args = ts.apply_spawn_target({}, local_node)
check("local spawn cwd", local_args.cwd, "C:/Users/me")
check("local spawn domain", local_args.domain.DomainName, "local")
check("local no cd needed", local_node.restore_cwd, false)

local wsl_node = { domain = "WSL:Ubuntu-22.04", cwd = "/home/me" }
local wsl_args = ts.apply_spawn_target({}, wsl_node)
check("wsl spawn omits cwd", wsl_args.cwd, nil)
check("wsl spawn domain", wsl_args.domain.DomainName, "WSL:Ubuntu-22.04")
check("wsl needs cd", wsl_node.restore_cwd, true)

-- Enough padding to lift the last row of restored scrollback above the top of
-- the viewport, so ConPTY cannot repaint over it and the shell's first prompt
-- lands underneath it rather than on top of it.
check("padding one line", ts.scrollback_padding_rows("only line", 40), 1)
check("padding three lines", ts.scrollback_padding_rows("a\nb\nc", 40), 3)
check("padding exactly viewport", ts.scrollback_padding_rows(string.rep("x\n", 39) .. "x", 40), 40)
check("padding capped at viewport", ts.scrollback_padding_rows(string.rep("x\n", 500) .. "x", 40), 40)
check("padding empty", ts.scrollback_padding_rows("", 40), 0)
check("padding nil", ts.scrollback_padding_rows(nil, 40), 0)

-------------------------------------------------------- wsl_integration
local wi = resurrect.wsl_integration
local cands = wi._test.unc_candidates("Ubuntu-22.04", "/home/me/.bashrc")
check("unc primary", cands[1], "\\\\wsl.localhost\\Ubuntu-22.04\\home\\me\\.bashrc")
check("unc fallback", cands[2], "\\\\wsl$\\Ubuntu-22.04\\home\\me\\.bashrc")
truthy("snippet has osc7", wi._test.INTEGRATION_SCRIPT:find("]7;file://") ~= nil)
truthy("snippet publishes shell id", wi._test.INTEGRATION_SCRIPT:find("SetUserVar=resurrect_shell_id") ~= nil)

local distro = os.getenv("RESURRECT_SMOKE_DISTRO")
if distro then
	local home = os.getenv("RESURRECT_SMOKE_HOME") or ("/home/" .. (os.getenv("USERNAME") or "user"))
	-- File writes only: the wsl.exe probes install_distro would otherwise run
	-- use run_child_process, which cannot yield during config evaluation.
	local ok, result = pcall(wi.install_distro, distro, home)
	truthy("install_distro ran", ok)
	check("install_distro result", result, true)

	-- Must land as LF even when git's autocrlf hands the plugin source a CRLF
	-- copy of the snippet, because a CRLF shell script does not run.
	local landed_path = wi._test.unc_candidates(distro, home .. "/.config/wezterm-resurrect/integration.sh")[1]
	local handle = io.open(landed_path, "rb")
	local landed = handle and handle:read("*a") or ""
	if handle then
		handle:close()
	end
	truthy("installed snippet is non-empty", #landed > 500)
	truthy("installed snippet has no CRLF", landed:find("\r") == nil)
	truthy("installed snippet has osc7", landed:find("]7;file://") ~= nil)
else
	skip = skip + 1
	wezterm.log_info("TESTSKIP WSL install checks (set RESURRECT_SMOKE_DISTRO to enable)")
end

wezterm.log_info(string.format("TESTSUMMARY pass=%d fail=%d skipped=%d", pass, fail, skip))

return config
