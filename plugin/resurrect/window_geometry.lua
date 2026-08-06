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
-- v2 added the apply mode and SetWindowPlacement.
local SCRIPT_VERSION = 2

local SCRIPT = [==[
param(
    [string]$AssemblyPath,
    [switch]$Apply,
    [int]$Left = 0, [int]$Top = 0, [int]$Right = 0, [int]$Bottom = 0, [int]$ShowCmd = 0
)

# Without -Apply: prints "<left> <top> <right> <bottom> <showCmd>" for the main
# WezTerm window, or exits non-zero when there is not one to read.
# With -Apply: hands those five numbers straight back to Windows.
#
# showCmd: 1 normal, 2 minimized, 3 maximized. The rect is rcNormalPosition --
# where the window sits when it is not maximized -- which is the only sensible
# thing to remember for a window that is.
#
# Reading and writing through the same struct is the point. Windows decides for
# itself which monitor the rect belongs to and how it scales there, so nothing
# has to reason about virtual desktop coordinates or per-monitor DPI.

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
  [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
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

if ($Apply) {
    $rect = New-Object RECT
    $rect.Left = $Left; $rect.Top = $Top; $rect.Right = $Right; $rect.Bottom = $Bottom
    $placement.rcNormalPosition = $rect
    # Never restore a window minimized: it was saved that way, but reopening to
    # nothing visible reads as a failure to open at all.
    $placement.showCmd = if ($ShowCmd -eq 3) { 3 } else { 1 }
    if (-not [WeztermResurrectWin32]::SetWindowPlacement($proc.MainWindowHandle, [ref]$placement)) { exit 1 }
    "applied"
    exit 0
}

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

-- The last geometry this process saw, with no expiry.
--
-- Most saves are event-driven and deliberately do not pay for a capture. Without
-- somewhere to remember the answer they would each write a state with no
-- geometry in it, so opening a tab would quietly erase the position that the
-- last periodic save recorded -- and closing before the next one would lose it.
local last_known = nil

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
	-- Only on success: a capture declined because two windows are open says
	-- nothing about where the window was, and must not erase what we knew.
	if geometry then
		last_known = geometry
	end
	return geometry
end

--- The most recent geometry seen, for saves that do not pay for a capture.
---@return table|nil
function pub.last_known()
	if not pub.enabled then
		return nil
	end
	return last_known
end

--- Put a restored window back where it was.
---
--- Handed back to Windows through SetWindowPlacement rather than applied with
--- WezTerm's own set_position and maximize. Mixing the two does not work: the
--- rect came out of GetWindowPlacement in Windows' coordinates, and feeding
--- those to set_position -- which has its own idea of scaling -- lands the
--- window near the right monitor but offset across it, and a maximize that
--- follows a position it disagrees with does not snap to the screen. Giving
--- Windows back the exact struct it produced sidesteps the whole question of
--- virtual desktop coordinates and per-monitor DPI.
---
--- Best effort: a window can be closing, and none of this is worth losing a
--- restore over.
---@param gui_window any GuiWindow, unused on Windows but kept for other platforms
---@param geometry table|nil
function pub.apply(gui_window, geometry)
	if not geometry then
		return
	end
	-- Seed what we know from what we just restored, so the saves before the
	-- first capture of this process carry it forward rather than dropping it.
	last_known = geometry

	if not pub.enabled or not utils.is_windows then
		return
	end
	if not (geometry.x and geometry.y and geometry.outer_width and geometry.outer_height) then
		return
	end

	local script_path, assembly_path = ensure_script()
	if not script_path then
		return
	end

	pcall(utils.exec, {
		"powershell.exe", "-NoProfile", "-NoLogo", "-File", script_path,
		"-AssemblyPath", assembly_path,
		"-Apply",
		"-Left", tostring(geometry.x),
		"-Top", tostring(geometry.y),
		"-Right", tostring(geometry.x + geometry.outer_width),
		"-Bottom", tostring(geometry.y + geometry.outer_height),
		"-ShowCmd", geometry.maximized and "3" or "1",
	})
end

-- Expose internals for unit testing only
pub._test = {
	SCRIPT = SCRIPT,
	reset = function()
		memo.at, memo.value = nil, nil
		last_known = nil
	end,
}

return pub
