-- Specs for pane_tree.create_pane_tree and tab_state.restore_tab split ordering
-- across symmetric, multi-column, and staggered pane grids.

local saved_globals = {
	wezterm = _G.wezterm,
	loaded = {},
	preload = {},
}

local modules_to_isolate = {
	"wezterm",
	"resurrect.pane_tree",
	"resurrect.tab_state",
	"resurrect.utils",
	"resurrect.process_handlers",
	"resurrect.state_manager",
	"resurrect.restore_guard",
}

for _, name in ipairs(modules_to_isolate) do
	saved_globals.loaded[name] = package.loaded[name]
	saved_globals.preload[name] = package.preload[name]
	package.loaded[name] = nil
	package.preload[name] = nil
end

package.path = table.concat({
	"./plugin/?.lua",
	"./plugin/?/init.lua",
	"../../plugin/?.lua",
	"../../plugin/?/init.lua",
}, ";") .. ";" .. package.path

local wezterm_stub = {
	target_triple = "x86_64-unknown-linux-gnu",
	emit = function() end,
	log_error = function() end,
	log_warn = function() end,
	log_info = function() end,
	shell_join_args = function(args)
		return table.concat(args, " ")
	end,
	mux = {
		get_domain = function()
			return {
				is_spawnable = function()
					return true
				end,
			}
		end,
	},
}

_G.wezterm = wezterm_stub
package.loaded["wezterm"] = wezterm_stub
package.preload["wezterm"] = function()
	return wezterm_stub
end

package.loaded["resurrect.process_handlers"] = {
	find_handler = function()
		return false
	end,
	read_pane_session = function()
		return nil
	end,
	sanitize_for_save = function() end,
	get_restore_command = function()
		return nil, false
	end,
}

package.loaded["resurrect.state_manager"] = {
	save_state = function() end,
}

package.loaded["resurrect.restore_guard"] = {
	get_snapshot = function()
		return {}
	end,
	check_command = function()
		return { allow = false }
	end,
	note_skipped = function() end,
	schedule_report = function() end,
}

local pane_tree = require("resurrect.pane_tree")
local tab_state = require("resurrect.tab_state")

local function make_pane_info(id, left, top, width, height, opts)
	opts = opts or {}
	local cwd = opts.cwd or ("/work/p" .. tostring(id))
	local alt = opts.alt_screen_active or false
	local proc = opts.process_info
	return {
		index = id,
		left = left,
		top = top,
		width = width,
		height = height,
		is_active = opts.is_active or false,
		is_zoomed = false,
		pane = {
			pane_id = function()
				return id
			end,
			get_domain_name = function()
				return "local"
			end,
			get_current_working_dir = function()
				return { file_path = cwd }
			end,
			is_alt_screen_active = function()
				return alt
			end,
			get_foreground_process_info = function()
				return proc
			end,
			get_dimensions = function()
				return { scrollback_rows = 10 }
			end,
			get_lines_as_escapes = function()
				return "pane-" .. tostring(id)
			end,
		},
	}
end

local function collect_cwds(node, out)
	out = out or {}
	if node == nil then
		return out
	end
	table.insert(out, node.cwd)
	collect_cwds(node.right, out)
	collect_cwds(node.bottom, out)
	return out
end

-- Simulates WezTerm pane splitting in a normalized [0, 1] x [0, 1] box to verify
-- that make_splits restores the exact number of panes and non-overlapping topology.
local function simulate_restore(tree)
	local panes = {}

	local function make_mock_pane(rect, cwd)
		local p = { rect = rect, cwd = cwd, activated = false }
		table.insert(panes, p)

		function p:split(args)
			local frac = args.size or 0.5
			if args.direction == "Right" then
				local new_w = self.rect.w * frac
				local keep_w = self.rect.w - new_w
				local child_rect = {
					x = self.rect.x + keep_w,
					y = self.rect.y,
					w = new_w,
					h = self.rect.h,
				}
				self.rect.w = keep_w
				return make_mock_pane(child_rect, args.cwd)
			elseif args.direction == "Bottom" then
				local new_h = self.rect.h * frac
				local keep_h = self.rect.h - new_h
				local child_rect = {
					x = self.rect.x,
					y = self.rect.y + keep_h,
					w = self.rect.w,
					h = new_h,
				}
				self.rect.h = keep_h
				return make_mock_pane(child_rect, args.cwd)
			end
			error("unexpected split direction: " .. tostring(args.direction))
		end

		function p:send_text() end
		function p:activate()
			self.activated = true
		end

		return p
	end

	local root_pane = make_mock_pane({ x = 0, y = 0, w = 1, h = 1 }, tree.cwd)
	local mock_tab = {
		set_title = function() end,
		active_pane = function()
			return root_pane
		end,
	}

	tab_state.restore_tab(mock_tab, { title = "t", pane_tree = tree }, {
		pane = root_pane,
		pane_is_new = true,
		relative = true,
	})

	return panes
