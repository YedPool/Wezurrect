<#
.SYNOPSIS
  Reduce the dated-backup backlog to N copies per save name.
.DESCRIPTION
  Looks only at files named <name>.<YYYYMMDD-HHMMSS>.json that sit directly
  inside <StateDir>\<type>\.backups. Everything else is ignored: the live save
  files, *.bak, instances\restored, other folders, and any file in .backups
  that does not match the dated pattern exactly. Per base name the newest
  -Keep copies survive (newest = the stamp in the file name). Base names are
  compared exactly, including letter case: "fleet" and "Fleet" are two saves.
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
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$totKept = 0; $totDel = 0; $totDelBytes = 0L; $totBytes = 0L; $totNames = 0; $totSkipped = 0; $failed = 0; $totVanished = 0
foreach ($typeDir in [System.IO.Directory]::EnumerateDirectories($StateDir)) {
    $bk = Join-Path $typeDir '.backups'
    if (-not [System.IO.Directory]::Exists($bk)) { continue }
    # Groups are keyed by the EXACT base name: an ordinal, case-SENSITIVE
    # dictionary. A plain @{} is case-insensitive (so "fleet" and "Fleet" would
    # merge into one group, ranked by name instead of by stamp) and also lets a
    # base name such as "Keys" or "Count" collide with the hashtable's own
    # properties. The plugin names a backup after the save title exactly as
    # typed and matches it case-sensitively when it prunes, so a case-differing
    # name is a separate save here too: each keeps its own newest -Keep copies.
    # That can only keep more than a case-folded merge would, never less.
    $groups = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]' ([StringComparer]::Ordinal)
    # NOTE: never read $groups.Count, .Keys or .Values. PowerShell resolves a
    # dictionary key as if it were a property, so a base name of "Count" or
    # "Keys" would answer in place of the real property. $names lists the keys.
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in [System.IO.Directory]::EnumerateFiles($bk)) {
        $name = [System.IO.Path]::GetFileName($path)
        $m = $rx.Match($name)
        $when = [datetime]::MinValue
        if (-not $m.Success -or -not [datetime]::TryParseExact($m.Groups['stamp'].Value, 'yyyyMMdd-HHmmss', $inv, [System.Globalization.DateTimeStyles]::None, [ref]$when)) {
            $totSkipped++; continue
        }
        $b = $m.Groups['base'].Value
        if (-not $groups.ContainsKey($b)) { $names.Add($b); $groups[$b] =New-Object 'System.Collections.Generic.List[object]' }
        $groups[$b].Add([pscustomobject]@{ Path = $path; When = $when })
    }
    $typeDel = 0; $typeDelBytes = 0L; $typeFiles = 0; $typeVanished = 0
    $names.Sort([StringComparer]::Ordinal)
    foreach ($b in $names) {
        $list = $groups[$b]
        $typeFiles += $list.Count
        # Oldest first, by the parsed stamp (the base is identical in a group).
        $arr = @($list | Sort-Object -Property When)
        $excess = $arr.Length - $Keep
        for ($i = 0; $i -lt $excess; $i++) {
            $p = $arr[$i].Path
            # A live save prunes these same folders, so a file can vanish after
            # it was listed. That is not an error: count it and move on.
            $fi = New-Object System.IO.FileInfo $p
            if (-not $fi.Exists) { $typeVanished++; continue }
            try { $len = $fi.Length } catch { $typeVanished++; continue }
            if ($Apply) {
                try { [System.IO.File]::Delete($p) } catch { $failed++; continue }
            }
            $typeDel++; $typeDelBytes += $len
        }
    }
    $totNames += $names.Count; $totDel += $typeDel; $totDelBytes += $typeDelBytes; $totVanished += $typeVanished
    $totKept += ($typeFiles - $typeDel - $typeVanished)
    '{0,-10} names={1,5} files={2,7} {3}={4,7} ({5:N1} MB)' -f ([System.IO.Path]::GetFileName($typeDir)), $names.Count, $typeFiles, $(if ($Apply) { 'deleted' } else { 'would delete' }), $typeDel, ($typeDelBytes / 1MB)
}
''
'{0}: {1} files ({2:N1} MB) across {3} base names; {4} remain; {5} non-matching files left untouched; {6} delete failures; {7} vanished before they could be sized' -f $(if ($Apply) { 'DELETED' } else { 'DRY RUN, would delete' }), $totDel, ($totDelBytes / 1MB), $totNames, $totKept, $totSkipped, $failed, $totVanished
if (-not $Apply) { 'Nothing was changed. Re-run with -Apply to delete.' }
