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

-- setup() runs on every launch and config reload, so an unchanged file must not
-- be rewritten -- a stale read written back would undo an edit Claude Code made
-- to settings.json in the meantime.
local stable = (os.getenv("TEMP") or "/tmp") .. "/resurrect-smoke-stable.json"
local sf = io.open(stable, "w")
sf:write("{}")
sf:close()
ph.configure_pane_session_hooks(stable, "W pane-sessions", "C pane-sessions")
local first = io.open(stable, "r")
local first_text = first:read("*a")
first:close()
-- Mark the file so a rewrite is detectable even if it would be byte-identical.
local marked = io.open(stable, "w")
marked:write(first_text .. "\n")
marked:close()
ph.configure_pane_session_hooks(stable, "W pane-sessions", "C pane-sessions")
local second = io.open(stable, "r")
local second_text = second:read("*a")
second:close()
os.remove(stable)
check("unchanged hooks are not rewritten", second_text, first_text .. "\n")

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
-- Restored scrollback is mostly whitespace: every line is padded to the pane
-- width. gsub("%s+$") retries at every position and walks each run it finds, so
-- on a real capture it took 15 seconds -- once per pane, on the GUI thread.
check("trim strips trailing spaces", ts.trim_trailing_whitespace("abc   "), "abc")
check("trim strips mixed trailing", ts.trim_trailing_whitespace("abc \t\r\n "), "abc")
check("trim keeps inner whitespace", ts.trim_trailing_whitespace("a  b  "), "a  b")
check("trim leaves clean text", ts.trim_trailing_whitespace("abc"), "abc")
check("trim handles empty", ts.trim_trailing_whitespace(""), "")
check("trim handles all whitespace", ts.trim_trailing_whitespace("   \n  "), "")
-- Padded like the real thing, and large enough that a backtracking pattern
-- would take seconds: this must stay instant.
local padded = string.rep("PS C:\\Users\\me>" .. string.rep(" ", 170) .. "\r\n", 3000)
local trim_started = os.clock()
local trimmed = ts.trim_trailing_whitespace(padded)
local trim_ms = math.floor((os.clock() - trim_started) * 1000)
check("trim of a real-sized capture is exact", #trimmed, #padded - 172)
truthy("trim of a real-sized capture is fast (" .. trim_ms .. "ms)", trim_ms < 100)

check("padding empty", ts.scrollback_padding_rows("", 40), 0)
check("padding nil", ts.scrollback_padding_rows(nil, 40), 0)

-- Parking must stop short of a full page, or the last history row lands on the
-- bottom edge and the live prompt sits one row past it, out of sight.
check("park keeps the prompt in view", ts.history_scroll_rows(500, 40), 34)
-- ...and never scroll past the history into the empty buffer above it.
check("park stops at the history top", ts.history_scroll_rows(5, 40), 5)
check("park with no history", ts.history_scroll_rows(0, 40), 0)
check("park in a tiny pane", ts.history_scroll_rows(500, 4), 0)

-- ------------------------------------------------------- instance_manager
local im = resurrect.instance_manager
-- The snapshot a restore adopts must not alias the state being restored:
-- restoring hangs live Pane objects off those tables, and json_encode throws on
-- the first one it meets, taking the adoption down with it.
local source = { workspace = "default", window_states = { { tabs = { { pane_tree = { cwd = "/a" } } } } } }
local snapshot = im._test.accumulate_adoption(nil, source)
check("adoption copies the workspace", snapshot.workspace, "default")
check("adoption copies the windows", #snapshot.window_states, 1)
source.window_states[1].tabs[1].pane_tree.pane = print
source.window_states[1].tabs[1].pane_tree.cwd = "/mutated"
check("adoption is not aliased", snapshot.window_states[1].tabs[1].pane_tree.cwd, "/a")
truthy("adoption stays serialisable", pcall(wezterm.json_encode, snapshot))
truthy("...unlike the state it copied", not pcall(wezterm.json_encode, source))

-------------------------------------------------------- wsl_integration
local wi = resurrect.wsl_integration
local cands = wi._test.unc_candidates("Ubuntu-22.04", "/home/me/.bashrc")
check("unc primary", cands[1], "\\\\wsl.localhost\\Ubuntu-22.04\\home\\me\\.bashrc")
check("unc fallback", cands[2], "\\\\wsl$\\Ubuntu-22.04\\home\\me\\.bashrc")
truthy("snippet has osc7", wi._test.INTEGRATION_SCRIPT:find("]7;file://") ~= nil)
truthy("snippet publishes shell id", wi._test.INTEGRATION_SCRIPT:find("SetUserVar=resurrect_shell_id") ~= nil)

-------------------------------------------------------- window_geometry
local geom = resurrect.window_geometry
check("geometry is opt-in", geom.enabled, false)
check("geometry capture is a no-op when off", geom.capture(), nil)
truthy("geometry script reads placement", geom._test.SCRIPT:find("GetWindowPlacement") ~= nil)
truthy("geometry script caches its assembly", geom._test.SCRIPT:find("OutputAssembly") ~= nil)
-- The rect Windows reports is the outer window; set_inner_size takes the inner
-- one. Feeding the first into the second would grow the window by its frame on
-- every save/restore cycle, so apply() must not touch the size at all.
truthy("geometry never sets a size", not geom._test.SCRIPT:find("set_inner_size"))

-- apply() is all best-effort: none of it should throw on a window that has gone.
truthy("apply tolerates nil geometry", pcall(geom.apply, nil, nil))
truthy("apply tolerates a dead window", pcall(geom.apply, nil, { x = 1, y = 2, maximized = true }))

-- Saves that do not pay for a capture must still carry the last geometry seen,
-- or opening a tab would erase the position the last periodic save recorded.
geom._test.reset()
geom.enabled = true
check("nothing known before a capture", geom.last_known(), nil)
geom.apply(nil, { x = 7, y = 9, maximized = true })
local remembered = geom.last_known()
check("restoring seeds what is known", remembered and remembered.x, 7)
check("...including maximized", remembered and remembered.maximized, true)
geom.enabled = false
check("nothing known while disabled", geom.last_known(), nil)
geom._test.reset()

-------------------------------------------------- powershell_integration
local psi = resurrect.powershell_integration
truthy("ps snippet emits osc7", psi._test.INTEGRATION_SCRIPT:find("%]7;file://") ~= nil)
truthy("ps snippet wraps the existing prompt", psi._test.INTEGRATION_SCRIPT:find("__WeztermResurrectInnerPrompt") ~= nil)
truthy("ps snippet guards re-sourcing", psi._test.INTEGRATION_SCRIPT:find("__WeztermResurrectInstalled") ~= nil)
truthy("ps block dot-sources the snippet", psi.profile_block("C:\\x\\y.ps1"):find(". 'C:\\x\\y.ps1'", 1, true) ~= nil)
-- PowerShell escapes a quote inside a single-quoted string by doubling it.
truthy("ps block escapes quotes", psi.profile_block("C:\\it's\\y.ps1"):find("it''s", 1, true) ~= nil)

-- Appending to a profile must be idempotent: setup() runs on every launch, and
-- a second copy of the block would wrap the prompt twice.
local prof = (os.getenv("TEMP") or "/tmp") .. "/resurrect-smoke-profile.ps1"
local pf = io.open(prof, "wb")
pf:write("Set-Alias ll Get-ChildItem\n")
pf:close()
truthy("ps profile patched", psi.ensure_profile_sources(prof, "C:\\snippet.ps1"))
truthy("ps profile patched again", psi.ensure_profile_sources(prof, "C:\\snippet.ps1"))
local pr = io.open(prof, "rb")
local profile_text = pr:read("*a")
pr:close()
os.remove(prof)
-- Counted with plain finds: the marker contains a dash, which is a quantifier
-- in a Lua pattern and would silently never match.
local block_count, at = 0, 1
while true do
	local found = profile_text:find(psi._test.PROFILE_BEGIN, at, true)
	if not found then
		break
	end
	block_count, at = block_count + 1, found + 1
end
check("ps block added exactly once", block_count, 1)
truthy("ps profile keeps what was there", profile_text:find("Set-Alias ll", 1, true) ~= nil)

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
