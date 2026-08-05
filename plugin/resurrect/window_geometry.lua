-- Where the window is on screen, and whether it is maximized.
--
-- WezTerm can set both -- set_position, maximize -- but can read neither: a
-- GuiWindow's get_dimensions reports pixel_width, pixel_height, dpi and
-- is_full_screen, and there is no get_position at all. So the values have to
-- come from Windows itself, via GetWindowPlacement.
--
-- That costs a PowerShell process, which is why this is off by default and only
-- runs on periodic and manual saves, never on the event-driven ones that fire
-- whenever a tab is opened. Compiling the interop takes about a second, so it is
-- cached as an assembly and merely loaded on later calls.
--
-- Only ever one window. Get-Process exposes MainWindowHandle, and WezTerm gives
-- Lua no way to map a GuiWindow to an OS window handle, so with two windows open
-- there is no telling which handle belongs to which. Rather than guess, capture
-- nothing.
local wezterm = require("wezterm") --[[@as Wezterm]]
local utils = require("resurrect.utils")

local pub = {}

-- Off by default: it is Windows-only and costs a subprocess per capture.
pub.enabled = false

-- Where the helper script and its cached assembly live. Set by setup().
pub.cache_dir = nil

-- Bump when SCRIPT changes so a stale copy on disk is replaced.
local SCRIPT_VERSION = 1

local SCRIPT = [==[
param([string]$AssemblyPath)

# Prints "<left> <top> <right> <bottom> <showCmd>" for the main WezTerm window,
# or exits non-zero when there is not one to read.
#
# showCmd: 1 normal, 2 minimized, 3 maximized. The rect is rcNormalPosition --
# where the window sits when it is not maximized -- which is the only sensible
# thing to remember for a window that is.

$source = @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
public struct WINDOWPLACEMENT {
  public int length; public int flags; public int showCmd;
  public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
}
public static class WeztermResurrectWin32 {
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
}
"@

$loaded = $false
if ($AssemblyPath) {
    if (Test-Path $AssemblyPath) {
        try { Add-Type -Path $AssemblyPath; $loaded = $true } catch { }
    }
    if (-not $loaded) {
        try {
            Add-Type -TypeDefinition $source -OutputAssembly $AssemblyPath -OutputType Library -ErrorAction Stop
            Add-Type -Path $AssemblyPath
            $loaded = $true
        } catch { }
    }
}
if (-not $loaded) { Add-Type -TypeDefinition $source }

$proc = Get-Process wezterm-gui -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { exit 1 }

$placement = New-Object WINDOWPLACEMENT
$placement.length = [System.Runtime.InteropServices.Marshal]::SizeOf($placement)
if (-not [WeztermResurrectWin32]::GetWindowPlacement($proc.MainWindowHandle, [ref]$placement)) { exit 1 }

$r = $placement.rcNormalPosition
"$($r.Left) $($r.Top) $($r.Right) $($r.Bottom) $($placement.showCmd)"
]==]

-- One capture is shared by everything saved in the same cycle, so a save that
-- walks several windows still only pays for one PowerShell.
--
-- Held for a couple of seconds rather than for the current one: the subprocess
-- itself takes over half a second, so an exact same-second test misses whenever
-- the call happens to straddle a tick, which is most of the time.
local MEMO_SECONDS = 2
local memo = { at = nil, value = nil }

---@return string|nil script_path
---@return string|nil assembly_path
local function ensure_script()
	if not pub.cache_dir then
		return nil, nil
	end
	if not utils.ensure_folder_exists(pub.cache_dir) then
		return nil, nil
	end

	local sep = utils.separator
	local script_path = pub.cache_dir .. sep .. "window-geometry.v" .. SCRIPT_VERSION .. ".ps1"
	local assembly_path = pub.cache_dir .. sep .. "window-geometry.v" .. SCRIPT_VERSION .. ".dll"

	local existing = io.open(script_path, "r")
	if existing then
		existing:close()
		return script_path, assembly_path
	end

	local handle = io.open(script_path, "wb")
	if not handle then
		wezterm.log_error("resurrect: cannot write window geometry helper to " .. script_path)
		return nil, nil
	end
	handle:write(SCRIPT)
	handle:flush()
	handle:close()
	return script_path, assembly_path
end

--- Read the position and maximized state of the WezTerm window.
---
--- Uses wezterm.run_child_process, so it must not run while the config is being
--- evaluated. Returns nil whenever the answer would be a guess -- disabled, not
--- Windows, no GUI, or more than one window open.
---@return {x: number, y: number, maximized: boolean}|nil
function pub.capture()
	if not pub.enabled or not utils.is_windows then
		return nil
	end

	local now = os.time()
	if memo.at and (now - memo.at) < MEMO_SECONDS then
		return memo.value
	end

	local ok, windows = pcall(wezterm.gui.gui_windows)
	if not ok or not windows or #windows ~= 1 then
		return nil
	end

	local script_path, assembly_path = ensure_script()
	if not script_path then
		return nil
	end

	local ran, output = utils.exec({
		"powershell.exe", "-NoProfile", "-NoLogo", "-File", script_path, "-AssemblyPath", assembly_path,
	})

	local geometry = nil
	if ran and output then
		local left, top, right, bottom, show =
			output:match("(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%d+)")
		if left then
			geometry = {
				x = tonumber(left),
				y = tonumber(top),
				-- Kept for diagnostics; the size actually restored comes from
				-- WezTerm's own pixel dimensions, which are the inner size.
				-- rcNormalPosition is the outer rect, and feeding that back into
				-- set_inner_size would grow the window by its frame every cycle.
				outer_width = tonumber(right) - tonumber(left),
				outer_height = tonumber(bottom) - tonumber(top),
				maximized = tonumber(show) == 3,
			}
		end
	end

	memo.at, memo.value = now, geometry
	return geometry
end

--- Put a restored window back where it was.
--- Best effort throughout: every one of these can fail on a window that is
--- closing, and none of them is worth losing a restore over.
---@param gui_window any GuiWindow
---@param geometry table|nil
function pub.apply(gui_window, geometry)
	if not geometry or not gui_window then
		return
	end
	if geometry.x and geometry.y then
		pcall(function()
			gui_window:set_position(geometry.x, geometry.y)
		end)
	end
	if geometry.maximized then
		pcall(function()
			gui_window:maximize()
		end)
	end
end

-- Expose internals for unit testing only
pub._test = {
	SCRIPT = SCRIPT,
	reset_memo = function()
		memo.at, memo.value = nil, nil
	end,
}

return pub
