#Requires -Version 7
# install-guard.ps1 - install a Wezurrect commit that carries the restore
# guard into the plugin copy WezTerm loads.
#
# Two modes.
#
#   Default: run ONLY with WezTerm fully quit. Refuses while any wezterm-gui.exe
#   or wezterm-mux-server.exe process exists, then does a git checkout.
#
#   -AllowRunning: install while WezTerm runs, without a quit. See "Why a
#   running WezTerm is safe" below. Refuses whenever anything is uncertain.
#
#   pwsh -File install-guard.ps1 -DryRun                    # checks only
#   pwsh -File install-guard.ps1                            # install (quit first)
#   pwsh -File install-guard.ps1 -AllowRunning -DryRun      # checks + plan only
#   pwsh -File install-guard.ps1 -AllowRunning              # install, no quit
#   pwsh -File install-guard.ps1 -Commit <sha-or-ref>
#
# Default mode, in order:
#   1. refuse if WezTerm is running
#   2. copy the whole plugin folder to <BackupRoot>\<stamp>\
#   3. keep the hand edit in plugin\resurrect\tab_state.lua as hand-edit.patch
#      in the backup folder (the backup copy has the file too), then discard
#      it from the working tree so the checkout can proceed. No git stash.
#   4. git fetch origin
#   5. git checkout --detach <commit>
#   6. verify plugin\resurrect\restore_guard.lua exists and utils.lua defines
#      utils.ENTER (the bare-CR fix from PR 25)
#
# -AllowRunning, in order:
#   1. checks: a git checkout, no git operation in progress, no modified
#      tracked file outside state\ except the known hand edit, a Lua
#      compiler to check the new code with, backup and plugin on one volume
#   2. copy the whole plugin folder to <BackupRoot>\<stamp>\
#   3. git fetch origin (touches .git only)
#   4. write the commit's tree to <BackupRoot>\<stamp>\staged (never inside
#      the plugins folder) and compile-check every .lua file in it
#   5. keep the hand edit as hand-edit.patch in the backup folder (the
#      backup copy holds the file too). No git stash: a stash would capture
#      every modified tracked file, state\current_state included, and popping
#      it later would overwrite live state.
#   6. the swap: move each new or changed file from staged into place with one
#      rename each, then delete tracked files the commit no longer has.
#      Nothing under state\ is ever written. Any error puts every moved file
#      back from the backup (each on its own; failures are listed) and
#      touches init.lua so a reload loads the complete old set.
#   7. point HEAD at the commit and reset the index (the working files are
#      already the commit's); verify nothing outside state\ differs
#   8. one deliberate reload: touch plugin\init.lua a second after the swap
#
# Why a running WezTerm is safe (from the WezTerm source, config/src/lua.rs
# and config/src/lib.rs, and wezterm-gui/src/main.rs):
#   * Every file the config loads with require is added to the reload watch
#     list, the plugin's files included. A change to any of them reloads the
#     config 200 ms after the first change event, and every reload loads
#     every module fresh from disk. A reload that lands mid-swap can load a
#     mix of old and new files; the order of the renames does not prevent
#     that. What protects you is the deliberate reload after the swap (the
#     last reload sees the complete tree) and not restoring anything while
#     the script runs.
#   * A reload that fails (a syntax error in a half-written file) keeps the
#     old config and its Lua state and shows the error. Step 4 checks every
#     file compiles before anything is moved.
#   * A reload does not restore anything: gui-startup, which runs
#     auto_restore_on_startup and the selector, is emitted once per WezTerm
#     process, not on reload. Restores only start from Alt+R or a restart.
#   * Until the reload, the running WezTerm keeps the code it loaded. Do not
#     press Alt+R (or restore anything) while this script runs.
#
# It deletes nothing it cannot restore from the backup, and never writes
# under state\.

[CmdletBinding()]
param(
    [string]$Commit = "",
    [switch]$DryRun,
    [switch]$AllowRunning,
    [string]$PluginDir = "C:\Users\Yedidya\AppData\Roaming\wezterm\plugins\httpssCssZssZsgithubsDscomsZsYedPoolsZsWezurrect",
    [string]$BackupRoot = "C:\Users\Yedidya\.wezurrect-backups",
    [string]$LuaCompiler = "C:\Users\Yedidya\AppData\Local\Programs\Lua\bin\luac.exe",
    # Skip "git fetch origin" (for a scratch copy without a reachable remote).
    [switch]$NoFetch
)

