-- Tests for the restore guard: a restore must never resume a Claude session
-- that is already running, and must never type into a pane it did not create.
--
-- These load the REAL tab_state, window_state, workspace_state,
-- process_handlers and instance_manager, with a stub wezterm, fake panes and
-- an injected answer for the one function that asks the operating system
-- (restore_guard.run_query).

local sep = "\\"

-- busted shares one Lua process: drop every module and preload stub an
-- earlier spec file left behind.
for _, name in ipairs({
    "file_io", "utils", "state_manager", "instance_manager", "workspace_state", "window_state",
    "tab_state", "fuzzy_loader", "process_handlers", "pane_tree", "json_text", "restore_guard",
}) do
    package.loaded["resurrect." .. name] = nil
    package.preload["resurrect." .. name] = nil
end
package.loaded["wezterm"] = nil

local json = require("dkjson")

-- ---------------------------------------------------------------------------
-- Stub wezterm
-- ---------------------------------------------------------------------------

local log = {}          -- { level = "warn", text = "..." }
local timers = {}       -- callbacks queued by wezterm.time.call_after
local panes = {}        -- pane_id -> fake pane
local next_pane_id = 100
local spawned_windows = 0
local listed_instance_ids = {}

local function add_log(level)
    return function(text)
        table.insert(log, { level = level, text = tostring(text) })
    end
end

local new_pane -- forward declaration

local function new_tab(pane)
    local tab = { title = nil }
    function tab:active_pane() return pane end
    function tab:set_title(title) self.title = title end
    function tab:panes() return { pane } end
    function tab:set_zoomed() end
    function tab:activate() end
    return tab
end

local function new_window(first_pane)
    local window = { tabs = {}, spawned_tabs = 0 }
    local first_tab = new_tab(first_pane)
    function window:active_tab() return first_tab end
    function window:active_pane() return first_pane end
    function window:set_title(title) self.title = title end
    function window:gui_window()
        return { set_inner_size = function() end }
    end
    function window:spawn_tab()
        self.spawned_tabs = self.spawned_tabs + 1
        local pane = new_pane()
        pane.owner_window = self
        return new_tab(pane), pane, self
    end
    first_pane.owner_window = window
    return window
end

-- A fake pane records everything typed into it.
new_pane = function(foreground)
    next_pane_id = next_pane_id + 1
    local pane = { id = next_pane_id, sent = {}, foreground = foreground }
    function pane:pane_id() return self.id end
    function pane:send_text(text) table.insert(self.sent, text) end
    function pane:inject_output() end
    function pane:activate() end
    function pane:split() return new_pane() end
    function pane:get_foreground_process_name() return self.foreground end
    function pane:window() return self.owner_window end
    function pane:tab() return new_tab(self) end
    panes[pane.id] = pane
    return pane
end

local wezterm_stub = {
    target_triple = "x86_64-pc-windows-msvc",
    GLOBAL = {},
    nerdfonts = setmetatable({}, { __index = function() return "" end }),
    emit = function() end,
    on = function() end,
    log_error = add_log("error"),
    log_warn = add_log("warn"),
    log_info = add_log("info"),
    json_encode = function(value) return json.encode(value) end,
    json_parse = function(text)
        local value, _, err = json.decode(text)
        if err then error(err) end
        return value
    end,
    shell_join_args = function(args) return table.concat(args, " ") end,
    -- Only instance_manager's directory listing reaches this; the guard's
    -- query is replaced in every test.
    run_child_process = function()
        return true, table.concat(listed_instance_ids, "\n"), ""
    end,
    time = {
        call_after = function(_, fn) table.insert(timers, fn) end,
    },
    gui = {
        gui_windows = function() return {} end,
    },
    mux = {
        get_pane = function(id) return panes[id] end,
        spawn_window = function()
            spawned_windows = spawned_windows + 1
            local pane = new_pane()
            local window = new_window(pane)
            return window:active_tab(), pane, window
        end,
        set_active_workspace = function() end,
        rename_workspace = function() end,
        get_active_workspace = function() return "default" end,
    },
    action = {
        InputSelector = function(spec) return spec end,
        PromptInputLine = function(spec) return spec end,
    },
    action_callback = function(fn) return fn end,
}

_G.wezterm = wezterm_stub
package.loaded["wezterm"] = wezterm_stub
package.preload["wezterm"] = function() return wezterm_stub end

-- In-memory file_io: saved instances live in file_store.
local file_store = {}
package.preload["resurrect.file_io"] = function()
    return {
        write_file = function(path, content)
            file_store[path] = content
            return true, nil
        end,
        read_file = function(path)
            if file_store[path] then return true, file_store[path] end
            return false, "not found"
        end,
        load_json = function(path)
            if file_store[path] then return wezterm_stub.json_parse(file_store[path]) end
            return nil
        end,
        write_state = function(path, state) file_store[path] = wezterm_stub.json_encode(state) end,
        file_exists = function(path) return file_store[path] ~= nil end,
        move_file = function(src, dst)
            if file_store[src] == nil then return false, "source missing" end
            file_store[dst] = file_store[src]
            file_store[src] = nil
            return true, nil
        end,
    }
end
-- The named-save browser: keep the callback it would run on a choice.
local fuzzy_callback = nil
package.preload["resurrect.fuzzy_loader"] = function()
    return { fuzzy_load = function(_, _, callback) fuzzy_callback = callback end }
end

package.path = table.concat({
    "./plugin/?.lua", "./plugin/?/init.lua", "../../plugin/?.lua", "../../plugin/?/init.lua",
}, ";") .. ";" .. package.path

local utils = require("resurrect.utils")
utils.ensure_folder_exists = function() return true end -- never touch the disk

local guard_loaded, guard = pcall(require, "resurrect.restore_guard")
local tab_state = require("resurrect.tab_state")
local state_manager = require("resurrect.state_manager")
state_manager.save_state_dir = "X:" .. sep .. "state"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local LIVE = "aaaaaaaa-1111-4111-8111-111111111111"
local DEAD = "bbbbbbbb-2222-4222-8222-222222222222"
local REUSED = "cccccccc-3333-4333-8333-333333333333"
local OTHER = "dddddddd-4444-4444-8444-444444444444"
local START = "134363212579349896"

local query_calls = 0

