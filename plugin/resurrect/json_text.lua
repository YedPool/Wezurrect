-- Find and extend members of a JSON document in its original text, without
-- decoding and re-encoding the rest of it.
--
-- Why this exists: WezTerm's json_parse/json_encode round trip is lossy.
-- Measured with WezTerm's own Lua (wezterm --config-file probe.lua ls-fonts):
--   in : {"env":{},"deny":[],"k":null,"big":12345678901234567890}
--   out: {"big":1.2345678901234567e19,"deny":{},"env":{}}
-- An empty array becomes an object, a null member disappears, a large
-- integer loses precision and the key order is lost. Splicing an addition
-- into the original text leaves every other byte as the user wrote it.
--
-- Every function here assumes the text has ALREADY been accepted by a real
-- JSON parser. The scanner only matches brackets and skips strings; it does
-- not validate. Callers must re-parse the result before trusting it.
--
-- Positions are 1-based byte indexes into the text.

local pub = {}

-- A decimal escape keeps a doubled backslash out of the source.
local BACKSLASH = "\092"

--- Index of the first non-whitespace byte at or after pos (#text + 1 if none).
---@param text string
---@param pos integer
---@return integer
function pub.skip_ws(text, pos)
	return text:find("[^ \t\r\n]", pos) or (#text + 1)
end

-- Index of the closing quote of the string whose opening quote is at pos.
local function string_end(text, pos)
	local i = pos + 1
	while true do
		local c = text:find('["' .. BACKSLASH .. ']', i)
		if not c then
			return nil
		end
		if text:byte(c) == 34 then -- '"'
			return c
		end
		i = c + 2 -- skip the escaped byte
	end
end

--- Index of the last byte of the JSON value that starts at pos.
---@param text string
---@param pos integer
---@return integer|nil
function pub.value_end(text, pos)
	local c = text:sub(pos, pos)
	if c == '"' then
		return string_end(text, pos)
	end
	if c == "{" or c == "[" then
		local depth = 0
		local i = pos
		while true do
			i = text:find('[%[%]{}"]', i)
			if not i then
				return nil
			end
			local b = text:sub(i, i)
			if b == '"' then
				i = string_end(text, i)
				if not i then
					return nil
				end
			elseif b == "{" or b == "[" then
				depth = depth + 1
			else
				depth = depth - 1
				if depth == 0 then
					return i
				end
			end
			i = i + 1
		end
	end
	-- number, true, false, null
	local _, e = text:find("^[%w%.%+%-]+", pos)
	return e
end

--- List the members of the object whose "{" is at pos.
--- Each member is { key = <raw key text between the quotes>,
--- value_start = <index>, value_end = <index> }.
---@param text string
---@param pos integer
---@return table[]|nil members
---@return integer|nil close index of the object's "}"
function pub.object_members(text, pos)
	if text:sub(pos, pos) ~= "{" then
		return nil
	end
	local members = {}
	local i = pub.skip_ws(text, pos + 1)
	if text:sub(i, i) == "}" then
		return members, i
	end
	while true do
		if text:sub(i, i) ~= '"' then
			return nil
		end
		local key_end = string_end(text, i)
		if not key_end then
			return nil
		end
		local key = text:sub(i + 1, key_end - 1)
		i = pub.skip_ws(text, key_end + 1)
		if text:sub(i, i) ~= ":" then
			return nil
		end
		local vs = pub.skip_ws(text, i + 1)
		local ve = pub.value_end(text, vs)
		if not ve then
			return nil
		end
		members[#members + 1] = { key = key, value_start = vs, value_end = ve }
		i = pub.skip_ws(text, ve + 1)
		local sep = text:sub(i, i)
		if sep == "}" then
			return members, i
		end
		if sep ~= "," then
			return nil
		end
		i = pub.skip_ws(text, i + 1)
	end
end

--- Find the member called key in the object whose "{" is at pos.
--- Returns nil when there is no such member (or pos is not an object).
---@return table|nil member
function pub.find_member(text, pos, key)
	local members = pub.object_members(text, pos)
	for _, m in ipairs(members or {}) do
		if m.key == key then
			return m
		end
	end
	return nil
end

-- Insert fragment after the last element of the container whose opening
-- bracket is at pos and whose closing bracket is at close. A separating
-- comma is added unless the container is empty.
local function append(text, pos, close, fragment)
	local last = close - 1
	while last > pos and text:sub(last, last):find("[ \t\r\n]") do
		last = last - 1
	end
	if last == pos then -- empty container
		return text:sub(1, pos) .. fragment .. text:sub(pos + 1)
	end
	return text:sub(1, last) .. "," .. fragment .. text:sub(last + 1)
end

--- Append "key":value_json as the last member of the object whose "{" is
--- at pos. key must not need escaping.
---@return string|nil new_text
function pub.append_member(text, pos, key, value_json)
	local _, close = pub.object_members(text, pos)
	if not close then
		return nil
	end
	return append(text, pos, close, '"' .. key .. '":' .. value_json)
end

--- Append value_json as the last element of the array whose "[" is at pos.
---@return string|nil new_text
function pub.append_element(text, pos, value_json)
	if text:sub(pos, pos) ~= "[" then
		return nil
	end
	local close = pub.value_end(text, pos)
	if not close then
		return nil
	end
	return append(text, pos, close, value_json)
end

return pub
