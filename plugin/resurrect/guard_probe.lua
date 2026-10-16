-- guard_probe.lua -- Prove the restore guard is loaded, and show what a
-- restore WOULD do, without restoring anything.
--
-- Two things, both read-only towards panes and windows:
--
--   announce()  run once per config evaluation: logs which guard version and
--               plugin commit were loaded.
--   dry_run()   for one saved copy (the newest by default), lists every
--               Claude session in it and whether a restore would resume it
--               or refuse it, and why. It types nothing, opens nothing,
--               claims nothing and tombstones nothing. The report goes to the
--               log and to ~/.wezurrect/guard-probe-report.txt.
--
-- Trigger without a keypress: a program in any WezTerm pane sets the user
-- var "resurrect_guard_probe" (OSC 1337 SetUserVar) to "<target>|<nonce>",
-- where target is "newest" or a saved instance id and nonce is 1-32 letters
-- or digits that the report repeats. tools/guard-probe.ps1 does exactly that.

local wezterm = require("wezterm") --[[@as Wezterm]]
local utils = require("resurrect.utils")
local file_io = require("resurrect.file_io")
local restore_guard = require("resurrect.restore_guard")

local pub = {}

-- Bump with every change to what a restore refuses.
pub.GUARD_VERSION = "2026-10-16.4 (claims per pane + cross-process claim files, no-restore markers)"

pub.USER_VAR = "resurrect_guard_probe"

-- The plugin's folder; set by init.lua. Used only to read the commit.
pub.plugin_dir = nil

-- When this Lua state evaluated the config (one per config load or reload).
pub.loaded_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

-- Probes closer together than this are ignored: any pane can set the var.
pub.min_interval_seconds = 5
local last_probe_at = nil

--- The report file, ~/.wezurrect/guard-probe-report.txt.
---@return string
function pub.report_path()
	local sep = utils.separator
	local home = utils.is_windows and (os.getenv("USERPROFILE") or os.getenv("HOME") or "") or (os.getenv("HOME") or "")
	return home .. sep .. ".wezurrect" .. sep .. "guard-probe-report.txt"
end

-- The commit the plugin folder is checked out at, or "unknown".
local function read_text(path)
	local ok, text = file_io.read_file(path)
	if ok and type(text) == "string" then
		return text
	end
	return nil
end

function pub.commit()
	if not pub.plugin_dir then
		return "unknown"
	end
	local sep = utils.separator
	local git = pub.plugin_dir .. sep .. ".git"
	local head = read_text(git .. sep .. "HEAD")
	if not head then
		return "unknown"
	end
	head = head:match("^%s*(.-)%s*$")
	if head:match("^%x+$") and #head >= 40 then
		return head
	end
	local ref = head:match("^ref:%s*(refs/[%w%._/%-]+)$")
	if not ref or ref:find("..", 1, true) then
		return "unknown"
	end
	local loose = read_text(git .. sep .. ref:gsub("/", sep))
	if loose and loose:match("^%s*(%x+)") then
		return loose:match("^%s*(%x+)") .. " (" .. ref .. ")"
	end
	local packed = read_text(git .. sep .. "packed-refs") or ""
	for line in packed:gmatch("[^\r\n]+") do
		local sha, name = line:match("^(%x+) (%S+)$")
		if name == ref then
			return sha .. " (" .. ref .. ")"
		end
	end
	return "unknown (" .. ref .. ")"
end

--- Log, once per config evaluation, that the guard is loaded.
function pub.announce()
	wezterm.log_info("resurrect: restore guard " .. pub.GUARD_VERSION .. " loaded from plugin commit "
		.. pub.commit() .. " at " .. pub.loaded_at)
end

local WORDS = {
	live = "running",
	parked = "parked",
	unknown = "uncertain",
}

--- What a restore of this saved state would do with each Claude session.
--- Pure: reads the snapshot, claims nothing.
---@param state table a workspace state
---@param get_command fun(pane_tree: table): string|nil, boolean|nil
---@param snapshot table from restore_guard.get_snapshot
---@return table[] entries { session_id, cwd, resume (bool), why, detail }
function pub.verdicts(state, get_command, snapshot)
	local entries = {}
	local seen = {}
	local function walk(node, depth)
		if type(node) ~= "table" or depth > 100 then
			return
		end
		local command, rejected = get_command(node)
		local target = restore_guard.resume_target(command)
		if rejected then
			target = { unreadable = true }
		end
		if target then
			local cwd = (type(node.process) == "table" and node.process.cwd) or node.cwd
			local entry = { session_id = target.session_id or "(unreadable command)", cwd = tostring(cwd or "") }
			local pane_state, reason = restore_guard.inspect(target, cwd, snapshot)
			if pane_state ~= "dead" then
				entry.why, entry.detail = WORDS[pane_state] or pane_state, reason
			elseif seen[target.session_id] then
				entry.why, entry.detail = "duplicate", "the same session appears earlier in this saved copy"
			elseif restore_guard.foreign_claim(target.session_id) then
				entry.why, entry.detail = "already resumed", restore_guard.foreign_claim(target.session_id)
			elseif restore_guard.is_claimed(target.session_id) then
				entry.why, entry.detail = "already resumed", "this WezTerm resumed it within "
					.. restore_guard.claim_ttl_seconds .. " seconds, or its pane is still open"
			else
				entry.resume = true
			end
			if target.session_id then
				seen[target.session_id] = true
			end
			table.insert(entries, entry)
		end
		walk(node.right, depth + 1)
		walk(node.bottom, depth + 1)
	end
	for _, window_state in ipairs(type(state) == "table" and type(state.window_states) == "table"
		and state.window_states or {}) do
		for _, tab in ipairs(type(window_state.tabs) == "table" and window_state.tabs or {}) do
			walk(tab.pane_tree, 0)
		end
	end
	return entries
