# wezterm-resurrect Fork Plan

## Project Overview

**Original repo:** MLFlexer/resurrect.wezterm (283 stars, 25 forks, MIT license)
**Our fork:** YedPool/resurrect.wezterm
**Status:** Semi-maintained upstream - last commit July 2025, 29 open issues, 9 unmerged PRs
**Architecture:** WezTerm Lua plugin, ~1,489 lines across 12 files, depends on dev.wezterm
**Decision:** Fork (not rewrite) - bugs are surface-level, core architecture is sound

## Why Fork Over Rewrite

1. Only 1,489 lines of Lua - small enough to fully understand
2. Bugs are surface-level (Windows paths, os.execute, module loading), not architectural
3. Core pane-tree algorithm and hierarchical state model are sound
4. 9 PRs with confirmed fixes already exist - just need to be landed
5. Valuable WezTerm API tribal knowledge embedded (Windows CWD munging, alt-screen detection, split ratios)
6. Rewrite would only save ~500-700 lines - not worth losing edge case handling

## Repository Structure

```
C:/Users/yedid/Documents/Code/wezterm-resurrect/          # main repo
C:/Users/yedid/Documents/Code/wezterm-resurrect Worktrees/ # worktrees
```

## Branch Strategy

```
main (fork, synced with upstream)
  |
  +-- integrate-community-fixes  (Phase 1: merge PRs)
       |
       +-- fix/115-windows-hang-on-require
       +-- fix/129-periodic-save-silent-failure
       +-- fix/124-fuzzy-loader-nil-str-date
       +-- fix/68-glob-chars-in-titles
       +-- fix/111-cwd-save-overwrite
       +-- fix/110-cursor-position-after-restore
       +-- fix/108-first-window-cwd
       +-- feature/claude-code-restoration
```

After each fix branch is tested, merge into main via PR (squash and merge). Never commit directly to main.

---

## Phase 1: Merge Existing Fix PRs

Merge order matters due to file overlap. Skip PR #134 (subsumed by #136).

### PR #123 - Fix module 'resurrect' not found (fixes #117, #119)

**Commits:** c7df652, a160481
**Files:** tab_state.lua, window_state.lua
**Change:** Replaces `require("resurrect")` with `require("resurrect.state_manager")` - the module is not in the standard require path.

### PR #127 - Fix nil pane access in symmetric layouts (fixes #98)

**Commit:** ec66651
**Files:** pane_tree.lua
**Change:** Adds guard clause at top of `insert_panes()` to check if `root.pane == nil` before calling `root.pane:get_domain_name()`. In symmetric layouts (e.g., 2x2 grid), a pane can appear in both right and bottom branches. After the first encounter sets `root.pane = nil`, the second would crash.

### PR #118 - Fix workspace name not restored (fixes #114)

**Commit:** 9a51cf5
**Files:** workspace_state.lua
**Change:** Adds `wezterm.mux.set_active_workspace()` after restore so workspace identity is preserved instead of staying as "default".

### PR #136 - Fix Windows path handling + tests (fixes #107)

**Commits:** 2204a55, efef173, d7a3e82
**Files:** utils.lua, state_manager.lua, pane_tree.lua, spec files, README.md
**Changes:**
- Complete rewrite of `ensure_folder_exists()` with `shell_mkdir()`, `parse_root()`, `dir_is_accessible()`, `mkdir_if_missing()`
- Handles drive letters, UNC paths, spaces in paths, proper quoting
- Fixes `get_file_path()` - adds missing separator, expands filename sanitization for `:`, `[`, `]`, `?`, `/`
- Adds WSL `/mnt/c/...` to `C:\...` conversion at save time
- Adds Busted test specs

### PR #130 - Fix flickering cmd.exe windows (fixes #125)

**Commit:** From PR branch
**Files:** utils.lua, init.lua
**Change:** Replaces `os.execute('mkdir ...')` with pure Lua alternative. NOTE: #136 also touches utils.lua - may need manual conflict resolution. Take #136's structure but ensure we eliminate ALL os.execute calls for mkdir on Windows.

