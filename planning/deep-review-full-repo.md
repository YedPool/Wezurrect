# Deep Review: wezterm-resurrect Full Repo
**Date:** 2026-03-13
**Branch:** main
**Files Reviewed:** 15 Lua files + README.md

---

## Executive Summary

The plugin is architecturally sound with clean call chains (0 broken cross-layer calls out of 73 verified). However, the security audit revealed 3 critical command injection vectors stemming from a single root cause: **state files are trusted implicitly, and their contents are sent as keystrokes to terminal panes**. Anyone who can write to the state directory can achieve arbitrary code execution. The optimization review found dead code, a 200-line function needing decomposition, and duplicated save logic. Overall this is solid work that needs input validation hardening before public release.

---

## Security Findings

### Critical

**S1. Command injection via crafted state files -- process restore commands**
- File: `tab_state.lua:197-206`, `process_handlers.lua:189`
- The `get_restore_cmd` function builds a command from JSON state data (`process_info.name`, `session_id`) and sends it to the terminal via `send_text()`. A tampered state file can inject arbitrary shell commands. While `wezterm.shell_join_args()` provides quoting, the binary name on line 189 is used without validation.
- Fix: Validate binary name matches `^claude[%d%-]*$` and session_id matches `^[%x%-]+$`.

**S2. Command injection via `cd` in tab restoration**
- File: `tab_state.lua:104`
- CWD from state file is sent as `cd <cwd>\r\n` to a shell pane. A crafted CWD with shell metacharacters could escape quoting.
- Fix: Reject CWDs containing `[;&|` + backtick + `$(){}]` characters.

**S3. Command injection in `setup_claude_session_hooks` via `os.execute`**
- File: `process_handlers.lua:290-293`
- `pane_sessions_dir` (derived from `HOME`/`USERPROFILE`) is interpolated into an `os.execute` shell string without sanitization. Does NOT use `utils.shell_mkdir` which has a `"` check.
- Fix: Use `utils.shell_mkdir()` or validate the path contains no shell metacharacters.

### High

**S4. Path traversal in `delete_state` -- incomplete protection**
- File: `state_manager.lua:251-266`
- Only checks for `..` but allows absolute paths, symlinks. `os.remove` called on user-influenced path.
- Fix: Also reject paths starting with `/`, `\`, or drive letters (`%a:`), and restrict to `.json` extension.

**S5. Secrets exposure -- terminal scrollback saved as plaintext JSON**
- File: `pane_tree.lua:239`
- Up to 3500 lines of scrollback (which may contain API keys, passwords, tokens) saved as plaintext JSON with default umask permissions.
- Fix: Set restrictive file permissions (0600/0700), consider secret-scrubbing regex, push encryption recommendation more prominently.

**S6. Arbitrary file overwrite via `WEZTERM_PANE` injection**
- File: `process_handlers.lua:343`
- The SessionStart hook command: `cat > "$HOME/.claude/pane-sessions/${WEZTERM_PANE:-unknown}.json"`. A crafted `WEZTERM_PANE` value like `../../.bashrc` would overwrite arbitrary files.
- Fix: Validate `WEZTERM_PANE` matches `^[0-9]+$` in the hook command.

**S7. Claude Code `settings.json` manipulation -- non-atomic write + TOCTOU**
- File: `process_handlers.lua:276-369`
- Reads, modifies, writes `settings.json` directly. Crash mid-write corrupts file. TOCTOU race with concurrent Claude Code writes.
- Fix: Write to temp file first, then rename. Add file locking or version marker.

### Medium

**S8. Shell injection in fuzzy_loader `find` command**
- File: `fuzzy_loader.lua:63-89`
- `base_path` embedded in shell string with only `"` escaping. `$()` or backticks not handled.
- Fix: Use `wezterm.run_child_process` with argument arrays.

**S9. Dead code with injection vulnerability (`execute_cmd_with_stdin`)**
- File: `encryption.lua:19-65`
- Unused function uses `io.popen(cmd)` with unescaped string. Risk if someone calls it later.
- Fix: Delete the function entirely.

**S10. Unvalidated `session_id` from pane session files**
- File: `process_handlers.lua:238-240`
- Session ID from JSON file used in commands without format validation.
- Fix: Validate matches `^[%x%-]+$`.

