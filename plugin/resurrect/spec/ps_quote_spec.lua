-- Specs for ps_quote: building a PowerShell single-quoted literal. The real
-- powershell.exe round trip is proven by test_debug/live_prune_check.ps1.

package.path = table.concat({
  "./plugin/?.lua",
  "./plugin/?/init.lua",
  "../../plugin/?.lua",
  "../../plugin/?/init.lua",
}, ";") .. ";" .. package.path

local ps_quote = require("resurrect.ps_quote")

describe("ps_quote.quote", function()
  it("wraps a plain string in single quotes", function()
    assert.are.equal("'plain name'", ps_quote.quote("plain name"))
  end)

  it("doubles the ASCII apostrophe", function()
    assert.are.equal("'it''s'", ps_quote.quote("it's"))
  end)

  it("doubles each typographic single quote U+2018 to U+201B", function()
    for _, cp in ipairs({ "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) do
      assert.are.equal("'a" .. cp .. cp .. "b'", ps_quote.quote("a" .. cp .. "b"))
    end
  end)

  it("doubles every occurrence, mixed with ASCII quotes", function()
    local s = "O\u{2019}Brien's \u{2018}x\u{2019}"
    local want = "'O\u{2019}\u{2019}Brien''s \u{2018}\u{2018}x\u{2019}\u{2019}'"
    assert.are.equal(want, ps_quote.quote(s))
  end)

  it("leaves other non-ASCII text and neighbouring code points alone", function()
    -- U+2017 and U+201C are not single-quote characters to PowerShell.
    local s = "\u{2733} \u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{2017}\u{201C}"
    assert.are.equal("'" .. s .. "'", ps_quote.quote(s))
  end)

  it("returns exactly one value", function()
    assert.are.equal(1, select("#", ps_quote.quote("x")))
  end)
end)