$ErrorActionPreference = "Stop"
trap {
    Write-Host "RESULT: FAILED - $($_.Exception.Message) (check the plugin folder against the backup under $BackupRoot)"
    exit 1
}
$prBranch = "origin/fix/windows-cr-enter-after-guard"
$handEditFile = "plugin/resurrect/tab_state.lua"
$mode = if ($DryRun) { "DRY-RUN" } else { "INSTALL" }
if ($AllowRunning) { $mode = "$mode/NO-QUIT" }

function Say([string]$text) { Write-Host "[$mode] $text" }
function Fail([string]$text) { Write-Host "RESULT: REFUSED - $text"; exit 1 }

function Invoke-Git {
    $out = & git.exe -C $PluginDir @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $out" }
    return $out
}

# True for a repo-relative path (forward slashes) under state/.
function Test-StatePath([string]$rel) { return $rel -like "state/*" -or $rel -eq "state" }

# Resolve the commit to install (default: origin/main once PR 25 is in it,
# else the PR 25 branch tip) and check it carries the guard.
function Resolve-Commit {
    if ($script:Commit -eq "") {
        $haveBranch = $true
        try { Invoke-Git rev-parse --verify --quiet "$prBranch^{commit}" | Out-Null } catch { $haveBranch = $false }
        if (-not $haveBranch) {
            $script:Commit = "origin/main"
            Say "$prBranch not found; default commit = origin/main"
        } else {
            & git.exe -C $PluginDir merge-base --is-ancestor $prBranch origin/main 2>$null
            if ($LASTEXITCODE -eq 0) { $script:Commit = "origin/main"; Say "PR 25 is merged; default commit = origin/main" }
            else { $script:Commit = $prBranch; Say "PR 25 not merged yet; default commit = $prBranch" }
        }
    }
    $resolved = ""
    try { $resolved = (Invoke-Git rev-parse --verify "$($script:Commit)^{commit}").Trim() }
    catch { return "" }
    $guardInCommit = $true
    try { Invoke-Git cat-file -e "${resolved}:plugin/resurrect/restore_guard.lua" | Out-Null } catch { $guardInCommit = $false }
    if (-not $guardInCommit) { Fail "$($script:Commit) ($($resolved.Substring(0,7))) has no plugin/resurrect/restore_guard.lua" }
    $utilsText = (Invoke-Git show "${resolved}:plugin/resurrect/utils.lua") -join "`n"
    if ($utilsText -notmatch 'utils\.ENTER\s*=') { Fail "$($script:Commit) ($($resolved.Substring(0,7))) lacks utils.ENTER (PR 25 bare-CR fix)" }
    return $resolved
}

function Backup-Plugin([string]$backupDir) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $PluginDir -Destination $backupDir -Recurse
    $srcCount = @(Get-ChildItem -LiteralPath $PluginDir -Recurse -Force -File).Count
    $dstCount = @(Get-ChildItem -LiteralPath (Join-Path $backupDir (Split-Path $PluginDir -Leaf)) -Recurse -Force -File).Count
    # A running WezTerm may save a state file during the copy; allow that one
    # difference only in -AllowRunning mode, and only upward or downward by
    # files under state\.
    if ($srcCount -ne $dstCount) {
        $srcCode = @(Get-ChildItem -LiteralPath $PluginDir -Recurse -Force -File | Where-Object { $_.FullName -notlike "$PluginDir\state\*" }).Count
        $dstCode = @(Get-ChildItem -LiteralPath (Join-Path $backupDir (Split-Path $PluginDir -Leaf)) -Recurse -Force -File |
            Where-Object { $_.FullName -notlike "*\state\*" }).Count
        if (-not $AllowRunning -or $srcCode -ne $dstCode) { Fail "backup incomplete: $dstCount of $srcCount files in $backupDir" }
        Say "backup: state\ changed during the copy (a live save); code files complete"
    }
    Say "backed up $srcCount files to $backupDir"
}

