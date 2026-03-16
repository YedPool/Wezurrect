-- instance_manager.lua -- Per-instance state management
--
-- Each WezTerm process gets a unique instance ID (time + random) and saves
-- independently to state/instances/. On startup or Alt+R, an InputSelector
-- shows all saved instances for restore/delete/rename.
--
-- This module owns all instance lifecycle logic. state_manager.lua stays
-- focused on named workspace/window/tab saves.

local wezterm = require("wezterm") --[[@as Wezterm]]
local file_io = require("resurrect.file_io")
local utils = require("resurrect.utils")

local pub = {}

-- Generated once per WezTerm process at setup() time
pub.instance_id = nil

-- Persistent display name for this instance (carries over on restore)
pub.display_name = nil

-- Configuration (set via setup())
pub.retention_days = 7
pub.auto_restore_prompt = true

-- ---------------------------------------------------------------------------
-- Instance ID
-- ---------------------------------------------------------------------------

--- Generate a unique instance ID: epoch seconds + underscore + 5-digit random.
--- Called once during setup(). The combination of 1-second resolution and 90k
--- random values makes collisions negligible for desktop use.
function pub.init_instance_id()
    math.randomseed(os.time())
    pub.instance_id = tostring(os.time()) .. "_" .. tostring(math.random(10000, 99999))
    return pub.instance_id
end

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

--- Return the absolute path to the instances directory.
---@return string
function pub.get_instances_dir()
    local state_manager = require("resurrect.state_manager")
    return state_manager.save_state_dir .. utils.separator .. "instances"
end

