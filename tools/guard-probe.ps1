# guard-probe.ps1 - ask the running WezTerm for a restore DRY RUN, no keypress.
#
# Run it in any WezTerm pane:
#   pwsh -File guard-probe.ps1                 # the newest saved copy
#   pwsh -File guard-probe.ps1 -Instance <id>  # one saved instance
#
# It prints one OSC 1337 SetUserVar sequence (resurrect_guard_probe =
# "<target>|<nonce>") to its own terminal. The plugin's user-var-changed
# handler (guard_probe.on_user_var) then writes, without typing into any pane,
# opening any window or claiming any session:
#   %USERPROFILE%\.wezurrect\guard-probe-report.txt
# This script waits for a report carrying its nonce and prints it.
#
# No report within the timeout means one of: the running WezTerm has not
# loaded a plugin with the probe (old code), the config failed to load, or the
# sequence did not reach WezTerm (not run inside a WezTerm pane).

[CmdletBinding()]
param(
    [string]$Instance = "newest",
    [int]$TimeoutSeconds = 30
)
$ErrorActionPreference = "Stop"

if ($Instance -ne "newest" -and $Instance -notmatch '^\d+_\d+$') { Write-Host "RESULT: REFUSED - bad instance id"; exit 1 }
if (-not $env:WEZTERM_PANE) { Write-Host "RESULT: REFUSED - not inside a WezTerm pane (WEZTERM_PANE unset)"; exit 1 }

$report = Join-Path $env:USERPROFILE ".wezurrect\guard-probe-report.txt"
$nonce = -join ((48..57) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
$value = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$Instance|$nonce"))
$esc = [char]27
$bel = [char]7
[Console]::Out.Write("$esc]1337;SetUserVar=resurrect_guard_probe=$value$bel")
[Console]::Out.Flush()
Write-Host "asked WezTerm pane $($env:WEZTERM_PANE) for a dry run of '$Instance' (nonce $nonce); waiting..."

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $report) {
        $text = Get-Content -LiteralPath $report -Raw -ErrorAction SilentlyContinue
        if ($text -and $text -match "(?m)^nonce: $nonce\s*$" -and $text -match "(?m)^END\s*$") {
            Write-Host $text
            Write-Host "RESULT: PROBE OK - report $report"
            exit 0
        }
    }
    Start-Sleep -Milliseconds 500
}
Write-Host "RESULT: NO REPORT in $TimeoutSeconds s - the running WezTerm has not loaded the probe (old plugin code or a config error), or this is not a WezTerm pane."
exit 2