### PR #137 - Event-driven save (new feature)

**Commits:** From PR branch
**Files:** New event-driven save module
**Change:** Adds event-based saving triggered by structural changes (tab open/close, pane split, etc.) instead of only periodic timer.

### PR #128 - NixOS nix store path sanitization

**Commit:** a24d52a
**Files:** pane_tree.lua
**Change:** Strips `/nix/store/*` paths from saved vim/nvim process info. NixOS-specific, no effect on Windows.

### Step: Fix init.lua keywords for fork

The `keywords` in `plugin/init.lua` must match the fork URL path. Change:
```lua
-- FROM:
keywords = { "github", "MLFlexer", "resurrect", "wezterm" },
-- TO:
keywords = { "resurrect", "wezterm" },
```
This matches both upstream and any fork URL.

---

## Phase 2: Fix Remaining Issues Without PRs

### #115 - Plugin hangs WezTerm on Windows at require()

**Root cause:** `dev.wezterm` dependency does network fetch on init; `os.execute('mkdir')` blocks WezTerm's Lua event loop.
**Fix:** Eliminate `dev.wezterm` dependency. Replace with direct path detection (~5 lines). Replace remaining `os.execute` mkdir calls with `wezterm.run_child_process` (non-blocking, no visible window).

### #129 - periodic_save silently fails

**Root cause:** No error handling in `wezterm.time.call_after` callback. If any error occurs, the recursive re-schedule never executes, killing auto-save permanently.
**Fix:** Wrap callback body in `pcall`, always re-schedule regardless of errors, log errors via `wezterm.log_error`.

### #124 - Fuzzy loader crashes on nil str_date

**Root cause:** `fmt_cost.str_date` is nil when no files were parsed but stdout was non-empty.
**Fix:** Add nil guards: `(fmt_cost.str_date or 0)`. Add early return if no files parsed.

### #68 - Glob characters in pane titles crash periodic save

**Root cause:** Shell metacharacters (`*`, `~`, `!`, `{`, `}`, etc.) in pane titles become part of save file paths, causing shell expansion errors.
**Fix:** Expand sanitization in `get_file_path()` to cover ALL shell-unsafe characters. Fix encryption.lua to use proper shell quoting.

### #111 - CWD not saved, subsequent saves overwrite ignored

**Root cause:** Partially fixed by #136 (missing path separator). Additional fix needed: guard against empty CWD in `workspace_state.lua`.

### #110 - Cursor at bottom of window after restore

**Root cause:** `inject_output()` positions cursor at end of injected content.
**Fix:** After injecting output, send `\r\n` to trigger a fresh shell prompt at the correct position.

### #108 - First window restores to zoxide path not actual CWD

**Root cause:** First window reuses existing pane which inherits whatever CWD it already has. No CWD is set for the reused pane.
**Fix:** When using existing pane, explicitly `cd` to the saved CWD via `pane:send_text("cd " .. path .. "\r\n")`.

---

## Phase 3: Claude Code Session Restoration

### Discovery: Session Detection via Process argv

From actual running processes on the system:
```
node cli.js --dangerously-skip-permissions
node cli.js --dangerously-skip-permissions --resume 3e55cd6d-52cc-4921-aa75-add4ea080b1f
```

Everything we need is in the process argv that WezTerm's `pane:get_foreground_process_info()` provides:
- `--resume <uuid>` or `-r <uuid>` = session ID
- `--dangerously-skip-permissions` = permission flag to preserve
- `--session-id <uuid>` = alternative session ID flag
- CWD already captured by existing pane tree logic

### Restore command construction

```
-- If --resume <uuid> captured from argv:
claude --resume <uuid> --dangerously-skip-permissions

-- If no session ID in argv (fresh session), fall back to:
claude --continue --dangerously-skip-permissions

-- Flags only included if they were present in the original argv
```

### New module: plugin/resurrect/process_handlers.lua

Extensible process handler registry. Each handler has:
- `detect(process_info)` -> boolean
- `get_restore_cmd(process_info, pane_tree)` -> string