--- Validate that an instance ID matches the expected format.
--- Rejects anything that could be a path traversal attempt.
---@param id string
---@return boolean
local function is_valid_instance_id(id)
    return type(id) == "string" and id:match("^%d+_%d+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Meta helpers
-- ---------------------------------------------------------------------------

--- Build the .meta file path for a given instance ID.
---@param instance_id string
---@return string
local function meta_path(instance_id)
    return pub.get_instances_dir() .. utils.separator .. instance_id .. ".meta"
end

--- Build the .json state file path for a given instance ID.
---@param instance_id string
---@return string
local function state_path(instance_id)
    return pub.get_instances_dir() .. utils.separator .. instance_id .. ".json"
end

--- Read and parse a .meta file. Returns nil on any failure.
---@param instance_id string
---@return table|nil
local function read_meta(instance_id)
    local path = meta_path(instance_id)
    local ok, content = file_io.read_file(path)
    if not ok or not content then
        return nil
    end
    local success, parsed = pcall(wezterm.json_parse, content)
    if not success then
        return nil
    end
    return parsed
end

--- Write a .meta file as JSON.
---@param instance_id string
---@param meta table
local function write_meta(instance_id, meta)
    local path = meta_path(instance_id)
    local json = wezterm.json_encode(meta)
    local ok, err = file_io.write_file(path, json)
    if not ok then
        wezterm.log_error("resurrect: failed to write instance meta: " .. tostring(err))
    end
end

--- Build tab summaries from workspace state for display in the selector.
--- Returns an array of short strings like "Claude Code", "PowerShell".
---@param workspace_state table
---@return string[]
local function build_tab_summaries(workspace_state)
    local summaries = {}
    if not workspace_state or not workspace_state.window_states then
        return summaries
    end
    for _, win_state in ipairs(workspace_state.window_states) do
        if win_state.tabs then
            for _, tab in ipairs(win_state.tabs) do
                local title = tab.title or ""
                if title ~= "" then
                    table.insert(summaries, title)
                end
            end
        end
    end
    return summaries
end

--- Count tabs across all windows in a workspace state.
---@param workspace_state table
---@return number
local function count_tabs(workspace_state)
    local count = 0
    if not workspace_state or not workspace_state.window_states then
        return count
    end
    for _, win_state in ipairs(workspace_state.window_states) do
        if win_state.tabs then
            count = count + #win_state.tabs
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Core CRUD
-- ---------------------------------------------------------------------------

--- Save the current instance state and metadata.
--- Wraps workspace_state with instance_id, writes both .json and .meta files.
---@param workspace_state table
function pub.save_instance(workspace_state)
    if not pub.instance_id then
        return
    end

    -- Wrap state with instance ID
    local instance_state = {
        instance_id = pub.instance_id,
        workspace_state = workspace_state,
    }

    -- Write state JSON
    local json = wezterm.json_encode(instance_state)
    local ok, err = file_io.write_file(state_path(pub.instance_id), json)
    if not ok then
        wezterm.log_error("resurrect: failed to write instance state: " .. tostring(err))
        wezterm.emit("resurrect.error", "Failed to save instance state: " .. tostring(err))
        return
    end

    -- Write metadata (lightweight, for fast listing)
    local tab_summaries = build_tab_summaries(workspace_state)
    local meta = {
        instance_id = pub.instance_id,
        display_name = pub.display_name,
        last_save_epoch = os.time(),
        last_save = os.date("%Y-%m-%dT%H:%M:%S"),
        tab_count = count_tabs(workspace_state),
        tab_summaries = tab_summaries,
    }
    write_meta(pub.instance_id, meta)

    wezterm.emit("resurrect.instance_manager.save_instance.finished", pub.instance_id)
end

--- Load an instance's workspace state from disk.
--- Returns the workspace_state portion, or nil on failure.
---@param instance_id string
---@return table|nil
function pub.load_instance(instance_id)
    if not is_valid_instance_id(instance_id) then
        wezterm.log_error("resurrect: load_instance rejected invalid ID: " .. tostring(instance_id))
        wezterm.emit("resurrect.error", "Invalid instance ID")
        return nil
    end

    local path = state_path(instance_id)
    local ok, content = file_io.read_file(path)
    if not ok or not content then
        wezterm.log_error("resurrect: could not read instance state: " .. path)
        return nil
    end

    local success, parsed = pcall(wezterm.json_parse, content)
    if not success or not parsed then
        wezterm.log_error("resurrect: invalid JSON in instance state: " .. path)
        return nil
    end

    return parsed.workspace_state
end

--- List all saved instances, newest first.
--- Reads only .meta files for speed, falls back gracefully if meta is missing.
---@return table[] array of { instance_id: string, meta: table }
function pub.list_instances()
    local instances_dir = pub.get_instances_dir()
    local results = {}

    -- Scan for .json files to find instance IDs, then read their .meta
    -- Use platform-appropriate directory listing
    local stdout
    if utils.is_windows then
        local success, output = wezterm.run_child_process({
            "powershell.exe", "-NoProfile", "-NoLogo", "-Command",
            string.format(
                "Get-ChildItem -Path '%s' -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }",
                instances_dir:gsub("'", "''")
            ),
        })
        if success then
            stdout = output
        end
    else
        local success, output = wezterm.run_child_process({
            "sh", "-c",
            'ls "' .. instances_dir:gsub('"', '\\"') .. '"/*.json 2>/dev/null | xargs -I{} basename {} .json',
        })
        if success then
            stdout = output
        end
    end

    if not stdout then
        return results
    end

    for id in stdout:gmatch("[^\r\n]+") do
        id = id:match("^%s*(.-)%s*$") -- trim whitespace
        if is_valid_instance_id(id) then
            local meta = read_meta(id) or {
                instance_id = id,
                last_save_epoch = 0,
                tab_count = 0,
                tab_summaries = {},
            }
            table.insert(results, { instance_id = id, meta = meta })
        end
    end

    -- Sort newest first by last_save_epoch
    table.sort(results, function(a, b)
        return (a.meta.last_save_epoch or 0) > (b.meta.last_save_epoch or 0)
    end)

    return results
end

--- Delete an instance's .json and .meta files.
---@param instance_id string
---@return boolean
function pub.delete_instance(instance_id)
    if not is_valid_instance_id(instance_id) then
        wezterm.log_error("resurrect: delete_instance rejected invalid ID: " .. tostring(instance_id))
        wezterm.emit("resurrect.error", "Invalid instance ID: path traversal rejected")
        return false
    end

    local json_path = state_path(instance_id)
    local meta_file = meta_path(instance_id)

    os.remove(json_path)
    os.remove(meta_file)

    wezterm.log_info("resurrect: deleted instance " .. instance_id)
    wezterm.emit("resurrect.instance_manager.delete_instance.finished", instance_id)
    return true
end

--- Remove instances older than retention_days.
function pub.cleanup_old_instances()
    local cutoff = os.time() - (pub.retention_days * 86400)
    local instances = pub.list_instances()
    for _, entry in ipairs(instances) do
        if (entry.meta.last_save_epoch or 0) < cutoff then
            pub.delete_instance(entry.instance_id)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Display formatting
-- ---------------------------------------------------------------------------

--- Format an instance summary line for the InputSelector.
--- Named:   "Orahvision Dev -- Claude Code, PowerShell [2 tabs]"
--- Unnamed: "Mar 13 16:45 -- Claude Code, PowerShell [2 tabs]"
---@param meta table
---@return string
function pub.format_instance_summary(meta)
    -- Build the tab summary portion: "Claude Code, PowerShell"
    local summaries = meta.tab_summaries or {}
    -- Deduplicate and count
    local counts = {}
    local order = {}
    for _, s in ipairs(summaries) do
        if not counts[s] then
            counts[s] = 0
            table.insert(order, s)
        end
        counts[s] = counts[s] + 1
    end
    local parts = {}
    for _, name in ipairs(order) do
        if counts[name] > 1 then
            table.insert(parts, name .. " x" .. counts[name])
        else
            table.insert(parts, name)
        end
    end
    local tab_str = table.concat(parts, ", ")
    if tab_str == "" then
        tab_str = "(empty)"
    end

    local tab_count = meta.tab_count or 0
    local tab_label = tab_count == 1 and "1 tab" or (tab_count .. " tabs")

    -- Prefix: display_name or formatted date
    local prefix
    if meta.display_name and meta.display_name ~= "" then
        prefix = meta.display_name
    else
        local epoch = meta.last_save_epoch or 0
        if epoch > 0 then
            prefix = os.date("%b %d %H:%M", epoch)
        else
            prefix = "Unknown"
        end
    end

    return prefix .. " -- " .. tab_str .. " [" .. tab_label .. "]"
end

--- Rename an instance by updating its .meta display_name field.
---@param instance_id string
---@param new_name string
function pub.rename_instance(instance_id, new_name)
    if not is_valid_instance_id(instance_id) then
        return
    end

    local meta = read_meta(instance_id)
    if not meta then
        meta = { instance_id = instance_id }
    end
    meta.display_name = new_name
    write_meta(instance_id, meta)

    -- If this is the current instance, update in memory too
    if instance_id == pub.instance_id then
        pub.display_name = new_name
    end
end

-- ---------------------------------------------------------------------------
-- Selector UI
-- ---------------------------------------------------------------------------

--- Show the main instance selector. Offers restore, browse named saves,
--- rename, and delete modes.
---@param window table MuxWindow
---@param pane table Pane
---@param restore_opts table options passed to restore_workspace
function pub.show_instance_selector(window, pane, restore_opts)
    local instances = pub.list_instances()

    -- If no instances, fall through to fuzzy_load for named saves
    if #instances == 0 then
        local fuzzy_loader = require("resurrect.fuzzy_loader")
        fuzzy_loader.fuzzy_load(window, pane, function(id, label)
            local state_type = id:match("^([^/\\]+)")
            local name = id:match("[/\\](.+)$")
            if name then
                name = name:gsub("%.json$", "")
            end
            local state_manager = require("resurrect.state_manager")
            if state_type == "workspace" then
                local state = state_manager.load_state(name, "workspace")
                require("resurrect.workspace_state").restore_workspace(state, restore_opts)
            elseif state_type == "window" then
                local state = state_manager.load_state(name, "window")
                require("resurrect.window_state").restore_window(pane:window(), state, restore_opts)
            elseif state_type == "tab" then
                local state = state_manager.load_state(name, "tab")
                require("resurrect.tab_state").restore_tab(pane:tab(), state, restore_opts)
            end
        end)
        return
    end

    -- Build choices
    local choices = {}
    for _, entry in ipairs(instances) do
        table.insert(choices, {
            id = entry.instance_id,
            label = pub.format_instance_summary(entry.meta),
        })
    end

    -- Action entries at the bottom
    table.insert(choices, { id = "__BROWSE_NAMED__", label = "[Browse named saves]" })
    table.insert(choices, { id = "__RENAME_MODE__", label = "[Rename an instance]" })
    table.insert(choices, { id = "__DELETE_MODE__", label = "[Delete saved instances]" })

    window:perform_action(
        wezterm.action.InputSelector({
            action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
                if not id then
                    return
                end

                if id == "__BROWSE_NAMED__" then
                    -- Launch fuzzy_loader for named workspace/window/tab saves
                    local fuzzy_loader = require("resurrect.fuzzy_loader")
                    fuzzy_loader.fuzzy_load(inner_win, inner_pane, function(fid, flabel)
                        local state_type = fid:match("^([^/\\]+)")
                        local name = fid:match("[/\\](.+)$")
                        if name then
                            name = name:gsub("%.json$", "")
                        end
                        local state_manager = require("resurrect.state_manager")
                        if state_type == "workspace" then
                            local state = state_manager.load_state(name, "workspace")
                            require("resurrect.workspace_state").restore_workspace(state, restore_opts)
                        elseif state_type == "window" then
                            local state = state_manager.load_state(name, "window")
                            require("resurrect.window_state").restore_window(inner_pane:window(), state, restore_opts)
                        elseif state_type == "tab" then
                            local state = state_manager.load_state(name, "tab")
                            require("resurrect.tab_state").restore_tab(inner_pane:tab(), state, restore_opts)
                        end
                    end, { ignore_instances = true })
                    return
                end

                if id == "__RENAME_MODE__" then
                    pub.show_rename_selector(inner_win, inner_pane, restore_opts)
                    return
                end

                if id == "__DELETE_MODE__" then
                    pub.show_delete_selector(inner_win, inner_pane, restore_opts)
                    return
                end

                -- Default: restore the selected instance
                local old_meta = read_meta(id)
                local workspace_state = pub.load_instance(id)
                if workspace_state then
                    require("resurrect.workspace_state").restore_workspace(workspace_state, restore_opts)

                    -- Carry over display_name from old instance
                    if old_meta and old_meta.display_name and old_meta.display_name ~= "" then
                        pub.display_name = old_meta.display_name
                    end

                    -- Auto-delete old instance after restore (it now has a new ID)
                    pub.delete_instance(id)
                end
            end),
            title = "Restore Instance",
            description = "Select an instance to restore, or pick an action. Enter = accept, Esc = cancel",
            choices = choices,
            fuzzy = false,
        }),
        pane
    )
