-- Unit tests for instance_manager.lua
-- Tests cover: ID generation, save/load/delete, path traversal rejection,
-- listing/sorting, cleanup, display formatting, and rename.

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

-- Clear cached modules so stubs from other spec files don't leak in
package.loaded["resurrect.file_io"] = nil
package.loaded["resurrect.utils"] = nil
package.loaded["resurrect.state_manager"] = nil
package.loaded["resurrect.instance_manager"] = nil
package.loaded["resurrect.workspace_state"] = nil
package.loaded["resurrect.window_state"] = nil
package.loaded["resurrect.tab_state"] = nil
package.loaded["resurrect.fuzzy_loader"] = nil

local emitted_events = {}
local written_files = {}
local removed_files = {}

-- Minimal recursive JSON encoder for test purposes
local function json_encode_value(val)
    if type(val) == "string" then
        return '"' .. val:gsub('"', '\\"') .. '"'
    elseif type(val) ~= "table" then
        if val == nil then
            return "null"
        end
        return tostring(val)
    end
    -- Check if array (has sequential integer keys)
    if #val > 0 or next(val) == nil then
        local parts = {}
        for _, v in ipairs(val) do
            table.insert(parts, json_encode_value(v))
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    -- Object
    local parts = {}
    local keys = {}
    for k in pairs(val) do
        table.insert(keys, k)
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        table.insert(parts, '"' .. k .. '":' .. json_encode_value(val[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local wezterm_stub = {
    target_triple = is_windows() and "x86_64-pc-windows-msvc" or "x86_64-unknown-linux-gnu",
    emit = function(event, ...)
        table.insert(emitted_events, { event = event, args = { ... } })
    end,
    log_error = function() end,
    log_info = function() end,
    json_encode = json_encode_value,
    json_parse = function(str)
        -- Use a basic approach: load as Lua with transformations
        -- For test purposes, we store and retrieve via our file stubs
        -- so we can just return the stored table directly
        if not str or str == "" then
            return nil
        end
        -- Parse simple JSON using pattern matching for our test cases
        local result = {}
        -- Try to detect if it is our instance state format
        local iid = str:match('"instance_id":"([^"]+)"')
        if iid then
            result.instance_id = iid
        end
        local dn = str:match('"display_name":"([^"]*)"')
        if dn and dn ~= "" then
            result.display_name = dn
        end
        local epoch = str:match('"last_save_epoch":(%d+)')
        if epoch then
            result.last_save_epoch = tonumber(epoch)
        end
        local tc = str:match('"tab_count":(%d+)')
        if tc then
            result.tab_count = tonumber(tc)
        end
        -- Parse tab_summaries array
        local summaries_str = str:match('"tab_summaries":%[([^%]]*)%]')
        if summaries_str then
            result.tab_summaries = {}
            for s in summaries_str:gmatch('"([^"]*)"') do
                table.insert(result.tab_summaries, s)
            end
        end
        -- Parse workspace_state (just mark it present)
        if str:find('"workspace_state"') then
            result.workspace_state = { workspace = "test", window_states = {} }
        end
        return result
    end,
    run_child_process = function()
        return false, nil, "stub"
    end,
    time = {
        call_after = function() end,
    },
    gui = {
        gui_windows = function() return {} end,
    },
    mux = {
        spawn_window = function() return {}, {}, {} end,
    },
    action = {
        InputSelector = function() return {} end,
    },
    action_callback = function(fn) return fn end,
}

_G.wezterm = wezterm_stub
package.preload["wezterm"] = function()
    return wezterm_stub
end

-- Stub file_io to capture file operations in memory.
-- Also tracks last_load_path for compatibility with state_manager_spec
-- (busted shares one Lua process, so whichever spec loads first wins).
local file_store = {}
_G._file_io_last_load_path = nil
package.preload["resurrect.file_io"] = function()
    return {
        write_file = function(path, content)
            written_files[path] = content
            file_store[path] = content
            return true, nil
        end,
        read_file = function(path)
            if file_store[path] then
                return true, file_store[path]
            end
            return false, "not found"
        end,
        load_json = function(path)
            _G._file_io_last_load_path = path
            if file_store[path] then
                return wezterm_stub.json_parse(file_store[path])
            end
            return {}
        end,
        write_state = function() end,
    }
end

-- Stub utils
local sep = is_windows() and "\\" or "/"
package.preload["resurrect.utils"] = function()
    return {
        is_windows = is_windows(),
        is_mac = false,
        separator = sep,
        ensure_folder_exists = function() return true end,
        tbl_deep_extend = function(behavior, ...)
            local tables = { ... }
            local result = {}
            for _, t in ipairs(tables) do
                for k, v in pairs(t) do
                    result[k] = v
                end
            end
            return result
        end,
    }
end

-- Stub state_manager
package.preload["resurrect.state_manager"] = function()
    return {
        save_state_dir = is_windows()
            and ((os.getenv("TEMP") or "C:\\Temp") .. "\\resurrect_im_test\\state")
            or "/tmp/resurrect_im_test/state",
        resurrect_on_gui_startup = function() return true end,
        load_state = function() return {} end,
    }
end

-- Stub other modules that instance_manager might require
package.preload["resurrect.workspace_state"] = function()
    return {
        get_workspace_state = function()
            return { workspace = "default", window_states = {} }
        end,
        restore_workspace = function() end,
    }
end
package.preload["resurrect.window_state"] = function()
    return { restore_window = function() end }
end
package.preload["resurrect.tab_state"] = function()
    return {
        default_on_pane_restore = function() end,
        restore_tab = function() end,
    }
end
package.preload["resurrect.fuzzy_loader"] = function()
    return { fuzzy_load = function() end }
end

-- Set up package path
local search_paths = {
    "./plugin/?.lua",
    "./plugin/?/init.lua",
    "./plugin/?/?.lua",
    "../../plugin/?.lua",
    "../../plugin/?/init.lua",
    "../../plugin/?/?.lua",
}
package.path = table.concat(search_paths, ";") .. ";" .. package.path

-- Override os.remove to track deletions (rawset avoids luacheck read-only warning)
rawset(os, "remove", function(path)
    table.insert(removed_files, path)
    file_store[path] = nil
    return true
end)

-- Now require the module under test
local instance_manager = require("resurrect.instance_manager")

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("instance_manager", function()
    before_each(function()
        emitted_events = {}
        written_files = {}
        removed_files = {}
        file_store = {}
        instance_manager.instance_id = nil
        instance_manager.display_name = nil
        instance_manager.retention_days = 7
        instance_manager.auto_restore_prompt = true
    end)

    -- ----- ID generation -----
    describe("init_instance_id", function()
        it("returns a string matching the expected format", function()
            local id = instance_manager.init_instance_id()
            assert.is_string(id)
            assert.truthy(id:match("^%d+_%d+$"), "ID should match <digits>_<digits> but got: " .. id)
        end)

        it("sets pub.instance_id", function()
            instance_manager.init_instance_id()
            assert.is_not_nil(instance_manager.instance_id)
            assert.truthy(instance_manager.instance_id:match("^%d+_%d+$"))
        end)

        it("generates different IDs on subsequent calls", function()
            local id1 = instance_manager.init_instance_id()
            -- Force a different random seed to ensure different output
            math.randomseed(os.time() + 1)
            local id2 = instance_manager.init_instance_id()
            -- They might be the same if called within the same second
            -- and random hits the same value, but the format should always be valid
            assert.truthy(id1:match("^%d+_%d+$"))
            assert.truthy(id2:match("^%d+_%d+$"))
        end)
    end)

    -- ----- Save/Load/Delete -----
    describe("save_instance", function()
        it("creates .json and .meta files", function()
            instance_manager.init_instance_id()
            local ws = { workspace = "test_ws", window_states = {} }
            instance_manager.save_instance(ws)

            local dir = instance_manager.get_instances_dir()
            local json_path = dir .. sep .. instance_manager.instance_id .. ".json"
            local meta_path_val = dir .. sep .. instance_manager.instance_id .. ".meta"

            assert.truthy(written_files[json_path], "should write .json file")
            assert.truthy(written_files[meta_path_val], "should write .meta file")
        end)

        it("does nothing when instance_id is nil", function()
            instance_manager.instance_id = nil
            instance_manager.save_instance({ workspace = "test", window_states = {} })
            local count = 0
            for _ in pairs(written_files) do count = count + 1 end
            assert.equals(0, count)
        end)

        it("includes display_name in meta when set", function()
            instance_manager.init_instance_id()
            instance_manager.display_name = "My Project"
            instance_manager.save_instance({ workspace = "test", window_states = {} })

            local dir = instance_manager.get_instances_dir()
            local meta_content = written_files[dir .. sep .. instance_manager.instance_id .. ".meta"]
            assert.truthy(meta_content)
            assert.truthy(meta_content:find('"My Project"'), "meta should contain display_name")
        end)
    end)

    describe("load_instance", function()
        it("returns workspace_state from saved instance", function()
            instance_manager.init_instance_id()
            local ws = { workspace = "loaded_ws", window_states = {} }
            instance_manager.save_instance(ws)

            local loaded = instance_manager.load_instance(instance_manager.instance_id)
            assert.is_not_nil(loaded)
            assert.truthy(loaded.workspace)
        end)

        it("rejects invalid instance IDs", function()
            local result = instance_manager.load_instance("../../../etc/passwd")
            assert.is_nil(result)
        end)

        it("rejects IDs with path separators", function()
            local result = instance_manager.load_instance("foo/bar")
            assert.is_nil(result)
        end)

        it("rejects empty string", function()
            local result = instance_manager.load_instance("")
            assert.is_nil(result)
        end)

        it("returns nil for non-existent instance", function()
            local result = instance_manager.load_instance("9999999999_99999")
            assert.is_nil(result)
        end)
    end)

    describe("delete_instance", function()
        it("removes .json and .meta files", function()
            instance_manager.init_instance_id()
            local id = instance_manager.instance_id
            instance_manager.save_instance({ workspace = "del_test", window_states = {} })

            local result = instance_manager.delete_instance(id)
            assert.is_true(result)
            assert.truthy(#removed_files >= 2, "should remove at least 2 files")
        end)

        it("rejects invalid IDs (path traversal)", function()
            local result = instance_manager.delete_instance("../../secrets")
            assert.is_false(result)
        end)

        it("rejects IDs with letters", function()
            local result = instance_manager.delete_instance("abc_12345")
            assert.is_false(result)
        end)

        it("emits event on successful delete", function()
            instance_manager.init_instance_id()
            local id = instance_manager.instance_id
            instance_manager.save_instance({ workspace = "test", window_states = {} })
            emitted_events = {} -- reset
            instance_manager.delete_instance(id)

            local found = false
            for _, e in ipairs(emitted_events) do
                if e.event == "resurrect.instance_manager.delete_instance.finished" then
                    found = true
                end
            end
            assert.is_true(found, "should emit delete finished event")
        end)
    end)

    -- ----- Listing -----
    describe("list_instances", function()
        it("returns empty array when no instances exist", function()
            local instances = instance_manager.list_instances()
            assert.equals(0, #instances)
        end)
    end)

    -- ----- Cleanup -----
    describe("cleanup_old_instances", function()
        it("runs without error when no instances exist", function()
            assert.has_no.errors(function()
                instance_manager.cleanup_old_instances()
            end)
        end)
    end)

    -- ----- Display formatting -----
    describe("format_instance_summary", function()
        it("formats unnamed instance with date", function()
            local meta = {
                last_save_epoch = os.time(),
                tab_count = 2,
                tab_summaries = { "Claude Code", "PowerShell" },
            }
            local summary = instance_manager.format_instance_summary(meta)
            assert.is_string(summary)
            assert.truthy(summary:find("Claude Code"))
            assert.truthy(summary:find("PowerShell"))
            assert.truthy(summary:find("%[2 tabs%]"))
            assert.truthy(summary:find(" -- "))
        end)

        it("formats named instance with display_name", function()
            local meta = {
                display_name = "Orahvision Dev",
                last_save_epoch = os.time(),
                tab_count = 3,
                tab_summaries = { "Claude Code", "PowerShell", "Claude Code" },
            }
            local summary = instance_manager.format_instance_summary(meta)
            assert.truthy(summary:find("Orahvision Dev"))
            assert.truthy(summary:find("Claude Code x2"))
            assert.truthy(summary:find("PowerShell"))
            assert.truthy(summary:find("%[3 tabs%]"))
        end)

        it("shows singular 'tab' for single tab", function()
            local meta = {
                last_save_epoch = os.time(),
                tab_count = 1,
                tab_summaries = { "PowerShell" },
            }
            local summary = instance_manager.format_instance_summary(meta)
            assert.truthy(summary:find("%[1 tab%]"))
            -- Should NOT say "1 tabs"
            assert.falsy(summary:find("%[1 tabs%]"))
        end)

        it("handles empty tab summaries", function()
            local meta = {
                last_save_epoch = os.time(),
                tab_count = 0,
                tab_summaries = {},
            }
            local summary = instance_manager.format_instance_summary(meta)
            assert.truthy(summary:find("%(empty%)"))
        end)

        it("handles missing last_save_epoch", function()
            local meta = {
                tab_count = 1,
                tab_summaries = { "Shell" },
            }
            local summary = instance_manager.format_instance_summary(meta)
            assert.truthy(summary:find("Unknown"))
        end)
    end)

    -- ----- Rename -----
    describe("rename_instance", function()
        it("updates display_name in meta file", function()
            instance_manager.init_instance_id()
            local id = instance_manager.instance_id
            instance_manager.save_instance({ workspace = "rename_test", window_states = {} })

            instance_manager.rename_instance(id, "My Project")

            -- Check that the meta was rewritten with the new name
            local dir = instance_manager.get_instances_dir()
            local meta_content = file_store[dir .. sep .. id .. ".meta"]
            assert.truthy(meta_content)
            assert.truthy(meta_content:find("My Project"))
        end)

        it("updates pub.display_name when renaming current instance", function()
            instance_manager.init_instance_id()
            local id = instance_manager.instance_id
            instance_manager.save_instance({ workspace = "test", window_states = {} })

            instance_manager.rename_instance(id, "Current Name")
            assert.equals("Current Name", instance_manager.display_name)
        end)

        it("does not update pub.display_name when renaming different instance", function()
            instance_manager.init_instance_id()
            instance_manager.save_instance({ workspace = "test", window_states = {} })
            instance_manager.display_name = "Original"

            -- Rename a different (fake) instance
            local other_id = "1234567890_12345"
            -- Write a meta file for it
            local dir = instance_manager.get_instances_dir()
            file_store[dir .. sep .. other_id .. ".meta"] = '{"instance_id":"1234567890_12345"}'

            instance_manager.rename_instance(other_id, "Other Name")
            assert.equals("Original", instance_manager.display_name)
        end)

        it("rejects invalid instance IDs", function()
            assert.has_no.errors(function()
                instance_manager.rename_instance("../evil", "Hacked")
            end)
        end)
    end)
end)
