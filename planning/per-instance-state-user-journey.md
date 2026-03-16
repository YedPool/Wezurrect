# Per-Instance State Management: Complete User Journey Map

## 1. First-Time Setup

### 1.1 User installs the plugin
- Adds `resurrect.setup(config)` to their `wezterm.lua`
- On first WezTerm launch:
  - Plugin downloads from GitHub
  - `setup()` runs:
    - Creates `state/instances/` directory
    - Configures Claude Code SessionStart hook in `~/.claude/settings.json` (idempotent)
    - Registers auto-save handlers
    - Registers keybindings
    - Registers status bar
  - Status bar appears: shows tab titles, no save time yet
  - Within seconds, first auto-save fires via `update-status` event
  - Status bar updates: "saved 14:30:05 | PowerShell"

### 1.2 User has Claude Code
- User runs `claude` or `claude2` in a pane
- Claude Code's SessionStart hook fires, writes session ID to `~/.claude/pane-sessions/<pane_id>.json`
- Next auto-save detects Claude Code via pane-session file (even if bash is the foreground process)
- State file captures: `{ name: "claude", argv: ["claude", "--resume", "<session-id>", "--dangerously-skip-permissions"] }`
- Status bar: "saved 14:30:15 | Claude Code, PowerShell"

---

## 2. Single Instance Daily Use

### 2.1 User opens WezTerm
- WezTerm starts, plugin loads
- Instance ID generated: `<pid>_<start_timestamp>` (e.g., `20184_1741873200`)
- Auto-save begins writing to `state/instances/20184_1741873200.json`
- Metadata written to `state/instances/20184_1741873200.meta`
- Status bar shows current tabs and save time
- NO auto-restore happens (tmux model: save auto, restore manual)
- If user wants previous sessions: presses Alt+R, sees saved instances, picks which to restore

### 2.2 User opens tabs and splits panes
- Opens new tab: `pane-focus-changed` fires (structure change), auto-save triggers
- Splits pane: same trigger, auto-save captures the new layout
- State file now includes the full pane tree (splits, CWDs, processes)
- Status bar updates save time

### 2.3 User closes a tab (intentionally done with it)
- Closes tab via Ctrl+W or clicking X
- `pane-focus-changed` fires (structure change)
- Auto-save triggers, captures current state WITHOUT the closed tab
- Instance state file updated: closed tab is gone
- Next restore will NOT include that tab
- This is the desired behavior: closed tab = user is done with it

### 2.4 User works normally for hours
- Periodic save fires every 5 minutes as a safety net
- Event-driven save fires on any structural change
- Claude Code pane-session files updated on each new Claude session
- Status bar continuously shows latest save time and tab titles

### 2.5 User closes WezTerm cleanly (clicks X / Alt+F4)
- WezTerm begins shutdown
- The last auto-save already captured the current state
- No special shutdown save needed (continuous save already has it)
- Instance state file remains in `state/instances/` for future restore
- User opens WezTerm later: can restore via Alt+R if desired

---

## 3. Multiple Instances

### 3.1 User opens three WezTerm windows
- Window A: PID 20184, instance_id = `20184_1741873200`
  - Tab 1: Claude Code (orahvision project)
  - Tab 2: Claude Code (wezterm-resurrect project)
- Window B: PID 29588, instance_id = `29588_1741873205`
  - Tab 1: Claude Code (personal project)
  - Tab 2: PowerShell
- Window C: PID 8916, instance_id = `8916_1741873210`
  - Tab 1: Claude Code (another project)

### 3.2 Each instance saves independently
- Instance A saves to `state/instances/20184_1741873200.json`
- Instance B saves to `state/instances/29588_1741873205.json`
- Instance C saves to `state/instances/8916_1741873210.json`
- No clobbering: each instance owns its own file

### 3.3 Metadata files show human-readable summaries
- `20184_1741873200.meta`:
  ```json
  {
    "instance_id": "20184_1741873200",
    "pid": 20184,
    "start_time": "2026-03-13T14:00:00",
    "last_save": "2026-03-13T16:45:12",
    "window_count": 1,
    "tab_count": 2,
    "tab_summaries": ["Claude Code (orahvision)", "Claude Code (wezterm-resurrect)"]
  }
  ```

### 3.4 User closes one tab in Window A
- Tab 2 (wezterm-resurrect) closed
- Instance A auto-saves: now only has Tab 1 (orahvision)
- Instances B and C are unaffected
- If user restores Instance A later, only Tab 1 comes back

### 3.5 Windows Update kills everything
- All three WezTerm processes killed
- No shutdown save fires (processes are dead)
- State files retain the last auto-save for each instance
- Instance A: 1 tab (orahvision) -- because the user already closed the other tab
- Instance B: 2 tabs (personal project + PowerShell)
- Instance C: 1 tab (another project)

