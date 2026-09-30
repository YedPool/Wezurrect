local wezterm = require("wezterm") --[[@as Wezterm]]
local utils = require("resurrect.utils")
local pub = {}

-- Cleanup of redundant named saves.
--
-- Because saves are named after the window title, one conversation ends up
-- spread across many files (spinner-glyph frames plus every title the session
-- has been renamed to). Restoring any of them runs the same claude --resume,
-- so only the newest carries information the others do not - the rest are
-- dead weight in both the menu and the state dir.
--
-- Deletion is never automatic: the flow reports exactly what it would remove
-- and requires an explicit confirmation before touching anything.

---@return string state dir without a trailing separator
local function state_dir()
	return require("resurrect.state_manager").save_state_dir:gsub("[/\\]+$", "")
end

-- Relative path in the form delete_state expects (type/filename.json).
---@param entry table
---@return string
local function relative_path(entry)
	return entry.type .. utils.separator .. entry.filename
end

-- Gather the current annotated saves and work out what is redundant.
---@return {plan: table[], total: number, redundant: number, conversations: number}
function pub.survey()
	local fuzzy_loader = require("resurrect.fuzzy_loader")
	local save_index = require("resurrect.save_index")

	local base = require("resurrect.state_manager").save_state_dir
	local entries = fuzzy_loader.list_state_files(base)
	local annotated = save_index.annotate(base, entries)
	local plan = save_index.plan_cleanup(annotated)

	local redundant = 0
	for _, group in ipairs(plan) do
		redundant = redundant + #group.remove
	end

	return {
		plan = plan,
		total = #annotated,
		redundant = redundant,
		conversations = #save_index.dedupe(annotated),
	}
end

-- Human-readable dry-run report, newest-kept first.
---@param survey table result of pub.survey
---@param limit number? how many groups to detail
---@return string
function pub.format_report(survey, limit)
	limit = limit or 20
	local lines = {
		string.format(
			"%d saves on disk, %d distinct conversations, %d redundant copies.",
			survey.total,
			survey.conversations,
			survey.redundant
		),
		"",
	}

	local shown = 0
	for _, group in ipairs(survey.plan) do
		if shown >= limit then
			table.insert(lines, string.format("... and %d more groups", #survey.plan - shown))
			break
		end
		table.insert(lines, string.format("KEEP   %s", relative_path(group.keep)))
		for _, entry in ipairs(group.remove) do
			table.insert(lines, string.format("  drop %s", relative_path(entry)))
		end
		shown = shown + 1
	end

	return table.concat(lines, "\n")
end

-- Delete every redundant save in the plan. Returns counts; failures are
-- collected rather than aborting the run so one locked file cannot strand the
-- rest half-done.
---@param plan table[]
---@return number deleted, string[] failures
function pub.execute(plan)
	local state_manager = require("resurrect.state_manager")
	local deleted, failures = 0, {}

	for _, group in ipairs(plan) do
		for _, entry in ipairs(group.remove) do
			local rel = relative_path(entry)
			local ok = pcall(state_manager.delete_state, rel)
			if ok then
				deleted = deleted + 1
				-- The rolling .bak sibling belongs to the save we just removed;
				-- leaving it behind would orphan it forever. Best effort only.
				pcall(os.remove, state_dir() .. utils.separator .. rel .. ".bak")
			else
				table.insert(failures, rel)
			end
		end
	end

	return deleted, failures
end

-- Interactive entry point: survey, show what would be removed, confirm, run.
---@param window table GuiWindow
---@param pane table Pane
function pub.show_cleanup_selector(window, pane)
	local survey = pub.survey()

	if survey.redundant == 0 then
		window:toast_notification("resurrect", "No redundant saves found - nothing to clean up.", nil, 4000)
		return
	end

	local summary = string.format(
		"%d saves, %d conversations, %d redundant",
		survey.total,
		survey.conversations,
		survey.redundant
	)

	window:perform_action(
		wezterm.action.InputSelector({
			action = wezterm.action_callback(function(inner_win, inner_pane, id)
				if not id or id == "__CANCEL__" then
					return
				end

				if id == "__SHOW__" then
					-- Log the full plan, then come back to the same prompt so the
					-- user can act on what they just read.
					wezterm.log_info("resurrect cleanup plan:\n" .. pub.format_report(survey, 1000))
					inner_win:toast_notification(
						"resurrect",
						"Cleanup plan written to the debug overlay (Ctrl+Shift+L).",
						nil,
						5000
					)
					pub.show_cleanup_selector(inner_win, inner_pane)
					return
				end

				if id == "__DELETE__" then
					local deleted, failures = pub.execute(survey.plan)
					local msg = string.format("Deleted %d redundant saves.", deleted)
					if #failures > 0 then
						msg = msg .. string.format(" %d could not be deleted (see debug overlay).", #failures)
						wezterm.log_error("resurrect cleanup failures:\n" .. table.concat(failures, "\n"))
					end
					inner_win:toast_notification("resurrect", msg, nil, 5000)
					wezterm.emit("resurrect.cleanup.finished", deleted, #failures)
				end
			end),
			title = "Clean up duplicate saves",
			description = summary .. " - Esc = cancel",
			choices = {
				{ id = "__SHOW__", label = "[Show exactly what would be deleted]" },
				{
					id = "__DELETE__",
					label = string.format("[Delete %d redundant saves, keep newest of each]", survey.redundant),
				},
				{ id = "__CANCEL__", label = "[Cancel]" },
			},
			fuzzy = false,
		}),
		pane
	)
end

pub._test = {
	relative_path = relative_path,
}

return pub
