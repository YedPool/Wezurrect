-- The REAL process query: restore_guard.run_query's PowerShell script run by
-- powershell.exe against temporary folders. Windows only; elsewhere these
-- tests are skipped (the guard refuses everything there anyway).

local is_windows = package.config:sub(1, 1) == "\\"
local describe_windows = is_windows and describe or pending

for _, name in ipairs({ "utils", "restore_guard", "file_io" }) do
    package.loaded["resurrect." .. name] = nil
    package.preload["resurrect." .. name] = nil
end
package.loaded["wezterm"] = nil

local TEMP = os.getenv("TEMP") or "."
local ROOT = TEMP .. "\\wezurrect-query-spec-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000))

-- powershell.exe -File on a script file: no quoting through cmd.exe.
local function run_powershell(script)
    local path = ROOT .. "\\query.ps1"
    local f = assert(io.open(path, "w"))
    f:write(script)
    f:close()
    local p = assert(io.popen('powershell.exe -NoProfile -NonInteractive -File "' .. path .. '"'))
    local out = p:read("a")
    p:close()
    return out
end

local wezterm_stub = {
    target_triple = "x86_64-pc-windows-msvc",
    GLOBAL = {},
    log_info = function() end, log_warn = function() end, log_error = function() end,
    nerdfonts = setmetatable({}, { __index = function() return "" end }),
    run_child_process = function(args) return true, run_powershell(args[#args]), "" end,
    time = { call_after = function() end },
}
package.loaded["wezterm"] = wezterm_stub
package.preload["wezterm"] = function() return wezterm_stub end
_G.wezterm = wezterm_stub

package.path = "./plugin/?.lua;./plugin/?/init.lua;" .. package.path

local function mkdir(path) os.execute('mkdir "' .. path .. '" 2>nul') end
local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

describe_windows("restore guard: the real process query", function()
    local guard
    local CTL = ROOT .. "\\ctl"
    local MARKERS = ROOT .. "\\no-restore"
    local LIVE_ID = "aaaaaaaa-1111-4111-8111-111111111111"

    setup(function()
        mkdir(ROOT)
        mkdir(CTL)
        mkdir(MARKERS)
        -- A control file whose pid (4000000) is not running.
        write(CTL .. "\\4000000.json", '{"sessionId":"' .. LIVE_ID .. '","pid":4000000,"procStart":"1","cwd":"C:\\\\x"}')
        write(MARKERS .. "\\bbbbbbbb-2222-4222-8222-222222222222.json",
            '{"v":1,"sessionId":"bbbbbbbb-2222-4222-8222-222222222222","by":"fleet park","reason":"parked"}')
        write(MARKERS .. "\\CCCCCCCC-3333-4333-8333-333333333333.JSON", "not json {")
        mkdir(MARKERS .. "\\dddddddd-4444-4444-8444-444444444444.json")
        write(MARKERS .. "\\eeeeeeee-5555-4555-8555-555555555555.json.tmp", "{}")
        guard = require("resurrect.restore_guard")
        guard.control_dirs = function() return { CTL } end
    end)

    teardown(function()
        os.execute('rmdir /s /q "' .. ROOT .. '"')
    end)

    before_each(function() guard._test.reset() end)

    it("lists every marker, readable or not, and none that is only a temporary file", function()
        guard.marker_dir = function() return MARKERS end
        local snapshot = guard.get_snapshot(true)
        assert.is_nil(snapshot.error)
        assert.same({ reason = "parked", by = "fleet park" }, snapshot.parked["bbbbbbbb-2222-4222-8222-222222222222"])
        assert.truthy(snapshot.parked["cccccccc-3333-4333-8333-333333333333"], "unparsable, upper-case name")
        assert.truthy(snapshot.parked["dddddddd-4444-4444-8444-444444444444"], "a folder named like a marker")
        assert.is_nil(snapshot.parked["eeeeeeee-5555-4555-8555-555555555555"])
        assert.equals("dead", snapshot.sessions[LIVE_ID].state)
    end)

    it("a marker folder that does not exist means no markers", function()
        guard.marker_dir = function() return ROOT .. "\\missing" end
        local snapshot = guard.get_snapshot(true)
        assert.is_nil(snapshot.error)
        assert.same({}, snapshot.parked)
    end)

    it("a marker path that is a file makes the whole answer an error", function()
        guard.marker_dir = function() return CTL .. "\\4000000.json" end
        local snapshot = guard.get_snapshot(true)
        assert.truthy(snapshot.error and snapshot.error:find("marker", 1, true), snapshot.error)
        assert.equals("no-restore markers unreadable", snapshot.error_label)
    end)
end)