### 3.6 User opens WezTerm after restart
- Fresh WezTerm window opens (no auto-restore)
- User presses Alt+R
- Selector shows:
  ```
  [x] Mar 13 16:45 -- Claude Code (orahvision) [1 tab]
  [x] Mar 13 16:44 -- Claude Code (personal), PowerShell [2 tabs]
  [x] Mar 13 16:43 -- Claude Code (another project) [1 tab]
  ```
- User checks all three, confirms
- Three windows open, each with their tabs and Claude sessions restored
- Each Claude Code session resumes via `claude --resume <exact-session-id>`
- Old instance state files are deleted (they now have new instance IDs)

---

## 4. Crash Recovery

### 4.1 WezTerm crashes mid-session
- Process dies unexpectedly
- No save fires (process is dead)
- Instance state file has the last auto-save (at most 5 minutes old, usually seconds)
- User reopens WezTerm, presses Alt+R, selects the crashed instance
- All tabs and Claude sessions restored from last save

### 4.2 System BSOD / power loss
- Same as crash: all instances die
- All instance state files retain their last save
- On reboot, user opens WezTerm, presses Alt+R
- All instances available for restore

### 4.3 WezTerm hangs (unresponsive)
- User kills via Task Manager
- Same as crash: no save fires, last state preserved
- Restore works normally

---

## 5. Manual Save and Restore (Keybindings)

### 5.1 Alt+W: Save workspace NOW
- Forces an immediate save of the current instance
- Useful before intentionally closing WezTerm
- Status bar updates save time

### 5.2 Alt+R: Restore from saved state
- Opens selector showing all saved instances
- Each entry shows: save time, tab summaries, tab count
- User selects one or more instances to restore
- Selected instances open as new windows
- Restored instance state files are cleaned up
- New instance IDs assigned to the restored windows

### 5.3 Alt+Shift+W: Save current window
- Saves just the current window (not the whole instance)
- Stored separately from instance saves
- Available in Alt+R alongside instance saves

### 5.4 Alt+Shift+T: Save current tab
- Saves just the current tab
- Available in Alt+R alongside instance saves

---

## 6. Claude Code Specific Journeys

### 6.1 Fresh Claude Code session (no --resume)
- User types `claude` or `claude --dangerously-skip-permissions`
- Claude Code starts, SessionStart hook fires
- Hook writes `{ session_id: "abc-123", ... }` to `~/.claude/pane-sessions/<pane_id>.json`
- Auto-save detects Claude Code via pane-session file
- Sanitize function reads session_id from pane-session file
- State saves: `argv: ["claude", "--resume", "abc-123", "--dangerously-skip-permissions"]`

### 6.2 Claude Code running a tool (bash command)
- Claude Code executes a bash command
- Foreground process changes to `bash` (not `claude`)
- Auto-save fires: foreground process is bash, no handler match
- Falls back to pane-session file check: file exists with session_id
- Builds synthetic process_info for claude
- State correctly saves Claude Code's info, not bash

### 6.3 Multiple Claude Code sessions across instances
- Instance A: pane 0 has Claude session abc-123, pane 1 has session def-456
- Instance B: pane 0 has Claude session ghi-789
- Each pane's session ID captured independently via WEZTERM_PANE env var
- Each instance's state file has the correct session IDs per pane
- On restore: each pane sends `claude --resume <correct-session-id>`

### 6.4 claude vs claude2 (multi-account)
- User runs `claude` (account 1) and `claude2` (account 2) in different panes
- detect() matches both via `^claude%d*$` pattern
- sanitize() preserves the original binary name (`claude` vs `claude2`)
- On restore: `claude --resume <id>` in one pane, `claude2 --resume <id>` in another

### 6.5 Restore sends command with delay
- On restore, PowerShell pane opens
- 3-second delay (configurable) allows PowerShell to initialize
- After delay: `claude --resume abc-123 --dangerously-skip-permissions` sent to pane
- Claude Code resumes the exact session

---

## 7. Status Bar

### 7.1 What the user sees
- Right side of tab bar shows:
  - Before first save: just tab titles (e.g., "Claude Code, PowerShell")
  - After first save: "saved 14:30:05 | Claude Code, PowerShell"
  - Multiple of same title: "saved 14:30:05 | Claude Code x3, PowerShell"

### 7.2 Updates
- Save time updates on every auto-save (event-driven or periodic)
- Tab titles update on every `update-status` event (frequently)
- User can glance at the status bar to know: what's saved and when

---

## 8. Cleanup and Retention

### 8.1 Automatic cleanup on startup
- On WezTerm startup, scan `state/instances/` for old files
- Delete instance state files older than 7 days (configurable)
- Prevents unbounded disk growth

### 8.2 Cleanup after restore (auto-delete)
- When user restores an instance, its old `.json` and `.meta` files are automatically deleted
- The restored windows get new instance IDs and start saving under those
- If the old instance had a `display_name`, it carries over to the new instance
- Prevents duplicate/stale entries in the selector

