-- ps_quote.lua -- Quote a string as a PowerShell single-quoted literal.
--
-- Every PowerShell command this plugin builds from a path or a save name goes
-- through quote(). Doubling the apostrophe is not enough: PowerShell treats
-- the typographic single quotes U+2018, U+2019, U+201A and U+201B as quote
-- characters too, so a name such as "O<U+2019>Brien" (or a profile folder
-- C:\Users\O<U+2019>Brien) closes the literal early and the whole command
-- fails to parse. Inside a single-quoted literal each of them is escaped the
-- same way as the ASCII one: by doubling it.
local pub = {}

-- UTF-8 encodings of U+2018 .. U+201B are E2 80 98 .. E2 80 9B.
local CURLY = "\226\128[\152-\155]"

---@param s string
---@return string literal the string wrapped in single quotes and safe to embed in a command
function pub.quote(s)
	local escaped = s:gsub("'", "''"):gsub(CURLY, "%0%0")
	return "'" .. escaped .. "'"
end

return pub
