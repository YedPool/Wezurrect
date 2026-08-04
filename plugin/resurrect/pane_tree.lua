local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")
local process_handlers = require("resurrect.process_handlers")

---@class pane_tree_module
---@field max_nlines integer
local pub = {}
pub.max_nlines = 3500

---@alias Pane any
---@alias PaneInformation {left: integer, top: integer, height: integer, width: integer}
---@alias pane_tree {left: integer, top: integer, height: integer, width: integer, bottom: pane_tree?, right: pane_tree?, text: string, cwd: string, domain?: string, process?: local_process_info?, pane: Pane?, is_active: boolean, is_zoomed: boolean, alt_screen_active: boolean}
---@alias local_process_info {name: string, argv: string[], cwd: string, executable: string}

---compare function returns true if a is more left than b
---@param a PaneInformation
---@param b PaneInformation
---@return boolean
local function compare_pane_by_coord(a, b)
	if a.left == b.left then
		return a.top < b.top
	else
		return a.left < b.left
	end
end

---@param root PaneInformation
---@param pane PaneInformation
---@return boolean
local function is_right(root, pane)
	if root.left + root.width < pane.left then
		return true
	end
	return false
end

---@param root PaneInformation
---@param pane PaneInformation
---@return boolean
local function is_bottom(root, pane)
	if root.top + root.height < pane.top then
		return true
	end
	return false
end

---@param root pane_tree
---@param panes PaneInformation
---@return pane_tree | nil
local function pop_connected_bottom(root, panes)
	for i, pane in ipairs(panes) do
		if root.left == pane.left and root.top + root.height + 1 == pane.top then
			table.remove(panes, i)
			return pane
		end
	end
end

---@param root pane_tree
---@param panes PaneInformation
---@return pane_tree | nil
local function pop_connected_right(root, panes)
	for i, pane in ipairs(panes) do
		if root.top == pane.top and root.left + root.width + 1 == pane.left then
			table.remove(panes, i)
			return pane
		end
	end
end

-- Maximum recursion depth to prevent stack overflow from maliciously
-- crafted state files with deeply nested pane trees.
local MAX_PANE_DEPTH = 100

--- Identify which pane-session file (if any) belongs to this pane.
---
--- Local panes are keyed by WezTerm's pane id, which WezTerm exports to child
--- processes as WEZTERM_PANE. WSL panes cannot use that: WezTerm's WSLENV list
--- covers only TERM/COLORTERM/TERM_PROGRAM/TERM_PROGRAM_VERSION, so WEZTERM_PANE
--- does not cross into the distro. They are keyed instead by a per-shell id that
--- the shell integration we install inside the distro publishes as a user var
--- and exports into the environment, so Claude Code's hook can name its file
--- after it. See resurrect.wsl_integration.
---@param pane Pane
---@param is_wsl boolean
---@return number|string|nil
local function session_key_for(pane, is_wsl)
	if not is_wsl then
		return pane:pane_id()
	end
	local ok, user_vars = pcall(pane.get_user_vars, pane)
	if ok and user_vars then
		return user_vars.resurrect_shell_id
	end
	return nil
end

