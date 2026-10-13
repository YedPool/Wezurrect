# Run the busted suite (and luacheck) with tools installed inside this clone.
#
# One-time setup, which writes only under test_debug/tools (git-ignored):
#   luarocks --lua-version 5.4 --tree test_debug/tools/rocks install busted
#   luarocks --lua-version 5.4 --tree test_debug/tools/rocks install luacheck
#
# Usage, from the repo root:
#   pwsh test_debug/run_tests.ps1                 # all specs + luacheck
#   pwsh test_debug/run_tests.ps1 <spec file>     # one spec, no luacheck
param([string]$Spec = "plugin\resurrect\spec")

$root = Split-Path -Parent $PSScriptRoot
$rocks = Join-Path $root "test_debug\tools\rocks"
$env:LUA_PATH = "$rocks\share\lua\5.4\?.lua;$rocks\share\lua\5.4\?\init.lua;;"
$env:LUA_CPATH = "$rocks\lib\lua\5.4\?.dll;;"

Push-Location $root
try {
    & "$rocks\bin\busted.bat" -o plainTerminal $Spec
    $failed = $LASTEXITCODE
    if ($Spec -eq "plugin\resurrect\spec") {
        & "$rocks\bin\luacheck.bat" --config .luacheckrc plugin | Select-Object -Last 3
        # luacheck: 0 = clean, 1 = warnings only, 2 = errors
        if ($LASTEXITCODE -ge 2) { $failed = 1 }
    }
} finally {
    Pop-Location
}
exit $failed
