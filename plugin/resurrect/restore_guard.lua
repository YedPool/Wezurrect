-- restore_guard.lua -- Never resume a Claude session that is already running
--
-- A restore types "claude --resume <session id>" into panes. If that session
-- still has a live process (the saved state is a copy of windows that are
-- still open, or of another running terminal), the conversation ends up
-- running twice. This module decides, for every restore command, whether it
-- may be sent.
--
-- The rule. Claude Code keeps one control file per running process in
-- ~/.claude/sessions/<pid>.json with the fields sessionId, pid and procStart
-- (the process start time). A session is LIVE when a control file names it,
-- that pid is a running process, AND the process start time equals procStart.
-- A pid alone proves nothing: Windows reuses pids.
--
-- Fail closed. If the control files cannot be read, or the answer for one
-- session cannot be established, the resume command is NOT sent.
--
-- Everything here is plain Lua over the text returned by pub.run_query, the
-- one function that asks the operating system. Tests replace that function.

local wezterm = require("wezterm") --[[@as Wezterm]]
local utils = require("resurrect.utils")

local pub = {}

-- How long one reading of the control files is reused. A restore checks every
-- pane; without this each pane would start its own PowerShell.
pub.snapshot_ttl_seconds = 10

-- How long a session counts as taken after this plugin sent its resume
-- command. Covers the gap before Claude has written its control file, so the
-- same session saved in two panes (or two saved copies) is resumed once.
pub.claim_ttl_seconds = 120

-- procStart and the measured start time are Windows FILETIME values (100 ns
-- units). They were identical on every file checked; one second of slack
-- costs nothing, because a reused pid cannot have started within a second of
-- the process that owned it before.
pub.start_time_tolerance = 10000000

-- ---------------------------------------------------------------------------
-- The one function that asks the operating system
-- ---------------------------------------------------------------------------

-- One PowerShell statement list, written without double quotes or newlines so
-- it survives being passed as a single process argument.
local QUERY_SCRIPT = table.concat({
	"$ErrorActionPreference = 'Stop'; $t = [char]9;",
	"try { $n = 0; $dirs = @(@DIRS@);",
	"for ($i = 0; $i -lt $dirs.Count; $i++) { $d = $dirs[$i];",
	"if (-not (Test-Path -LiteralPath $d -PathType Container)) {",
	"if ($i -eq 0) { throw 'control directory not found' } else { continue } };",
	"foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File)) {",
	"$n++; $sid = ''; $id = ''; $ps = ''; $cwd = '';",
	"try { $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json;",
	"$sid = [string]$j.sessionId; $id = [string]$j.pid;",
	"$ps = [string]$j.procStart; $cwd = [string]$j.cwd } catch { };",
	"if ($id -notmatch '^[0-9]+$') { $id = $f.BaseName };",
	"$run = 1; $st = '?';",
	"if ($id -match '^[0-9]+$') {",
	"$p = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue;",
	"if ($p) { try { $st = [string]$p.StartTime.ToFileTimeUtc() } catch { $st = '?' } }",
	"else { $run = 0 } };",
	"('S', $sid, $id, $ps, $run, $st, $cwd) -join $t } };",
	"('END', $n) -join $t }",
	"catch { ('ERR', $_.Exception.Message) -join $t }",
}, " ")

