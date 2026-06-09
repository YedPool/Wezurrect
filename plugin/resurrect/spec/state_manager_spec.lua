local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

-- Clear any previously cached modules AND preloads from other spec files
-- (busted shares one Lua process, so earlier specs may have loaded different stubs).
package.loaded["resurrect.file_io"] = nil
package.loaded["resurrect.state_manager"] = nil
package.loaded["resurrect.utils"] = nil
package.loaded["resurrect.instance_manager"] = nil
package.loaded["wezterm"] = nil
package.preload["resurrect.file_io"] = nil
package.preload["resurrect.state_manager"] = nil
package.preload["resurrect.utils"] = nil
package.preload["resurrect.instance_manager"] = nil

-- Minimal wezterm stub (needs log_error/log_info for instance_manager compat).
local wezterm_stub = {
  target_triple = is_windows() and "x86_64-pc-windows-msvc" or "x86_64-unknown-linux-gnu",
  emit = function() end,
  log_error = function() end,
  log_info = function() end,
  -- list_dated_backups shells out via this; stubbed empty so it returns no
  -- prior backups (which is what a fresh-test state would actually show).
  run_child_process = function() return false, nil, "stub" end,
}
_G.wezterm = wezterm_stub
package.loaded["wezterm"] = wezterm_stub
package.preload["wezterm"] = function()
  return wezterm_stub
end

-- Stub file_io with an in-memory file store so backup-rotation tests can
-- verify that previous content lands in .bak and dated archives correctly.
local last_load_path
local file_store = {}
local move_calls = {}
local write_calls = {}
local removed_paths = {}

-- Capture os.remove so we can assert backup pruning without touching disk.
rawset(os, "remove", function(path)
  table.insert(removed_paths, path)
  file_store[path] = nil
  return true
end)

package.loaded["resurrect.file_io"] = {
  load_json = function(path)
    last_load_path = path
    return {}
  end,
  write_state = function(path, state)
    -- Mark the canonical file present after a save (state_manager.save_state
    -- calls write_state immediately after rotate_backup).
    file_store[path] = "<canonical>"
    table.insert(write_calls, { path = path, kind = "state" })
  end,
  write_file = function(path, content)
    file_store[path] = content
    table.insert(write_calls, { path = path, kind = "file", content = content })
    return true, nil
  end,
  read_file = function(path)
    if file_store[path] == nil then
      return false, "not found"
    end
    return true, file_store[path]
  end,
  file_exists = function(path)
    return file_store[path] ~= nil
  end,
  move_file = function(src, dst)
    if file_store[src] == nil then
      return false, "missing"
    end
    file_store[dst] = file_store[src]
    file_store[src] = nil
    table.insert(move_calls, { src = src, dst = dst })
    return true, nil
  end,
}

-- Stub instance_manager so state_manager's require doesn't pull in the real module
package.loaded["resurrect.instance_manager"] = {
  instance_id = nil,
  save_instance = function() end,
}

-- Stub workspace_state for save_workspace_full
package.loaded["resurrect.workspace_state"] = {
  get_workspace_state = function()
    return { workspace = "test", window_states = {} }
  end,
}

-- Stub utils so ensure_folder_exists is a no-op
package.loaded["resurrect.utils"] = nil
local sep_for_stub = package.config:sub(1, 1)
package.preload["resurrect.utils"] = function()
  return {
    is_windows = sep_for_stub == "\\",
    is_mac = false,
    separator = sep_for_stub,
    ensure_folder_exists = function() return true end,
  }
end

local search_paths = {
  -- repo root
  "./plugin/?.lua",
  "./plugin/?/init.lua",
  "./plugin/?/?.lua",
  -- when cwd is plugin/resurrect
  "../../plugin/?.lua",
  "../../plugin/?/init.lua",
  "../../plugin/?/?.lua",
}

package.path = table.concat(search_paths, ";") .. ";" .. package.path

local state_manager = require("resurrect.state_manager")

