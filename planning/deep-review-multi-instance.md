# Deep Review: Multi-Instance State Management + Claude2 Support
**Date:** 2026-03-16
**Branch:** feat/multi-instance-state
**Files Reviewed:** 10 (plugin modules) + 2 (spec files) + 3 (docs)

---

## Executive Summary

The implementation is **functionally correct** -- all 6 call chains verified with 0 broken links. Security posture is strong on Windows (proper PowerShell quoting, instance ID validation, path traversal prevention) but has **3 HIGH shell injection risks on Unix** from `sh -c` string interpolation. The main optimization opportunities are consolidating duplicated save logic into a single "full save" function and extracting the repeated fuzzy-restore callback.

---

## Security Findings

### High

**H1. Shell injection via `base_path` in `fuzzy_loader.lua` (Unix branch)**
- File: `fuzzy_loader.lua:80-88`
- The Unix `find_json_files_recursive` embeds `base_path` in `sh -c` with only `"` escaping. `$()` and backticks can inject commands.
- Fix: Use `wezterm.run_child_process` with argument arrays instead of `sh -c`.

**H2. Shell injection via `instances_dir` in `instance_manager.lua` (Unix branch)**
- File: `instance_manager.lua:233-239`
- Same pattern as H1: `ls "..." | xargs` with only `"` escaping.
- Fix: Use argument arrays or `find -maxdepth 1` with `run_child_process`.

**H3. `shell_mkdir` in `utils.lua` vulnerable to command injection on Unix**
- File: `utils.lua:77-90`
- `os.execute('mkdir -p "' .. path .. '"')` with no metacharacter guard on Unix (Windows has `"` rejection).
- Fix: Add metacharacter rejection for Unix paths, matching the Windows guard.

### Medium

**M1. TOCTOU race in `file_io.write_file` atomic rename on Windows**
- File: `file_io.lua:23-31`
- `os.remove(file_path)` then `os.rename(tmp_path, file_path)` has a window where another process can interfere.
- Fix: Accept last-writer-wins for per-instance files (unique IDs prevent collision).

**M2. `pane_sessions_dir` path injected into bash command in hook setup**
- File: `process_handlers.lua:352-356`
- Single quotes in `HOME` path could break the bash command stored in `settings.json`.
- Fix: Escape single quotes (`'` -> `'\''`) in `pane_sessions_dir`.

**M3. No validation of `display_name` content in `rename_instance`**
- File: `instance_manager.lua:356-372`
- ANSI escape sequences in display names could manipulate terminal UI.
- Fix: Strip control characters before storing.

**M4. `delete_state` path confinement is fragile**
- File: `state_manager.lua:263-291`
- Path concatenation relies on implicit format of `file_path` from `insert_choices`.
- Fix: Canonicalize and verify path is under `save_state_dir` after concatenation.

**M5. Weak instance ID randomness**
- File: `instance_manager.lua:33-36`
- `math.randomseed(os.time())` -- two processes in the same second collide.
- Fix: Add `os.clock()` or PID to seed: `math.randomseed(os.time() * 1000 + os.clock() * 1000)`.

### Low

**L1. Deserialized state data not validated before use**
- File: `instance_manager.lua:188-209`
- `load_instance` returns `parsed.workspace_state` without schema validation.
- Fix: Check `workspace_state` is a table with `window_states` array.

**L2. `current_state` file written without locking**
- File: `state_manager.lua:217-230`
- Multiple instances can corrupt. Low impact since multi-instance mode supersedes it.
- Fix: Skip writing `current_state` when instance mode is active.

**L3. Unbounded recursion in `insert_panes`**
- File: `pane_tree.lua:74-283`
- Crafted state files could cause stack overflow.
- Fix: Add recursion depth guard (max 100).

**L4. `tab_summaries` displayed without sanitization**
- File: `instance_manager.lua:308-351`
- ANSI escapes in `.meta` files rendered in UI.
- Fix: Strip control characters from summaries before display.

---

## Optimization Findings

### Duplication

**O1. Fuzzy-restore callback copied twice (HIGH)**
- File: `instance_manager.lua:389-406` and `434-451`
- Same callback logic (parse id, dispatch to workspace/window/tab restore) is duplicated.
- Fix: Extract into `local function make_fuzzy_restore_callback(restore_opts)`.

**O2. Dedup-and-count display logic duplicated (MEDIUM)**
- Files: `init.lua:107-125` (status bar) and `instance_manager.lua:313-329` (format_instance_summary)
- Identical algorithm for counting duplicate titles.
- Fix: Extract `utils.deduplicate_with_counts(items)`.

**O3. `write_current_state` called redundantly (MEDIUM)**
- File: `state_manager.lua:33,71,141` + `init.lua:183`
- Called inside `save_state` AND by callers. Runs 2-3x per save cycle.
- Fix: Pick one canonical location.