---@param root pane_tree | nil
---@param panes PaneInformation[]
---@param depth? number current recursion depth (defaults to 0)
---@return pane_tree | nil
local function insert_panes(root, panes, depth)
	depth = depth or 0
	if root == nil then
		return nil
	end
	if depth > MAX_PANE_DEPTH then
		wezterm.log_error("resurrect: pane tree exceeds maximum depth of " .. MAX_PANE_DEPTH)
		return root
	end

	-- Guard against duplicate processing in symmetric layouts
	-- In a perfect cross layout, a pane can appear in both right and bottom branches
	-- If already processed by another branch, skip to avoid nil pane access
	if root.pane == nil then
		return root
	end

	local domain = root.pane:get_domain_name()
	if not wezterm.mux.get_domain(domain):is_spawnable() then
		wezterm.log_warn("Domain " .. domain .. " is not spawnable")
		wezterm.emit("resurrect.error", "Domain " .. domain .. " is not spawnable")
	else
		root.domain = domain

		local is_wsl = utils.is_wsl_domain(domain)

		local cwd_url = root.pane:get_current_working_dir()
		root.cwd = utils.normalize_saved_cwd(cwd_url and cwd_url.file_path, domain)

		-- WSL panes are local ptys as far as the terminal is concerned, so
		-- scrollback capture and inject_output work on them exactly as they do
		-- for the "local" domain. Genuine multiplexer domains (SSH/mux) stay
		-- excluded: inject_output is unavailable there, and pulling scrollback
		-- over the wire would slow every save down.
		-- See: https://github.com/MLFlexer/resurrect.wezterm/issues/41
		if domain == "local" or is_wsl then
			root.alt_screen_active = root.pane:is_alt_screen_active()

			-- Windows can read the argv and cwd of a local child process. A WSL
			-- pane's foreground process lives inside the WSL VM and is reported
			-- as wsl.exe, so its argv is never replayable. For WSL panes the
			-- pane-session file is the only trustworthy process signal, and
			-- everything else falls through to scrollback restore.
			local can_replay_argv = not is_wsl
			local process_info = root.pane:get_foreground_process_info()
			local has_handler = can_replay_argv and process_handlers.find_handler(process_info) or false

			-- Check the pane-session file for Claude Code detection and
			-- binary disambiguation. This serves two purposes:
			-- 1. Fallback: when Claude runs a child process (bash, node),
			--    the foreground process isn't "claude" so find_handler misses it.
			-- 2. Binary fix: claude2.bat wraps the same "claude" binary with
			--    CLAUDE_CONFIG_DIR=~/.claude-alt. WezTerm reports name="claude"
			--    for both, but the transcript_path reveals which config dir
			--    was used, letting us restore with the correct binary.
			local session_key = session_key_for(root.pane, is_wsl)
			local pane_session = process_handlers.read_pane_session(session_key)
			if pane_session and pane_session.session_id then
				-- Infer which claude binary from the transcript_path.
				local bin = "claude"
				local tp = pane_session.transcript_path or ""
				if tp:find("[/\\]%.claude%-alt[/\\]") then
					bin = "claude2"
				end

				if not has_handler then
					-- Fallback: foreground process is a child, not claude
					has_handler = true
				end

				-- Always rebuild process_info from pane-session data so
				-- the correct binary name is used (claude vs claude2).
				-- The hook payload's cwd is authoritative: for a WSL pane it is
				-- the only source that reports a path from inside the distro.
				process_info = {
					name = bin,
					executable = bin,
					argv = (process_info and process_info.argv) or {},
					cwd = pane_session.cwd or (process_info and process_info.cwd) or "",
				}
			end

			if (root.alt_screen_active and can_replay_argv and process_info) or has_handler then
				process_info.children = nil
				process_info.pid = nil
				process_info.ppid = nil

				local nix_store = '/nix/store/'

				-- Since NixOS uses immutable paths for executables,
				-- we need to sanitize them before saving,
				-- otherwise restoring sessions will be a pain.
				if process_info.executable and process_info.executable:find(nix_store) then
					-- Replace executable path with `process_info.name`,
					-- because nix store paths are not stable across sessions,
					-- as well as being long and ugly.
					--
					-- Plus they pollute shell history if restored as part of `executable` + `argv`.
					process_info.executable = process_info.name or process_info.executable

					-- Clean up `process_info.argv` by removing command flags followed by `*/nix/store/*` paths.
					--
					-- Original `argv` stored by `resurrect.wezterm` before sanitization:
					--
					-- [
					--   "/nix/store/jx332jllgyrqbnzi8svnk8xbygc9nbmp-neovim-unwrapped-0.11.5/bin/nvim",
					--   "--cmd",
					--   "lua vim.g.loaded_node_provider=0;vim.g.loaded_perl_provider=0;vim.g.loaded_python_provider=0;vim.g.python3_host_prog='/nix/store/252cmdyhmr8ai7qz266yrawgmx7nfz5h-neovim-0.11.5/bin/nvim-python3';vim.g.ruby_host_prog='/nix/store/252cmdyhmr8ai7qz266yrawgmx7nfz5h-neovim-0.11.5/bin/nvim-ruby'",
					--   "--cmd",
					--   "set packpath^=/nix/store/g0f4d93y9q79q84qq4g41lyfcw3i1z7h-vim-pack-dir",
					--   "--cmd",
					--   "set rtp^=/nix/store/g0f4d93y9q79q84qq4g41lyfcw3i1z7h-vim-pack-dir",
					--   "Cargo.toml"
					-- ]
					--
					-- Sanitized `argv` after processing:
					-- [
					--   "nvim",
					--   "Cargo.toml",
					-- ]
					--
					-- Meaning that any `--cmd` or `-c` flags containing `/nix/store/*` paths are removed entirely from `argv`,
					-- while keeping other arguments intact.
					--
					-- On restoration, the executable will be resolved via `PATH`,
					-- so as long as `nvim`/`vim`/`gvim` is available in `PATH`, it should work fine.
					if process_info.argv then
						local args = {}
						local flag = nil
						local executables = {
							nvim = true,
							vim = true,
							gvim = true,
						}
						local is_vim = executables[process_info.executable]

						for i, arg in ipairs(process_info.argv) do
							if i == 1 then
								-- Ensure first element of `argv` is the `executable` path,
								-- which we have already sanitized above.
								args[#args + 1] = process_info.executable
							else
								if is_vim == nil then
									-- For non-vim executables, we only need to sanitize the `executable` path,
									-- so we can keep the rest of `argv` as is.

									args[#args + 1] = arg
								else
									if arg == '--cmd' or arg == '-c' then
										-- Save current flag for later use, in case next `arg` is `/nix/store/*` path (see next condition).
										flag = arg
									elseif flag ~= nil then
										if arg:find(nix_store) then
											-- Skip this `arg` as it contains `/nix/store/*` path
											-- Do not add anything to `args`
										else
											-- Not a nix store path, keep both `flag` and `arg` (value).
											args[#args + 1] = flag
											args[#args + 1] = arg
										end

										flag = nil
									else
										args[#args + 1] = arg
									end
								end
							end
						end

						process_info.argv = args
					end
				end

				-- Let registered process handlers sanitize argv for portable restoration.
				-- Pass the session key so handlers can look up external state (e.g.,
				-- Claude Code reads session IDs from ~/.claude/pane-sessions/<key>.json).
				process_handlers.sanitize_for_save(process_info, session_key)

				root.process = process_info
			else
				local nlines = root.pane:get_dimensions().scrollback_rows
				if nlines > pub.max_nlines then
					nlines = pub.max_nlines
				end
				root.text = root.pane:get_lines_as_escapes(nlines)
			end
		end
	end

	root.pane = nil

	if #panes == 0 then
		return root
	end

	local right, bottom = {}, {}
	for _, pane in ipairs(panes) do
		if is_right(root, pane) then
			table.insert(right, pane)
		end
		if is_bottom(root, pane) then
			table.insert(bottom, pane)
		end
	end

	if #right > 0 then
		local right_child = pop_connected_right(root, right)
		root.right = insert_panes(right_child, right, depth + 1)
	end

	if #bottom > 0 then
		local bottom_child = pop_connected_bottom(root, bottom)
		root.bottom = insert_panes(bottom_child, bottom, depth + 1)
	end

	return root
end

---Create a pane tree from a list of PaneInformation
---@param panes PaneInformation
---@return pane_tree | nil
function pub.create_pane_tree(panes)
	table.sort(panes, compare_pane_by_coord)
	local root = table.remove(panes, 1)
	return insert_panes(root, panes)
end

---maps over the pane tree (mutates in place)
---@param pane_tree pane_tree
---@param f fun(pane_tree: pane_tree): pane_tree
---@return pane_tree|nil
function pub.map(pane_tree, f)
	if pane_tree == nil then
		return nil
	end

	pane_tree = f(pane_tree)
	if pane_tree.right then
		pub.map(pane_tree.right, f)
	end
	if pane_tree.bottom then
		pub.map(pane_tree.bottom, f)
	end

	return pane_tree
end

function pub.fold(pane_tree, acc, f)
	if pane_tree == nil then
		return acc
	end

	acc = f(acc, pane_tree)
	if pane_tree.right then
		acc = pub.fold(pane_tree.right, acc, f)
	end
	if pane_tree.bottom then
		acc = pub.fold(pane_tree.bottom, acc, f)
	end

	return acc
end

return pub