end

-- Only printable ASCII reaches the report.
local function clean(s)
	return (tostring(s):gsub("[^ -~]", "?"))
end

--- Dry-run a restore of one saved instance and write the report.
---@param target string "newest" or a saved instance id
---@param nonce string|nil repeated in the report
---@return string report
function pub.dry_run(target, nonce)
	local instance_manager = require("resurrect.instance_manager")
	local tab_state = require("resurrect.tab_state")
	local lines = {
		"Wezurrect guard probe - DRY RUN: nothing typed, nothing opened, nothing claimed",
		"nonce: " .. clean(nonce or ""),
		"guard version: " .. pub.GUARD_VERSION,
		"plugin commit: " .. clean(pub.commit()),
		"config loaded at: " .. pub.loaded_at,
		"probe at: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	local id = target
	if target == "newest" then
		local newest = instance_manager.list_instances()[1]
		id = newest and newest.instance_id or nil
	end
	local state = id and instance_manager.load_instance(id) or nil
	if not state then
		table.insert(lines, "saved copy: none found (" .. clean(target) .. ")")
	else
		local snapshot = restore_guard.get_snapshot(true)
		local get_command = function(pane_tree)
			return tab_state.get_pane_restore_command(pane_tree, true)
		end
		local own = instance_manager.is_own_instance(id) and " - this terminal's own live copy" or ""
		table.insert(lines, "saved copy: " .. id .. own)
		local _, detail = restore_guard.refusal(restore_guard.summarize(state, get_command))
		if own ~= "" then
			detail = "it is this terminal's own live copy"
		end
		table.insert(lines, "whole copy: " .. (detail and ("a real restore would refuse it entirely: " .. clean(detail))
			or "a real restore would open it"))
		if snapshot.error then
			table.insert(lines, "liveness: UNREADABLE (" .. clean(snapshot.error) .. ")")
		end
		local entries = pub.verdicts(state, get_command, snapshot)
		local counts = { resume = 0 }
		for _, entry in ipairs(entries) do
			if entry.resume then
				counts.resume = counts.resume + 1
			else
				counts[entry.why] = (counts[entry.why] or 0) + 1
			end
		end
		local summary = { #entries .. " sessions", counts.resume .. " would resume" }
		for _, why in ipairs({ "running", "parked", "duplicate", "already resumed", "uncertain" }) do
			if counts[why] then
				table.insert(summary, counts[why] .. " refused (" .. why .. ")")
			end
		end
		table.insert(lines, "sessions: " .. table.concat(summary, ", "))
		for _, entry in ipairs(entries) do
			if entry.resume then
				table.insert(lines, "RESUME  " .. entry.session_id .. "  in " .. clean(entry.cwd))
			else
				table.insert(lines, "REFUSE  " .. entry.session_id .. "  " .. entry.why .. ": " .. clean(entry.detail))
			end
		end
	end
	table.insert(lines, "END")
	local report = table.concat(lines, "\n") .. "\n"
	for _, line in ipairs(lines) do
		wezterm.log_info("resurrect: guard probe: " .. line)
	end
	local path = pub.report_path()
	local dir = path:match("^(.*)[/\\][^/\\]+$")
	if dir then
		utils.ensure_folder_exists(dir)
	end
	local ok, err = file_io.write_file(path, report)
	if not ok then
		wezterm.log_warn("resurrect: guard probe could not write " .. path .. ": " .. tostring(err))
	end
	return report
end

--- The user-var-changed handler. Returns nothing, so other handlers still run.
---@param name string
---@param value string
function pub.on_user_var(name, value)
	if name ~= pub.USER_VAR then
		return
	end
	local target, nonce = tostring(value):match("^([%w_]+)|(%w+)$")
	if not target or #nonce > 32 or (target ~= "newest" and not target:match("^%d+_%d+$")) then
		wezterm.log_warn("resurrect: guard probe ignored a malformed request")
		return
	end
	if last_probe_at and os.time() - last_probe_at < pub.min_interval_seconds then
		wezterm.log_warn("resurrect: guard probe ignored: the last one was under "
			.. pub.min_interval_seconds .. " seconds ago")
		return
	end
	last_probe_at = os.time()
	local ok, err = pcall(pub.dry_run, target, nonce)
	if not ok then
		wezterm.log_error("resurrect: guard probe failed: " .. tostring(err))
	end
end

pub._test = {
	reset = function()
		last_probe_at = nil
	end,
}

return pub
