# Proves the REAL powershell.exe command that state_manager.list_dated_backups
# generates, against a scratch folder with non-ASCII names. Busted specs stub
# run_child_process and so cannot see encoding bugs in this layer.
# Usage (repo root): pwsh test_debug/live_prune_check.ps1
# Writes only under a fresh folder in $env:TEMP, which it deletes at the end.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path $env:TEMP ("wezurrect-prune-check-" + [guid]::NewGuid().ToString('N'))
$bk = Join-Path $scratch 'window\.backups'
New-Item -ItemType Directory -Force $bk | Out-Null
$star = [string][char]0x2733
$heb = -join ([char]0x05E9, [char]0x05DC, [char]0x05D5, [char]0x05DD)
$bases = @("$star Claude Code", "$heb notes", 'plain')
foreach ($b in $bases) {
    1..15 | ForEach-Object { Set-Content -LiteralPath (Join-Path $bk ("{0}.20260101-{1:D6}.json" -f $b, $_)) -Value '{}' }
}
# decoys that must never be matched for base "plain"
Set-Content -LiteralPath (Join-Path $bk 'plain.json.bak') -Value '{}'
Set-Content -LiteralPath (Join-Path $bk 'plain.notastamp.json') -Value '{}'
Set-Content -LiteralPath (Join-Path $bk 'plainer.20260101-000001.json') -Value '{}'
$lua = Join-Path $scratch 'check.lua'
@'
local scratch, root = ...
package.path = root .. "/plugin/?.lua;" .. root .. "/plugin/?/?.lua;" .. package.path
local calls = 0
package.loaded["wezterm"] = {
  target_triple = "x86_64-pc-windows-msvc", emit = function() end,
  log_error = function() end, log_info = function() end, log_warn = function() end,
  -- Real process, like WezTerm: UTF-16 argv, stdout read as raw UTF-8 bytes.
  run_child_process = function(argv)
    calls = calls + 1
    local af, of = scratch .. "/argv.txt", scratch .. "/out.txt"
    local f = assert(io.open(af, "wb")); f:write(table.concat(argv, "\n")); f:close()
    os.execute('pwsh -NoProfile -File "' .. root .. '/test_debug/ps_runner.ps1" "' .. af .. '" "' .. of .. '"')
    local o = assert(io.open(of, "rb")); local out = o:read("a"); o:close()
    return true, out, ""
  end,
}
package.loaded["resurrect.file_io"] = {}
local sm = require("resurrect.state_manager")
local dir = scratch .. "/window/.backups"
local fails = 0
for _, base in ipairs({ "\u{2733} Claude Code", "\u{05E9}\u{05DC}\u{05D5}\u{05DD} notes", "plain" }) do
  local e = sm._test.list_dated_backups(dir, base)
  local ok = (#e == 15)
  if not ok then fails = fails + 1 end
  print(string.format("%-8s base with %d bytes: %d entries (expect 15)", ok and "PASS" or "FAIL", #base, #e))
end
os.exit(fails == 0 and 0 or 1)
'@ | Set-Content -LiteralPath $lua -Encoding ASCII
try {
    & lua $lua ($scratch.Replace([string][char]92, '/')) ($root.Replace([string][char]92, '/'))
    $rc = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
exit $rc
