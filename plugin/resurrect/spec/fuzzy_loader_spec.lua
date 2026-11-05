-- Specs for resurrect.fuzzy_loader.
--
-- The regression under test: insert_choices derives a state file's "type" from
-- its immediate parent directory. Any directory other than the supported types
-- (a .backups/, .trash/ or instances/restored/ folder) produced a type with no
-- entry in `files` or `fmt_cost`, so the first such file raised
-- "attempt to perform arithmetic on a nil value" and took the entire picker
-- down. On a well-used store those files outnumber real saves 100:1.

package.loaded["resurrect.fuzzy_loader"] = nil
package.loaded["resurrect.utils"] = nil
package.loaded["resurrect.file_io"] = nil
package.loaded["resurrect.state_manager"] = nil

-- ---------------------------------------------------------------------------
-- wezterm stub
-- ---------------------------------------------------------------------------
local emitted = {}

local wezterm_stub = {
	nerdfonts = setmetatable({}, {
		__index = function()
			return "*"
		end,
	}),
	-- Return the concatenated Text runs so specs can assert on plain text.
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
		table.insert(emitted, { event = event, args = { ... } })
	end,
	log_info = function() end,
	log_error = function() end,
	run_child_process = function()
		return false, nil, "stub: no child processes in specs"
	end,
	action = {
		InputSelector = function(args)
			return { __selector = args }
		end,
	},
	action_callback = function(fn)
		return fn
	end,
}

package.loaded["wezterm"] = wezterm_stub

-- ---------------------------------------------------------------------------
-- Real utils: insert_choices does arithmetic on utf8len's return value and
-- string surgery with replace_center, so a no-op stub would not exercise the
-- code path this spec exists to protect.
-- ---------------------------------------------------------------------------
package.path = table.concat({
	"./plugin/?.lua",
	"./plugin/?/init.lua",
	"./plugin/?/?.lua",
	"../../plugin/?.lua",
	"../../plugin/?/init.lua",
	"../../plugin/?/?.lua",
	package.path,
}, ";")

local utils = require("resurrect.utils")

-- state_manager is required at the bottom of fuzzy_load; stub it so requiring
-- the loader does not drag in the whole save stack.
package.loaded["resurrect.state_manager"] = { save_state_dir = "C:\\state\\" }
package.loaded["resurrect.file_io"] = {}

local fuzzy_loader = require("resurrect.fuzzy_loader")

-- insert_choices is a module local, reached through the seam fuzzy_load uses.
-- Rather than reimplement it, drive it the way the picker does: build a stdout
-- blob and call the exported test hook.
local insert_choices = fuzzy_loader._test and fuzzy_loader._test.insert_choices

local function line(epoch, dir, file)
	return string.format("%d C:\\state\\%s\\%s", epoch, dir, file)
end

local function opts()
	return require("resurrect.utils").tbl_deep_extend("force", fuzzy_loader.default_fuzzy_load_opts, {})
end

