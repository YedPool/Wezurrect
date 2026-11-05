<#
.SYNOPSIS
  Reduce the dated-backup backlog to N copies per save name.
.DESCRIPTION
  Looks only at files named <name>.<YYYYMMDD-HHMMSS>.json that sit directly
  inside <StateDir>\<type>\.backups. Everything else is ignored: the live save
  files, *.bak, instances\restored, other folders, and any file in .backups
  that does not match the dated pattern exactly. Per base name the newest
  -Keep copies survive (newest = the stamp in the file name).
  DRY RUN by default: prints counts and bytes and deletes nothing.
  Pass -Apply to delete.
.PARAMETER StateDir
  The plugin state folder. Default: the installed plugin cache.
.PARAMETER Keep
  Copies to keep per base name (default 10, the plugin's backup_retention_count).
.PARAMETER Apply
  Actually delete. Without it nothing is changed.
#>
param(
    [string]$StateDir = (Join-Path $env:APPDATA 'wezterm\plugins\httpssCssZssZsgithubsDscomsZsYedPoolsZsWezurrect\state'),
    [ValidateRange(1, 100000)][int]$Keep = 10,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) { throw "State folder not found: $StateDir" }
$rx = [regex]'^(?<base>.+)\.(?<stamp>\d{8}-\d{6})\.json$'
$totKept = 0; $totDel = 0; $totDelBytes = 0L; $totBytes = 0L; $totNames = 0; $totSkipped = 0; $failed = 0
foreach ($typeDir in [System.IO.Directory]::EnumerateDirectories($StateDir)) {
    $bk = Join-Path $typeDir '.backups'
    if (-not [System.IO.Directory]::Exists($bk)) { continue }
    $groups = @{}
    foreach ($path in [System.IO.Directory]::EnumerateFiles($bk)) {
        $name = [System.IO.Path]::GetFileName($path)
        $m = $rx.Match($name)
        if (-not $m.Success) { $totSkipped++; continue }
        $b = $m.Groups['base'].Value
        if (-not $groups.ContainsKey($b)) { $groups[$b] = New-Object 'System.Collections.Generic.List[string]' }
        $groups[$b].Add($path)
    }
    $typeDel = 0; $typeDelBytes = 0L; $typeFiles = 0
    foreach ($b in $groups.Keys) {
        $list = $groups[$b]
        $typeFiles += $list.Count
        # Sort by the full file name, ordinal: same base so the stamp decides.
        $arr = $list.ToArray()
        [Array]::Sort($arr, [StringComparer]::Ordinal)
        $excess = $arr.Length - $Keep
        if ($excess -gt 0) {
            for ($i = 0; $i -lt $excess; $i++) {
                $len = ([System.IO.FileInfo]$arr[$i]).Length
                if ($Apply) {
                    try { [System.IO.File]::Delete($arr[$i]) } catch { $failed++; continue }
                }
                $typeDel++; $typeDelBytes += $len
            }
        }
    }
    $totNames += $groups.Count; $totDel += $typeDel; $totDelBytes += $typeDelBytes
    $totKept += ($typeFiles - $typeDel)
    '{0,-10} names={1,5} files={2,7} {3}={4,7} ({5:N1} MB)' -f ([System.IO.Path]::GetFileName($typeDir)), $groups.Count, $typeFiles, $(if ($Apply) { 'deleted' } else { 'would delete' }), $typeDel, ($typeDelBytes / 1MB)
}
''
'{0}: {1} files ({2:N1} MB) across {3} base names; {4} remain; {5} non-matching files left untouched; {6} delete failures' -f $(if ($Apply) { 'DELETED' } else { 'DRY RUN, would delete' }), $totDel, ($totDelBytes / 1MB), $totNames, $totKept, $totSkipped, $failed
if (-not $Apply) { 'Nothing was changed. Re-run with -Apply to delete.' }
