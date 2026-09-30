local wezterm = require("wezterm") --[[@as Wezterm]]
local utils = require("resurrect.utils")
local file_io = require("resurrect.file_io")
local pub = {}

-- Session identity index for saved state files.
--
-- The plugin names a window/tab save after the window title, and titles are
-- not stable: Claude Code prefixes a spinner glyph that ticks between frames
-- and renames a session as its topic evolves. One conversation therefore
-- accumulates many save files under different names (measured on a real
-- install: 947 saves that were only 331 distinct conversations, with a single
-- conversation spread across 22 files). Grouping by the Claude session UUIDs
-- embedded in the save is the only identity that survives both renames and
-- glyph churn.
--
-- Reading every save to extract those UUIDs costs roughly 13ms per file, so
-- this module keeps a cache keyed by file name plus mtime. The first build
-- reads everything; later browses only read saves whose mtime moved, which is
-- normally none or one.

local INDEX_VERSION = 1
local INDEX_FILE = ".save_index.json"

---@param base_path string state dir, with or without a trailing separator
---@return string
local function index_path(base_path)
	local trimmed = base_path:gsub("[/\\]+$", "")
	return trimmed .. utils.separator .. INDEX_FILE
end

-- Platform-neutral key so an index stays valid if the separator ever differs.
---@param save_type string
---@param filename string
---@return string
local function entry_key(save_type, filename)
	return save_type .. "/" .. filename
end

---@param base_path string
---@param save_type string
---@param filename string
---@return string
local function file_path(base_path, save_type, filename)
	local trimmed = base_path:gsub("[/\\]+$", "")
	return trimmed .. utils.separator .. save_type .. utils.separator .. filename
end

-- Build the command that reads each listed save and prints
-- "<path>|<comma separated sorted unique uuids>" per line.
--
-- Paths are passed via a file rather than on the command line: a full rebuild
-- can involve hundreds of paths whose combined length would exceed the
-- Windows command line limit. Output is batched and forced to UTF-8 for the
-- same reasons as the enumeration itself.
---@param list_file string path to a UTF-8 file containing one save path per line
---@param is_windows boolean
---@return string[] argv
local function build_extract_command(list_file, is_windows)
	if is_windows then
		local ps_cmd = string.format(
			"[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
				.. "$sb = New-Object System.Text.StringBuilder; "
				.. "foreach ($p in [System.IO.File]::ReadAllLines('%s', [System.Text.Encoding]::UTF8)) { "
				.. "if ($p -and [System.IO.File]::Exists($p)) { "
				.. "$c = [System.IO.File]::ReadAllText($p); "
				.. "$ids = @(); "
				.. "foreach ($m in [regex]::Matches($c, '--resume\\W+([0-9a-fA-F-]{36})')) "
				.. "{ $ids += $m.Groups[1].Value }; "
				.. "[void]$sb.AppendLine($p + '|' + (($ids | Sort-Object -Unique) -join ',')) } }; "
				.. "[Console]::Out.Write($sb.ToString())",
			list_file:gsub("'", "''")
		)
		return { "powershell.exe", "-NoProfile", "-NoLogo", "-Command", ps_cmd }
	end
	local safe = list_file:gsub("'", "'\\''")
	-- grep -o emits one uuid per line; paste them back onto one line per file.
	local sh_cmd = string.format(
		"while IFS= read -r p; do "
			.. '[ -f "$p" ] || continue; '
			.. "ids=$(grep -oE -- '--resume[^0-9a-fA-F]+[0-9a-fA-F-]{36}' \"$p\" "
			.. "| grep -oE '[0-9a-fA-F-]{36}' | sort -u | tr '\\n' ',');"
			.. 'printf "%%s|%%s\\n" "$p" "$ids"; '
			.. "done < '%s'",
		safe
	)
	return { "sh", "-c", sh_cmd }
end

-- Parse extractor output into { [path] = key }.
---@param stdout string|nil
---@return table<string, string>
local function parse_extract_output(stdout)
	local keys = {}
	if not stdout then
		return keys
	end
	for line in stdout:gmatch("[^\r\n]+") do
		local path, key = line:match("^(.-)|(.*)$")
		if path and path ~= "" then
			keys[path] = (key or ""):gsub(",+$", "")
		end
	end
	return keys
end

-- Entries whose cached key is missing or stale (mtime moved).
---@param entries {epoch: number, type: string, filename: string}[]
---@param index table
---@return {epoch: number, type: string, filename: string}[]
local function find_stale(entries, index)
	local stale = {}
	local cached = index.entries or {}
	for _, entry in ipairs(entries) do
		local hit = cached[entry_key(entry.type, entry.filename)]
		if not hit or hit.epoch ~= entry.epoch then
			table.insert(stale, entry)
		end
	end
	return stale
end

-- Collapse entries to one per conversation, newest first.
--
-- Saves that share a session-uuid set are the same conversation recorded under
-- different titles; only the newest is kept because restoring any of them runs
-- the same claude --resume, and the newest has the most accurate layout. Saves
-- with no session id (plain shells) have no identity to group on, so they are
-- all kept. Grouping includes the save type so a window save and a tab save of
-- the same conversation stay separately restorable.
---@param entries {epoch: number, type: string, filename: string, key: string?}[]
---@return {epoch: number, type: string, filename: string, key: string?}[]
function pub.dedupe(entries)
	local newest_by_group = {}
	local order = {}
	local kept = {}

	for _, entry in ipairs(entries) do
		if entry.key == nil or entry.key == "" then
			table.insert(kept, entry)
		else
			local group = entry.type .. "\1" .. entry.key
			local current = newest_by_group[group]
			if not current then
				newest_by_group[group] = entry
				table.insert(order, group)
			elseif entry.epoch > current.epoch then
				newest_by_group[group] = entry
			end
		end
	end

	for _, group in ipairs(order) do
		table.insert(kept, newest_by_group[group])
	end

	table.sort(kept, function(a, b)
		if a.epoch ~= b.epoch then
			return a.epoch > b.epoch
		end
		-- Stable tiebreak so the menu order never jitters between opens
		return entry_key(a.type, a.filename) < entry_key(b.type, b.filename)
	end)

	return kept
