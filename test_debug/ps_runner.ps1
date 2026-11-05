# Helper for live_prune_check.ps1: runs argv (one arg per line in $ArgFile) as a
# real process with UTF-16 arguments and writes its stdout, decoded as UTF-8
# (what WezTerm does), to $OutFile.
param([string]$ArgFile, [string]$OutFile)
$a = [System.IO.File]::ReadAllText($ArgFile, [System.Text.Encoding]::UTF8) -split "`n"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $a[0]
$a[1..($a.Length - 1)] | ForEach-Object { [void]$psi.ArgumentList.Add($_) }
$psi.RedirectStandardOutput = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($psi)
$out = $p.StandardOutput.ReadToEnd()
$p.WaitForExit()
[System.IO.File]::WriteAllText($OutFile, $out, (New-Object System.Text.UTF8Encoding($false)))