# Sanity: the plugin folder is the expected git checkout.
if (-not (Test-Path -LiteralPath (Join-Path $PluginDir ".git"))) { Fail "not a git checkout: $PluginDir" }

# =============================================================================
# Default mode: WezTerm must be fully quit.
# =============================================================================
if (-not $AllowRunning) {
    $running = @(Get-Process -Name "wezterm-gui", "wezterm-mux-server" -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        $list = ($running | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ", "
        Fail "WezTerm is running: $list. Quit every WezTerm window first, or use -AllowRunning."
    }
    Say "no wezterm-gui / wezterm-mux-server process"

    $head = (Invoke-Git rev-parse --short HEAD).Trim()
    $dirty = @(Invoke-Git status --porcelain --untracked-files=no)
    Say "plugin at $head; modified tracked files: $($dirty.Count)"

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $BackupRoot $stamp
    if ($DryRun) { Say "would copy $PluginDir -> $backupDir" } else { Backup-Plugin $backupDir }

    $handEdited = @(Invoke-Git status --porcelain --untracked-files=no '--' $handEditFile).Count -gt 0
    if (-not $handEdited) {
        Say "no hand edit in $handEditFile"
    } elseif ($DryRun) {
        Say "would keep the hand edit as $backupDir\hand-edit.patch, then discard it from $handEditFile"
    } else {
        $patch = Join-Path $backupDir "hand-edit.patch"
        (Invoke-Git diff '--' $handEditFile) -join "`n" | Set-Content -LiteralPath $patch -Encoding ascii
        if (-not (Test-Path -LiteralPath $patch) -or (Get-Item -LiteralPath $patch).Length -eq 0) { Fail "could not write $patch" }
        Invoke-Git checkout '--' $handEditFile | Out-Null
        Say "kept hand edit as $patch (the backup copy has the file too)"
    }

    if ($DryRun -or $NoFetch) { Say "not fetching (dry run or -NoFetch); using the refs already fetched" }
    else { Invoke-Git fetch origin | Out-Null; Say "fetched origin" }

    $sha = Resolve-Commit
    if ($sha -eq "") { Fail "cannot resolve $Commit" }
    if ($DryRun) {
        Write-Host "RESULT: DRY-RUN OK - would check out $($sha.Substring(0,7)) ($Commit) from $head; nothing changed."
        exit 0
    }
    Invoke-Git checkout --detach $sha | Out-Null
    $guardFile = Join-Path $PluginDir "plugin\resurrect\restore_guard.lua"
    if (-not (Test-Path -LiteralPath $guardFile)) { Fail "restore_guard.lua missing after checkout" }
    $now = (Invoke-Git rev-parse --short HEAD).Trim()
    Write-Host "RESULT: INSTALLED $now (was $head); guard present; backup $backupDir; state\instances untouched."
    exit 0
}

# =============================================================================
# -AllowRunning: install under a running WezTerm.
# =============================================================================
$running = @(Get-Process -Name "wezterm-gui", "wezterm-mux-server" -ErrorAction SilentlyContinue)
Say "WezTerm processes running: $($running.Count) (allowed in this mode)"

# 1. Checks. Anything uncertain is a refusal.
$gitDir = (Invoke-Git rev-parse --absolute-git-dir).Trim()
foreach ($busy in @("index.lock", "MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD")) {
    if (Test-Path -LiteralPath (Join-Path $gitDir $busy)) { Fail "a git operation is in progress in the plugin folder ($busy)" }
}
if (-not (Test-Path -LiteralPath $LuaCompiler)) { Fail "no Lua compiler at $LuaCompiler to check the new code before it goes live (-LuaCompiler)" }
$pluginRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($PluginDir))
$backupFull = [IO.Path]::GetFullPath($BackupRoot)
if ($pluginRoot -ne [IO.Path]::GetPathRoot($backupFull)) {
    Fail "backup root $BackupRoot is on another volume than the plugin; a move would be a copy, not a rename"
}
if ($backupFull.StartsWith([IO.Path]::GetFullPath((Split-Path $PluginDir -Parent)), [StringComparison]::OrdinalIgnoreCase)) {
    Fail "backup root must not be inside the WezTerm plugins folder"
}