**O4. `instance_manager.save_instance` called from 3 places (MEDIUM)**
- Files: `state_manager.lua:74-77,143-146` + `init.lua:184-186`
- Fix: Create `pub.save_workspace_full()` that does save_state + write_current_state + save_instance.

### Dead Code

**O5. `is_windows`/`separator` in `init.lua` (LOW)**
- File: `init.lua:7-8`
- Duplicates `utils.is_windows`/`utils.separator`, only used on line 18.
- Fix: Use `require("resurrect.utils").separator` directly.

### Performance

**O6. `list_instances` shells out to PowerShell (MEDIUM)**
- File: `instance_manager.lua:214-265`
- Spawns PowerShell (~200-400ms) on every selector display.
- Fix: Use `io.popen` for lighter listing, or maintain an index file.

**O7. `get_instances_dir()` re-requires `state_manager` on every call (LOW)**
- File: `instance_manager.lua:45-48`
- Fix: Cache as module-level local.

### Code Quality

**O8. `delete_state` path joining missing explicit separator (MEDIUM)**
- File: `state_manager.lua:284`
- Fix: Use `save_state_dir .. utils.separator .. file_path`.

**O9. Alt+S emits misleading event name (LOW)**
- File: `init.lua:187`
- Emits `event_driven_save.finished` from a manual save.
- Fix: Use a dedicated `resurrect.manual_save.finished` event.

---

## Traceability Findings

### All 6 Call Chains: VERIFIED

| Chain | Status | Issues |
|-------|--------|--------|
| 1. Setup (init -> instance_manager + state_manager) | OK | All calls match signatures |
| 2. Save (state_manager -> workspace_state -> file_io) | OK | Data flows correctly |
| 3. Pane detection (pane_tree -> process_handlers) | OK | Fallback path works |
| 4. Restore (instance_manager -> workspace_state -> tab_state) | OK | All types match |
| 5. Alt+S (init -> save functions) | OK | 1 WARNING below |
| 6. Startup (gui-startup -> instance_manager auto-restore) | OK | 2 WARNINGs below |

### Warnings (non-blocking)

| Caller | Callee | Status | Issue |
|--------|--------|--------|-------|
| init.lua:187 | wezterm.emit(...) | WARNING | Alt+S emits event_driven_save.finished without `opts` arg. Listeners expecting opts get nil. Status bar listener works fine (takes 0 args). |
| instance_manager.lua:389 | fuzzy_loader.fuzzy_load callback | WARNING | Callback declares `(id, label)` but receives `(id, label, save_state_dir)`. 3rd arg silently ignored in Lua. Functionally correct. |
| instance_manager.lua:617 | show_instance_selector(gui_win, pane) | WARNING | Docstring says MuxWindow but receives GuiWindow. Works because perform_action is a GuiWindow method. |
| instance_manager.lua:47 | state_manager.save_state_dir | WARNING | No nil guard. Safe due to call ordering (init sets it first) but fragile. |
| tab_state.lua:183 | SAFE_RESTORE_PROCESSES | WARNING | `claude` in allowlist is defense-in-depth fallback. If handler pcall fails, falls through to raw argv replay bypassing handler's validations. |

---

## Action Items

### Must fix before merge (Critical/High security)
- [ ] **[HIGH]** Fix Unix shell injection in `fuzzy_loader.lua:80-88` -- use argument arrays
- [ ] **[HIGH]** Fix Unix shell injection in `instance_manager.lua:233-239` -- use argument arrays
- [ ] **[HIGH]** Fix Unix shell injection in `utils.lua:77-90` -- add metacharacter guard

### Should fix before merge
- [ ] **[MEDIUM]** Escape single quotes in hook command path (`process_handlers.lua:352-356`)
- [ ] **[MEDIUM]** Strengthen instance ID seeding (`instance_manager.lua:33-36`)
- [ ] **[MEDIUM]** Strip control chars from display_name and tab_summaries
- [ ] **[HIGH-OPT]** Extract duplicated fuzzy-restore callback (`instance_manager.lua`)
- [ ] **[MEDIUM-OPT]** Consolidate save logic into single `save_workspace_full()` function

### Can fix later
- [ ] **[MEDIUM]** Canonicalize path in `delete_state` (`state_manager.lua:284`)
- [ ] **[MEDIUM]** Lighter directory listing for `list_instances` (avoid PowerShell spawn)
- [ ] **[LOW]** Add schema validation to `load_instance`
- [ ] **[LOW]** Skip `write_current_state` when instance mode is active
- [ ] **[LOW]** Add recursion depth guard to `insert_panes`
- [ ] **[LOW]** Fix `pane_tree.map` return type annotation
- [ ] **[LOW]** Remove dead `is_windows`/`separator` from `init.lua`
- [ ] **[LOW]** Use dedicated event name for Alt+S manual save
- [ ] **[LOW]** Cache `state_manager` require in `instance_manager`
