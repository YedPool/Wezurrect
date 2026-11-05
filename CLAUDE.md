# wezterm-resurrect

Fork of MLFlexer/resurrect.wezterm with Windows fixes, security hardening, and Claude Code session restoration.

## Branching & Worktrees

- Never commit directly to main branch
- All feature/fix work happens on branches in worktrees
- Worktrees live at `Documents/Code/wezterm-resurrect Worktrees/<branch-name>`
- Before creating a new worktree, update local main with latest from remote main
- Create a worktree from an updated main, from the main repo:
  `git fetch origin main; git worktree add -b <branch> "../wezterm-resurrect Worktrees/<name>" origin/main`
- PRs merge to main with a regular merge commit via `gh pr merge --merge`. Never squash:
  squashing drops the branch commits' ancestry, which breaks `git branch --contains`,
  bisect and cherry-pick provenance. Use `git log --first-parent` for a linear view.
- Main repo at `Documents/Code/wezterm-resurrect` stays on `main` as the clean reference

## Plugin Architecture

- Entry point: `plugin/init.lua`
- Modules: `plugin/resurrect/` (state_manager, instance_manager, pane_tree, tab_state, window_state, workspace_state, process_handlers, file_io, encryption, fuzzy_loader, utils, restore_guard, restore_report)
- Plugin cache on Windows: `%APPDATA%/wezterm/plugins/httpssCssZssZsgithubsDscomsZsYedPoolsZsresurrectsDswezterm/`
- After pushing changes, also copy modified files to the plugin cache for immediate testing

## WezTerm Lua Constraints

- `wezterm.run_child_process` yields (async) -- cannot be called during plugin init or config loading. Use `os.execute` for synchronous operations needed at init time.
- `package.config:sub(1,1)` returns `/` in WezTerm Lua on Windows -- use `utils.is_windows` and `utils.separator` instead
- `os.rename` fails on Windows when target file exists -- use direct `io.open("w")` writes instead of atomic rename for small metadata files
- Plugin code is loaded into memory on WezTerm startup -- cache updates require a WezTerm restart to take effect

## Testing

- Run `bash test_debug/verify.sh` for luacheck + busted tests
- Always verify cached plugin matches source repo before testing
- No Lua runtime installed on system -- tests use bundled tools in `test_debug/tools/`
- Where `verify.sh`'s tools are missing: `pwsh test_debug/run_tests.ps1` runs busted + luacheck from a luarocks tree in `test_debug/tools/rocks` (setup commands are at the top of the script)

## Restore Guard

