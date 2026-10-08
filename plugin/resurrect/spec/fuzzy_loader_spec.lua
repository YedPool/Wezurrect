-- Regression tests for the named-save listing in fuzzy_loader.
--
-- fuzzy_loader lists state files with a *recursive* `find`, so it also picks
-- up `.json` files whose parent directory is not a real state type:
--   * state/*/.backups/<name>.<stamp>.json   (dated backups)
--   * state/instances/restored/<id>.json     (tombstones of restored instances)
-- The parser derives the type from the parent directory, so those entries became
-- type ".backups" / "restored"; fmt_cost[type] was nil and insert_choices threw
-- "attempt to perform arithmetic on a nil value", which made
-- "[Browse named saves]" close the selector without listing anything.
--
-- These tests drive the public fuzzy_load() with a fake window and a stubbed
-- file listing, so they exercise the real listing/parsing path.

-- Clear modules other specs may have cached (busted shares one Lua process).
package.loaded["wezterm"] = nil
package.loaded["resurrect.utils"] = nil
package.loaded["resurrect.file_io"] = nil
package.loaded["resurrect.state_manager"] = nil
package.loaded["resurrect.fuzzy_loader"] = nil
package.preload["wezterm"] = nil
package.preload["resurrect.utils"] = nil
package.preload["resurrect.file_io"] = nil
package.preload["resurrect.state_manager"] = nil

-- Fixture returned by the stubbed `find`: known state types mixed with the two
-- stray kinds that used to crash the loader.
local FIND_OUTPUT = table.concat({
	"1700000000 /state/workspace/default.json",
	"1700000000 /state/workspace/.backups/default.20260101-000000.json",
	"1700000000 /state/window/win.json",
	"1700000000 /state/tab/tab.json",
	"1700000000 /state/instances/12345_67890.json",
	"1700000000 /state/instances/restored/12345_67890.json",
}, "\n")

local wezterm_stub = {
	target_triple = "x86_64-unknown-linux-gnu",
	emit = function() end,
	log_error = function() end,
	log_info = function() end,
	log_warn = function() end,
	-- Referenced while fuzzy_loader.lua is loaded (default options).
	nerdfonts = { cod_ellipsis = "..." },
	format = function()
		return ""
	end,
	-- The listing is produced here; we never touch the real filesystem.
	run_child_process = function()
		return true, FIND_OUTPUT, ""
	end,
	action_callback = function(f)
		return f
	end,
	action = {
		InputSelector = function(t)
			return { InputSelector = t }
		end,
	},
}

_G.wezterm = wezterm_stub
package.loaded["wezterm"] = wezterm_stub

-- Minimal utils stub: only what this code path calls.
package.preload["resurrect.utils"] = function()
	return {
		is_windows = false,
		is_mac = false,
		separator = "/",
		utf8len = function(s)
			return #s
		end,
		strip_format_esc_seq = function(s)
			return s
		end,
		replace_center = function(s)
			return s
		end,
		get_current_window_width = function()
			return 200
		end,
		tbl_deep_extend = function(_, ...)
			local out = {}
			for _, t in ipairs({ ... }) do
				for k, v in pairs(t) do
					out[k] = v
				end
			end
			return out
		end,
	}
end

package.preload["resurrect.file_io"] = function()
	return {}
end

package.preload["resurrect.state_manager"] = function()
	return { save_state_dir = "/state" }
end

package.path = "./plugin/?.lua;./plugin/?/?.lua;" .. package.path

local fuzzy_loader = require("resurrect.fuzzy_loader")

-- Identity formatters keep the display width equal to the filename length, so
-- the assertions below are independent of nerd-font glyph widths.
local LOAD_OPTS = {
	ignore_screen_width = true,
	fmt_workspace = function(l)
		return l
	end,
	fmt_window = function(l)
		return l
	end,
	fmt_tab = function(l)
		return l
	end,
}

---Drive fuzzy_load() with a fake window and capture the choices it builds.
---@return table choices
local function load_choices()
	local captured
	local fake_window = {
		perform_action = function(_, action)
			local spec = action.InputSelector or action
			captured = spec.choices or {}
		end,
	}
	fuzzy_loader.fuzzy_load(fake_window, {}, function() end, LOAD_OPTS)
	return captured
end

describe("fuzzy_loader named-save listing", function()
	it("does not crash on .backups / instances-restored json files", function()
		local ok, err = pcall(load_choices)
		assert.is_true(ok, "fuzzy_load raised: " .. tostring(err))
	end)

	it("lists only workspace/window/tab states", function()
		local choices = load_choices()
		assert.equals(3, #choices)
		assert.equals("workspace/default.json", choices[1].id)
		assert.equals("window/win.json", choices[2].id)
		assert.equals("tab/tab.json", choices[3].id)
	end)

	it("ignores instance files when ignore_instances is set", function()
		local choices = load_choices()
		for _, c in ipairs(choices) do
			assert.is_nil(c.id:find("instances", 1, true))
		end
	end)
end)
