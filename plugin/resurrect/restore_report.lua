-- restore_report.lua -- What one restore did to one saved copy
--
-- restore_guard.summarize says, before a restore, what each session of a saved
-- copy should come to; default_on_pane_restore leaves the guard's real answer
-- on each pane tree node (node.restore_verdict). This module turns the two
-- into one outcome per session, decides from those whether the copy has to be
-- kept, and writes the report a person reads afterwards.
--
-- Nothing here reads restore_guard's report tally: it is global to the process
-- and note_resumed adds to it from a timer, after the copy has been dealt with.
--
-- Reports live in ~/.wezurrect/restore-reports/<instance id>.txt, not under
-- state/: the state lister scans state/ recursively for *.json and expects a
-- saved state in each. Plain text, because a person opens it to recover.

local wezterm = require("wezterm") --[[@as Wezterm]]
local file_io = require("resurrect.file_io")
local utils = require("resurrect.utils")
local restore_guard = require("resurrect.restore_guard")

local pub = {}

-- A selector entry with this prefix and an instance id means "resume the rest".
pub.REST_PREFIX = "__RESUME_REST__"

-- Outcomes, in the order a person needs them.
local OUTCOMES = {
	{ key = "held_back", heading = "HELD BACK", row = "HELD", count = "Held back" },
	{ key = "failed", heading = "FAILED", row = "FAILED", count = "Failed" },
	{ key = "parked", heading = "PARKED", row = "PARKED", count = "Parked" },
	{ key = "running", heading = "ALREADY RUNNING", row = "RUNNING", count = "Already running" },
	{ key = "resumed", heading = "RESUMED", row = "RESUMED", count = "Resumed" },
}

-- State files are plain JSON anything could have written: no control characters
-- (escape sequences) from them reach the selector or the report.
local function clean(text)
	return (tostring(text or ""):gsub("%c", " "))
end

--- The file a saved copy's report is written to.
---@param instance_id string
---@return string
function pub.path(instance_id)
	return restore_guard.report_dir() .. utils.separator .. instance_id .. ".txt"
end

-- One session's outcome and why. The guard's real answer when it gave one. The
-- summary's prediction otherwise, which means the pane was never reached (the
-- restore threw) or a custom on_pane_restore took it.
local function outcome_of(entry, threw)
	if entry.error then
		return "failed", entry.error
	end
	local verdict = entry.node.restore_verdict
	if verdict and verdict.allow then
		if verdict.typed == "parked" then
			return "parked", "a no-restore marker appeared before the line was typed"
		elseif verdict.typed == "no_pane" then
			return "failed", "its pane was closed before the line was typed"
		end
		return "resumed"
	elseif verdict then
		if verdict.state == "parked" then
			return "parked", verdict.reason
		elseif verdict.kind == "live" then
			return "running", verdict.reason
		end
		return "held_back", verdict.reason
	end
	if entry.state == "dead" then
		if threw then
			return "failed", "the restore threw before reaching this pane"
		end
		return "resumed"
	elseif entry.state == "parked" then
		return "parked", entry.reason
	elseif entry.kind == "live" then
		return "running", entry.reason
	end
	return "held_back", entry.reason
end

-- Whether this restore, in this copy or another of the same run, resumed the session.
local function resumed_in_run(report, session_id)
	local function resumed_in(entries)
		for _, entry in ipairs(entries) do
			if entry.outcome == "resumed" and entry.target.session_id == session_id then
				return true
			end
		end
		return false
	end
	if resumed_in(report.entries) then
		return true
	end
	for _, other in ipairs(report.same_run or {}) do
		if other ~= report and resumed_in(other.entries) then
			return true
		end
	end
	return false
end

-- A claim says a pane was given this session, not that it still runs there. It
-- counts for nothing here unless this same restore typed the session elsewhere.
local function settle_claim(report, entry)
	local verdict = entry.node.restore_verdict
	if entry.kind ~= "claimed" and not (verdict and verdict.kind == "claimed") then
		return
	end
	if resumed_in_run(report, entry.target.session_id) then
		entry.outcome, entry.why = "running", "resumed in another pane by this restore"
	else
		entry.why = "a pane of this terminal holds its resume claim, and no control file confirms it is"
			.. " running - close that pane to retry, or resume it by hand"
	end