local sep = is_windows() and "\\" or "/"
local base = is_windows()
  and ((os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp") .. "\\resurrect_sm_test")
  or "/tmp/resurrect_sm_test"

-- get_file_path is a local function and cannot be called directly.
-- These tests exercise it via load_state(), which passes its return value
-- straight to file_io.load_json() with no intervening transformation.
describe("state_manager path construction (via load_state)", function()
  before_each(function()
    last_load_path = nil
    state_manager.save_state_dir = base
  end)

  it("separates save_state_dir and type with a path separator", function()
    state_manager.load_state("myworkspace", "workspace")
    assert.equals(base .. sep .. "workspace" .. sep .. "myworkspace.json", last_load_path)
  end)

  it("replaces path separator characters in file names with +", function()
    state_manager.load_state("foo" .. sep .. "bar", "workspace")
    assert.equals(base .. sep .. "workspace" .. sep .. "foo+bar.json", last_load_path)
  end)

  it("replaces reserved characters : [ ] ? / in file names with +", function()
    state_manager.load_state("name:with[reserved]chars?and/slashes", "window")
    assert.equals(
      base .. sep .. "window" .. sep .. "name+with+reserved+chars+and+slashes.json",
      last_load_path
    )
  end)
end)

describe("state_manager save_state backup rotation", function()
  before_each(function()
    file_store = {}
    move_calls = {}
    write_calls = {}
    removed_paths = {}
    state_manager.save_state_dir = base
    state_manager.backup_retention_count = 10
  end)

  it("does NOT create .bak on the first save (no prior file)", function()
    state_manager.save_state({ workspace = "fresh", window_states = {} })
    -- No move calls because file_exists returned false for the canonical path
    assert.equals(0, #move_calls)
  end)

  it("rotates previous content into .bak on the second save", function()
    -- First save populates the canonical file (via write_state stub)
    state_manager.save_state({ workspace = "rotate_ws", window_states = {} })
    move_calls = {}
    -- Second save: rotate_backup should move canonical -> .bak before writing
    state_manager.save_state({ workspace = "rotate_ws", window_states = {} })

    assert.equals(1, #move_calls, "exactly one move (canonical -> .bak)")
    local m = move_calls[1]
    local expected_canonical = base .. sep .. "workspace" .. sep .. "rotate_ws.json"
    assert.equals(expected_canonical, m.src)
    assert.equals(expected_canonical .. ".bak", m.dst)
  end)

  it("writes a dated archive copy to .backups/", function()
    state_manager.save_state({ workspace = "dated_ws", window_states = {} })
    write_calls = {}
    state_manager.save_state({ workspace = "dated_ws", window_states = {} })

    -- Look for a write_file call landing in .backups/ with the timestamped
    -- "dated_ws.YYYYMMDD-HHMMSS.json" tail. Match on substring and pattern
    -- on the filename only (avoids backslash/pattern-escape pitfalls).
    local found = false
    for _, w in ipairs(write_calls) do
      if w.kind == "file" and w.path:find(".backups", 1, true) then
        local tail = w.path:match("[^/\\]+$") or ""
        if tail:match("^dated_ws%.%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.json$") then
          found = true
        end
      end
    end
    assert.is_true(found, "expected a dated archive write in .backups/")
  end)

  it("skips dated archive when backup_retention_count = 0", function()
    state_manager.save_state({ workspace = "no_dated", window_states = {} })
    state_manager.backup_retention_count = 0
    write_calls = {}
    state_manager.save_state({ workspace = "no_dated", window_states = {} })

    for _, w in ipairs(write_calls) do
      assert.is_nil(w.path:find(".backups"), "should not write to .backups/ when disabled")
    end
    -- But the rolling .bak should still happen
    assert.is_true(#move_calls > 0, "rolling .bak still rotates")
  end)

  it("also rotates window saves (state.tabs branch)", function()
    -- First save: populates canonical
    state_manager.save_state({ title = "win1", tabs = {} })
    move_calls = {}
    -- Second save: should rotate
    state_manager.save_state({ title = "win1", tabs = {} })
    assert.equals(1, #move_calls)
    assert.truthy(move_calls[1].src:find("window"))
  end)

  it("also rotates tab saves (state.pane_tree branch)", function()
    state_manager.save_state({ title = "tab1", pane_tree = {} })
    move_calls = {}
    state_manager.save_state({ title = "tab1", pane_tree = {} })
    assert.equals(1, #move_calls)
    assert.truthy(move_calls[1].src:find("tab"))
  end)
end)

describe("state_manager _test helpers", function()
  it("basename_no_ext strips directory and .json suffix", function()
    local sep_loc = package.config:sub(1, 1)
    assert.equals("foo", state_manager._test.basename_no_ext("dir" .. sep_loc .. "foo.json"))
    assert.equals("name+with+plus", state_manager._test.basename_no_ext("a" .. sep_loc .. "name+with+plus.json"))
  end)

  it("dirname returns path without the final component", function()
    local sep_loc = package.config:sub(1, 1)
    assert.equals("a" .. sep_loc .. "b", state_manager._test.dirname("a" .. sep_loc .. "b" .. sep_loc .. "c.json"))
  end)
end)
