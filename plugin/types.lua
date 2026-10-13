---@alias tab_size {rows: integer, cols: integer, pixel_width: integer, pixel_height: integer, dpi: integer}
---@alias workspace_state {workspace: string, window_states: window_state[]}
---@alias window_state {title: string, tabs: tab_state[], workspace: string, size: tab_size}
---@alias tab_state {title: string, pane_tree: pane_tree, is_active: boolean, is_zoomed: boolean}
---@alias MuxTab any
---@alias MuxWindow any

---@alias restore_opts {spawn_in_workspace: boolean?, relative: boolean?, absolute: boolean?, close_open_tabs: boolean?, close_open_panes: boolean?, pane: Pane?, pane_is_new: boolean?, liveness_read: boolean?, tab: MuxTab?, window: MuxWindow, resize_window: boolean?, on_pane_restore: fun(pane_tree: pane_tree)}