**S11. `read_pane_session` path injection via `pane_id`**
- File: `process_handlers.lua:128-152`
- `pane_id` used directly in file path. If ever a string with `..`, allows reading arbitrary JSON files.
- Fix: Validate `tostring(pane_id)` matches `^%d+$`.

**S12. Non-atomic file operations**
- Files: `state_manager.lua:209`, `process_handlers.lua:358`, `file_io.lua:25-27`
- Windows fallback in `write_file` has a window where file is deleted but not yet renamed (data loss on crash).

### Low

**S13.** `get_file_path` sanitization misses `%`, `#`, newlines, high-Unicode (`state_manager.lua:19`)
**S14.** Unbounded recursion in pane tree traversal (`pane_tree.lua:74-271`)
**S15.** `os.tmpname()` uses predictable paths on some systems (`encryption.lua:72`)
**S16.** No file permission control on state files (`file_io.lua`)
**S17.** `--dangerously-skip-permissions` flag persisted across restore cycles (`process_handlers.lua:205-207`)

---

## Optimization Findings

### Dead Code

**O1.** `execute_cmd_with_stdin` -- 47 lines, never called (`encryption.lua:19-65`) -- MEDIUM
**O2.** `utils.exec()` and `utils.execute()` -- never called by any module (`utils.lua:52-72`) -- LOW
**O3.** `pane_tree.map()` -- defined/exported but never called (`pane_tree.lua:286-300`) -- LOW
**O4.** `utils.deepcopy()` -- only called internally by `tbl_deep_extend`, could be local (`utils.lua:202-213`) -- LOW

### Duplication

**O5.** `periodic_save` and `event_driven_save` have near-identical save logic (`state_manager.lua:68-104` vs `129-157`) -- MEDIUM. Extract shared `save_all(opts, window_override)`.
**O6.** Inline `require()` calls repeated in save callbacks instead of top-level locals (`state_manager.lua:71,135,79,139,89,148`) -- LOW
**O7.** `is_windows` and `separator` computed in both `init.lua:7-8` and `utils.lua:5-7` -- LOW
**O8.** `save_tab_action()` and `save_window_action()` follow identical prompt-then-save pattern (`tab_state.lua:128-149`, `window_state.lua:90-112`) -- MEDIUM

### Code Quality

**O9.** `insert_panes` is 200 lines with 7+ responsibilities: domain detection, CWD normalization, alt-screen detection, process handler lookup, NixOS sanitization, scrollback capture, tree recursion (`pane_tree.lua:74-271`) -- **HIGH**
**O10.** Deep nesting (5+ levels) in process capture path (`pane_tree.lua:108-241`) -- MEDIUM
**O11.** `insert_choices` is 150 lines combining file parsing, width computation, and label assembly (`fuzzy_loader.lua:103-254`) -- LOW
**O12.** Filename sanitization regex is a magic character set with no documentation (`state_manager.lua:19`) -- LOW
**O13.** `acc.active_pane` nil dereference if no pane has `is_active = true` (`tab_state.lua:123`) -- MEDIUM

### Performance

**O14.** `periodic_save` reschedules itself recursively, creating new closures each time (`state_manager.lua:65-104`) -- MEDIUM
**O15.** `sanitize_json` runs gsub on entire JSON string every save; may be unnecessary if `json_encode` already escapes (`file_io.lua:74-81`) -- LOW
**O16.** `pane-focus-changed` handler computes structure signature on every focus change without debounce (`state_manager.lua:164-186`) -- LOW

### Architecture

**O17.** `pane_tree.lua` tightly coupled to `process_handlers` -- data structure module does process detection/session lookup (`pane_tree.lua`) -- **HIGH**
**O18.** `setup_claude_session_hooks` modifies external app config on every startup (`process_handlers.lua:276-369`) -- MEDIUM
**O19.** `save_state()` uses duck-typing to determine state type instead of explicit type field (`state_manager.lua:26-39`) -- MEDIUM
**O20.** Encryption state scattered across `file_io.lua` defaults + `encryption.lua` implementation + `state_manager.lua` delegation (`file_io.lua:3-5`) -- LOW

---

## Traceability Findings

### Call Chain: Save Flow (Trigger -> State Capture -> Process Handlers -> File I/O)

73 cross-layer calls verified across both save and restore flows.

| Category | Count |
|----------|-------|
| OK | 69 |
| WARNING | 4 |
| BROKEN | 0 |

