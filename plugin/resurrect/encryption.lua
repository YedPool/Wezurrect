local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
---@alias encryption_opts {enable: boolean, method: string, private_key: string?, public_key: string?, encrypt: fun(file_path: string, lines: string), decrypt: fun(file_path: string): string}

local utils = require("resurrect.utils")

---@type encryption_opts
local pub = {
	enable = false,
	method = "age",
	private_key = nil,
	public_key = nil,
}

---executes cmd and passes input to stdin
---@param cmd string command to be run
---@param input string input to stdin
---@return boolean
---@return string
local function execute_cmd_with_stdin(cmd, input)
	if utils.is_windows and #input < 32000 then -- Check if input is larger than max cmd length on Windows
		cmd = string.format("%s | %s", wezterm.shell_join_args({ "Write-Output", "-NoEnumerate", input }), cmd)
		local process_args = { "pwsh.exe", "-NoProfile", "-Command", cmd }

		local success, stdout, stderr = wezterm.run_child_process(process_args)
		if success then
			return success, stdout
		else
			return success, stderr
		end
	elseif #input < 150000 and not utils.is_windows then -- Check if input is larger than common max on MacOS and Linux
		cmd = string.format("%s | %s", wezterm.shell_join_args({ "echo", "-E", "-n", input }), cmd)
		local process_args = { os.getenv("SHELL"), "-c", cmd }

		local success, stdout, stderr = wezterm.run_child_process(process_args)
		if success then
			return success, stdout
		else
			return success, stderr
		end
	else
		-- redirect stderr to stdout to test if cmd will execute
		-- can't check on Windows because it doesn't support /dev/stdin
		if not utils.is_windows then
			local stdout = io.popen(cmd .. " 2>&1", "r")
			if not stdout then
				return false, "Failed to execute: " .. cmd
			end
			local stderr = stdout:read("*all")
			stdout:close()
			if stderr ~= "" then
				wezterm.log_error(stderr)
				return false, stderr
			end
		end
		-- if no errors, execute cmd using stdin with input
		local stdin = io.popen(cmd, "w")
		if not stdin then
			return false, "Failed to execute: " .. cmd
		end
		stdin:write(input)
		stdin:flush()
		stdin:close()
		return true, '"' .. cmd .. '" <input> ran successfully.'
	end
end

---@param file_path string
---@param lines string
function pub.encrypt(file_path, lines)
	-- Write data to a temp file, then encrypt from file to avoid shell injection
	-- and command-line length limits
	local temp_input = os.tmpname()
	local f = io.open(temp_input, "w")
	if not f then
		error("Encryption failed: could not create temp file")
	end
	f:write(lines)
	f:flush()
	f:close()

	local cmd
	if pub.method:find("gpg") then
		cmd = {
			pub.method, "--batch", "--yes", "--encrypt",
			"--recipient", pub.public_key,
			"--output", file_path,
			temp_input,
		}
	else
		cmd = { pub.method, "-r", pub.public_key, "-o", file_path, temp_input }
	end

	local success, _, stderr = wezterm.run_child_process(cmd)
	os.remove(temp_input)
	if not success then
		error("Encryption failed: " .. (stderr or "unknown error"))
	end
end

---@param file_path string
---@return string
function pub.decrypt(file_path)
	local cmd = { pub.method, "-d", "-i", pub.private_key, file_path }

	if pub.method:find("gpg") then
		cmd = { pub.method, "--batch", "--yes", "--decrypt", file_path }
	end

	local success, stdout, stderr = wezterm.run_child_process(cmd)
	if not success then
		error("Decryption failed: " .. stderr)
	end

	return stdout
end

return pub