end

---@param base_path string
---@return table index with an entries table
function pub.load_index(base_path)
	local ok, index = pcall(file_io.load_json, index_path(base_path))
	if ok and type(index) == "table" and index.version == INDEX_VERSION and type(index.entries) == "table" then
		return index
	end
	return { version = INDEX_VERSION, entries = {} }
end

---@param base_path string
---@param index table
function pub.write_index(base_path, index)
	local ok, err = pcall(function()
		file_io.write_file(index_path(base_path), wezterm.json_encode(index))
	end)
	if not ok then
		-- A missing cache only costs time on the next browse, never correctness
		wezterm.log_error("resurrect: could not write save index: " .. tostring(err))
	end
end

-- Read the given saves and return { [path] = key }. Returns an empty table if
-- the child process fails, which degrades to "no dedupe" rather than an error.
---@param stale {epoch: number, type: string, filename: string}[]
---@param base_path string
---@return table<string, string>
function pub.extract_keys(base_path, stale)
	if #stale == 0 then
		return {}
	end

	local tmp_dir = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local list_file = tmp_dir .. utils.separator .. "wzr-index-" .. tostring(os.time()) .. ".txt"

	local handle = io.open(list_file, "wb")
	if not handle then
		wezterm.emit("resurrect.error", "Could not write index work list to " .. list_file)
		return {}
	end
	for _, entry in ipairs(stale) do
		handle:write(file_path(base_path, entry.type, entry.filename), "\n")
	end
	handle:close()

	local success, stdout, stderr = wezterm.run_child_process(build_extract_command(list_file, utils.is_windows))
	os.remove(list_file)

	if not success then
		wezterm.emit("resurrect.error", stderr or "Failed to read saves for session index")
		return {}
	end
	return parse_extract_output(stdout)
end

-- Annotate entries with their session key, refreshing the cache as needed.
---@param base_path string
---@param entries {epoch: number, type: string, filename: string}[]
---@return {epoch: number, type: string, filename: string, key: string}[]
function pub.annotate(base_path, entries)
	local index = pub.load_index(base_path)
	index.entries = index.entries or {}

	local stale = find_stale(entries, index)
	if #stale > 0 then
		local extracted = pub.extract_keys(base_path, stale)
		for _, entry in ipairs(stale) do
			local key = extracted[file_path(base_path, entry.type, entry.filename)]
			if key ~= nil then
				index.entries[entry_key(entry.type, entry.filename)] = { epoch = entry.epoch, key = key }
			end
		end
	end

	-- Drop cache rows for saves that no longer exist so the index cannot grow
	-- without bound as saves are deleted.
	local live = {}
	for _, entry in ipairs(entries) do
		live[entry_key(entry.type, entry.filename)] = true
	end
	for key in pairs(index.entries) do
		if not live[key] then
			index.entries[key] = nil
		end
	end

	if #stale > 0 then
		pub.write_index(base_path, index)
	end

	local annotated = {}
	for _, entry in ipairs(entries) do
		local hit = index.entries[entry_key(entry.type, entry.filename)]
		table.insert(annotated, {
			epoch = entry.epoch,
			type = entry.type,
			filename = entry.filename,
			key = hit and hit.key or "",
		})
	end
	return annotated
end

-- Convenience: annotate then collapse to one entry per conversation.
---@param base_path string
---@param entries {epoch: number, type: string, filename: string}[]
---@return {epoch: number, type: string, filename: string, key: string}[]
function pub.annotate_and_dedupe(base_path, entries)
	return pub.dedupe(pub.annotate(base_path, entries))
end

-- Group annotated entries into { key = ..., keep = entry, remove = {entries} }
-- so a cleanup flow can report exactly what it would delete before doing it.
---@param entries {epoch: number, type: string, filename: string, key: string}[]
---@return {key: string, keep: table, remove: table[]}[]
function pub.plan_cleanup(entries)
	local groups = {}
	local order = {}

	for _, entry in ipairs(entries) do
		if entry.key ~= nil and entry.key ~= "" then
			local group = entry.type .. "\1" .. entry.key
			if not groups[group] then
				groups[group] = {}
				table.insert(order, group)
			end
			table.insert(groups[group], entry)
		end
	end

	local plan = {}
	for _, group in ipairs(order) do
		local members = groups[group]
		if #members > 1 then
			table.sort(members, function(a, b)
				if a.epoch ~= b.epoch then
					return a.epoch > b.epoch
				end
				return entry_key(a.type, a.filename) < entry_key(b.type, b.filename)
			end)
			local remove = {}
			for i = 2, #members do
				table.insert(remove, members[i])
			end
			table.insert(plan, { key = members[1].key, keep = members[1], remove = remove })
		end
	end
	return plan
end

pub._test = {
	index_path = index_path,
	entry_key = entry_key,
	file_path = file_path,
	build_extract_command = build_extract_command,
	parse_extract_output = parse_extract_output,
	find_stale = find_stale,
}

return pub
