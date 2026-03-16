# wezterm-resurrect

Fork of MLFlexer/resurrect.wezterm with Windows fixes, security hardening, and Claude Code session restoration.

## Branching & Worktrees

- Never commit directly to main branch
- All feature/fix work happens on branches in worktrees
- Worktrees live at `Documents/Code/wezterm-resurrect Worktrees/<branch-name>`
- Before creating a new worktree, update local main with latest from remote main
- PRs merge to main with squash via `gh pr merge --squash`
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
