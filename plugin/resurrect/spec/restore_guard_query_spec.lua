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

    -- Real processes with real command lines. The script reads the whole
    -- machine, so these only look at ids made up here. The stand-in sleeps
    -- and ignores its arguments; it ends by itself if teardown never runs.
    describe("live claude command lines", function()
        local ON_CLAUDE = "a1a1a1a1-0000-4000-8000-000000000001"
        local ON_CLAUDE2 = "a1a1a1a1-0000-4000-8000-000000000002"
        local ON_DASHED = "a1a1a1a1-0000-4000-8000-000000000003"
        local QUOTED = "a1a1a1a1-0000-4000-8000-000000000004"
        local ON_HOST = "a1a1a1a1-0000-4000-8000-000000000005"
        local ON_STRANGER = "a1a1a1a1-0000-4000-8000-000000000006"
        local ON_LOOKALIKE = "a1a1a1a1-0000-4000-8000-000000000007"
        local SUFFIXED = "a1a1a1a1-0000-4000-8000-000000000008"
        local PREFIXED_FLAG = "a1a1a1a1-0000-4000-8000-000000000009"
        local UPPER = "A1A1A1A1-0000-4000-8000-00000000000A"
        local HOST_IN_TEXT = "a1a1a1a1-0000-4000-8000-00000000000b"
        local HOST_AFTER = "a1a1a1a1-0000-4000-8000-00000000000c"
        local IN_TEXT = "a1a1a1a1-0000-4000-8000-00000000000d"
        local WHOLE_VALUE = "a1a1a1a1-0000-4000-8000-00000000000e"
        local ESCAPED = "a1a1a1a1-0000-4000-8000-00000000000f"
        local AFTER_DASHES = "a1a1a1a1-0000-4000-8000-000000000010"
        local pids = {}
        local dir = ROOT .. "\\bin"

        local function start(exe, arguments)
            return 'Start-Process -PassThru -WindowStyle Hidden -FilePath "' .. dir .. "\\" .. exe .. '" '
                .. "-ArgumentList '" .. arguments .. "' | ForEach-Object { $_.Id };"
        end

        setup(function()
            mkdir(dir)
            local out = run_powershell(table.concat({
                "Add-Type -OutputAssembly '" .. dir .. "\\sleeper.exe' -OutputType ConsoleApplication",
                " -TypeDefinition 'class P { static void Main() { System.Threading.Thread.Sleep(120000); } }';",
                "foreach ($n in 'claude-wezspec.exe', 'claude2.exe', 'wezspec-other.exe', 'claudette-wezspec.exe') {",
                " Copy-Item -LiteralPath '" .. dir .. "\\sleeper.exe' -Destination (Join-Path '" .. dir .. "' $n) };",
                start("claude-wezspec.exe", "--resume " .. ON_CLAUDE .. " --dangerously-skip-permissions"),
                start("claude2.exe", "--resume " .. ON_CLAUDE2),
                start("claude-wezspec.exe", "--verbose --resume " .. ON_DASHED),
                start("claude-wezspec.exe", '--resume "' .. QUOTED .. '"'),
                start("claude-wezspec.exe", "--chrome-native-host --resume " .. ON_HOST),
                start("wezspec-other.exe", "--resume " .. ON_STRANGER),
                start("claudette-wezspec.exe", "--resume " .. ON_LOOKALIKE),
                start("claude-wezspec.exe", "--resume " .. SUFFIXED .. "-extra"),
                start("claude-wezspec.exe", "--no--resume " .. PREFIXED_FLAG),
                start("claude-wezspec.exe", "--resume " .. UPPER),
                start("claude-wezspec.exe", "--resume " .. HOST_IN_TEXT
                    .. ' --append-system-prompt "about --chrome-native-host here"'),
                start("claude-wezspec.exe", "--resume " .. HOST_AFTER .. " --chrome-native-host"),
                start("claude-wezspec.exe", '--append-system-prompt "see --resume ' .. IN_TEXT .. ' for more"'),
                start("claude-wezspec.exe", '--append-system-prompt "--resume ' .. WHOLE_VALUE .. '"'),
                start("claude-wezspec.exe", '--append-system-prompt "say \\" --resume ' .. ESCAPED
                    .. ' \\" now"'),
                start("claude-wezspec.exe", "-- --resume " .. AFTER_DASHES),
            }, " "))
            for pid in out:gmatch("%d+") do table.insert(pids, pid) end
            assert.equals(16, #pids, "the stand-in processes did not start: " .. out)
        end)

        teardown(function()
            if #pids > 0 then
                -- Only the pids this spec started, and wait so the folder can go.
                local list = table.concat(pids, ",")
                run_powershell("Stop-Process -Id " .. list .. " -ErrorAction SilentlyContinue;"
                    .. "Wait-Process -Id " .. list .. " -Timeout 10 -ErrorAction SilentlyContinue")
            end
        end)

        before_each(function()
            guard.control_dirs = function() return { CTL } end
            guard.marker_dir = function() return ROOT .. "\\missing" end
        end)

        local function live_pid(snapshot, id)
            local session = snapshot.sessions[id]
            return session and session.state == "live" and session.pid or nil
        end

        it("reads each supported claude variant as live, whatever else is on the line", function()
            local snapshot = guard.get_snapshot(true)
            assert.is_nil(snapshot.error)
            assert.equals(tonumber(pids[1]), live_pid(snapshot, ON_CLAUDE))
            assert.equals(tonumber(pids[2]), live_pid(snapshot, ON_CLAUDE2))
            assert.equals(tonumber(pids[3]), live_pid(snapshot, ON_DASHED))
            assert.equals(tonumber(pids[4]), live_pid(snapshot, QUOTED))
        end)

        it("ignores a native host, another program, a lookalike name and a word that is not the id", function()
            local snapshot = guard.get_snapshot(true)
            assert.is_nil(snapshot.error)
            assert.is_nil(snapshot.sessions[ON_HOST], "--chrome-native-host")
            assert.is_nil(snapshot.sessions[ON_STRANGER], "a program not named claude")
            assert.is_nil(snapshot.sessions[ON_LOOKALIKE], "claudette is not a claude variant")
            assert.is_nil(snapshot.sessions[SUFFIXED], "more text after the id")
            assert.is_nil(snapshot.sessions[PREFIXED_FLAG], "a flag that only ends in --resume")
            assert.is_nil(snapshot.sessions[UPPER:lower()], "not a lower-case id")
        end)

        it("a --chrome-native-host that is not the first argument does not hide a real resume", function()
            local snapshot = guard.get_snapshot(true)
            assert.is_nil(snapshot.error)
            assert.equals(tonumber(pids[11]), live_pid(snapshot, HOST_IN_TEXT), "inside another flag's text")
            assert.equals(tonumber(pids[12]), live_pid(snapshot, HOST_AFTER), "a word of its own, after --resume")
        end)

        it("an id quoted inside another flag's text is not a resume of it", function()
            local snapshot = guard.get_snapshot(true)
            assert.is_nil(snapshot.error)
            assert.is_nil(snapshot.sessions[IN_TEXT], "inside a sentence")
            assert.is_nil(snapshot.sessions[WHOLE_VALUE], "the whole of one quoted argument")
            assert.is_nil(snapshot.sessions[AFTER_DASHES], "after --, where nothing is a flag")
        end)

        it("splits arguments the way Windows does, escaped quotes included", function()
            -- The escaped quotes close nothing: the id is inside the text.
            local snapshot = guard.get_snapshot(true)
            assert.is_nil(snapshot.error)
            assert.is_nil(snapshot.sessions[ESCAPED])
        end)

        it("a process list that cannot be read makes the whole answer an error", function()
            local original = wezterm_stub.run_child_process
            wezterm_stub.run_child_process = function(args)
                -- A real CIM failure, through the script's real error path.
                local script = args[#args]
                local broken, hits = script:gsub("Win32_Process %-Filter 'Name", "NoSuchClassWezspec -Filter 'Name")
                assert.equals(1, hits, "the process list query was not found")
                args[#args] = broken
                return original(args)
            end
            local ok, snapshot = pcall(guard.get_snapshot, true)
            wezterm_stub.run_child_process = original
            assert.is_true(ok, snapshot)
            assert.truthy(snapshot.error and snapshot.error:find("process list unreadable", 1, true), snapshot.error)
            assert.equals("process list unreadable", snapshot.error_label)
        end)
    end)

    -- A real stand-in process, through the real script. Stopped by its own pid.
    it("a matching procStart reads live even when the file's time is older than the process", function()
        local dir = ROOT .. "\\ctl-clockback"
        local sid = "ce19dc26-7a4b-4c1e-9d2f-3b5a6c7d8e90"
        mkdir(dir)
        local out = run_powershell("$p = Start-Process -PassThru -WindowStyle Hidden -FilePath powershell.exe "
            .. "-ArgumentList '-NoProfile','-Command','Start-Sleep 60';"
            .. "$p.Id; $p.StartTime.ToFileTimeUtc()")
        local pid, started = out:match("(%d+)%s+(%d+)")
        assert.truthy(pid, "the stand-in did not start: " .. out)
        local file = dir .. "\\" .. pid .. ".json"
        write(file, '{"sessionId":"' .. sid .. '","pid":' .. pid .. ',"procStart":"' .. started
            .. '","cwd":"C:\\\\work"}')
        run_powershell("(Get-Item -LiteralPath '" .. file .. "').LastWriteTimeUtc = [datetime]'2000-01-01 00:00:00Z'")
        guard.control_dirs = function() return { dir } end
        guard.marker_dir = function() return ROOT .. "\\missing" end
        local ok, snapshot = pcall(guard.get_snapshot, true)
        run_powershell("Stop-Process -Id " .. pid .. " -ErrorAction SilentlyContinue")
        assert.is_true(ok, snapshot)
        assert.is_nil(snapshot.error)
        assert.equals("live", snapshot.sessions[sid].state)
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