end

--- Show the rename selector: pick an instance, then enter a name.
---@param window table
---@param pane table
---@param restore_opts table
function pub.show_rename_selector(window, pane, restore_opts)
    local instances = pub.list_instances()
    if #instances == 0 then
        return
    end

    local choices = {}
    for _, entry in ipairs(instances) do
        table.insert(choices, {
            id = entry.instance_id,
            label = pub.format_instance_summary(entry.meta),
        })
    end

    window:perform_action(
        wezterm.action.InputSelector({
            action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
                if not id then
                    return
                end

                -- Prompt for a name using InputSelector with a text entry
                inner_win:perform_action(
                    wezterm.action.PromptInputLine({
                        description = "Enter a name for this instance:",
                        action = wezterm.action_callback(function(name_win, name_pane, name)
                            if name and name ~= "" then
                                pub.rename_instance(id, name)
                            end
                            -- Re-show main selector after rename
                            pub.show_instance_selector(name_win, name_pane, restore_opts)
                        end),
                    }),
                    inner_pane
                )
            end),
            title = "Rename Instance",
            description = "Select an instance to rename",
            choices = choices,
            fuzzy = false,
        }),
        pane
    )
end

--- Show the delete selector: pick instances to delete, one at a time.
---@param window table
---@param pane table
---@param restore_opts table
function pub.show_delete_selector(window, pane, restore_opts)
    local instances = pub.list_instances()
    if #instances == 0 then
        -- No more instances to delete, return to main selector
        pub.show_instance_selector(window, pane, restore_opts)
        return
    end

    local choices = {}
    for _, entry in ipairs(instances) do
        table.insert(choices, {
            id = entry.instance_id,
            label = pub.format_instance_summary(entry.meta),
        })
    end
    table.insert(choices, { id = "__BACK__", label = "[Back to main selector]" })

    window:perform_action(
        wezterm.action.InputSelector({
            action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
                if not id or id == "__BACK__" then
                    pub.show_instance_selector(inner_win, inner_pane, restore_opts)
                    return
                end

                pub.delete_instance(id)
                -- Re-show delete selector for deleting multiple
                pub.show_delete_selector(inner_win, inner_pane, restore_opts)
            end),
            title = "Delete Instance",
            description = "Select an instance to DELETE (permanent). Esc = back",
            choices = choices,
            fuzzy = false,
        }),
        pane
    )