--- Ask the operating system which Claude control files exist and whether the
--- process each one names is running. THE ONLY PLACE THIS MODULE TOUCHES THE
--- OS; everything else works on the text it returns.
---
--- Contract:
---   dirs    control-file directories. The first MUST exist; later ones are
---           skipped when absent.
---   returns stdout (string) on success, or nil and a reason.
---
--- stdout is lines of tab-separated fields:
---   S <sessionId> <pid> <procStart> <running> <startTime> <cwd>
---       one per *.json control file. sessionId, procStart and cwd are copied
---       from the file (empty when the file could not be parsed; pid then
---       falls back to the file's base name, which Claude sets to the pid).
---       running is 1 when a process with that pid exists now, 0 when not,
---       and 1 when the pid is unknown (so it can never read as "gone").
---       startTime is that process's start time as a FILETIME in decimal --
---       the same encoding Claude writes to procStart on Windows -- or ? when
---       it could not be read.
---   END <n>     last line; n is the number of S lines. Its absence means the
---               output is incomplete and must not be trusted.
---   ERR <text>  the query failed (for example the first directory is gone).
---
--- Yields (wezterm.run_child_process), so it must be called from an event or
--- key callback, never while the config file is being evaluated.
---@param dirs string[]
---@return string|nil stdout
---@return string|nil err
function pub.run_query(dirs)
	if not utils.is_windows then
		-- procStart is encoded per platform and only the Windows encoding has
		-- been checked against real files. Unknown means "do not resume".
		return nil, "the running-session check is only implemented on Windows"
	end
	local quoted = {}
	for _, dir in ipairs(dirs) do
		table.insert(quoted, "'" .. dir:gsub("'", "''") .. "'")
	end
	local dir_list = table.concat(quoted, ", ")
	local script = QUERY_SCRIPT:gsub("@DIRS@", function()
		return dir_list
	end)
	local success, stdout, stderr = wezterm.run_child_process({
		"powershell.exe", "-NoProfile", "-NoLogo", "-NonInteractive", "-Command", script,
	})
	if not success then
		return nil, "powershell.exe failed: " .. tostring(stderr)
	end
	return stdout
end

--- The directories Claude Code writes control files to: ~/.claude/sessions,
--- and ~/.claude-alt/sessions for the claude2 multi-account setup.
---@return string[]
function pub.control_dirs()
	local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
	local sep = utils.separator
	return {
		home .. sep .. ".claude" .. sep .. "sessions",
		home .. sep .. ".claude-alt" .. sep .. "sessions",
	}
end

-- ---------------------------------------------------------------------------
-- Reading the answer
-- ---------------------------------------------------------------------------

-- Split one line on tabs, keeping empty fields.
local function split_tabs(line)
	local fields = {}
	for field in (line .. "\t"):gmatch("(.-)\t") do
		table.insert(fields, field)
	end
	return fields
end

--- Parse the text returned by run_query into records.
---@param stdout string
---@return table[]|nil records { session_id, pid, proc_start, running, start_time, cwd }
---@return string|nil err
local function parse_query_output(stdout)
	if type(stdout) ~= "string" then
		return nil, "no output"
	end
	local records = {}
	local declared = nil
	for line in stdout:gmatch("[^\r\n]+") do
		local fields = split_tabs(line)
		if fields[1] == "ERR" then
			return nil, fields[2] or "query failed"
		elseif fields[1] == "END" then
			declared = tonumber(fields[2])
		elseif fields[1] == "S" then
			table.insert(records, {
				session_id = fields[2] or "",
				pid = tonumber(fields[3]),
				proc_start = fields[4] or "",
				-- Anything but an explicit 0 counts as running.
				running = fields[5] ~= "0",
				start_time = fields[6] or "?",
				cwd = fields[7] or "",
			})
		end
	end
	if declared == nil or declared ~= #records then
		return nil, "incomplete answer from the process query"
	end
	return records
end

-- A decimal string as an integer, or nil when it is not one (or overflows).
local function to_integer(s)
	if type(s) ~= "string" or not s:match("^%d+$") then
		return nil
	end
	return math.tointeger(tonumber(s))
end

-- "dead": no such process, or the pid now belongs to a process that started
--         at another time (pid reuse).
-- "live": the process is running and started when the control file says.
-- "unknown": the process is running but the start times cannot be compared.
local function classify(record)
	if not record.running then
		return "dead"
	end
	local expected = to_integer(record.proc_start)
	local actual = to_integer(record.start_time)
	if not record.pid or not expected or not actual then
		return "unknown"
	end
	if math.abs(expected - actual) <= pub.start_time_tolerance then
		return "live"
	end
	return "dead"
end

local STATE_RANK = { dead = 1, unknown = 2, live = 3 }

-- Same validation process_handlers applies before a session id reaches a
-- shell command.
local function is_session_id(s)
	return type(s) == "string" and s:match("^[%x%-]+$") ~= nil
end

-- Compare working directories the way Windows does: slash direction, case and
-- a trailing separator do not matter. WezTerm reports /C:/..., Claude C:\...
local function normalize_cwd(cwd)
	if type(cwd) ~= "string" or cwd == "" then
		return nil
	end
	local n = cwd:gsub("\\", "/"):gsub("^/(%a:)", "%1"):gsub("/+$", "")
	return n:lower()
end

--- Turn records into a snapshot: sessions[<id>] = { state, pid }, the records
--- with their state, and .error when nothing in it may be trusted.
---@param records table[]
---@return table snapshot
local function build_snapshot(records)
	local snapshot = { sessions = {}, records = records }
	for _, record in ipairs(records) do
		record.state = classify(record)
		if not is_session_id(record.session_id) then
			-- A control file we could not read. If its process is gone it
			-- cannot matter; if it is running, some session is live and we do
			-- not know which, so no answer from this snapshot is safe.
			if record.state ~= "dead" then
				snapshot.error = "the control file of running process "
					.. tostring(record.pid or "?") .. " could not be read"
			end
		else
			local id = record.session_id:lower()
			local known = snapshot.sessions[id]
			if not known or STATE_RANK[record.state] > STATE_RANK[known.state] then
				snapshot.sessions[id] = { state = record.state, pid = record.pid }
			end
		end
	end
	return snapshot
end

local cached_snapshot = nil
local cached_at = nil

--- The current reading of which sessions are running. Reused for
--- snapshot_ttl_seconds; pass force to read again.
---@param force boolean?
---@return table snapshot { sessions, records, error? }
function pub.get_snapshot(force)
	if not force and cached_snapshot and os.time() - cached_at < pub.snapshot_ttl_seconds then
		return cached_snapshot
	end
	local records
	local stdout, err = pub.run_query(pub.control_dirs())
	if stdout then
		records, err = parse_query_output(stdout)
	end
	if records then
		cached_snapshot = build_snapshot(records)
	else
		cached_snapshot = { sessions = {}, records = {}, error = err or "unknown error" }
	end
	cached_at = os.time()
	return cached_snapshot
end

-- ---------------------------------------------------------------------------
-- What a restore command would resume
-- ---------------------------------------------------------------------------

-- Words of a shell command, with quotes dropped.
local function command_words(cmd)
	local words = {}
	for word in cmd:gmatch("[^%s;&|]+") do
		table.insert(words, (word:gsub("[\"']", "")))
	end
	return words
end

--- What Claude session a command would resume.
--- Returns nil when it resumes nothing (not a claude command, or a claude
--- command that starts a fresh session), otherwise one of
---   { session_id = <id> }  claude --resume / -r / --session-id <id>
---   { continue = true }    claude --continue / -c (latest session in the cwd)
---   { unreadable = true }  a resume flag whose session id cannot be read
---@param cmd string|nil
---@return table|nil target
function pub.resume_target(cmd)
	if type(cmd) ~= "string" then
		return nil
	end
	local words = command_words(cmd)
	local is_claude = false
	for _, word in ipairs(words) do
		local base = (word:match("([^/\\]+)$") or word):lower():gsub("%.exe$", ""):gsub("%.cmd$", ""):gsub("%.bat$", "")
		if base:match("^claude[%w%-]*$") then
			is_claude = true
		end
	end
	if not is_claude then
		return nil
	end
	local target = nil
	for i, word in ipairs(words) do
		local flag, inline = word:match("^(%-%-[%w%-]+)=(.*)$")
		flag = flag or word
		if flag == "--resume" or flag == "-r" or flag == "--session-id" then
			local id = inline or words[i + 1]
			if is_session_id(id) then
				return { session_id = id:lower() }
			end
			target = { unreadable = true }
		elseif flag == "--continue" or flag == "-c" then
			target = target or { continue = true }
		end
	end
	return target
end

--- Whether the session a command would resume is running, per a snapshot.
---@param target table from resume_target
---@param cwd string|nil the pane's working directory (needed for --continue)
---@param snapshot table from get_snapshot
---@return string state "dead" (safe to resume), "live" or "unknown"
---@return string|nil reason why it is not "dead"
---@return number|nil pid
function pub.inspect(target, cwd, snapshot)
	if snapshot.error then
		return "unknown", "liveness unreadable (" .. snapshot.error .. ")"
	end
	if target.session_id then
		local session = snapshot.sessions[target.session_id]
		if not session or session.state == "dead" then
			return "dead"
		end
		if session.state == "live" then
			return "live", "already running pid " .. tostring(session.pid), session.pid
		end
		return "unknown", "liveness unreadable (pid " .. tostring(session.pid)
			.. " is running but its start time could not be confirmed)", session.pid
	end
	if target.continue then
		-- --continue picks the newest session of the directory, so it is only
		-- safe when no running session belongs to that directory.
		local wanted = normalize_cwd(cwd)
		if not wanted then
			return "unknown", "liveness unreadable (--continue without a working directory)"
		end
		for _, record in ipairs(snapshot.records) do
			if record.state ~= "dead" and normalize_cwd(record.cwd) == wanted then
				return "live", "a session is already running in this directory, pid "
					.. tostring(record.pid), record.pid
			end
		end
		return "dead"
	end
	return "unknown", "liveness unreadable (no session id in the resume command)"
end

-- Sessions this plugin has just sent a resume command for: key -> os.time().
local claims = {}

local function claim_key(target, cwd)
	if target.session_id then
		return target.session_id
	end
	if target.continue then
		return "continue:" .. tostring(normalize_cwd(cwd))
	end
	return nil
end

--- Decide whether a restore command may be sent, and reserve its session so
--- that a second pane asking for the same one is refused.
---@param cmd string the command about to be typed into a pane
---@param cwd string|nil the pane's working directory
---@return table verdict { allow, target?, state?, reason?, pid? }
function pub.check_command(cmd, cwd)
	local target = pub.resume_target(cmd)
	if not target then
		return { allow = true }
	end
	local state, reason, pid = pub.inspect(target, cwd, pub.get_snapshot())
	if state ~= "dead" then
		return { allow = false, target = target, state = state, reason = reason, pid = pid }
	end
	local key = claim_key(target, cwd)
	local claimed_at = key and claims[key]
	if claimed_at and os.time() - claimed_at < pub.claim_ttl_seconds then
		return {
			allow = false,
			target = target,
			state = "live",
			reason = "already resumed in another pane by this restore",
		}
	end
	if key then
		claims[key] = os.time()
	end
	return { allow = true, target = target, state = "dead" }
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

local function new_tally()
	return { resumed = 0, skipped_live = 0, skipped_unknown = 0 }
end

local tally = new_tally()
local report_generation = 0

-- Best effort: a toast on the first window. Never allowed to fail a restore.
local function toast(message)
	pcall(function()
		local windows = wezterm.gui.gui_windows()
		if windows[1] then
			windows[1]:toast_notification("resurrect", message, nil, 10000)
		end
	end)
end

--- Log a line and show it as a toast.
---@param message string
function pub.notify(message)
	wezterm.log_warn("resurrect: " .. message)
	toast(message)
end

-- First 8 characters of a session id: enough to recognise, short in a log.
local function short_id(target)
	if target and target.session_id then
		return target.session_id:sub(1, 8)
	end
	if target and target.continue then
		return "(--continue)"
	end
	return "(unknown)"
end

--- Record that a resume command was sent.
function pub.note_resumed()
	tally.resumed = tally.resumed + 1
end

--- Record, and log, that a pane was left as a plain shell.
---@param verdict table from check_command
---@param pane_id number|string the pane the command would have gone to
function pub.note_skipped(verdict, pane_id)
	if verdict.state == "live" then
		tally.skipped_live = tally.skipped_live + 1
	else
		tally.skipped_unknown = tally.skipped_unknown + 1
	end
	wezterm.log_warn("resurrect: not resuming session " .. short_id(verdict.target)
		.. " in pane " .. tostring(pane_id) .. ": " .. tostring(verdict.reason))
end

local function plural(n, one, many)
	return tostring(n) .. " " .. (n == 1 and one or many)
end

-- Say what the restore did, then start counting afresh.
local function report()
	local done = tally
	tally = new_tally()
	if done.resumed + done.skipped_live + done.skipped_unknown == 0 then
		return
	end
	local message = "restore finished: " .. plural(done.resumed, "session", "sessions") .. " resumed, "
		.. plural(done.skipped_live, "pane", "panes") .. " left alone because the session is already running"
	if done.skipped_unknown > 0 then
		message = message .. ", " .. plural(done.skipped_unknown, "pane", "panes")
			.. " left alone because it could not be told whether the session is running"
	end
	wezterm.log_info("resurrect: " .. message)
	wezterm.emit("resurrect.restore_guard.report", done)
	toast(message)
end

--- Ask for the report once things have been quiet for delay_seconds. Every
--- pane decision calls this; only the last one's timer reports.
---@param delay_seconds number
function pub.schedule_report(delay_seconds)
	report_generation = report_generation + 1
	local mine = report_generation
	wezterm.time.call_after(delay_seconds, function()
		if mine == report_generation then
			report()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Looking at a saved state before restoring it
-- ---------------------------------------------------------------------------

--- Count what restoring a saved state would resume, without claiming
--- anything. Accepts a workspace, window or tab state.
---@param state table
---@param get_command fun(pane_tree: table): string|nil builds a pane's restore command
---@return table summary { panes, sessions, live, unknown, error? }
function pub.summarize(state, get_command)
	local snapshot = pub.get_snapshot()
	local summary = { panes = 0, sessions = 0, live = 0, unknown = 0, error = snapshot.error }

	local function walk(node, depth)
		if type(node) ~= "table" or depth > 100 then
			return
		end
		summary.panes = summary.panes + 1
		local target = pub.resume_target(get_command(node))
		if target then
			summary.sessions = summary.sessions + 1
			local cwd = (type(node.process) == "table" and node.process.cwd) or node.cwd
			local pane_state = pub.inspect(target, cwd, snapshot)
			if pane_state == "live" then
				summary.live = summary.live + 1
			elseif pane_state == "unknown" then
				summary.unknown = summary.unknown + 1
			end
		end
		walk(node.right, depth + 1)
		walk(node.bottom, depth + 1)
	end

	local function walk_tabs(tabs)
		for _, tab in ipairs(type(tabs) == "table" and tabs or {}) do
			walk(tab.pane_tree, 0)
		end
	end

	if type(state) ~= "table" then
		return summary
	end
	if type(state.window_states) == "table" then
		for _, window_state in ipairs(state.window_states) do
			walk_tabs(window_state.tabs)
		end
	elseif state.tabs then
		walk_tabs(state.tabs)
	elseif state.pane_tree then
		walk(state.pane_tree, 0)
	end
	return summary
end

--- Why a saved state must not be restored at all, or nil when it may be.
--- A state that would resume nothing is always restorable. Otherwise:
---   * if what is running cannot be established, it is refused -- unknown is
---     not permission, and restoring it as bare shells would only retire the
---     saved copy without bringing anything back;
---   * if every session in it is running, it is a stale copy of running
---     windows and there is nothing in it to bring back.
---@param summary table from summarize
---@return string|nil reason
function pub.refusal(summary)
	if summary.sessions == 0 then
		return nil
	end
	if summary.error or summary.unknown > 0 then
		return "cannot tell what is running, cannot restore"
	end
	if summary.live == summary.sessions then
		local which = summary.sessions == 1 and "its session is" or ("all " .. summary.sessions .. " sessions")
		return which .. " already running, cannot restore"
	end
	return nil
end

--- For a restorable state: how many of its sessions are already running (and
--- so will be left alone), or nil when none are.
---@param summary table from summarize
---@return string|nil note
function pub.running_note(summary)
	if summary.live > 0 then
		return summary.live .. " of " .. summary.sessions .. " sessions already running"
	end
	return nil
end

-- Expose internals for unit testing only
pub._test = {
	parse_query_output = parse_query_output,
	build_snapshot = build_snapshot,
	normalize_cwd = normalize_cwd,
	reset = function()
		cached_snapshot = nil
		cached_at = nil
		claims = {}
		tally = new_tally()
		report_generation = 0
	end,
}

return pub