end

--- Work out every session's outcome again from what is known now. Called once
--- right after the restore and once after the delayed lines have been typed.
---@param report table
function pub.settle(report)
	report.counts = { held_back = 0, failed = 0, parked = 0, running = 0, resumed = 0 }
	for _, entry in ipairs(report.entries) do
		entry.outcome, entry.why = outcome_of(entry, #report.failures > 0)
	end
	for _, entry in ipairs(report.entries) do
		if entry.outcome == "held_back" then
			settle_claim(report, entry)
		end
		report.counts[entry.outcome] = report.counts[entry.outcome] + 1
	end
end

--- A report on one saved copy.
---@param instance_id string
---@param name string what the person calls the copy
---@param run string "restore" or "resume the rest"
---@param entries table[] from restore_guard.summarize
---@param failures table[] { window?, error }: what threw
---@param other_panes number panes with no session in them
---@param same_run table[]|nil the reports of other copies restored in this run
---@return table report
function pub.new(instance_id, name, run, entries, failures, other_panes, same_run)
	local report = {
		instance_id = instance_id, name = name, run = run, entries = entries, failures = failures,
		other_panes = other_panes, at = os.date("%Y-%m-%d %H:%M:%S"), same_run = same_run,
	}
	pub.settle(report)
	return report
end

--- True when the saved copy has to stay: a session of it was held back or
--- failed, or its restore threw. Parked sessions were held back on purpose. A
--- session its control file confirms running is safe where it runs, and every
--- session a restore resumes is one: counting them, a copy could never retire by
--- being restored. Weaker signs of running (a command line, a claim) are held
--- back: retiring the copy over a false one would leave no way back.
---@param report table
---@return boolean
function pub.keeps_copy(report)
	return report.counts.held_back > 0 or report.counts.failed > 0 or #report.failures > 0
end

--- The sessions "resume the rest" is for, each once.
---@param report table
---@return string[]
function pub.held_ids(report)
	local ids, seen = {}, {}
	for _, entry in ipairs(report.entries) do
		local id = entry.target.session_id
		if id and not seen[id] and (entry.outcome == "held_back" or entry.outcome == "failed") then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	return ids
end

local function counts_line(report)
	local parts = {}
	for i = #OUTCOMES, 1, -1 do
		table.insert(parts, OUTCOMES[i].count .. ": " .. report.counts[OUTCOMES[i].key])
	end
	return table.concat(parts, "   ")
end

local function pane_id_of(entry)
	local ok, id = pcall(function()
		return entry.node.pane:pane_id()
	end)
	return ok and id or nil
end

--- One run's report as text.
---@param report table
---@return string
function pub.format(report)
	local lines = {
		"Wezurrect restore report",
		"Run:        " .. report.at .. " (" .. report.run .. ")",
		"Saved copy: " .. report.instance_id .. " (" .. clean(report.name) .. ")",
	}
	if report.kept then
		table.insert(lines, "Its state:  KEPT - still listed by Alt+R, with 'Resume the rest' if a session can be retried")
	elseif report.retired then
		table.insert(lines, "Its state:  retired to state/instances/restored; nothing in it is waiting")
	else
		table.insert(lines, "Its state:  retired once its lines have been typed. If this line stays, a config reload"
			.. " or exit interrupted that: the copy is still listed by Alt+R")
	end
	table.insert(lines, counts_line(report))
	if report.other_panes and report.other_panes > 0 then
		table.insert(lines, "Panes with no session in them: " .. report.other_panes)
	end
	for _, failure in ipairs(report.failures) do
		table.insert(lines, "Threw" .. (failure.window and (" in window " .. failure.window) or "") .. ": "
			.. clean(failure.error))
	end
	for _, outcome in ipairs(OUTCOMES) do
		if report.counts[outcome.key] > 0 then
			table.insert(lines, "")
			table.insert(lines, outcome.heading .. " (" .. report.counts[outcome.key] .. ")")
			for _, entry in ipairs(report.entries) do
				if entry.outcome == outcome.key then
					local pane_id = pane_id_of(entry)
					table.insert(lines, "  " .. tostring(entry.target.session_id or "(unreadable command)"))
					table.insert(lines, "    folder: " .. clean(entry.cwd)
						.. (pane_id and ("   pane: " .. tostring(pane_id)) or ""))
					if entry.why then
						table.insert(lines, "    why: " .. clean(entry.why))
					end
					if (outcome.key == "held_back" or outcome.key == "failed") and entry.target.line then
						table.insert(lines, "    by hand, once you know it is not running:")
						table.insert(lines, '      cd "' .. clean(entry.cwd) .. '"')
						table.insert(lines, "      " .. entry.target.line)
					end
				end
			end
		end
	end
	table.insert(lines, "")
	table.insert(lines, string.rep("-", 72))
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

--- Write the report, newest run first. Safe to call again for the same run. A
--- report that cannot be written is logged: it never changes what happens to
--- the saved copy.
---@param report table
function pub.write(report)
	local ok, err = pcall(function()
		if not utils.ensure_folder_exists(restore_guard.report_dir()) then
			error("cannot create " .. restore_guard.report_dir())
		end
		local path = pub.path(report.instance_id)
		if report.earlier_runs == nil then
			local read_ok, text = file_io.read_file(path)
			report.earlier_runs = read_ok and text or ""
		end
		local wrote, why = file_io.write_file(path, pub.format(report) .. report.earlier_runs)
		if not wrote then
			error(why)
		end
		report.path = path
	end)
	if not ok then
		report.path = nil
		wezterm.log_warn("resurrect: could not write the restore report: " .. tostring(err))
	end
end

--- True when a person has to see this: something was held back or failed.
---@param reports table[]
---@return boolean
function pub.needs_attention(reports)
	for _, report in ipairs(reports) do
		if pub.keeps_copy(report) then
			return true
		end
	end
	return false
end

--- A selector entry's label for "resume the rest".
---@param name string
---@param count number
---@return string
function pub.rest_label(name, count)
	return "[Resume the rest of " .. clean(name) .. ": " .. count
		.. " held back or failed; the guard still decides, in new panes]"
end

--- The outcome selector. It appears about 4 seconds after a restore, maybe under
--- someone still typing, and with fuzzy on, typed text and Enter pick the best
--- match (wezterm's selector.rs sorts by score). So every row here only closes it:
--- what starts anything is the "resume the rest" entry in Alt+R, opened on purpose.
---@param reports table[]
---@return table spec { title, description, choices }
function pub.outcome_selector(reports)
	local choices = { { id = "__CLOSE__", label = "[Close - kept copies stay in Alt+R]" } }
	local paths = {}
	local totals = { held_back = 0, failed = 0 }
	for _, report in ipairs(reports) do
		totals.held_back = totals.held_back + report.counts.held_back
		totals.failed = totals.failed + report.counts.failed
		table.insert(paths, report.path or "(not written, see the log)")
	end
	for r, report in ipairs(reports) do
		table.insert(choices, { id = "__INFO_" .. r, label = clean(report.name) .. ": " .. counts_line(report) })
		for _, failure in ipairs(report.failures) do
			table.insert(choices, { id = "__INFO_" .. r .. "_F", label = "THREW  " .. clean(failure.error) })
		end
		for _, outcome in ipairs(OUTCOMES) do
			for e, entry in ipairs(report.entries) do
				if entry.outcome == outcome.key then
					table.insert(choices, {
						id = "__INFO_" .. r .. "_" .. e,
						label = outcome.row .. "  " .. tostring(entry.target.session_id or "(unreadable command)")
							.. "  " .. clean(entry.cwd) .. (entry.why and ("  - " .. clean(entry.why)) or ""),
					})
				end
			end
		end
	end
	return {
		title = "Restore finished: " .. totals.held_back .. " held back, " .. totals.failed .. " failed",
		description = "Enter or Esc closes this; typing only filters. To retry: Alt+R, Resume the rest. Report: "
			.. table.concat(paths, " ; "),
		fuzzy_description = "Filter (nothing here starts anything): ",
		choices = choices,
	}
end

return pub