$head = (Invoke-Git rev-parse HEAD).Trim()
$dirtyLines = @(Invoke-Git status --porcelain --untracked-files=no)
$unexpected = @()
$handEdited = $false
foreach ($line in $dirtyLines) {
    $rel = $line.Substring(3).Trim('"')
    if (Test-StatePath $rel) { continue }
    if ($rel -eq $handEditFile) { $handEdited = $true; continue }
    $unexpected += $rel
}
if ($unexpected.Count -gt 0) { Fail "modified tracked files besides the known hand edit: $($unexpected -join ', ')" }
Say "plugin at $($head.Substring(0,7)); hand edit present: $handEdited"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $BackupRoot $stamp
$backupPlugin = Join-Path $backupDir (Split-Path $PluginDir -Leaf)
$staged = Join-Path $backupDir "staged"

# 2. Backup (also the rollback source).
if ($DryRun) { Say "would copy $PluginDir -> $backupDir" } else { Backup-Plugin $backupDir }

# 3. Fetch (writes .git only, which WezTerm does not watch).
if ($DryRun -or $NoFetch) { Say "not fetching (dry run or -NoFetch); using the refs already fetched" }
else { Invoke-Git fetch origin | Out-Null; Say "fetched origin" }

$sha = Resolve-Commit
if ($sha -eq "") { Fail "cannot resolve $Commit" }
Say "installing $($sha.Substring(0,7)) ($Commit)"

# 4. Stage the commit's tree outside the plugins folder and compile-check it.
if ($DryRun) { $staged = Join-Path ([IO.Path]::GetTempPath()) "wezurrect-dryrun-$stamp" }
New-Item -ItemType Directory -Path $staged -Force | Out-Null
$zip = "$staged.zip"
Invoke-Git archive --format=zip -o $zip $sha | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $staged -Force
Remove-Item -LiteralPath $zip
$luaFiles = @(Get-ChildItem -LiteralPath (Join-Path $staged "plugin") -Recurse -File -Filter "*.lua")
foreach ($f in $luaFiles) {
    $out = & $LuaCompiler -p $f.FullName 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "the new code does not compile: $out" }
}
Say "staged $sha tree; $($luaFiles.Count) .lua files compile"

