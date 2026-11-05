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

    -- Windows hides StartTime of other users' processes from a non-elevated
    -- caller (Get-Process returns the process, StartTime is empty). A pid
    -- reused by such a process after a reboot made a stale control file read
    -- as "running, start time unknown". Needs a live pid like that.
    local function find_unreadable_pid()
        local out = run_powershell(
            "foreach ($p in Get-Process) { $ok = $true; "
            .. "try { [void]$p.StartTime.ToFileTimeUtc() } catch { $ok = $false }; "
            .. "if (-not $ok) { $p.Id; break } }")
        return tonumber(out:match("%d+"))
    end

    it("a pid whose StartTime cannot be read still gets a start time and a reused pid reads dead", function()
        local pid = find_unreadable_pid()
        if not pid then
            return pending("no running process with an unreadable StartTime on this machine")
        end
        local dir = ROOT .. "\\ctl-reused"
        local sid = "ce19dc26-7a4b-4c1e-9d2f-3b5a6c7d8e9f"
        mkdir(dir)
        write(dir .. "\\" .. pid .. ".json", '{"sessionId":"' .. sid .. '","pid":' .. pid
            .. ',"procStart":"134369884913177861","cwd":"C:\\\\work"}')
        guard.control_dirs = function() return { dir } end
        guard.marker_dir = function() return ROOT .. "\\missing" end
        local snapshot = guard.get_snapshot(true)
        assert.is_nil(snapshot.error)
        local record = snapshot.records[1]
        assert.equals(pid, record.pid)
        assert.is_true(record.running)
        assert.is_truthy(record.start_time:match("^%d+$"), "start time was " .. tostring(record.start_time))
        assert.equals("dead", snapshot.sessions[sid].state)
    end)

    it("an unparseable control file older than the process of its pid reads dead, a fresh one does not", function()
        local pid = find_unreadable_pid()
        if not pid then
            return pending("no running process with an unreadable StartTime on this machine")
        end
        local dir = ROOT .. "\\ctl-garbage"
        mkdir(dir)
        local file = dir .. "\\" .. pid .. ".json"
        write(file, "not json {")
        guard.control_dirs = function() return { dir } end
        guard.marker_dir = function() return ROOT .. "\\missing" end
        -- Just written: after the process started, so it may be that process's file.
        local fresh = guard.get_snapshot(true)
        assert.truthy(fresh.error and fresh.error:find("could not be read", 1, true), tostring(fresh.error))
        guard._test.reset()
        run_powershell("(Get-Item -LiteralPath '" .. file .. "').LastWriteTimeUtc = [datetime]'2000-01-01 00:00:00Z'")
        local aged = guard.get_snapshot(true)
        assert.is_nil(aged.error)
        assert.equals("dead", aged.records[1].state)
    end)

    it("passes the query as one argument without double quotes or newlines", function()
        local seen
        local original = wezterm_stub.run_child_process
        wezterm_stub.run_child_process = function(args)
            seen = args[#args]
            return original(args)
        end
        guard.control_dirs = function() return { CTL } end
        guard.marker_dir = function() return MARKERS end
        local ok = pcall(guard.get_snapshot, true)
        wezterm_stub.run_child_process = original
        assert.is_true(ok)
        assert.is_nil(seen:find('"', 1, true))
        assert.is_nil(seen:find("%c"))
    end)
end)
