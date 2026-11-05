-- Headless end-to-end harness for fuzzy_loader against the REAL state store.
-- Unlike the busted specs, run_child_process here actually spawns the process,
-- so this exercises the PowerShell command text itself -- the layer the specs
-- stub out and therefore cannot protect.

local STATE_DIR = [[C:\Users\Yedidya\AppData\Roaming\wezterm\plugins\httpssCssZssZsgithubsDscomsZsYedPoolsZsWezurrect\state\]]

package.path = table.concat({
	"./plugin/?.lua",
	"./plugin/?/init.lua",
	"./plugin/?/?.lua",
	package.path,
}, ";")

local errors = {}

-- Minimal wezterm stub, with a REAL run_child_process.
package.loaded["wezterm"] = {
	target_triple = "x86_64-pc-windows-msvc",
	nerdfonts = setmetatable({}, {
		__index = function()
			return "*"
		end,
	}),
	format = function(items)
		local out = {}
		for _, item in ipairs(items) do
			if item.Text then
				table.insert(out, item.Text)
			end
		end
		return table.concat(out)
	end,
	emit = function(event, ...)
		if event == "resurrect.error" then
			table.insert(errors, tostring((...)))
		end
	end,
	log_info = function() end,
	log_error = function() end,
	action = { InputSelector = function(a) return a end },
	action_callback = function(f) return f end,

	-- The real thing: spawn the process and capture stdout.
	run_child_process = function(argv)
		local parts = {}
		for i, a in ipairs(argv) do
			-- argv[1] is the executable; the rest are arguments.
			if i == 1 then
				parts[i] = '"' .. a .. '"'
			else
				parts[i] = '"' .. a:gsub('"', '\\"') .. '"'
			end
		end
		-- cmd.exe strips the outer quote pair, so a command whose executable AND
		-- arguments are both quoted needs one extra wrapping pair.
		local cmd = '"' .. table.concat(parts, " ") .. '"'
		local pipe = io.popen(cmd, "r")
		if not pipe then
			return false, nil, "io.popen failed"
		end
		local out = pipe:read("a")
		local ok = pipe:close()
		return ok and true or false, out, ok and nil or "child process failed"
	end,
}

package.loaded["resurrect.file_io"] = {}
package.loaded["resurrect.state_manager"] = { save_state_dir = STATE_DIR }

local fuzzy_loader = require("resurrect.fuzzy_loader")
local t = fuzzy_loader._test

print("state dir: " .. STATE_DIR)
print("subdirs scanned: " .. table.concat(t.STATE_SUBDIRS, ", "))
print("")

-- 1. Real scan
local stdout = t.find_state_files(STATE_DIR)
local scanned = 0
for _ in stdout:gmatch("[^\n]+") do
	scanned = scanned + 1
end
print(string.format("SCAN            -> %d lines returned", scanned))
if scanned == 0 then
	print("  !! scan returned nothing; errors emitted:")
	for _, e in ipairs(errors) do
		print("     " .. e)
	end
	os.exit(1)
end

-- 2. Real insert_choices over that output
local opts = {}
for k, v in pairs(fuzzy_loader.default_fuzzy_load_opts) do
	opts[k] = v
end
opts.show_state_with_date = true

local ok, choices = pcall(t.insert_choices, stdout, opts)
if not ok then
	print("INSERT_CHOICES  -> ERROR: " .. tostring(choices))
	os.exit(1)
end
print(string.format("INSERT_CHOICES  -> %d choices built, no error", #choices))
print("")

-- 3. Break the results down by state type, the way the picker groups them
local by_type = {}
for _, c in ipairs(choices) do
	local ty = c.id:match("^([^/\\]+)")
	by_type[ty] = (by_type[ty] or 0) + 1
end
print("choices by type:")
for _, ty in ipairs({ "workspace", "window", "shelf", "tab" }) do
	print(string.format("  %-10s %4d", ty, by_type[ty] or 0))
end
print("")

print("first 5 labels as the picker would render them:")
for i = 1, math.min(5, #choices) do
	print("  " .. choices[i].label)
end
print("")

if #errors > 0 then
	print("errors emitted during the run:")
	for _, e in ipairs(errors) do
		print("  " .. e)
	end
else
	print("no resurrect.error events emitted")
end