# The plan: new and changed files, and tracked files the commit drops.
$plan = @()
foreach ($f in @(Get-ChildItem -LiteralPath $staged -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($staged.Length + 1).Replace('\', '/')
    if (Test-StatePath $rel) { continue }
    $target = Join-Path $PluginDir ($rel.Replace('/', '\'))
    if (Test-Path -LiteralPath $target -PathType Container) { Fail "$rel is a folder in the plugin copy" }
    $isNew = -not (Test-Path -LiteralPath $target)
    if (-not $isNew -and (Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { continue }
    $plan += [pscustomobject]@{ Rel = $rel; Source = $f.FullName; Target = $target; New = $isNew }
}
$stagedSet = @{}
foreach ($f in @(Get-ChildItem -LiteralPath $staged -Recurse -File -Force)) {
    $stagedSet[$f.FullName.Substring($staged.Length + 1).Replace('\', '/')] = $true
}
$drop = @()
foreach ($rel in @(Invoke-Git ls-files)) {
    if ((Test-StatePath $rel) -or $stagedSet.ContainsKey($rel)) { continue }
    $target = Join-Path $PluginDir ($rel.Replace('/', '\'))
    if (Test-Path -LiteralPath $target) { $drop += [pscustomobject]@{ Rel = $rel; Target = $target } }
}
# New files first (nothing watches them yet), then changed files.
$plan = @($plan | Sort-Object @{ Expression = { -not $_.New } }, @{ Expression = { $_.Rel -eq "plugin/init.lua" } }, Rel)
Say "plan: $(@($plan | Where-Object New).Count) new, $(@($plan | Where-Object { -not $_.New }).Count) changed, $($drop.Count) dropped"
foreach ($p in $plan) { Say "  $(if ($p.New) { 'new    ' } else { 'replace' }) $($p.Rel)" }
foreach ($d in $drop) { Say "  drop    $($d.Rel)" }

if ($DryRun) {
    Remove-Item -LiteralPath $staged -Recurse -Force
    Write-Host "RESULT: DRY-RUN OK - would swap $($plan.Count) files and drop $($drop.Count) under a running WezTerm; nothing changed."
    exit 0
}
if ($plan.Count -eq 0 -and $drop.Count -eq 0 -and $head -eq $sha) {
    Write-Host "RESULT: NOTHING TO DO - the plugin already is $($sha.Substring(0,7))."
    exit 0
}

# 5. Keep the hand edit as a patch next to the backup (no git stash).
if ($handEdited) {
    $patch = Join-Path $backupDir "hand-edit.patch"
    (Invoke-Git diff '--' $handEditFile) -join "`n" | Set-Content -LiteralPath $patch -Encoding ascii
    Say "kept hand edit as $patch (the backup copy has the file too)"
}

# 6. The swap. One rename per file; roll everything back on any error.
$done = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    foreach ($p in $plan) {
        $dir = Split-Path $p.Target -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::Move($p.Source, $p.Target, $true)
        $done += $p
    }
    foreach ($d in $drop) {
        Remove-Item -LiteralPath $d.Target -Force
        $done += [pscustomobject]@{ Rel = $d.Rel; Target = $d.Target; New = $false; Dropped = $true }
    }
} catch {
    $err = $_.Exception.Message
    $notRestored = @()
    foreach ($p in $done) {
        $orig = Join-Path $backupPlugin ($p.Rel.Replace('/', '\'))
        try {
            if ($p.New) { Remove-Item -LiteralPath $p.Target -Force -ErrorAction Stop }
            else { Copy-Item -LiteralPath $orig -Destination $p.Target -Force -ErrorAction Stop }
        } catch {
            $notRestored += "$($p.Rel) ($($_.Exception.Message))"
        }
    }
    # A reload now loads the full old set (or shows which files are mixed).
    $touch = "init.lua touched"
    try { (Get-Item -LiteralPath (Join-Path $PluginDir "plugin\init.lua")).LastWriteTime = Get-Date }
    catch { $touch = "init.lua could NOT be touched ($($_.Exception.Message)): press Ctrl+Shift+R in WezTerm" }
    if ($notRestored.Count -gt 0) {
        Fail ("swap failed after $($done.Count) files ($err); COULD NOT PUT BACK: $($notRestored -join '; '). " +
            "Copy them from $backupPlugin by hand, then press Ctrl+Shift+R in WezTerm. ($touch)")
    }
    Fail "swap failed after $($done.Count) files ($err); every moved file was put back from $backupPlugin; $touch"
}
$sw.Stop()
Say "swapped $($plan.Count) files and dropped $($drop.Count) in $($sw.ElapsedMilliseconds) ms"

# 7. Git bookkeeping: HEAD and index to the commit; the files already are.
Invoke-Git update-ref --no-deref HEAD $sha | Out-Null
Invoke-Git reset -q | Out-Null
$left = @(Invoke-Git status --porcelain --untracked-files=no | Where-Object { -not (Test-StatePath $_.Substring(3).Trim('"')) })
if ($left.Count -gt 0) { Fail "after the swap these differ from $($sha.Substring(0,7)): $($left -join '; '). Backup: $backupDir" }

# 8. One deliberate reload, after the tree is complete.
Start-Sleep -Milliseconds 1000
$reload = "A reload restores nothing; the guard applies from the next restore."
try {
    (Get-Item -LiteralPath (Join-Path $PluginDir "plugin\init.lua")).LastWriteTime = Get-Date
    Say "touched plugin\init.lua: WezTerm reloads the config now (Ctrl+Shift+R if automatically_reload_config is off)"
} catch {
    $reload = "reload pending - press Ctrl+Shift+R in every WezTerm window (init.lua could not be touched: $($_.Exception.Message))"
}

Write-Host ("RESULT: INSTALLED $($sha.Substring(0,7)) (was $($head.Substring(0,7))) without a quit; " +
    "backup $backupDir; state\ untouched. $reload")
exit 0