end

-- ---------------------------------------------------------------------------
-- Startup integration
-- ---------------------------------------------------------------------------

--- Auto-restore callback for gui-startup.
--- 1. Cleans up old instances
--- 2. If instances exist and auto_restore_prompt: spawns window + shows selector
--- 3. If no instances: falls back to state_manager.resurrect_on_gui_startup()
function pub.auto_restore_on_startup()
    pub.cleanup_old_instances()

    local instances = pub.list_instances()

    if #instances == 0 then
        -- Backward compat: fall back to current_state mechanism
        require("resurrect.state_manager").resurrect_on_gui_startup()
        return
    end

    if not pub.auto_restore_prompt then
        -- User disabled auto-prompt; they can use Alt+R manually
        return
    end

    -- Spawn a default window, then show the instance selector after a short
    -- delay so the window is fully initialized.
    wezterm.mux.spawn_window({})

    wezterm.time.call_after(1, function()
        local gui_windows = wezterm.gui.gui_windows()
        if #gui_windows > 0 then
            local gui_win = gui_windows[1]
            local restore_opts = {
                relative = true,
                restore_text = true,
                on_pane_restore = require("resurrect.tab_state").default_on_pane_restore,
            }
            pub.show_instance_selector(gui_win, gui_win:active_pane(), restore_opts)
        end
    end)
end

return pub