-- Answer the guard's one OS question with these control files.
-- Each is { session, pid, proc_start, running (bool), start_time, cwd }.
local function control_files(files)
    if not guard_loaded then return end
    guard.run_query = function()
        query_calls = query_calls + 1
        local lines = {}
        for _, f in ipairs(files) do
            table.insert(lines, table.concat({
                "S", f[1], tostring(f[2]), f[3], f[4] and "1" or "0", f[5] or "?", f[6] or "",
            }, "\t"))
        end
        table.insert(lines, "END\t" .. #files)
        return table.concat(lines, "\r\n") .. "\r\n"
    end
end

-- The control directory cannot be read at all.
local function control_dir_unreadable()
    if not guard_loaded then return end
    guard.run_query = function()
        query_calls = query_calls + 1
        return nil, "access denied"
    end
end

-- The usual world: LIVE is running, DEAD's process is gone, REUSED's pid now
-- belongs to a process that started at another time.
local function usual_world()
    control_files({
        { LIVE, 4242, START, true, START, "C:\\work\\live" },
        { DEAD, 5151, START, false, "?", "C:\\work\\dead" },
        { REUSED, 6161, START, true, "134399999999999999", "C:\\work\\reused" },
    })
end

local function claude_pane(session_id, cwd)
    return {
        cwd = cwd or "C:\\work",
        left = 0, top = 0, width = 80, height = 24,
        process = {
            name = "claude", executable = "claude", cwd = cwd or "C:\\work",
            argv = { "claude", "--resume", session_id },
        },
    }
end

local function run_timers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

local function all_sent(pane)
    return table.concat(pane.sent, "")
end

-- Everything typed into every pane.
local function everything_sent()
    local out = {}
    for _, pane in pairs(panes) do
        table.insert(out, all_sent(pane))
    end
    return table.concat(out, "")
end

local function logged(pattern)
    for _, entry in ipairs(log) do
        if entry.text:find(pattern) then return entry.text end
    end
    return nil
end

-- Restore one pane through the real default_on_pane_restore and return it.
local function restore_pane(tree)
    tree.pane = new_pane()
    tab_state.default_on_pane_restore(tree)
    run_timers()
    return tree.pane
end

local function reset()
    log = {}
    timers = {}
    panes = {}
    file_store = {}
    listed_instance_ids = {}
    spawned_windows = 0
    query_calls = 0
    wezterm_stub.GLOBAL = {}
    if guard_loaded then guard._test.reset() end
    usual_world()
end

-- ---------------------------------------------------------------------------
-- Never resume a session that is already running
-- ---------------------------------------------------------------------------

describe("restore guard: resume commands", function()
    before_each(reset)

    it("does not resume a session whose control file names a running process with a matching start time", function()
        local pane = restore_pane(claude_pane(LIVE))
        assert.equals("", all_sent(pane), "nothing may be typed into the pane")
    end)

    it("resumes a session whose control file names a process that is gone", function()
        local pane = restore_pane(claude_pane(DEAD))
        assert.truthy(all_sent(pane):find("claude --resume " .. DEAD, 1, true))
    end)

    it("resumes a session whose pid was reused by a process with another start time", function()
        local pane = restore_pane(claude_pane(REUSED))
        assert.truthy(all_sent(pane):find("claude --resume " .. REUSED, 1, true))
    end)

    it("resumes a session that has no control file", function()
        local pane = restore_pane(claude_pane(OTHER))
        assert.truthy(all_sent(pane):find("claude --resume " .. OTHER, 1, true))
    end)

    it("resumes nothing when the control directory cannot be read", function()
        control_dir_unreadable()
        local dead = restore_pane(claude_pane(DEAD))
        local other = restore_pane(claude_pane(OTHER))
        assert.equals("", all_sent(dead))
        assert.equals("", all_sent(other))
    end)

    it("does not resume when the process is running but its start time cannot be read", function()
        control_files({ { OTHER, 7171, START, true, "?", "C:\\work" } })
        local pane = restore_pane(claude_pane(OTHER))
        assert.equals("", all_sent(pane))
    end)

    it("resumes nothing when the answer from the process query is cut short", function()
        guard.run_query = function()
            return "S\t" .. LIVE .. "\t4242\t" .. START .. "\t1\t" .. START .. "\tC:\\work\r\n"
        end
        local pane = restore_pane(claude_pane(DEAD))
        assert.equals("", all_sent(pane))
    end)

    it("resumes nothing when a running process's control file could not be parsed", function()
        control_files({ { "", 8181, "", true, START, "" } })
        local pane = restore_pane(claude_pane(DEAD))
        assert.equals("", all_sent(pane))
    end)

    it("ignores an unparseable control file whose process is gone", function()
        control_files({ { "", 8181, "", false, "?", "" } })
        local pane = restore_pane(claude_pane(DEAD))
        assert.truthy(all_sent(pane):find(DEAD, 1, true))
    end)

    it("resumes a session only once when two panes ask for it", function()
        local first = restore_pane(claude_pane(DEAD))
        local second = restore_pane(claude_pane(DEAD))
        assert.truthy(all_sent(first):find(DEAD, 1, true))
        assert.equals("", all_sent(second))
    end)


    it("still restores a program that is not Claude", function()
        local pane = restore_pane({
            cwd = "C:\\work",
            process = { name = "vim", executable = "vim", argv = { "vim", "notes.txt" } },
        })
        assert.truthy(all_sent(pane):find("vim notes.txt", 1, true))
    end)

    it("reads the control files once for a whole restore", function()
        restore_pane(claude_pane(LIVE))
        restore_pane(claude_pane(DEAD))
        restore_pane(claude_pane(OTHER))
        assert.equals(1, query_calls)
    end)

    it("logs each skipped session with its short id, the pane and the reason", function()
        local pane = restore_pane(claude_pane(LIVE))
        local line = logged("not resuming session")
        assert.truthy(line, "a skip must be logged")
        assert.truthy(line:find("aaaaaaaa", 1, true))
        assert.falsy(line:find(LIVE, 1, true), "only the first 8 characters of the id")
        assert.truthy(line:find("pane " .. pane.id, 1, true))
        assert.truthy(line:find("already running pid 4242", 1, true))
    end)

    it("logs an unreadable control directory as the reason", function()
        control_dir_unreadable()
        restore_pane(claude_pane(DEAD))
        local line = logged("not resuming session")
        assert.truthy(line and line:find("liveness unreadable", 1, true))
        assert.truthy(line:find("access denied", 1, true))
    end)
end)

describe("restore guard: a restored tab", function()
    before_each(reset)

    -- One tab, three panes: LIVE (root), DEAD (right), OTHER (bottom).
    local function mixed_tab()
        local root = claude_pane(LIVE, "C:\\work\\a")
        root.right = claude_pane(DEAD, "C:\\work\\b")
        root.right.left = 81
        root.bottom = claude_pane(OTHER, "C:\\work\\c")
        root.bottom.top = 25
        return { title = "mixed", pane_tree = root }
    end

    local function restore_mixed_tab()
        local existing = new_pane("C:\\Program Files\\PowerShell\\7\\pwsh.exe")
        local state = mixed_tab()
        tab_state.restore_tab(new_tab(existing), state, {
            relative = true,
            on_pane_restore = tab_state.default_on_pane_restore,
        })
        run_timers()
        run_timers() -- the report timer
        return state, existing
    end

    it("resumes only the sessions that are not running", function()
        local state = restore_mixed_tab()
        assert.equals("", all_sent(state.pane_tree.pane))
        assert.truthy(all_sent(state.pane_tree.right.pane):find(DEAD, 1, true))
        assert.truthy(all_sent(state.pane_tree.bottom.pane):find(OTHER, 1, true))
        assert.falsy(everything_sent():find(LIVE, 1, true), "the live session id must never be typed anywhere")
    end)

    it("reports how many sessions were resumed and how many panes were left alone", function()
        restore_mixed_tab()
        local line = logged("restore finished")
        assert.truthy(line, "the restore must report what it did")
        assert.truthy(line:find("2 sessions resumed", 1, true))
        assert.truthy(line:find("1 pane left alone because the session is already running", 1, true))
    end)
end)

-- ---------------------------------------------------------------------------
-- Never type into a pane the restore did not create
-- ---------------------------------------------------------------------------

local instance_manager = require("resurrect.instance_manager")
local workspace_state_mod = require("resurrect.workspace_state")

local restore_opts = {
    relative = true,
    restore_text = true,
    on_pane_restore = tab_state.default_on_pane_restore,
}

-- A saved workspace with one window; each argument is one tab's pane tree.
local function workspace_of(...)
    local tabs = {}
    for _, tree in ipairs({ ... }) do
        table.insert(tabs, { title = "t", pane_tree = tree })
    end
    return {
        workspace = "default",
        window_states = { {
            title = "",
            size = { cols = 80, rows = 24, pixel_width = 800, pixel_height = 600 },
            tabs = tabs,
        } },
    }
end

-- Put a saved instance "on disk".
local function save_instance_file(id, workspace_state)
    local dir = instance_manager.get_instances_dir()
    file_store[dir .. sep .. id .. ".json"] = json.encode({ instance_id = id, workspace_state = workspace_state })
    file_store[dir .. sep .. id .. ".meta"] = json.encode({
        instance_id = id, last_save_epoch = os.time(), tab_count = 1, window_count = 1, pane_count = 1,
    })
    table.insert(listed_instance_ids, id)
end

-- A gui window that remembers the selector it was asked to show.
local function new_gui_window()
    local gui = { toasts = {} }
    function gui:perform_action(action) self.selector = action end
    function gui:toast_notification(_, message) table.insert(self.toasts, message) end
    function gui:choice(id)
        for _, choice in ipairs(self.selector.choices) do
            if choice.id == id then return choice end
        end
        return nil
    end
    -- Pick an entry of the selector currently shown.
    function gui:pick(id, pane)
        local choice = self:choice(id)
        self.selector.action(self, pane, id, choice and choice.label or id)
    end
    return gui
end

-- A pane in an existing window that is busy running a Claude session.
local function busy_pane()
    local pane = new_pane("C:\\Users\\me\\.local\\bin\\claude.exe")
    new_window(pane)
    return pane
end

describe("restore guard: panes that already exist", function()
    before_each(function()
        reset()
        instance_manager.instance_id = "1700000000_10000"
    end)

    it("restore_tab does not type into a pane handed to it", function()
        local existing = busy_pane()
        tab_state.restore_tab(new_tab(existing), { title = "t", pane_tree = claude_pane(DEAD) }, {
            pane = existing,
            on_pane_restore = tab_state.default_on_pane_restore,
        })
        run_timers()
        assert.equals("", all_sent(existing), "nothing may be typed into the existing pane")
        assert.truthy(everything_sent():find(DEAD, 1, true), "the session is resumed in a new pane instead")
    end)

    it("restore_workspace into an existing window does not type into its active pane", function()
        local existing = busy_pane()
        workspace_state_mod.restore_workspace(workspace_of(claude_pane(DEAD), claude_pane(OTHER)), {
            window = existing:window(),
            on_pane_restore = tab_state.default_on_pane_restore,
        })
        run_timers()
        assert.equals("", all_sent(existing))
        assert.truthy(everything_sent():find(DEAD, 1, true))
        assert.truthy(everything_sent():find(OTHER, 1, true))
    end)

    it("Alt+R restore opens a new window and leaves the pane it was pressed in alone", function()
        local existing = busy_pane()
        local gui = new_gui_window()
        save_instance_file("1700000001_11111", workspace_of(claude_pane(DEAD)))

        instance_manager.show_instance_selector(gui, existing, restore_opts)
        gui:pick("1700000001_11111", existing)
        gui:pick("__RESTORE_SELECTED__", existing)
        run_timers()

        assert.equals("", all_sent(existing))
        assert.equals(1, spawned_windows)
        assert.truthy(everything_sent():find(DEAD, 1, true))
    end)

    it("a restore leaves nothing behind in the options table it was given", function()
        -- The keybinding passes the same table to every restore. A pane or
        -- window left in it would be reused, and typed into, by the next one.
        local opts = { relative = true, on_pane_restore = tab_state.default_on_pane_restore }
        workspace_state_mod.restore_workspace(workspace_of(claude_pane(DEAD)), opts)
        assert.is_nil(opts.window)
        assert.is_nil(opts.tab)
        assert.is_nil(opts.pane)
        assert.is_nil(opts.pane_is_new)
        run_timers()

        local first_restore_panes = {}
        for id, pane in pairs(panes) do first_restore_panes[id] = #pane.sent end
        local existing = busy_pane()
        tab_state.restore_tab(new_tab(existing), { title = "t", pane_tree = claude_pane(OTHER) }, opts)
        run_timers()
        for id, count in pairs(first_restore_panes) do
            assert.equals(count, #panes[id].sent, "a pane of the earlier restore was typed into")
        end
        assert.truthy(everything_sent():find(OTHER, 1, true))
    end)

    it("the startup selector reuses its own blank window", function()
        local gui = new_gui_window()
        save_instance_file("1700000001_11111", workspace_of(claude_pane(DEAD)))
        wezterm_stub.gui.gui_windows = function()
            -- The window auto_restore_on_startup just spawned.
            local blank
            for _, pane in pairs(panes) do blank = pane end
            blank.foreground = "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
            function gui:active_pane() return blank end
            return { gui }
        end

        instance_manager.auto_restore_on_startup()
        run_timers()
        local blank = gui:active_pane()
        gui:pick("1700000001_11111", blank)
        gui:pick("__RESTORE_SELECTED__", blank)
        run_timers()
        wezterm_stub.gui.gui_windows = function() return {} end

        assert.equals(1, spawned_windows, "no window beyond the one startup opened")
        assert.truthy(all_sent(blank):find(DEAD, 1, true))
    end)

    it("Alt+R never reuses the startup window, even when its foreground process is a shell", function()
        -- Start with saved copies, press Esc on the startup selector, run
        -- Claude in that first pane. Claude's pane reports its CHILD process
        -- (bash, pwsh) as the foreground, so it looks like a blank shell.
        local gui = new_gui_window()
        save_instance_file("1700000001_11111", workspace_of(claude_pane(DEAD)))
        local first_pane
        wezterm_stub.gui.gui_windows = function()
            for _, pane in pairs(panes) do first_pane = pane end
            first_pane.foreground = "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
            function gui:active_pane() return first_pane end
            return { gui }
        end
        instance_manager.auto_restore_on_startup()
        run_timers()
        wezterm_stub.gui.gui_windows = function() return {} end
        gui.selector.action(gui, first_pane, nil, nil) -- Esc
        first_pane.foreground = "C:\\Program Files\\Git\\usr\\bin\\bash.exe"

        -- Later: Alt+R in that pane, with the keybinding's own options.
        instance_manager.show_instance_selector(gui, first_pane, restore_opts)
        gui:pick("1700000001_11111", first_pane)
        gui:pick("__RESTORE_SELECTED__", first_pane)
        run_timers()

        assert.equals("", all_sent(first_pane), "nothing may be typed into the pane Alt+R was pressed in")
        assert.equals(2, spawned_windows, "the restore must open its own window")
        assert.truthy(everything_sent():find(DEAD, 1, true))
    end)

    it("the startup window is not reused once a program runs in it", function()
        local gui = new_gui_window()
        save_instance_file("1700000001_11111", workspace_of(claude_pane(DEAD)))
        wezterm_stub.gui.gui_windows = function()
            local blank
            for _, pane in pairs(panes) do blank = pane end
            blank.foreground = "C:\\Users\\me\\.local\\bin\\claude.exe"
            function gui:active_pane() return blank end
            return { gui }
        end

        instance_manager.auto_restore_on_startup()
        run_timers()
        local started = gui:active_pane()
        gui:pick("1700000001_11111", started)
        gui:pick("__RESTORE_SELECTED__", started)
        run_timers()
        wezterm_stub.gui.gui_windows = function() return {} end

        assert.equals("", all_sent(started))
        assert.equals(2, spawned_windows)
    end)
end)

-- ---------------------------------------------------------------------------
-- The running terminal's own instance
-- ---------------------------------------------------------------------------

local OWN_ID = "1700000000_10000"
local SAVED_ID = "1700000001_11111"

local function instance_file_exists(id)
    return file_store[instance_manager.get_instances_dir() .. sep .. id .. ".json"] ~= nil
end

describe("restore guard: this terminal's own instance", function()
    before_each(function()
        reset()
        instance_manager.instance_id = OWN_ID
        -- Sessions that are NOT running, so only the instance check can stop it.
        save_instance_file(OWN_ID, workspace_of(claude_pane(DEAD)))
        save_instance_file(SAVED_ID, workspace_of(claude_pane(OTHER)))
    end)

    it("restore_instances refuses its own instance id", function()
        local existing = busy_pane()
        instance_manager._test.restore_instances({ OWN_ID }, new_gui_window(), existing, restore_opts)
        run_timers()

        assert.equals(0, spawned_windows, "no window may be opened for the terminal's own state")
        assert.equals("", everything_sent())
        assert.is_true(instance_file_exists(OWN_ID), "the live instance's file must not be tombstoned")
        assert.truthy(logged("refusing to restore instance " .. OWN_ID))
    end)

    it("still restores the other instances asked for in the same call", function()
        local existing = busy_pane()
        instance_manager._test.restore_instances({ OWN_ID, SAVED_ID }, new_gui_window(), existing, restore_opts)
        run_timers()

        assert.equals(1, spawned_windows)
        assert.truthy(everything_sent():find(OTHER, 1, true))
        assert.falsy(everything_sent():find(DEAD, 1, true))
    end)

    it("the selector marks its own instance as live and will not select it", function()
        local existing = busy_pane()
        local gui = new_gui_window()
        instance_manager.show_instance_selector(gui, existing, restore_opts)

        local own = gui:choice(OWN_ID)
        assert.truthy(own.label:find("this terminal's own live copy %- cannot restore"), own.label)
        assert.falsy(own.label:find("^%[ %]"), "must not look selectable")

        gui:pick(OWN_ID, existing)
        assert.is_nil(gui:choice("__RESTORE_SELECTED__"), "picking it must not select anything")
        assert.truthy(gui:choice(OWN_ID).label:find("cannot restore"))
    end)
end)

-- ---------------------------------------------------------------------------
-- The instance id across config reloads
-- ---------------------------------------------------------------------------

-- WezTerm evaluates the config in a fresh Lua state on every reload; only
-- wezterm.GLOBAL carries over. Loading the module again models that.
local function reload_config()
    package.loaded["resurrect.instance_manager"] = nil
    local fresh = require("resurrect.instance_manager")
    fresh.init_instance_id()
    return fresh
end

describe("restore guard: instance id across config reloads", function()
    before_each(reset)
    after_each(function()
        package.loaded["resurrect.instance_manager"] = instance_manager
    end)

    it("a reloaded config keeps the same instance id", function()
        local first = reload_config()
        local second = reload_config()
        local third = reload_config()
        assert.truthy(first.instance_id:match("^%d+_%d+$"))
        assert.equals(first.instance_id, second.instance_id)
        assert.equals(first.instance_id, third.instance_id)
    end)

    it("a reloaded config keeps the instance's display name", function()
        local first = reload_config()
        save_instance_file(first.instance_id, workspace_of(claude_pane(DEAD)))
        first.rename_instance(first.instance_id, "Fleet")
        local second = reload_config()
        assert.equals("Fleet", second.display_name)
    end)

    it("a new WezTerm process gets a new instance id", function()
        reload_config()
        wezterm_stub.GLOBAL = {} -- a new process starts with an empty GLOBAL
        local other = reload_config()
        assert.truthy(other.instance_id:match("^%d+_%d+$"))
        assert.equals(other.instance_id, wezterm_stub.GLOBAL.resurrect_instance_id)
    end)

    it("ignores a remembered id that is not a valid instance id", function()
        wezterm_stub.GLOBAL.resurrect_instance_id = "..\\..\\evil"
        local fresh = reload_config()
        assert.truthy(fresh.instance_id:match("^%d+_%d+$"))
    end)
end)
-- ---------------------------------------------------------------------------
-- Saved copies of sessions that are running
-- ---------------------------------------------------------------------------

local STALE_ID = "1700000002_22222"
local MIXED_ID = "1700000003_33333"
local SHELLS_ID = "1700000004_44444"

describe("restore guard: saved copies in the selector", function()
    local existing, gui

    before_each(function()
        reset()
        instance_manager.instance_id = OWN_ID
        -- Every session of STALE is running; MIXED has one running, one not.
        control_files({
            { LIVE, 4242, START, true, START, "C:\\work\\a" },
            { OTHER, 4343, START, true, START, "C:\\work\\b" },
        })
        save_instance_file(STALE_ID, workspace_of(claude_pane(LIVE), claude_pane(OTHER)))
        save_instance_file(MIXED_ID, workspace_of(claude_pane(LIVE), claude_pane(DEAD)))
        save_instance_file(SHELLS_ID, workspace_of({ cwd = "C:\\work", text = "PS C:\\work>" }))
        existing = busy_pane()
        gui = new_gui_window()
    end)

    it("does not offer a saved instance whose sessions are all running", function()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        local label = gui:choice(STALE_ID).label
        assert.truthy(label:find("all 2 sessions already running", 1, true), label)
        assert.truthy(label:find("cannot restore", 1, true), label)

        gui:pick(STALE_ID, existing)
        assert.is_nil(gui:choice("__RESTORE_SELECTED__"))
    end)

    it("restore_instances refuses a saved instance whose sessions are all running", function()
        instance_manager._test.restore_instances({ STALE_ID }, gui, existing, restore_opts)
        run_timers()
        assert.equals(0, spawned_windows)
        assert.equals("", everything_sent())
        assert.is_true(instance_file_exists(STALE_ID))
        assert.truthy(logged("refusing to restore instance " .. STALE_ID))
    end)

    it("shows how many sessions of a partly running copy are already running", function()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        local label = gui:choice(MIXED_ID).label
        assert.truthy(label:find("resumes 1; 1 already running", 1, true), label)
        assert.truthy(label:find("^%[ %]"), "it stays selectable")
    end)

    it("restores a partly running copy but resumes only the sessions that are not running", function()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        gui:pick(MIXED_ID, existing)
        gui:pick("__RESTORE_SELECTED__", existing)
        run_timers()
        assert.equals(1, spawned_windows)
        assert.truthy(everything_sent():find(DEAD, 1, true))
        assert.falsy(everything_sent():find(LIVE, 1, true))
        assert.is_false(instance_file_exists(MIXED_ID), "a restored copy is tombstoned as before")
    end)

    it("says so and restores nothing with a resume line when liveness cannot be read", function()
        control_dir_unreadable()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        local label = gui:choice(MIXED_ID).label
        assert.truthy(label:find("cannot tell what is running", 1, true), label)
        gui:pick(MIXED_ID, existing)
        assert.is_nil(gui:choice("__RESTORE_SELECTED__"))

        instance_manager._test.restore_instances({ MIXED_ID, STALE_ID }, gui, existing, restore_opts)
        run_timers()
        assert.equals(0, spawned_windows)
        assert.equals("", everything_sent())
        assert.is_true(instance_file_exists(MIXED_ID))
    end)

    it("still restores a copy that resumes nothing when liveness cannot be read", function()
        control_dir_unreadable()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        assert.truthy(gui:choice(SHELLS_ID).label:find("^%[ %]"))
        gui:pick(SHELLS_ID, existing)
        gui:pick("__RESTORE_SELECTED__", existing)
        assert.equals(1, spawned_windows)
    end)

    it("reads the control files afresh when the restore starts", function()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        gui:pick(MIXED_ID, existing)
        -- DEAD is started somewhere else while the selector is open.
        control_files({
            { LIVE, 4242, START, true, START, "C:\\work\\a" },
            { DEAD, 4444, START, true, START, "C:\\work\\c" },
        })
        gui:pick("__RESTORE_SELECTED__", existing)
        run_timers()
        assert.equals("", everything_sent())
        assert.is_true(instance_file_exists(MIXED_ID))
    end)
end)

-- ---------------------------------------------------------------------------
-- Every other way into a restore
-- ---------------------------------------------------------------------------

describe("restore guard: other entry points", function()
    local real_open = io.open
    local workspace_file = state_manager.save_state_dir .. sep .. "workspace" .. sep .. "default.json"

    -- state/current_state is read with io.open; serve it from memory.
    local function current_state_names_default()
        rawset(io, "open", function(path, mode)
            if path == state_manager.save_state_dir .. sep .. "current_state" then
                local lines = { "default", "workspace" }
                return {
                    read = function() return table.remove(lines, 1) end,
                    close = function() end,
                }
            end
            return real_open(path, mode)
        end)
    end

    before_each(function()
        reset()
        instance_manager.instance_id = OWN_ID
        current_state_names_default()
    end)
    after_each(function()
        rawset(io, "open", real_open)
    end)

    it("startup with no saved instances resumes only the sessions that are not running", function()
        file_store[workspace_file] = json.encode(workspace_of(claude_pane(LIVE), claude_pane(DEAD)))
        instance_manager.auto_restore_on_startup()
        run_timers()
        assert.equals(1, spawned_windows)
        assert.truthy(everything_sent():find(DEAD, 1, true))
        assert.falsy(everything_sent():find(LIVE, 1, true))
    end)

    it("startup with no saved instances restores nothing when every session is running", function()
        file_store[workspace_file] = json.encode(workspace_of(claude_pane(LIVE)))
        instance_manager.auto_restore_on_startup()
        run_timers()
        assert.equals(0, spawned_windows)
        assert.equals("", everything_sent())
        assert.truthy(logged("not restoring workspace default at startup"))
    end)

    it("startup with no saved instances restores nothing when liveness cannot be read", function()
        control_dir_unreadable()
        file_store[workspace_file] = json.encode(workspace_of(claude_pane(DEAD)))
        instance_manager.auto_restore_on_startup()
        run_timers()
        assert.equals(0, spawned_windows)
        assert.equals("", everything_sent())
    end)

    it("Browse named saves resumes only the sessions that are not running", function()
        file_store[workspace_file] = json.encode(workspace_of(claude_pane(LIVE), claude_pane(DEAD)))
        save_instance_file(SAVED_ID, workspace_of(claude_pane(OTHER)))
        local existing = busy_pane()
        local gui = new_gui_window()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        gui:pick("__BROWSE_NAMED__", existing)
        fuzzy_callback("workspace" .. sep .. "default.json", "default")
        run_timers()
        assert.equals("", all_sent(existing))
        assert.truthy(everything_sent():find(DEAD, 1, true))
        assert.falsy(everything_sent():find(LIVE, 1, true))
    end)

    it("a config calling restore_workspace directly resumes only the sessions that are not running", function()
        -- What WezTerm-Recovery\recovery.lua does on gui-startup.
        workspace_state_mod.restore_workspace(workspace_of(claude_pane(LIVE), claude_pane(DEAD)), {
            relative = true,
            restore_text = true,
            on_pane_restore = tab_state.default_on_pane_restore,
        })
        run_timers()
        assert.truthy(everything_sent():find(DEAD, 1, true))
        assert.falsy(everything_sent():find(LIVE, 1, true))
    end)
end)
-- ---------------------------------------------------------------------------
-- The typed line is rebuilt from fixed parts, never copied from the file
-- ---------------------------------------------------------------------------

describe("restore guard: the line that is typed", function()
    before_each(reset)

    it("is exactly cd <dir> and claude --resume <id>", function()
        local pane = restore_pane(claude_pane(DEAD))
        assert.equals("cd C:\\work\rclaude --resume " .. DEAD .. "\r", all_sent(pane))
    end)

    it("ends each line with a bare CR on Windows, never an LF", function()
        -- PSReadLine reads CRLF as Enter plus a second key; the stray LF
        -- lands in the next prompt, in front of the resume line.
        local pane = restore_pane(claude_pane(DEAD))
        assert.falsy(all_sent(pane):find("\n", 1, true), "no LF may be typed on Windows")
    end)

    it("restore_tab ends its cd into the reused first pane with a bare CR on Windows", function()
        -- The guard types the resume line into this same pane 3 s later; an
        -- LF left here would land in front of it.
        local fresh = new_pane()
        tab_state.restore_tab(new_tab(fresh), { title = "t", pane_tree = { cwd = "C:\\work" } }, {
            pane = fresh,
            pane_is_new = true,
        })
        assert.equals("cd C:\\work\r", all_sent(fresh))
    end)

    it("ends the prompt nudge after restored scrollback with a bare CR on Windows", function()
        local pane = restore_pane({ cwd = "C:\\work", text = "PS C:\\work>" })
        assert.equals("\r", all_sent(pane))
    end)

    it("the claude handler joins cd and the resume line with a bare CR on Windows", function()
        local cmd = require("resurrect.process_handlers").get_restore_command(
            { name = "claude", executable = "claude", cwd = "C:\\work", argv = { "claude", "--resume", DEAD } },
            { cwd = "C:\\work" }
        )
        assert.truthy(cmd, "the claude handler must build a command")
        assert.truthy(cmd:find("cd C:\\work\r", 1, true))
        assert.falsy(cmd:find("\n", 1, true), "no LF may be typed on Windows")
    end)

    it("utils.ENTER is a bare CR on Windows", function()
        assert.equals("\r", utils.ENTER)
    end)

    it("keeps the one allowed flag", function()
        local tree = claude_pane(DEAD)
        tree.process.argv = { "claude", "--resume", DEAD, "--dangerously-skip-permissions" }
        local pane = restore_pane(tree)
        assert.equals(
            "cd C:\\work\rclaude --resume " .. DEAD .. " --dangerously-skip-permissions\r",
            all_sent(pane)
        )
    end)

    it("keeps the claude2 binary name", function()
        local tree = claude_pane(DEAD)
        tree.process.name = "claude2"
        tree.process.argv = { "claude2", "--resume", DEAD }
        local pane = restore_pane(tree)
        assert.equals("cd C:\\work\rclaude2 --resume " .. DEAD .. "\r", all_sent(pane))
    end)

    for _, bad_id in ipairs({
        "abc-123",
        "BBBBBBBB-2222-4222-8222-222222222222",
        DEAD .. "0",
        "bbbbbbbb22224222822222222222222222222",
        "------------------------------------",
    }) do
        it("is not typed when the session id is " .. bad_id, function()
            local tree = claude_pane(DEAD)
            tree.process.argv = { "claude", "--resume", bad_id }
            local pane = restore_pane(tree)
            assert.equals("", all_sent(pane))
        end)
    end

    it("is not typed when the saved command carries a flag that is not allowed", function()
        local tree = claude_pane(DEAD)
        tree.process.argv = { "claude", "--resume", DEAD, "--model", "x" }
        local pane = restore_pane(tree)
        assert.equals("", all_sent(pane))
        assert.truthy(logged("pane " .. pane.id), "the refusal names the pane")
    end)

    it("is not typed when the saved command has no session id", function()
        local tree = claude_pane(DEAD)
        tree.process.argv = { "claude" }
        local pane = restore_pane(tree)
        assert.equals("", all_sent(pane))
    end)

    it("is not typed when the saved process name carries a path", function()
        -- The Claude handler does not recognise this name; the argv used to
        -- be replayed as written because "claude" was on the allow-list.
        local tree = claude_pane(DEAD)
        tree.process.name = "C:\\evil\\claude.exe"
        tree.process.argv = { "claude", "--resume", DEAD, "--append-system-prompt", "x" }
        local pane = restore_pane(tree)
        assert.equals("", all_sent(pane))
    end)

    it("is not typed when the saved argv does not start with a claude binary", function()
        local tree = claude_pane(DEAD)
        tree.process.argv = { "powershell", "--resume", DEAD }
        local pane = restore_pane(tree)
        assert.equals("", all_sent(pane))
    end)

    it("is not typed when another handler builds a claude command of another shape", function()
        require("resurrect.process_handlers").register({
            name = "wrapper",
            detect = function(info) return info.name == "wrapped" end,
            get_restore_cmd = function() return "claude --resume " .. DEAD .. " ; calc" end,
        })
        local pane = restore_pane({
            cwd = "C:\\work",
            process = { name = "wrapped", executable = "wrapped", argv = { "wrapped" } },
        })
        assert.equals("", all_sent(pane))
    end)

    for _, bad_cwd in ipairs({
        "C:\\a' > 'C:\\Users\\me\\precious.txt",
        "C:\\a\" > \"C:\\x",
        "C:\\a > C:\\x",
        "C:\\a < C:\\x",
        "C:\\a; calc",
        "C:\\a\r\ncalc",
    }) do
        it("types nothing when the saved directory is " .. bad_cwd:gsub("[\r\n]", "<newline>"), function()
            local pane = restore_pane(claude_pane(DEAD, bad_cwd))
            assert.equals("", all_sent(pane))
        end)

        it("restore_tab does not cd into " .. bad_cwd:gsub("[\r\n]", "<newline>"), function()
            local fresh = new_pane()
            tab_state.restore_tab(new_tab(fresh), { title = "t", pane_tree = { cwd = bad_cwd } }, {
                pane = fresh,
                pane_is_new = true,
            })
            assert.equals("", all_sent(fresh))
        end)
    end
end)
-- ---------------------------------------------------------------------------
-- Where the control files are looked for, and an empty answer
-- ---------------------------------------------------------------------------

describe("restore guard: the control folder", function()
    local real_getenv = os.getenv
    before_each(reset)
    after_each(function() rawset(os, "getenv", real_getenv) end)

    it("an existing but empty control folder is unknown, not 'nothing running'", function()
        control_files({})
        local pane = restore_pane(claude_pane(DEAD))
        assert.equals("", all_sent(pane))
        local line = logged("not resuming session")
        assert.truthy(line and line:find("no control files", 1, true), line)
    end)

    it("a saved copy with resume lines cannot be restored when the control folder is empty", function()
        control_files({})
        instance_manager.instance_id = OWN_ID
        save_instance_file(MIXED_ID, workspace_of(claude_pane(LIVE), claude_pane(DEAD)))
        save_instance_file(SHELLS_ID, workspace_of({ cwd = "C:\\work", text = "PS C:\\work>" }))
        local existing = busy_pane()
        local gui = new_gui_window()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        assert.truthy(gui:choice(MIXED_ID).label:find("cannot tell what is running", 1, true))
        assert.truthy(gui:choice(SHELLS_ID).label:find("^%[ %]"), "a copy with no resume line stays restorable")
    end)

    it("looks under USERPROFILE on Windows even when HOME points elsewhere", function()
        rawset(os, "getenv", function(name)
            if name == "HOME" then return "/c/stray/home" end
            if name == "USERPROFILE" then return "C:\\Users\\me" end
            return real_getenv(name)
        end)
        local dirs = guard.control_dirs()
        assert.equals("C:\\Users\\me\\.claude\\sessions", dirs[1])
        for _, dir in ipairs(dirs) do
            assert.falsy(dir:find("stray", 1, true), dir)
        end
    end)
end)
-- ---------------------------------------------------------------------------
-- A session whose id has changed since the copy was saved
-- ---------------------------------------------------------------------------

describe("restore guard: a running session in the same directory", function()
    before_each(reset)

    -- Claude can give a conversation a new id (compaction, /resume). A saved
    -- copy then holds the old id, which has no control file. The only trace
    -- is that a running session sits in the same directory.
    for _, saved_cwd in ipairs({ "C:\\work\\live", "c:/WORK/Live/", "C:\\work\\live\\", "/C:/work/live" }) do
        it("does not resume an id with no control file when a session runs in " .. saved_cwd, function()
            local pane = restore_pane(claude_pane(OTHER, saved_cwd))
            assert.equals("", all_sent(pane))
            local line = logged("not resuming session dddddddd")
            assert.truthy(line and line:find("same folder", 1, true), line)
            assert.truthy(line:find("pid 4242", 1, true), line)
        end)
    end

    it("resumes it when the running sessions are in other directories", function()
        local pane = restore_pane(claude_pane(OTHER, "C:\\work\\livelier"))
        assert.truthy(all_sent(pane):find(OTHER, 1, true))
    end)

    it("does not resume when the pane has no directory and a session is running", function()
        local tree = claude_pane(OTHER)
        tree.cwd = nil
        tree.process.cwd = nil
        local pane = restore_pane(tree)
        assert.equals("", all_sent(pane))
    end)

    it("a session this restore resumed does not block the next pane of the same directory", function()
        local first = restore_pane(claude_pane(DEAD, "C:\\work\\shared"))
        assert.truthy(all_sent(first):find(DEAD, 1, true))
        -- DEAD has started and written its control file; the reading is renewed.
        control_files({ { DEAD, 9090, START, true, START, "C:\\work\\shared" } })
        guard.get_snapshot(true)
        local second = restore_pane(claude_pane(OTHER, "C:\\work\\shared"))
        assert.truthy(all_sent(second):find(OTHER, 1, true))
    end)

    it("a saved copy holding only such ids cannot be restored", function()
        instance_manager.instance_id = OWN_ID
        save_instance_file(MIXED_ID, workspace_of(claude_pane(OTHER, "C:\\work\\live")))
        local existing = busy_pane()
        local gui = new_gui_window()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        assert.truthy(gui:choice(MIXED_ID).label:find("may be running under a new id", 1, true))
        instance_manager._test.restore_instances({ MIXED_ID }, gui, existing, restore_opts)
        run_timers()
        assert.equals(0, spawned_windows)
        assert.equals("", everything_sent())
    end)
end)
-- ---------------------------------------------------------------------------
-- Browse named saves
-- ---------------------------------------------------------------------------

describe("restore guard: Browse named saves", function()
    local existing, gui
    local dir = state_manager.save_state_dir .. sep

    before_each(function()
        reset()
        instance_manager.instance_id = OWN_ID
        save_instance_file(SAVED_ID, workspace_of(claude_pane(OTHER)))
        existing = busy_pane()
        existing:window().title = "my live window"
        function existing:tab() return existing:window():active_tab() end
        function existing:split()
            self.was_split = true
            return new_pane()
        end
        gui = new_gui_window()
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        gui:pick("__BROWSE_NAMED__", existing)
    end)

    it("a named tab save opens in a new window, not as a split of the pane Alt+R was pressed in", function()
        file_store[dir .. "tab" .. sep .. "notes.json"] = json.encode({ title = "notes", pane_tree = claude_pane(DEAD) })
        fuzzy_callback("tab" .. sep .. "notes.json", "notes")
        run_timers()
        assert.equals(1, spawned_windows)
        assert.is_nil(existing.was_split, "the existing pane must not be split")
        assert.is_nil(existing:tab().title, "the existing tab must not be renamed")
        assert.equals("", all_sent(existing))
        assert.truthy(everything_sent():find(DEAD, 1, true))
    end)

    it("a named window save opens in a new window, not as tabs of the current one", function()
        local window_state = workspace_of(claude_pane(DEAD)).window_states[1]
        window_state.title = "saved window"
        file_store[dir .. "window" .. sep .. "saved.json"] = json.encode(window_state)
        fuzzy_callback("window" .. sep .. "saved.json", "saved")
        run_timers()
        assert.equals(1, spawned_windows)
        assert.equals(0, existing:window().spawned_tabs, "no tab may be added to the current window")
        assert.equals("my live window", existing:window().title, "the current window must keep its title")
        assert.equals("", all_sent(existing))
        assert.truthy(everything_sent():find(DEAD, 1, true))
    end)

    it("decides on a fresh reading of what is running", function()
        file_store[dir .. "tab" .. sep .. "notes.json"] = json.encode({ title = "notes", pane_tree = claude_pane(DEAD) })
        -- DEAD is started elsewhere after the selector took its reading.
        control_files({ { DEAD, 4444, START, true, START, "C:\\elsewhere" } })
        fuzzy_callback("tab" .. sep .. "notes.json", "notes")
        run_timers()
        assert.falsy(everything_sent():find("claude", 1, true))
    end)

    it("a config calling restore_workspace directly also gets a fresh reading", function()
        guard.get_snapshot() -- an earlier reading, still within its 10 seconds
        control_files({ { DEAD, 4444, START, true, START, "C:\\elsewhere" } })
        workspace_state_mod.restore_workspace(workspace_of(claude_pane(DEAD)), {
            on_pane_restore = tab_state.default_on_pane_restore,
        })
        run_timers()
        assert.falsy(everything_sent():find("claude", 1, true))
    end)
end)
-- ---------------------------------------------------------------------------
-- A slow or failing process query
-- ---------------------------------------------------------------------------

describe("restore guard: the process query itself", function()
    local real_time = os.time
    before_each(reset)
    after_each(function() rawset(os, "time", real_time) end)

    it("an answer that took too long is unknown", function()
        local now = real_time()
        rawset(os, "time", function() return now end)
        usual_world()
        local answer = guard.run_query
        guard.run_query = function(...)
            now = now + guard.query_time_limit_seconds + 1 -- the query hangs for a while
            return answer(...)
        end
        local pane = restore_pane(claude_pane(DEAD))
        assert.equals("", all_sent(pane))
        local line = logged("not resuming session")
        assert.truthy(line and line:find("took", 1, true), line)
    end)

    it("a query that reports its own timeout is unknown", function()
        guard.run_query = function()
            return "ERR\tthe process query did not finish in 10 seconds\r\n"
        end
        local pane = restore_pane(claude_pane(DEAD))
        assert.equals("", all_sent(pane))
        assert.truthy(logged("did not finish"))
    end)

    it("the query asks PowerShell to stop its own work after the time limit", function()
        local seen
        wezterm_stub.run_child_process = function(args)
            seen = args
            return true, "END\t0\r\n", ""
        end
        package.loaded["resurrect.restore_guard"] = nil
        local fresh = require("resurrect.restore_guard")
        fresh.run_query({ "C:\\Users\\me\\.claude\\sessions" })
        package.loaded["resurrect.restore_guard"] = guard
        wezterm_stub.run_child_process = function()
            return true, table.concat(listed_instance_ids, "\n"), ""
        end
        local script = seen[#seen]
        assert.truthy(script:find("BeginInvoke", 1, true), "the work runs where it can be abandoned")
        assert.truthy(script:find("WaitOne(" .. fresh.query_time_limit_seconds .. "000)", 1, true), script)
        assert.falsy(script:find('"', 1, true), "no double quotes: it is passed as one argument")
    end)
end)
-- ---------------------------------------------------------------------------
-- When wezterm.GLOBAL does not keep the instance id
-- ---------------------------------------------------------------------------

describe("restore guard: an instance id that is not kept", function()
    before_each(reset)
    after_each(function()
        package.loaded["resurrect.instance_manager"] = instance_manager
    end)

    it("a missing wezterm.GLOBAL does not break the config", function()
        wezterm_stub.GLOBAL = nil
        local fresh
        assert.has_no.errors(function() fresh = reload_config() end)
        assert.truthy(fresh.instance_id:match("^%d+_%d+$"))
        assert.truthy(logged("wezterm.GLOBAL"))
    end)

    it("a wezterm.GLOBAL that cannot be read or written does not break the config", function()
        wezterm_stub.GLOBAL = setmetatable({}, {
            __index = function() error("GLOBAL is not available") end,
            __newindex = function() error("GLOBAL is not available") end,
        })
        local fresh
        assert.has_no.errors(function() fresh = reload_config() end)
        assert.truthy(fresh.instance_id:match("^%d+_%d+$"))
        assert.has_no.errors(function() fresh.rename_instance(fresh.instance_id, "Fleet") end)
    end)

    -- The original fault: every reload a new id, and the previous id's file
    -- left behind as a copy of the windows still open. The copy is then not
    -- recognised as "own", so the running-session rules have to stop it.
    describe("with a new id on every reload", function()
        local PREVIOUS_ID = "1700000005_55555"
        local fresh, existing, gui

        before_each(function()
            control_files({
                { LIVE, 4242, START, true, START, "C:\\work\\a" },
                { OTHER, 4343, START, true, START, "C:\\work\\b" },
            })
            wezterm_stub.GLOBAL = nil -- nothing is kept between evaluations
            reload_config()
            fresh = reload_config()
            assert.are_not.equal(PREVIOUS_ID, fresh.instance_id)
            existing = busy_pane()
            gui = new_gui_window()
        end)

        it("the previous id's copy is refused when all its sessions are running", function()
            save_instance_file(PREVIOUS_ID, workspace_of(claude_pane(LIVE), claude_pane(OTHER)))
            fresh.show_instance_selector(gui, existing, restore_opts)
            assert.truthy(gui:choice(PREVIOUS_ID).label:find("all 2 sessions already running - cannot restore", 1, true))
            gui:pick(PREVIOUS_ID, existing)
            assert.is_nil(gui:choice("__RESTORE_SELECTED__"))

            fresh._test.restore_instances({ PREVIOUS_ID }, gui, existing, restore_opts)
            run_timers()
            assert.equals(0, spawned_windows)
            assert.equals("", everything_sent())
        end)

        it("a partly running copy resumes only the sessions that are not running", function()
            save_instance_file(PREVIOUS_ID, workspace_of(claude_pane(LIVE), claude_pane(DEAD)))
            fresh.show_instance_selector(gui, existing, restore_opts)
            assert.truthy(gui:choice(PREVIOUS_ID).label:find("resumes 1; 1 already running", 1, true))
            gui:pick(PREVIOUS_ID, existing)
            gui:pick("__RESTORE_SELECTED__", existing)
            run_timers()
            assert.truthy(everything_sent():find(DEAD, 1, true))
            assert.falsy(everything_sent():find(LIVE, 1, true))
            assert.equals("", all_sent(existing))
        end)
    end)
end)
-- ---------------------------------------------------------------------------
-- The selector says why, in plain words
-- ---------------------------------------------------------------------------

describe("restore guard: the reason shown for each saved copy", function()
    local existing, gui
    local COPY = "1700000006_66666"
    local A, B, C = "C:\\work\\a", "C:\\work\\b", "C:\\work\\c"

    -- LIVE runs in A. OTHER runs in B but its start time cannot be read.
    local function world()
        control_files({
            { LIVE, 4242, START, true, START, A },
            { OTHER, 4343, START, true, "?", B },
        })
    end

    -- The text in the trailing parentheses of a copy's selector entry.
    local function reason_for(...)
        save_instance_file(COPY, workspace_of(...))
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        local label = gui:choice(COPY).label
        return label:match("%((.-)%)$"), label
    end

    -- What the log says when a person picks the entry anyway.
    local function log_when_picked()
        log = {}
        gui:pick(COPY, existing)
        return logged("cannot be selected") or ""
    end

    local ROTATED = "eeeeeeee-5555-4555-8555-555555555555"
    local ROTATED2 = "ffffffff-6666-4666-8666-666666666666"

    before_each(function()
        reset()
        world()
        instance_manager.instance_id = OWN_ID
        existing = busy_pane()
        gui = new_gui_window()
    end)

    it("this terminal's own live copy", function()
        save_instance_file(OWN_ID, workspace_of(claude_pane(DEAD, C)))
        instance_manager.show_instance_selector(gui, existing, restore_opts)
        local label = gui:choice(OWN_ID).label
        assert.equals("this terminal's own live copy - cannot restore", label:match("%((.-)%)$"))
        assert.truthy(label:find("^%[%-%]"))
        log = {}
        gui:pick(OWN_ID, existing)
        assert.truthy(logged("a snapshot of the windows open now"))
    end)

    it("every session already running", function()
        local reason, label = reason_for(claude_pane(LIVE, A), claude_pane(LIVE, A))
        assert.equals("all 2 sessions already running - cannot restore", reason)
        assert.truthy(label:find("^%[%-%]"))
        assert.truthy(log_when_picked():find("stale copy of running windows", 1, true))
    end)

    it("its one session already running", function()
        assert.equals("its session is already running - cannot restore", reason_for(claude_pane(LIVE, A)))
    end)

    for _, case in ipairs({
        { "control folder not found", function() return "ERR\tcontrol directory not found\r\n" end },
        { "control folder unreadable", function() return "ERR\tAccess to the path is denied.\r\n" end },
        { "control folder is empty", function() return "END\t0\r\n" end },
        { "process query failed", function() return nil, "powershell.exe failed: boom" end },
        { "process query failed", function() return "S\tgarbage\r\n" end },
        { "process query timed out", function() return "ERR\tthe process query did not finish in 10 seconds\r\n" end },
        { "not supported on this system", function() return nil, "the running-session check is only implemented on Windows" end },
        { "a control file is unreadable", function() return "S\t\t77\t\t1\t" .. START .. "\t\r\nEND\t1\r\n" end },
    }) do
        it("cannot tell what is running: " .. case[1], function()
            guard.run_query = case[2]
            local reason, label = reason_for(claude_pane(DEAD, C))
            assert.equals("cannot tell what is running: " .. case[1] .. " - cannot restore", reason)
            assert.truthy(label:find("^%[%-%]"))
            assert.truthy(log_when_picked():find("nothing carrying a resume line is restored", 1, true))
        end)
    end

    it("sessions that may be running under a new id, none resumable", function()
        local reason, label = reason_for(claude_pane(ROTATED, A), claude_pane(ROTATED2, "c:/work/A/"), claude_pane(LIVE, A))
        assert.equals(
            "nothing to resume: 1 already running, 2 may be running under a new id - cannot restore",
            reason
        )
        assert.truthy(label:find("^%[%-%]"))
        local line = log_when_picked()
        assert.truthy(line:find("share a working folder with a running session", 1, true), line)
        assert.truthy(line:find("resume those by hand", 1, true), line)
    end)

    it("a session whose process could not be checked, none resumable", function()
        local reason = reason_for(claude_pane(OTHER, B))
        assert.equals("nothing to resume: 1 could not be checked - cannot restore", reason)
        assert.truthy(log_when_picked():find("start time could not be confirmed", 1, true))
    end)

    it("a saved command that is not a plain resume line", function()
        local odd = claude_pane(DEAD, C)
        odd.process.argv = { "claude", "--resume", DEAD, "--model", "x" }
        local reason, label = reason_for(odd, claude_pane(DEAD, C))
        assert.equals("1 saved command is not a plain resume line - cannot restore", reason)
        assert.truthy(label:find("^%[%-%]"))
        assert.truthy(log_when_picked():find("may have been edited", 1, true))
    end)

    it("a partly restorable copy says what will be resumed, what runs and what is uncertain", function()
        local reason, label = reason_for(
            claude_pane(DEAD, C), claude_pane("abababab-7777-4777-8777-777777777777", "C:\\work\\d"),
            claude_pane(LIVE, A), claude_pane(ROTATED, A), claude_pane(OTHER, B)
        )
        assert.equals("resumes 2; 1 already running; 2 uncertain, left alone", reason)
        assert.truthy(label:find("^%[ %]"), "it can be selected")
    end)

    it("a partly restorable copy leaves out the counts that are zero", function()
        assert.equals("resumes 1; 1 already running", reason_for(claude_pane(DEAD, C), claude_pane(LIVE, A)))
    end)

    it("a copy whose sessions can all be resumed carries no remark", function()
        local reason, label = reason_for(claude_pane(DEAD, C))
        assert.is_nil(reason)
        assert.truthy(label:find("^%[ %]"))
    end)

    it("restoring a partly restorable copy resumes the certain ones and logs why each other was left", function()
        reason_for(claude_pane(DEAD, C), claude_pane(LIVE, A), claude_pane(ROTATED, A))
        gui:pick(COPY, existing)
        gui:pick("__RESTORE_SELECTED__", existing)
        run_timers()
        run_timers()
        assert.truthy(everything_sent():find(DEAD, 1, true))
        assert.falsy(everything_sent():find(LIVE, 1, true))
        assert.falsy(everything_sent():find(ROTATED, 1, true))
        assert.truthy(logged("not resuming session aaaaaaaa.*already running pid 4242"))
        assert.truthy(logged("not resuming session eeeeeeee.*same folder as running pid 4242.*resume it by hand"))
        assert.truthy(logged("1 session resumed, 1 pane left alone because the session is already running, "
            .. "1 pane left alone as uncertain"))
    end)

    it("restore_instances gives the same plain reason when asked to restore a refused copy", function()
        reason_for(claude_pane(ROTATED, A))
        log = {}
        instance_manager._test.restore_instances({ COPY }, gui, existing, restore_opts)
        local line = logged("refusing to restore instance " .. COPY)
        assert.truthy(line and line:find("share a working folder with a running session", 1, true), line)
        assert.equals(0, spawned_windows)
    end)

    it("the startup path that restores without a prompt logs the same plain reason", function()
        local real_open = io.open
        rawset(io, "open", function(path, mode)
            if path == state_manager.save_state_dir .. sep .. "current_state" then
                local lines = { "default", "workspace" }
                return { read = function() return table.remove(lines, 1) end, close = function() end }
            end
            return real_open(path, mode)
        end)
        file_store[state_manager.save_state_dir .. sep .. "workspace" .. sep .. "default.json"] =
            json.encode(workspace_of(claude_pane(LIVE, A)))
        instance_manager.auto_restore_on_startup()
        rawset(io, "open", real_open)
        assert.truthy(logged("not restoring workspace default at startup: its one session is already running"))
    end)
end)