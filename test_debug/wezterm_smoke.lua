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
local hook = ph.build_pane_session_hook_command("/mnt/c/Users/me/.claude/pane-sessions", "${SHELL_ID:-unknown}")
truthy("hook cmd has dir", hook:find("/mnt/c/Users/me/.claude/pane%-sessions/%${key}%.json") ~= nil)
truthy("hook cmd has key expr", hook:find("%${SHELL_ID:%-unknown}") ~= nil)
check("read_pane_session traversal", ph.read_pane_session("../../.bashrc"), nil)
check("read_pane_session absent", ph.read_pane_session("definitelynotarealkey"), nil)

local cleanup = ph.build_pane_session_cleanup_command("/mnt/c/Users/me/.claude/pane-sessions", "${SHELL_ID:-unknown}")
truthy("cleanup removes the file", cleanup:find('rm %-f "/mnt/c/Users/me/.claude/pane%-sessions/%${key}%.json"') ~= nil)
truthy("cleanup drains stdin", cleanup:find("cat > /dev/null") ~= nil)

-- Local keys carry the WezTerm process's instance id, because pane ids restart
-- from 0 every launch. Both sides of the boundary must spell it the same way.
local saved_prefix = ph.pane_session_prefix
ph.pane_session_prefix = "1785872700_35949"
check("local key is prefixed", ph.local_pane_session_key(0), "1785872700_35949-0")
ph.pane_session_prefix = nil
check("local key without instance", ph.local_pane_session_key(7), "noinstance-7")
ph.pane_session_prefix = saved_prefix
check("key expr matches lua", ph.local_pane_session_key_expr(), "${RESURRECT_INSTANCE:-noinstance}-${WEZTERM_PANE:-unknown}")

-- Reinstalling must replace our hooks rather than stack them up, or a stale
-- command writing under an old key would keep running forever.
local tmp = (os.getenv("TEMP") or "/tmp") .. "/resurrect-smoke-settings.json"
local seed = io.open(tmp, "w")
seed:write([[{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"play-a-sound"}]},]]
	.. [[{"hooks":[{"type":"command","command":"cat > /old/pane-sessions/0.json"}]}]}}]])
seed:close()
truthy("configure rewrites settings", ph.configure_pane_session_hooks(tmp, "NEWWRITE pane-sessions", "NEWCLEAN pane-sessions"))
local written = io.open(tmp, "r")
local settings = wezterm.json_parse(written:read("*a"))
written:close()
os.remove(tmp)
local stop_commands = {}
for _, entry in ipairs(settings.hooks.Stop) do
	for _, h in ipairs(entry.hooks or {}) do
		table.insert(stop_commands, h.command)
	end
end
check("unrelated hook survives", stop_commands[1], "play-a-sound")
check("stale hook replaced, not stacked", #stop_commands, 2)
check("stop hook is the new one", stop_commands[2], "NEWWRITE pane-sessions")
check("session end registered", settings.hooks.SessionEnd[1].hooks[1].command, "NEWCLEAN pane-sessions")
truthy("session end skips clear/resume", settings.hooks.SessionEnd[1].matcher:find("prompt_input_exit") ~= nil)
check("session end excludes clear", settings.hooks.SessionEnd[1].matcher:find("clear"), nil)

-- Rewriting the whole file means unparseable input must abort, not be treated
-- as empty and silently discard everything the user had configured.
local broken = (os.getenv("TEMP") or "/tmp") .. "/resurrect-smoke-broken.json"
local bf = io.open(broken, "w")
bf:write('{"hooks": {"Stop": [ }}}')
bf:close()
check("refuses unparseable settings", ph.configure_pane_session_hooks(broken, "W pane-sessions", "C pane-sessions"), false)
local after = io.open(broken, "r")
check("unparseable settings left alone", after:read("*a"), '{"hooks": {"Stop": [ }}}')
after:close()
os.remove(broken)

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

-- A terminal scrolls only once the cursor is on the bottom row, so writing R
-- rows then N newlines scrolls max(0, R + N - viewport) rows. Lifting all R rows
-- of restored history out of the viewport therefore needs a full viewport of
-- newlines whatever R is -- padding by the row count would leave a short history
-- on screen for ConPTY's first repaint to erase.
check("padding one line", ts.scrollback_padding_rows("only line", 40), 40)
check("padding three lines", ts.scrollback_padding_rows("a\nb\nc", 40), 40)
check("padding exactly viewport", ts.scrollback_padding_rows(string.rep("x\n", 39) .. "x", 40), 40)
check("padding longer than viewport", ts.scrollback_padding_rows(string.rep("x\n", 500) .. "x", 40), 40)
check("padding tracks viewport size", ts.scrollback_padding_rows("a\nb", 12), 12)
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
