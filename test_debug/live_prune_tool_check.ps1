# Proves tools/prune-backups.ps1 against scratch folders with decoys, under
# BOTH Windows PowerShell 5.1 (powershell.exe) and PowerShell 7 (pwsh).
# Usage (repo root): pwsh test_debug/live_prune_tool_check.ps1
# Writes only under a fresh folder in $env:TEMP (deleted at the end). It never
# touches the real state folder.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'tools\prune-backups.ps1'
$script:fails = 0

function Check([bool]$ok, [string]$what) {
    if (-not $ok) { $script:fails++ }
    '{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $what
}
function MakeFiles($dir, [string]$base, [int[]]$nums) {
    foreach ($n in $nums) {
        Set-Content -LiteralPath (Join-Path $dir ("{0}.20260101-{1:D6}.json" -f $base, $n)) -Value '{}'
    }
}
function Left($dir, [string]$base) {
    # stamps still present for exactly this (case-exact) base name
    $pre = $base + '.20260101-'
    @([System.IO.Directory]::EnumerateFiles($dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) } |
        Where-Object { $_.StartsWith($pre, [StringComparison]::Ordinal) } |
        ForEach-Object { [int]$_.Substring($pre.Length, 6) } | Sort-Object)
}
function RunTool([string]$shell, [string]$state, [int]$keep, [bool]$apply) {
    $a = @('-NoProfile', '-File', $tool, '-StateDir', $state, '-Keep', $keep)
    if ($apply) { $a += '-Apply' }
    $out = & $shell @a 2>&1 | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

foreach ($shell in @('powershell.exe', 'pwsh')) {
    "=== $shell ==="
    $scratch = Join-Path $env:TEMP ('wezurrect-tool-check-' + [guid]::NewGuid().ToString('N'))
    try {
        # ---- F4: case-differing base names ----
        $s = Join-Path $scratch 'f4'
        $bk = Join-Path $s 'window\.backups'
        New-Item -ItemType Directory -Force $bk | Out-Null
        MakeFiles $bk 'fleet' (1..8)
        MakeFiles $bk 'Fleet' (101..108)
        Set-Content -LiteralPath (Join-Path $bk 'fleet.json.bak') -Value '{}'
        Set-Content -LiteralPath (Join-Path $bk 'fleet.notastamp.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $bk 'fleeter.20260101-000001.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $s 'window\fleet.json') -Value '{}'
        New-Item -ItemType Directory -Force (Join-Path $s 'window\restored') | Out-Null
        $r = RunTool $shell $s 3 $false
        Check ((Left $bk 'fleet').Count -eq 8 -and (Left $bk 'Fleet').Count -eq 8) 'F4 dry run deletes nothing'
        $r = RunTool $shell $s 3 $true
        Check ($r.Code -eq 0) 'F4 exit code 0'
        Check (((Left $bk 'fleet') -join ',') -eq '6,7,8') ('F4 fleet keeps newest 6,7,8 (got ' + ((Left $bk 'fleet') -join ',') + ')')
        Check (((Left $bk 'Fleet') -join ',') -eq '106,107,108') ('F4 Fleet keeps newest 106,107,108 (got ' + ((Left $bk 'Fleet') -join ',') + ')')
        Check ((Test-Path (Join-Path $bk 'fleet.json.bak')) -and (Test-Path (Join-Path $bk 'fleet.notastamp.json')) -and
            (Test-Path (Join-Path $bk 'fleeter.20260101-000001.json')) -and (Test-Path (Join-Path $s 'window\fleet.json'))) 'F4 decoys untouched'

        # ---- F5: base names Keys and Count, with later types after them ----
        $s = Join-Path $scratch 'f5'
        foreach ($t in 'tab', 'window', 'workspace') {
            $d = Join-Path $s "$t\.backups"
            New-Item -ItemType Directory -Force $d | Out-Null
            MakeFiles $d 'Keys' (1..5)
            MakeFiles $d 'Count' (1..5)
            MakeFiles $d 'other' (1..5)
        }
        $r = RunTool $shell $s 2 $true
        Check ($r.Code -eq 0) 'F5 exit code 0'
        Check ($r.Out -match 'DELETED: 27 files') ('F5 summary printed, 27 deleted (3 types x 3 names x 3)')
        $okAll = $true
        foreach ($t in 'tab', 'window', 'workspace') {
            foreach ($b in 'Keys', 'Count', 'other') {
                if (((Left (Join-Path $s "$t\.backups") $b) -join ',') -ne '4,5') { $okAll = $false }
            }
        }
        Check $okAll 'F5 every type and name trimmed to newest 2'

        # ---- F6: files that disappear between listing and sizing ----
        # A concurrent deleter plays the live save that prunes the same files.
        # It is armed first, then waits until the tool has deleted its first
        # oldest file, then removes every other file in one fast sweep, so the
        # tool is certain to meet files that vanished after it listed them.
        $s = Join-Path $scratch 'f6'
        $bk = Join-Path $s 'window\.backups'
        New-Item -ItemType Directory -Force $bk | Out-Null
        foreach ($b in 'aaa', 'zzz') {
            1..5000 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $bk ('{0}.{1}.json' -f $b, ([datetime]'2026-01-01').AddSeconds($_).ToString('yyyyMMdd-HHmmss'))), '{}') }
        }
        $ready = Join-Path $scratch 'f6-ready.txt'
        $first = @((Join-Path $bk 'aaa.20260101-000001.json'), (Join-Path $bk 'zzz.20260101-000001.json'))
        $cmd = '$first = @(''' + $first[0] + ''', ''' + $first[1] + '''); $all = [System.IO.Directory]::GetFiles(''' + $bk + '''); ' +
            'Set-Content -LiteralPath ''' + $ready + ''' -Value 1; ' +
            'while ([System.IO.File]::Exists($first[0]) -and [System.IO.File]::Exists($first[1])) { Start-Sleep -Milliseconds 1 }; ' +
            'foreach ($f in $all) { try { [System.IO.File]::Delete($f) } catch {} }'
        $del = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', $cmd)
        $t0 = Get-Date
        while (-not (Test-Path -LiteralPath $ready) -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 50 }
        $r = RunTool $shell $s 5 $true
        if (-not $del.WaitForExit(60000)) { Stop-Process -Id $del.Id }
        Check ($r.Code -eq 0) ('F6 exit code 0 when files vanish mid-run (code ' + $r.Code + ')')
        Check ($r.Out -match 'DELETED:') 'F6 summary still printed'
        Check ($r.Out -match 'vanished') 'F6 vanished files are reported'
        $mm = [regex]::Match($r.Out, 'DELETED: (\d+) files.*?; (\d+) remain;.*?; (\d+) vanished')
        Check ($mm.Success -and ([int]$mm.Groups[1].Value + [int]$mm.Groups[2].Value + [int]$mm.Groups[3].Value) -eq 10000) 'F6 deleted + remain + vanished accounts for all 10000 files'
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
''
"$script:fails check(s) failed"
exit $(if ($script:fails -eq 0) { 0 } else { 1 })
