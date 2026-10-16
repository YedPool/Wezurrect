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
- Modules: `plugin/resurrect/` (state_manager, instance_manager, pane_tree, tab_state, window_state, workspace_state, process_handlers, file_io, encryption, fuzzy_loader, utils)
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
- A Claude session is live when a control file `~/.claude/sessions/<pid>.json` names it, that pid is running, and the process start time equals the file's `procStart`. Live or unknown = not resumed (fail closed)
- Also unknown: an empty control folder; an id with no control file while a running session has the same cwd (ids rotate on compaction); a query that took over 10 seconds
- A Claude line is typed only when the saved command is exactly `<claude binary> --resume <lower-case UUID> [--dangerously-skip-permissions]`; the typed line is rebuilt from those parts, never copied from the state file. `claude --continue` is never typed
- `restore_guard.run_query` is the only function that asks the OS (one PowerShell call, Windows only). Tests replace it
- "Browse named saves" restores every kind of save into a new window; the startup selector's blank window is the only pre-existing pane ever reused, and only via `restore_opts.startup_pane_id`
- A restore only types into panes it created (`opts.pane_is_new`); never into a pane that already existed
- A claimed session is never resumed again while the claim holds (`claim_ttl_seconds` or while its pane exists). In-process claims live in `wezterm.GLOBAL` (flat keys `resurrect_resume_claim_<id>` / `_pane_<id>`) so a reload keeps them; across GUI processes a claim file `~/.wezurrect/resuming/<id>` is created by temp-write + rename (fails if it exists on Windows), refreshed by a heartbeat, and taken over when stale
- Spec hygiene: busted runs every spec file in one process; a spec that replaces `os.remove` or other globals must put them back
- A session with a no-restore marker `~/.wezurrect/no-restore/<id>.json` (parked/hibernated) is never resumed; the marker exists = refused, contents only for the log. The marker folder is listed by the same `run_query` call (`M` lines). Contract in README
- The instance ID lives in `wezterm.GLOBAL` so a config reload keeps it. A terminal's own instance, and a saved copy whose sessions are all running, cannot be restored

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