### 8.3 Manual cleanup
- Alt+R shows all saved instances
- User can choose to delete saved states they don't want
- Or user deletes files directly from `state/instances/`

---

## 9. Edge Cases

### 9.1 WezTerm opened but no tabs created
- Instance ID generated, but state has just one empty PowerShell pane
- Saved as a minimal state file
- On restore: just opens a PowerShell window (harmless)

### 9.2 Instance state file is corrupt
- `wezterm.json_parse` fails in pcall
- Log error, skip that instance in the selector
- Other instances still available for restore
- Graceful degradation: one corrupt file doesn't break everything

### 9.3 Pane-session file missing for a Claude Code pane
- SessionStart hook didn't fire (Claude Code started before hook was configured)
- Foreground process detection is also unreliable (might be bash)
- Falls back to saving as a text pane (scrollback)
- On restore: user gets a shell with scrollback text instead of Claude session
- Not ideal but not broken -- user can manually run `claude --resume`

### 9.4 Two instances have the same PID (PID reuse after reboot)
- Instance ID includes timestamp, not just PID
- `20184_1741873200` vs `20184_1741959600` are different instances
- No collision

### 9.5 Very long WezTerm session (days/weeks)
- Periodic save keeps state fresh every 5 minutes
- Instance state file stays small (process info, not scrollback)
- Claude Code pane-session files updated on each new session
- No memory or disk growth issues

### 9.6 User opens 20+ instances
- Each saves to its own file (20 files, each a few KB)
- Alt+R selector shows all 20 with summaries
- User can select/deselect which to restore
- Cleanup removes files older than 7 days

### 9.7 User restores into an instance that already has tabs
- Restored tabs open as NEW windows (not merged into existing)
- Existing tabs are untouched
- User now has their existing work PLUS the restored sessions

---

## 10. Configuration Options

All optional, sane defaults:

| Option | Default | Description |
|--------|---------|-------------|
| `periodic_interval` | 300 | Seconds between periodic saves |
| `restore_delay` | 3 | Seconds to wait before sending restore commands |
| `retention_days` | 7 | Auto-delete instance states older than this |
| `save_workspaces` | true | Save workspace-level state |
| `save_windows` | true | Save window-level state |
| `save_tabs` | true | Save tab-level state |
| `keybindings` | true | Register Alt+W/R/Shift+W/Shift+T |
| `status_bar` | true | Show save time + tab titles |
| `claude_hooks` | true | Auto-configure Claude Code SessionStart hook |
| `auto_restore_prompt` | true | Show instance selector on startup if saved instances exist |

---

## 11. Auto-Start Selector on Startup

On WezTerm startup, if saved instance files exist in `state/instances/`, the plugin
automatically shows the instance selector (InputSelector). This replaces the old
behavior of silently restoring `current_state`.

- **Config option**: `auto_restore_prompt` (default `true`)
- If `true` and saved instances exist: spawn a default window, then show selector after 1s delay
- If `true` but no instances: fall back to `resurrect_on_gui_startup()` (backward compat)
- If `false`: do nothing on startup; user can manually press Alt+R

User can dismiss the selector (Esc) to start fresh with the default window.

---

## 12. Delete Mode in Selector

The instance selector (shown on startup or via Alt+R) includes action entries at the bottom:

- **[Browse named saves]**: Opens the fuzzy_loader for workspace/window/tab named saves
- **[Rename an instance]**: Shows instance list; picking one prompts for a name
- **[Delete saved instances]**: Switches to delete mode

### Delete Mode
- Shows the same instance list, but selecting an instance **deletes** it (both `.json` and `.meta`)
- After each deletion, the delete selector re-shows (for deleting multiple instances)
- **[Back to main selector]** entry at the bottom returns to the restore selector
- Pressing Esc also exits delete mode

### Auto-Delete After Restore
- When the user restores an instance, the old instance files are automatically deleted
- The restored windows get new instance IDs and start saving under those
- If the old instance had a `display_name`, it carries over to the new instance

---

## 13. Persistent Instance Names

Instances can have a user-assigned `display_name` that persists across saves and restores.

### How It Works
- `.meta` files have a `display_name` field (nil by default)
- **Named instances** show as: `"Orahvision Dev -- Claude Code, PowerShell [2 tabs]"`
- **Unnamed instances** show as: `"Mar 13 16:45 -- Claude Code, PowerShell [2 tabs]"`

### Renaming
- In the main selector, pick **[Rename an instance]**
- Select which instance to rename from the list
- Enter a name in the text prompt
- Name is written to the `.meta` file and immediately reflected
- If renaming the current instance, the in-memory `display_name` also updates

### Carry-Over on Restore
- When restoring an instance, its `display_name` carries over to the new instance ID
- The user does not need to re-name the instance after each restore
