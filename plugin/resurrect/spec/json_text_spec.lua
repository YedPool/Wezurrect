-- Specs for json_text: locating and appending members in JSON text without
-- re-encoding it.

package.path = table.concat({
  "./plugin/?.lua",
  "./plugin/?/init.lua",
  "../../plugin/?.lua",
  "../../plugin/?/init.lua",
}, ";") .. ";" .. package.path

local json_text = require("resurrect.json_text")

describe("json_text", function()
  it("finds the end of strings containing escaped quotes and brackets", function()
    local text = '"a\\"}]b" rest'
    assert.are.equal(8, json_text.value_end(text, 1))
  end)

  it("finds the end of nested containers with brackets inside strings", function()
    local text = '{"a":[1,{"b":"]}"}],"c":{}} tail'
    assert.are.equal(27, json_text.value_end(text, 1))
  end)

  it("lists object members with their value spans", function()
    local text = '{ "a" : 1 , "b":[ ] ,"c":{"d":null} }'
    local members, close = json_text.object_members(text, 1)
    assert.are.equal(#text, close)
    assert.are.same({ "a", "b", "c" }, { members[1].key, members[2].key, members[3].key })
    assert.are.equal("[ ]", text:sub(members[2].value_start, members[2].value_end))
    assert.are.equal('{"d":null}', text:sub(members[3].value_start, members[3].value_end))
  end)

  it("appends a member to an empty and to a non-empty object", function()
    assert.are.equal('{"k":1}', json_text.append_member("{}", 1, "k", "1"))
    assert.are.equal('{"k":1 \n}', json_text.append_member("{ \n}", 1, "k", "1"))
    assert.are.equal('{"a":[],"k":1\n}\n', json_text.append_member('{"a":[]\n}\n', 1, "k", "1"))
  end)

  it("appends an element to an empty and to a non-empty array", function()
    assert.are.equal("[1]", json_text.append_element("[]", 1, "1"))
    assert.are.equal("[0,1]", json_text.append_element("[0]", 1, "1"))
    assert.are.equal('{"a":[0,1 ]}', json_text.append_element('{"a":[0 ]}', 6, "1"))
  end)

  it("returns nil when pos is not the container it expects", function()
    assert.is_nil(json_text.object_members("[1]", 1))
    assert.is_nil(json_text.append_member("[1]", 1, "k", "1"))
    assert.is_nil(json_text.append_element("{}", 1, "1"))
  end)
end)
