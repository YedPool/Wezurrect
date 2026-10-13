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
    function window:set_title() end
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
package.preload["resurrect.fuzzy_loader"] = function()
    return { fuzzy_load = function() end }
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

    it("does not send --continue into a directory that has a running session", function()
        local tree = claude_pane(LIVE, "C:/work/live/")
        tree.process.argv = { "claude" }
        local pane = restore_pane(tree)
        assert.equals("", all_sent(pane))
    end)

    it("sends --continue into a directory with no running session", function()
        local tree = claude_pane(LIVE, "C:\\work\\elsewhere")
        tree.process.argv = { "claude" }
        local pane = restore_pane(tree)
        assert.truthy(all_sent(pane):find("claude --continue", 1, true))
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
        assert.truthy(own.label:find("live %- this terminal, cannot restore"), own.label)
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