- `plugin/resurrect/restore_guard.lua` decides whether a restore command may be typed into a pane. `tab_state.default_on_pane_restore` is the only place a command is sent and it asks the guard first
- A Claude session is live when a control file `~/.claude/sessions/<pid>.json` names it, that pid is running, and the process start time equals the file's `procStart`; or when a live process named `claude`, `claude<digits>` or `claude-<name>` has `--resume` and that id as two whole arguments on its command line, split by Windows' `CommandLineToArgvW`, before any `--` (`P` lines of the same `run_query` call; a native host, `--chrome-native-host` as the first argument, excluded; a failed process query is an error for the whole answer). Live or unknown = not resumed (fail closed)
- Start time comes from `Get-Process`; when that is unreadable (non-elevated caller, SYSTEM process) the query falls back to `Win32_Process.CreationDate` for that pid only, else it stays `?` = unknown
- A `procStart` matching the process start time is live and a differing one is dead, whatever the file's time says: a clock stepped back can make a live session's file look older than its process. Only when `procStart` is missing or unusable (an unparseable file) does file age decide: a file last written before the process its pid names started (query reports each file's `LastWriteTimeUtc` as the last `S` field; tolerance `start_time_tolerance`) cannot belong to it, so dead. Without a known start time and file time it stays unknown (an unparseable file with a running pid refuses everything)
- Also unknown: an empty control folder; a query that took over 10 seconds
- A running session in the same folder is not evidence: ids do not rotate on compaction. Measured 2026-11-05 on versions 2.1.252 to 2.1.318: 202 compact_boundary records in 37 main transcripts, 0 with a sessionId differing from the filename, 0 files with more than one sessionId; 18 of 18 running `--resume X` processes had a control file sessionId equal to X. `/clear` does make a new id, but that is a new conversation. In-session `/resume` and `--fork-session` had no samples. The old rule refused 13 of 18 panes on 2026-11-05 because of one stale record
- A Claude line is typed only when the saved command is exactly `<claude binary> --resume <lower-case UUID> [--dangerously-skip-permissions]`; the typed line is rebuilt from those parts, never copied from the state file. `claude --continue` is never typed
- `restore_guard.run_query` is the only function that asks the OS (one PowerShell call, Windows only). Tests replace it
- "Browse named saves" restores every kind of save into a new window; the startup selector's blank window is the only pre-existing pane ever reused, and only via `restore_opts.startup_pane_id`
- A restore only types into panes it created (`opts.pane_is_new`); never into a pane that already existed
- A claimed session is never resumed again while the claim holds (`claim_ttl_seconds` or while its pane exists). In-process claims live in `wezterm.GLOBAL` (flat keys `resurrect_resume_claim_<id>` / `_pane_<id>`) so a reload keeps them; across GUI processes a claim file `~/.wezurrect/resuming/<id>` is created by temp-write + rename (fails if it exists on Windows), refreshed by a heartbeat, and taken over when stale
- Spec hygiene: busted runs every spec file in one process; a spec that replaces `os.remove` or other globals must put them back
- A session with a no-restore marker `~/.wezurrect/no-restore/<id>.json` (parked/hibernated) is never resumed; the marker exists = refused, contents only for the log. The marker folder is listed by the same `run_query` call (`M` lines). Contract in README
- The instance ID lives in `wezterm.GLOBAL` so a config reload keeps it. A terminal's own instance, and a saved copy whose sessions are all running, cannot be restored

## Partial Restores

- A saved copy is retired (tombstoned) only when nothing of it is waiting. It stays when a session was held back or failed, or its restore threw. Parked sessions are held back on purpose and a session its control file confirms (matching start time) is safe where it runs: neither keeps a copy. Weaker signs of running (an id on a command line with no confirming control file, a claim) still refuse the resume but count as held back: after `--resume X` and `/clear`, or with a pane whose Claude has exited, they read as running with nothing running that conversation. Exception: a claim from this same run, where the session was typed in another pane or copy, counts as running `restore_report.keeps_copy` decides, from `restore_guard.summarize`'s entries and the verdict `default_on_pane_restore` leaves on each pane tree node, never from the guard's report tally (global, and `note_resumed` runs in a timer)
- A kept copy's `.meta` lists `held_back` (session ids) and `restore_failed`. `last_save_epoch` is never touched, so `retention_days` still prunes it. A restore never creates a copy, so restarts cannot multiply them
- Reports: `~/.wezurrect/restore-reports/<instance id>.txt`, newest run first, removed with the copy or its tombstone. Never under `state/`: the state lister scans it recursively for `*.json`
- A copy is retired only after its typing timers have fired (`settle_copy` with `lines_are_out`). A config reload drops those timers, so the copy then stays listed instead of being retired over a line never typed. Its pane's claim still blocks a retry until that pane is closed and the claim has run out; a retry meanwhile holds the session back with its by-hand line
- The outcome is shown in an InputSelector that stays until dismissed, only when something is held back or failed. It is `fuzzy = true` and every row only closes it: it may appear under someone typing, the default mode selects rows on digits and letters, and fuzzy mode picks the best match on Enter
- "Resume the rest" (Alt+R only) asks the guard again for the `held_back` sessions only and types through `default_on_pane_restore`, in panes of one new window. There is no force option. A copy holding a malformed command is refused as a whole here too
- `restore_workspace` catches errors per window, emits `resurrect.error` and returns the failures

## Multi-Instance State Management

- Each WezTerm process gets a unique instance ID (`os.time() .. "_" .. math.random()`)
- Instance state saved to `state/instances/<instance_id>.json` + `.meta`
- On startup, instance selector auto-shows if saved instances exist (`auto_restore_prompt` option)
- Alt+R shows instance selector with restore/delete/rename modes; [Browse named saves] falls through to fuzzy_loader
- Alt+S triggers a full manual save (workspace + instance + status bar update)
- Old instances auto-cleaned after `retention_days` (default 7)

## Claude Code Integration

- SessionStart hook writes session data to `~/.claude/pane-sessions/<WEZTERM_PANE>.json`
- `setup_claude_session_hooks()` auto-configures both `~/.claude/settings.json` and `~/.claude-alt/settings.json` (for claude2 multi-account setups)
- Process detection uses pane-session files as primary signal (foreground process is unreliable when Claude runs child processes)
- claude vs claude2 distinguished via `transcript_path` in pane-session data (`.claude-alt` = claude2)
- Supports `claude`, `claude2`, and other variants via pattern matching