end

describe("pane_tree and tab_state split layouts", function()
	teardown(function()
		_G.wezterm = saved_globals.wezterm
		for _, name in ipairs(modules_to_isolate) do
			package.loaded[name] = saved_globals.loaded[name]
			package.preload[name] = saved_globals.preload[name]
		end
	end)

	it("does not duplicate the bottom-right pane in a symmetric 2x2 grid", function()
		local tree = pane_tree.create_pane_tree({
			make_pane_info(1, 0, 0, 50, 20, { is_active = true }),
			make_pane_info(2, 51, 0, 50, 20),
			make_pane_info(3, 0, 21, 50, 20),
			make_pane_info(4, 51, 21, 50, 20),
		})

		local cwds = collect_cwds(tree)
		table.sort(cwds)
		assert.are.same({ "/work/p1", "/work/p2", "/work/p3", "/work/p4" }, cwds)

		-- Bottom-left must not also hold a duplicate of bottom-right
		assert.is_nil(tree.bottom.right)
		assert.are.equal("/work/p4", tree.right.bottom.cwd)

		local restored = simulate_restore(tree)
		assert.are.equal(4, #restored)
		-- Each quadrant should have half width and half height
		for _, p in ipairs(restored) do
			assert.is_true(math.abs(p.rect.w - 0.5) < 1e-6)
			assert.is_true(math.abs(p.rect.h - 0.5) < 1e-6)
		end
	end)

	it("captures and restores a 7-pane multi-column grid with two split middle columns", function()
		local tree = pane_tree.create_pane_tree({
			make_pane_info(1, 0, 0, 78, 72),
			make_pane_info(2, 79, 0, 79, 36),
			make_pane_info(3, 79, 37, 79, 35),
			make_pane_info(4, 159, 0, 159, 36, { is_active = true }),
			make_pane_info(5, 159, 37, 159, 35),
			make_pane_info(6, 319, 0, 141, 72),
			make_pane_info(7, 461, 0, 176, 72),
		})

		local cwds = collect_cwds(tree)
		table.sort(cwds)
		assert.are.same({
			"/work/p1", "/work/p2", "/work/p3", "/work/p4",
			"/work/p5", "/work/p6", "/work/p7",
		}, cwds)

		local restored = simulate_restore(tree)
		assert.are.equal(7, #restored)
		-- Columns 1, 4, and 5 must span full height (1.0)
		local by_cwd = {}
		for _, p in ipairs(restored) do
			by_cwd[p.cwd] = p.rect
		end
		assert.is_true(math.abs(by_cwd["/work/p1"].h - 1.0) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p6"].h - 1.0) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p7"].h - 1.0) < 1e-6)
		-- Split middle columns should each span roughly half height
		assert.is_true(by_cwd["/work/p2"].h < 0.6 and by_cwd["/work/p3"].h < 0.6)
		assert.is_true(by_cwd["/work/p4"].h < 0.6 and by_cwd["/work/p5"].h < 0.6)
	end)

	it("preserves horizontal-first split with full-width bottom pane", function()
		local tree = pane_tree.create_pane_tree({
			make_pane_info(1, 0, 0, 50, 20, { is_active = true }),
			make_pane_info(2, 51, 0, 50, 20),
			make_pane_info(3, 0, 21, 101, 20),
		})

		local cwds = collect_cwds(tree)
		table.sort(cwds)
		assert.are.same({ "/work/p1", "/work/p2", "/work/p3" }, cwds)

		local restored = simulate_restore(tree)
		assert.are.equal(3, #restored)
		local by_cwd = {}
		for _, p in ipairs(restored) do
			by_cwd[p.cwd] = p.rect
		end
		assert.is_true(math.abs(by_cwd["/work/p3"].w - 1.0) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p1"].w - 0.5) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p2"].w - 0.5) < 1e-6)
	end)

	it("captures and restores horizontal-first staggered columns without dropping panes", function()
		-- Top row: [0..29] | [31..99], Bottom row: [0..69] | [71..99]
		local tree = pane_tree.create_pane_tree({
			make_pane_info(1, 0, 0, 30, 20, { is_active = true }),
			make_pane_info(2, 31, 0, 69, 20),
			make_pane_info(3, 0, 21, 70, 20),
			make_pane_info(4, 71, 21, 29, 20),
		})

		local cwds = collect_cwds(tree)
		table.sort(cwds)
		assert.are.same({ "/work/p1", "/work/p2", "/work/p3", "/work/p4" }, cwds)

		local restored = simulate_restore(tree)
		assert.are.equal(4, #restored)
		local by_cwd = {}
		for _, p in ipairs(restored) do
			by_cwd[p.cwd] = p.rect
		end
		-- Top row spans y=0..0.5, bottom row spans y=0.5..1.0
		assert.is_true(math.abs(by_cwd["/work/p1"].y - 0.0) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p2"].y - 0.0) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p3"].y - 0.5) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p4"].y - 0.5) < 1e-6)
	end)

	it("captures and restores 3-over-2 horizontal-first staggered grid", function()
		-- Top row: A[0..29] | B[31..59] | C[61..99]
		-- Bottom row: D[0..59] | E[61..99]
		local tree = pane_tree.create_pane_tree({
			make_pane_info(1, 0, 0, 30, 20, { is_active = true }),
			make_pane_info(2, 31, 0, 29, 20),
			make_pane_info(3, 61, 0, 39, 20),
			make_pane_info(4, 0, 21, 60, 20),
			make_pane_info(5, 61, 21, 39, 20),
		})

		local cwds = collect_cwds(tree)
		table.sort(cwds)
		assert.are.same({ "/work/p1", "/work/p2", "/work/p3", "/work/p4", "/work/p5" }, cwds)

		local restored = simulate_restore(tree)
		assert.are.equal(5, #restored)
		local by_cwd = {}
		for _, p in ipairs(restored) do
			by_cwd[p.cwd] = p.rect
		end
		-- Bottom row panes start at y=0.5 and together span full width 1.0
		assert.is_true(math.abs(by_cwd["/work/p4"].y - 0.5) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p5"].y - 0.5) < 1e-6)
		assert.is_true(math.abs((by_cwd["/work/p4"].w + by_cwd["/work/p5"].w) - 1.0) < 1e-6)
	end)

	it("captures and restores vertical-first staggered rows without dropping panes", function()
		-- Left col: [0..9] / [11..40], Right col: [0..29] / [31..40]
		local tree = pane_tree.create_pane_tree({
			make_pane_info(1, 0, 0, 50, 10, { is_active = true }),
			make_pane_info(2, 0, 11, 50, 30),
			make_pane_info(3, 51, 0, 50, 30),
			make_pane_info(4, 51, 31, 50, 10),
		})

		local cwds = collect_cwds(tree)
		table.sort(cwds)
		assert.are.same({ "/work/p1", "/work/p2", "/work/p3", "/work/p4" }, cwds)

		local restored = simulate_restore(tree)
		assert.are.equal(4, #restored)
		local by_cwd = {}
		for _, p in ipairs(restored) do
			by_cwd[p.cwd] = p.rect
		end
		assert.is_true(math.abs(by_cwd["/work/p1"].w - 0.5) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p2"].w - 0.5) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p3"].w - 0.5) < 1e-6)
		assert.is_true(math.abs(by_cwd["/work/p4"].w - 0.5) < 1e-6)
	end)

	it("handles alt-screen pane when get_foreground_process_info returns nil", function()
		local tree = pane_tree.create_pane_tree({
			make_pane_info(1, 0, 0, 80, 24, {
				is_active = true,
				alt_screen_active = true,
				process_info = nil,
			}),
		})

		assert.is_not_nil(tree)
		assert.are.equal("/work/p1", tree.cwd)
		assert.is_nil(tree.process)
	end)
end)