describe("fuzzy_loader.insert_choices", function()
	before_each(function()
		emitted = {}
	end)

	it("is exported for testing", function()
		assert.is_not_nil(insert_choices)
	end)

	it("does not error on a .backups directory", function()
		local stdout = table.concat({
			line(1700000000, "window", "Real+Window.json"),
			line(1700000100, ".backups", "Real+Window.20260817-212536.json"),
		}, "\n")

		local ok, result = pcall(insert_choices, stdout, opts())

		assert.is_true(ok)
		assert.equals(1, #result)
	end)

	it("skips every unsupported directory and keeps the supported ones", function()
		local stdout = table.concat({
			line(1700000000, "workspace", "default.json"),
			line(1700000001, "window", "Deploy+voice+pin.json"),
			line(1700000002, "tab", "one+bug.json"),
			line(1700000003, ".backups", "Deploy+voice+pin.20260817-212536.json"),
			line(1700000004, "restored", "1786550232_42663.json"),
			line(1700000005, ".trash", "old+window.json"),
			line(1700000006, ".quarantine", "broken.json"),
			line(1700000007, "instances-backup-2026-08-19", "1786550232_15222.json"),
		}, "\n")

		local ok, result = pcall(insert_choices, stdout, opts())

		assert.is_true(ok)
		assert.equals(3, #result)

		local ids = {}
		for _, choice in ipairs(result) do
			ids[choice.id] = true
		end
		assert.is_true(ids["workspace" .. utils.separator .. "default.json"])
		assert.is_true(ids["window" .. utils.separator .. "Deploy+voice+pin.json"])
		assert.is_true(ids["tab" .. utils.separator .. "one+bug.json"])
	end)

	it("does not error on unsupported directories with dates enabled", function()
		local o = opts()
		o.show_state_with_date = true

		local stdout = table.concat({
			line(1700000000, ".backups", "Anything.20260817-212536.json"),
			line(1700000001, "window", "Real+Window.json"),
		}, "\n")

		local ok, result = pcall(insert_choices, stdout, o)

		assert.is_true(ok)
		assert.equals(1, #result)
	end)

	it("includes shelf entries as their own state type", function()
		local stdout = table.concat({
			line(1700000000, "window", "Live+Window.json"),
			line(1700000001, "shelf", "Pinned+Window.json"),
		}, "\n")

		local ok, result = pcall(insert_choices, stdout, opts())

		assert.is_true(ok)
		assert.equals(2, #result)

		local ids = {}
		for _, choice in ipairs(result) do
			ids[choice.id] = true
		end
		assert.is_true(ids["shelf" .. utils.separator .. "Pinned+Window.json"])
	end)

	it("still filters instances when ignore_instances is set", function()
		local stdout = table.concat({
			line(1700000000, "instances", "1786550232_42663.json"),
			line(1700000001, "window", "Real+Window.json"),
		}, "\n")

		local o = opts()
		o.ignore_instances = true

		local result = insert_choices(stdout, o)

		assert.equals(1, #result)
		assert.equals("window" .. utils.separator .. "Real+Window.json", result[1].id)
	end)

	it("honours ignore_windows", function()
		local stdout = table.concat({
			line(1700000000, "window", "Real+Window.json"),
			line(1700000001, "tab", "one+bug.json"),
		}, "\n")

		local o = opts()
		o.ignore_windows = true

		local result = insert_choices(stdout, o)

		assert.equals(1, #result)
		assert.equals("tab" .. utils.separator .. "one+bug.json", result[1].id)
	end)

	-- powershell.exe emits CRLF. insert_choices splits on "[^\n]+" and anchors
	-- its pattern with "%.json$", so a surviving CR makes every line fail to
	-- parse. This silently shrank a 156-entry picker to 3 -- one per directory,
	-- being the only lines whose CR had been trimmed -- with no error raised.
	it("parses CRLF output, not just LF", function()
		local stdout = table.concat({
			line(1700000000, "workspace", "default.json"),
			line(1700000001, "window", "One.json"),
			line(1700000002, "window", "Two.json"),
			line(1700000003, "tab", "Three.json"),
		}, "\r\n") .. "\r\n"

		local result = insert_choices(stdout, opts())

		assert.equals(4, #result)
	end)

	it("parses a lone trailing CR without dropping the last entry", function()
		local stdout = line(1700000000, "window", "Only.json") .. "\r\n"
		assert.equals(1, #insert_choices(stdout, opts()))
	end)

	it("returns an empty list for nil stdout", function()
		assert.same({}, insert_choices(nil, opts()))
	end)

	it("returns an empty list when nothing is supported", function()
		local stdout = table.concat({
			line(1700000000, ".backups", "a.20260817-212536.json"),
			line(1700000001, ".backups", "b.20260817-212537.json"),
		}, "\n")

		local result = insert_choices(stdout, opts())

		assert.equals(0, #result)
	end)
end)
