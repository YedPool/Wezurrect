-- Specs for process_handlers.setup_claude_session_hooks: the SessionStart/Stop
-- hook writer must never destroy a settings.json it could not understand.
--
-- Every test runs against a throwaway HOME under the system temp dir. os.getenv
-- is wrapped so HOME and USERPROFILE point there; the real ~/.claude is never
-- read or written.

local dkjson = require("dkjson")

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

local logged = { warn = {}, error = {}, info = {} }

local wezterm_stub = {
  target_triple = is_windows() and "x86_64-pc-windows-msvc" or "x86_64-unknown-linux-gnu",
  log_warn = function(msg) table.insert(logged.warn, msg) end,
  log_error = function(msg) table.insert(logged.error, msg) end,
  log_info = function(msg) table.insert(logged.info, msg) end,
  -- wezterm.json_parse raises on malformed input; mirror that.
  json_parse = function(str)
    local value, _, err = dkjson.decode(str)
    if err then
      error(err)
    end
    return value
  end,
  json_encode = function(value)
    return dkjson.encode(value)
  end,
}
_G.wezterm = wezterm_stub
package.preload["wezterm"] = function()
  return wezterm_stub
end

package.path = table.concat({
  "./plugin/?.lua",
  "./plugin/?/init.lua",
  "../../plugin/?.lua",
  "../../plugin/?/init.lua",
}, ";") .. ";" .. package.path

local utils = require("resurrect.utils")
local process_handlers = require("resurrect.process_handlers")

local sep = utils.separator

local function unique_tmp_home()
  local id = tostring(os.time()) .. "_" .. tostring({}):gsub("[^%w]", "")
  if utils.is_windows then
    local tmp_dir = assert(os.getenv("TEMP") or os.getenv("TMP"), "TEMP is not set")
    return tmp_dir .. sep .. "_resurrect_home_" .. id
  end
  return "/tmp/_resurrect_home_" .. id
end

local function rmdir_recursive(path)
  if utils.is_windows then
    if not path:find('"') then
      os.execute('rmdir /s /q "' .. path .. '" >nul 2>&1')
    end
  else
    os.execute("rm -rf '" .. path:gsub("'", "'\\''") .. "'")
  end
end

local function read_bytes(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_bytes(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

local function count_pane_session_hooks(settings, event_name)
  local n = 0
  for _, entry in ipairs((settings.hooks or {})[event_name] or {}) do
    for _, hook in ipairs(entry.hooks or {}) do
      if hook.command and hook.command:find("pane%-sessions") then
        n = n + 1
      end
    end
  end
  return n
end

describe("process_handlers.setup_claude_session_hooks", function()
  local home, claude_dir, settings_path
  local real_getenv

  before_each(function()
    logged.warn, logged.error, logged.info = {}, {}, {}
    home = unique_tmp_home()
    claude_dir = home .. sep .. ".claude"
    settings_path = claude_dir .. sep .. "settings.json"
    assert.is_true(utils.ensure_folder_exists(claude_dir))
    real_getenv = os.getenv
    os.getenv = function(name) -- luacheck: ignore 122
      if name == "HOME" or name == "USERPROFILE" then
        return home
      end
      return real_getenv(name)
    end
  end)

  after_each(function()
    os.getenv = real_getenv -- luacheck: ignore 122
    rmdir_recursive(home)
  end)

  it("leaves an unparseable settings.json byte-identical", function()
    local original = '{ "model": "opus", "permissions": { "allow": ["Bash"] }, BROKEN\r\n'
    write_bytes(settings_path, original)

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_false(ok)
    assert.are.equal(original, read_bytes(settings_path))
    assert.is_true(#logged.warn + #logged.error > 0)
  end)

  it("leaves a settings.json that parses to a non-object byte-identical", function()
    local original = "null"
    write_bytes(settings_path, original)

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_false(ok)
    assert.are.equal(original, read_bytes(settings_path))
  end)

  -- A directory at the settings path exists but cannot be read as a file
  -- (io.open fails with EACCES on Windows; on POSIX it opens and the read
  -- fails). Either way the loader must refuse rather than start from {}.
  it("does not write when settings.json exists but cannot be read", function()
    assert.is_true(utils.ensure_folder_exists(settings_path))

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_false(ok)
    -- Still a directory: a file can be created inside it.
    write_bytes(settings_path .. sep .. "probe", "x")
    assert.are.equal("x", read_bytes(settings_path .. sep .. "probe"))
    assert.is_true(#logged.warn > 0)
  end)

  it("control: adds both hooks to a parseable settings.json and keeps other settings", function()
    write_bytes(settings_path, '{ "model": "opus", "permissions": { "allow": ["Bash"] } }')

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_true(ok)
    local settings = dkjson.decode(read_bytes(settings_path))
    assert.are.equal("opus", settings.model)
    assert.are.same({ "Bash" }, settings.permissions.allow)
    assert.are.equal(1, count_pane_session_hooks(settings, "SessionStart"))
    assert.are.equal(1, count_pane_session_hooks(settings, "Stop"))
  end)

  it("control: creates settings.json with both hooks when none exists", function()
    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_true(ok)
    local settings = dkjson.decode(read_bytes(settings_path))
    assert.are.equal(1, count_pane_session_hooks(settings, "SessionStart"))
    assert.are.equal(1, count_pane_session_hooks(settings, "Stop"))
  end)
end)
