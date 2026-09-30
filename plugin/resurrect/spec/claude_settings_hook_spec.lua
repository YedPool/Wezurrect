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

-- The stub mirrors what WezTerm's own json_parse/json_encode do, as measured
-- by running WezTerm's Lua (wezterm --config-file probe.lua ls-fonts):
--   * json_parse raises on malformed input, on a leading UTF-8 BOM and on
--     trailing characters, and returns plain tables: an array and an object
--     are indistinguishable afterwards, and a null member simply vanishes.
--   * json_encode emits object keys sorted, turns an empty table into {},
--     and raises "Unexpected key ... for array style table" on a table that
--     mixes integer and string keys (e.g. [1,2] after .hooks was set on it).
local function strip_array_marks(value)
  if type(value) == "table" then
    setmetatable(value, nil)
    for _, v in pairs(value) do
      strip_array_marks(v)
    end
  end
  return value
end

local function wez_encode(value)
  local t = type(value)
  if t == "table" then
    local has_num, has_str = false, false
    for k in pairs(value) do
      if type(k) == "number" then
        has_num = true
      else
        has_str = true
      end
    end
    if has_num and has_str then
      error("error converting Lua string to numeric array index (Unexpected key for array style table)")
    end
    local parts = {}
    if has_num then
      for i = 1, #value do
        parts[i] = wez_encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
      parts[i] = dkjson.quotestring(k) .. ":" .. wez_encode(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return dkjson.quotestring(value)
  elseif t == "number" then
    if math.type(value) == "integer" then
      return tostring(value)
    end
    return string.format("%.17g", value)
  elseif t == "boolean" then
    return tostring(value)
  end
  error("cannot encode a " .. t)
end

local wezterm_stub = {
  target_triple = is_windows() and "x86_64-pc-windows-msvc" or "x86_64-unknown-linux-gnu",
  log_warn = function(msg) table.insert(logged.warn, msg) end,
  log_error = function(msg) table.insert(logged.error, msg) end,
  log_info = function(msg) table.insert(logged.info, msg) end,
  json_parse = function(str)
    local value, pos, err = dkjson.decode(str)
    if err then
      error(err)
    end
    if str:find("%S", pos) then
      error("trailing characters")
    end
    return strip_array_marks(value)
  end,
  json_encode = wez_encode,
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

-- Sorted names in dir that match pattern.
local function list_dir(dir, pattern)
  local cmd
  if utils.is_windows then
    cmd = 'dir /b /a "' .. dir .. '" 2>nul'
  else
    cmd = "ls -A '" .. dir .. "'"
  end
  local names = {}
  local p = assert(io.popen(cmd))
  for line in p:lines() do
    line = line:gsub("\r$", "")
    if line:find(pattern) then
      names[#names + 1] = line
    end
  end
  p:close()
  table.sort(names)
  return names
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
  -- Shapes that parse but are not a settings object, or whose hooks section
  -- has the wrong types. Each one used to raise out of setup (and so out of
  -- the user's whole WezTerm config) or to replace the file.
  local malformed = {
    { "a top-level array", "[1,2]" },
    { "an empty top-level array", "[]" },
    { "hooks set to a number", '{"hooks":5}' },
    { "a hook event set to a string", '{"hooks":{"SessionStart":"x"}}' },
    { "a hook entry that is a number", '{"hooks":{"Stop":[5]}}' },
    { "an entry whose hooks is a string", '{"hooks":{"Stop":[{"hooks":"x"}]}}' },
    { "a hook command that is a number", '{"hooks":{"Stop":[{"hooks":[{"command":5}]}]}}' },
  }
  for _, case in ipairs(malformed) do
    local label, original = case[1], case[2]
    it("refuses " .. label .. " without raising and leaves the file byte-identical", function()
      write_bytes(settings_path, original)

      local ok
      assert.has_no.errors(function()
        ok = process_handlers.setup_claude_session_hooks()
      end)

      assert.is_false(ok)
      assert.are.equal(original, read_bytes(settings_path))
      assert.is_true(#logged.warn + #logged.error > 0)
    end)
  end

  it("contains an unexpected error instead of raising it out of setup", function()
    local original = '{ "model": "opus" }'
    write_bytes(settings_path, original)
    local real_encode = wezterm_stub.json_encode
    wezterm_stub.json_encode = function() error("simulated encoder failure") end

    local ok, raised
    raised = not pcall(function()
      ok = process_handlers.setup_claude_session_hooks()
    end)
    wezterm_stub.json_encode = real_encode

    assert.is_false(raised)
    assert.is_false(ok)
    assert.are.equal(original, read_bytes(settings_path))
    assert.is_true(#logged.error > 0)
  end)

  -- Windows PowerShell 5.1 "Set-Content -Encoding utf8" writes a UTF-8 BOM.
  -- WezTerm's json_parse rejects it ("expected value at line 1 column 1").
  it("adds both hooks to a BOM-prefixed settings.json and keeps the BOM", function()
    local bom = "\239\187\191"
    write_bytes(settings_path, bom .. '{ "model": "opus" }')

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_true(ok)
    local after = read_bytes(settings_path)
    assert.are.equal(bom, after:sub(1, 3))
    local settings = dkjson.decode(after:sub(4))
    assert.are.equal("opus", settings.model)
    assert.are.equal(1, count_pane_session_hooks(settings, "SessionStart"))
    assert.are.equal(1, count_pane_session_hooks(settings, "Stop"))
  end)

  it("copies the original bytes to settings.json.bak before overwriting", function()
    local original = '{ "model": "opus" }\r\n'
    write_bytes(settings_path, original)

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_true(ok)
    assert.are.equal(original, read_bytes(settings_path .. ".bak"))
    local settings = dkjson.decode(read_bytes(settings_path))
    assert.are.equal(1, count_pane_session_hooks(settings, "SessionStart"))
    -- The staging file is gone once the replace succeeded.
    assert.are.same({ "settings.json", "settings.json.bak" }, list_dir(claude_dir, "^settings"))
  end)

  it("does not overwrite settings.json when the backup cannot be written", function()
    local original = '{ "model": "opus" }'
    write_bytes(settings_path, original)
    -- A directory where the backup should go makes the backup write fail.
    assert.is_true(utils.ensure_folder_exists(settings_path .. ".bak"))

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_false(ok)
    assert.are.equal(original, read_bytes(settings_path))
    assert.is_true(#logged.warn + #logged.error > 0)
  end)

  it("does not overwrite settings.json when the new content does not re-parse", function()
    local original = '{ "model": "opus" }'
    write_bytes(settings_path, original)
    -- Accept the original; reject anything that already carries our hook,
    -- which is only ever the staged new content.
    local real_parse = wezterm_stub.json_parse
    wezterm_stub.json_parse = function(str)
      if str:find("pane%-sessions") then
        error("simulated parse failure")
      end
      return real_parse(str)
    end

    local ok = process_handlers.setup_claude_session_hooks()
    wezterm_stub.json_parse = real_parse

    assert.is_false(ok)
    assert.are.equal(original, read_bytes(settings_path))
    assert.are.same({ "settings.json", "settings.json.bak" }, list_dir(claude_dir, "^settings"))
  end)

  it("control: makes no backup when there was no settings.json", function()
    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_true(ok)
    assert.are.same({ "settings.json" }, list_dir(claude_dir, "^settings"))
  end)

  it("control: an empty settings.json gets both hooks", function()
    write_bytes(settings_path, "")

    local ok = process_handlers.setup_claude_session_hooks()

    assert.is_true(ok)
    local settings = dkjson.decode(read_bytes(settings_path))
    assert.are.equal(1, count_pane_session_hooks(settings, "SessionStart"))
    assert.are.equal(1, count_pane_session_hooks(settings, "Stop"))
  end)

end)