**Warnings:**

| Caller | Callee | Issue |
|--------|--------|-------|
| `state_manager.lua:129-157` | `event_driven_save do_save()` | Not wrapped in `pcall` unlike `periodic_save`. Unhandled error could break WezTerm event handler chain. |
| `tab_state.lua:124` | `acc.active_pane:activate()` | `active_pane` may be nil if no pane has `is_active = true` (corrupted state). |
| `state_manager.lua:206` | `pub.save_state_dir` | No nil-guard. If `init()` fails, all subsequent calls produce confusing nil concatenation errors. |
| `pane_tree.lua:114` | `get_foreground_process_info()` | Could return nil if process exits between domain check and call. Guarded by `domain == "local"` but not nil-checked. |

### Call Chain: Restore Flow (Trigger -> File I/O -> State Restore -> Process Handlers)

| Category | Count |
|----------|-------|
| OK | 31 |
| WARNING | 2 |
| BROKEN | 0 |

**Warnings:**

| Caller | Callee | Issue |
|--------|--------|-------|
| `tab_state.lua:124` | `acc.active_pane:activate()` | Same nil dereference issue as save flow. |
| `init.lua:170` vs `fuzzy_loader.lua:283` | Callback arity | Fuzzy loader passes 3 args, callback declares 2. Harmless in Lua but unused `save_state_dir` arg. |

---

## Action Items

### 1. Must Fix (Critical/High security)

- [ ] **[CRITICAL]** Validate binary name in Claude Code restore command (`process_handlers.lua:189`) -- reject names not matching `^claude[%d%-]*$`
- [ ] **[CRITICAL]** Validate session_id format as UUID-like `^[%x%-]+$` (`process_handlers.lua:244`, `232-233`)
- [ ] **[CRITICAL]** Validate CWD in tab restore -- reject shell metacharacters (`tab_state.lua:104`)
- [ ] **[CRITICAL]** Fix `os.execute` injection in `setup_claude_session_hooks` -- use `utils.shell_mkdir` (`process_handlers.lua:290-293`)
- [ ] **[HIGH]** Harden `delete_state` path traversal protection -- reject absolute paths and non-.json files (`state_manager.lua:251-266`)
- [ ] **[HIGH]** Validate `WEZTERM_PANE` in hook command -- require numeric only (`process_handlers.lua:343`)
- [ ] **[HIGH]** Add nil guard for `acc.active_pane:activate()` (`tab_state.lua:124`)

### 2. Should Fix

- [ ] **[MEDIUM]** Delete dead `execute_cmd_with_stdin` function (`encryption.lua:19-65`)
- [ ] **[MEDIUM]** Validate `pane_id` is numeric in `read_pane_session` (`process_handlers.lua:128`)
- [ ] **[MEDIUM]** Wrap `event_driven_save do_save()` in `pcall` (`state_manager.lua:129-157`)
- [ ] **[MEDIUM]** Add nil-guard for `save_state_dir` (`state_manager.lua:206`)
- [ ] **[MEDIUM]** Use argument arrays in fuzzy_loader instead of shell strings (`fuzzy_loader.lua:63-89`)
- [ ] **[MEDIUM]** Extract duplicated save logic into shared function (`state_manager.lua:68-104` vs `129-157`)
- [ ] **[MEDIUM]** Decompose `insert_panes` 200-line function (`pane_tree.lua:74-271`)

### 3. Can Fix Later

- [ ] **[LOW]** Remove unused `utils.exec()`/`utils.execute()` (`utils.lua:52-72`)
- [ ] **[LOW]** Remove unused `pane_tree.map()` or document as public API (`pane_tree.lua:286-300`)
- [ ] **[LOW]** Decouple `pane_tree.lua` from `process_handlers` (`pane_tree.lua`)
- [ ] **[LOW]** Add explicit `type` field to state objects instead of duck-typing (`state_manager.lua:26-39`)
- [ ] **[LOW]** Debounce `pane-focus-changed` handler (`state_manager.lua:164-186`)
- [ ] **[LOW]** Use named local function for `periodic_save` rescheduling (`state_manager.lua:65-104`)
- [ ] **[LOW]** Set restrictive file permissions on state files (`file_io.lua`)
- [ ] **[LOW]** Consider not persisting `--dangerously-skip-permissions` flag (`process_handlers.lua:205-207`)
