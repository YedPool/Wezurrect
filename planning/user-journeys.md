# Resurrect: User Journey Map

Everything below is from the user's point of view. No implementation details.

---

## Journey 1: Normal Workday

1. I open WezTerm. Fresh window with PowerShell.
2. I open 3 tabs. In each one I start a Claude Code session for different projects.
3. I work for a few hours. The status bar in the top right says "saved 14:30:05 | Claude Code x3".
4. I finish one project. I close that tab.
5. Status bar updates: "saved 14:30:12 | Claude Code x2". The closed tab is gone from the save.
6. End of day. I close WezTerm.
7. Next morning I open WezTerm. Fresh window.
8. I press Alt+R. I see:
   ```
   Mar 13 14:30 -- Claude Code x2 [2 tabs]
   ```
9. I select it and hit enter.
10. A window opens with 2 tabs. Each tab has my exact Claude Code session resumed right where I left off.
11. The third tab (the one I closed yesterday) is not there. Good, I was done with it.

---

## Journey 2: Multiple WezTerm Windows

1. I open WezTerm window A. Start Claude Code for the orahvision project.
2. I open WezTerm window B. Start Claude Code for a personal project and a PowerShell tab for git work.
3. I open WezTerm window C. Start two Claude Code sessions for a client project.
4. Status bars show independently:
   - Window A: "saved 14:00 | Claude Code"
   - Window B: "saved 14:01 | Claude Code, PowerShell"
   - Window C: "saved 14:02 | Claude Code x2"
5. In window B, I close the PowerShell tab. I'm done with it.
6. Window B status bar updates: "saved 14:03 | Claude Code". PowerShell tab is gone from the save.
7. I close all three windows and go to lunch.
8. After lunch I open WezTerm. Fresh window.
9. I press Alt+R. I see:
   ```
   Mar 13 14:03 -- Claude Code [1 tab]
   Mar 13 14:02 -- Claude Code x2 [2 tabs]
   Mar 13 14:00 -- Claude Code [1 tab]
   ```
10. I select all three and hit enter.
11. Three windows open. Each has exactly the tabs I left open (not the ones I closed).
12. All five Claude Code sessions resume to their exact conversations.

---

## Journey 3: Windows Update Kills Everything

1. I have 3 WezTerm windows open with 8 Claude Code sessions across them.
2. Windows says "Restarting in 5 minutes" and I ignore it.
3. Windows kills everything. WezTerm didn't get a chance to do anything special.
4. Computer restarts. I log in. I open WezTerm.
5. I press Alt+R. All three instances are there with all 8 sessions.
6. I select all three, hit enter.
7. Three windows open. All 8 Claude Code sessions resume exactly where they were.
8. I lost at most 5 minutes of state (the periodic save interval).

---

## Journey 4: WezTerm Crashes

1. I'm working in WezTerm. One window has 3 Claude Code sessions.
2. WezTerm freezes. I kill it in Task Manager.
3. I reopen WezTerm. Fresh window.
4. I press Alt+R. My crashed instance is there:
   ```
   Mar 13 16:42 -- Claude Code x3 [3 tabs]
   ```
5. I select it, hit enter.
6. Window opens with all 3 sessions restored.

---

## Journey 5: I Only Want Some of My Old Sessions

1. Yesterday I had 4 WezTerm windows open. I closed them all at end of day.
2. Today I only need 2 of those projects.
3. I open WezTerm, press Alt+R. I see all 4 instances:
   ```
   Mar 12 17:30 -- Claude Code (orahvision) [3 tabs]
   Mar 12 17:28 -- Claude Code, PowerShell [2 tabs]
   Mar 12 17:25 -- Claude Code (client project) [2 tabs]
   Mar 12 17:20 -- PowerShell [1 tab]
   ```
4. I select only the first two. Hit enter.
5. Two windows open with those sessions. The other two stay saved in case I want them later.
6. After 7 days, the unrestored ones get automatically cleaned up.

---

## Journey 6: I Close a Tab by Mistake

1. I accidentally close a tab with a Claude Code session.
2. The auto-save fires and saves the state WITHOUT that tab.
3. BUT: the previous save (from before I closed it) is gone because the instance state file was overwritten.
4. However, Claude Code sessions persist on their end. I can always run `claude --continue` or `claude --resume <id>` manually to get that session back.
5. Resurrect handles windows and panes. Claude Code handles session persistence. They complement each other.

---

## Journey 7: I Open WezTerm But Don't Want to Restore Anything

1. I open WezTerm. Fresh window with PowerShell.
2. I don't press Alt+R. I just start working.
3. Old saved instances sit in storage. I can restore them anytime with Alt+R.
4. After 7 days they auto-delete.
5. No popups, no prompts, no interruptions.

---

## Journey 8: I Want to Save a Specific Layout to Reuse Later

1. I set up a perfect window layout: 4 panes split just right, each with the right CWD.
2. I press Alt+W to manually save this workspace. It saves alongside the auto-saves.
3. Days later, I press Alt+R and see my named save alongside the instance auto-saves.
4. I select it. My layout is restored exactly.
5. Unlike instance auto-saves, manual saves don't auto-delete after 7 days.

---

## Journey 9: First Time Using the Plugin

1. I add two lines to my wezterm.lua:
   ```lua
   local resurrect = wezterm.plugin.require("https://github.com/YedPool/resurrect.wezterm")
   resurrect.setup(config)
   ```
2. I restart WezTerm. Plugin downloads.
3. I see a status bar in the top right that says "saved 14:00:01 | PowerShell".
4. I don't need to configure anything else. Claude Code hooks are set up automatically. Save is automatic. Keybindings work.
5. I open some Claude Code sessions, work for a while, close WezTerm.
6. Next time I open WezTerm, I press Alt+R and my sessions are there.

---

## Journey 10: Running claude and claude2 (Multiple Accounts)

1. I have two Claude Code binaries: `claude` (work account) and `claude2` (personal account).
2. I open a WezTerm window. Tab 1 runs `claude`, Tab 2 runs `claude2`.
3. Auto-save captures both, remembering which binary each tab used.
4. I close WezTerm, reopen, press Alt+R.
5. Tab 1 restores with `claude --resume <session-id>`. Tab 2 restores with `claude2 --resume <session-id>`.
6. Each resumes in the correct account.

---

## What the User Never Sees or Thinks About

- Instance IDs, PIDs, timestamps -- all hidden behind human-readable summaries
- Pane-session files, SessionStart hooks -- set up automatically
- State file format, directory structure -- just works
- Cleanup of old files -- happens silently on startup
- The distinction between "foreground process is bash but Claude Code is running" -- handled automatically