Built-in handlers:
1. **claude_code** - detects `claude` or `node` with `claude-code` in argv
   - Parses `--resume <uuid>`, `--dangerously-skip-permissions`, `--session-id`
   - Constructs restore command with all captured flags
2. **vim** (existing behavior, refactored into handler)

Users can register custom handlers in their wezterm.lua:
```lua
resurrect.process_handlers.register({
    name = "htop",
    detect = function(info) return info.name == "htop" end,
    get_restore_cmd = function(info, _) return "htop" end,
})
```

### Integration into tab_state.lua

Modify `default_on_pane_restore()`:
1. Check process_handlers for a matching handler first
2. If found, use handler's restore command
3. If not, fall back to existing behavior (replay argv)

### Save-time sanitization in pane_tree.lua

When saving Claude Code process info:
- Store clean argv: `{"claude", "--resume", "<uuid>", "--dangerously-skip-permissions"}`
- Strip the full node path and cli.js path (not portable)
- Preserve all relevant flags

---

## Phase 4: Comment on Original Issues

For each fix, comment on the original issue at MLFlexer/resurrect.wezterm:

```
gh issue comment <NUMBER> --repo MLFlexer/resurrect.wezterm --body "..."
```

Template:
```
I've addressed this in a maintained fork: https://github.com/YedPool/resurrect.wezterm

The fix is on the `<branch>` branch. You can use the fork by changing your plugin require to:

local resurrect = wezterm.plugin.require("https://github.com/YedPool/resurrect.wezterm")

[Brief description of the fix]
```

---

## Phase 5: User Configuration

Update wezterm config to use the fork with auto-save and Claude Code restoration.

Key config points:
- `periodic_save` with 5-minute interval
- `resurrect_on_gui_startup` event handler
- Keybindings for manual save (ALT+SHIFT+S) and restore (ALT+SHIFT+R)
- `default_on_pane_restore` with process handler integration

---

## Testing Strategy

For each fix:
1. Apply change in worktree
2. Run Busted test suite (`busted` from repo root)
3. Point wezterm config at local plugin path for manual testing
4. Check WezTerm debug overlay (Ctrl+Shift+L) for Lua errors
5. User confirms everything works before committing

For Claude Code restoration:
1. Open WezTerm, start `claude` in a pane
2. Save workspace state
3. Close WezTerm
4. Reopen, restore saved workspace
5. Verify Claude Code resumes with correct session ID and flags

---

## Critical Files

| File | Purpose | Phases |
|------|---------|--------|
| plugin/init.lua | Entry point, module exports, keywords | 1, 3 |
| plugin/resurrect/pane_tree.lua | Core pane tree serialization | 1, 3 |
| plugin/resurrect/utils.lua | Platform utilities, ensure_folder_exists | 1, 2 |
| plugin/resurrect/state_manager.lua | State persistence, periodic_save, file paths | 1, 2 |
| plugin/resurrect/tab_state.lua | Save/restore tabs, default_on_pane_restore | 1, 2, 3 |
| plugin/resurrect/workspace_state.lua | Save/restore workspaces | 1, 2 |
| plugin/resurrect/window_state.lua | Save/restore windows | 1 |
| plugin/resurrect/fuzzy_loader.lua | UI for selecting saved states | 2 |
| plugin/resurrect/encryption.lua | age/gpg encryption | 2 |
| plugin/resurrect/file_io.lua | JSON read/write | - |
| plugin/resurrect/process_handlers.lua | NEW - extensible process handler registry | 3 |

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Cherry-pick conflicts between PRs | Ordered by file overlap; #127/#118/#123 touch different files; #136 conflicts documented |
| os.execute still flashes on first run | Replace with wezterm.run_child_process entirely |
| Claude process shows as "node" not "claude" | Handler checks both process name AND argv for claude-code markers |
| dev.wezterm elimination breaks something | Test thoroughly; the dependency only provides path detection |
| Session ID not in argv for fresh sessions | Fall back to claude --continue which finds most recent session in CWD |
