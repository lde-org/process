local isWindows = jit.os == "Windows"

---@class process.raw
local raw = isWindows
	and require("process.raw.windows")
	or require("process.raw.posix")

local buffer = require("string.buffer")

---@alias process.Stdio "pipe" | "inherit" | "null"

---@class process.Options
---@field cwd string?
---@field env table<string, string>?
---@field stdin string?
---@field stdout process.Stdio?
---@field stderr process.Stdio?
---@field unsafe boolean? # Windows only: pass name and args through verbatim (space-joined, no quoting/escaping). Use when args already form a fully-quoted shell command string (e.g. { "/c", cmd } for cmd.exe, whose quote handling is incompatible with per-arg escaping); the caller owns quoting. No-op on POSIX, where args are passed to the child directly.

---@class process.Child
---@field pid number
---@field kill fun(self: process.Child, force: boolean?)
---@field wait fun(self: process.Child): number?, string?, string?
---@field poll fun(self: process.Child): number?

---@class process
local process = {}

if jit.os == "Windows" then
	process.platform = "win32"
elseif jit.os == "Linux" then
	process.platform = "linux"
elseif jit.os == "OSX" then
	process.platform = "darwin"
else
	process.platform = "unix"
end

local function waitHandle(r)
	if isWindows then return raw.wait(r.handle) else return raw.wait(r.pid) end
end

local function pollHandle(r)
	if isWindows then return raw.poll(r.handle) else return raw.poll(r.pid) end
end

local function killHandle(r, force)
	if isWindows then raw.kill(r.handle) else raw.kill(r.pid, force) end
end

--- Spawn a process asynchronously. Returns a Child handle.
---@param name string
---@param args string[]?
---@param opts process.Options?
---@return process.Child?, string?
function process.spawn(name, args, opts)
	opts = opts or {}
	local result, err = raw.spawn(name, args or {}, {
		cwd    = opts.cwd,
		env    = opts.env,
		stdin  = opts.stdin,
		stdout = opts.stdout or "null",
		stderr = opts.stderr or "null",
		unsafe = opts.unsafe,
	})
	if not result then return nil, err end

	-- Piped output is drained incrementally into these buffers. poll() reads
	-- whatever is available before checking the process state, so a child that
	-- out-writes the pipe buffer (a compiler emitting ~120KB of warnings, say)
	-- can never block on a full pipe and deadlock a spawn+poll consumer.
	-- wait() returns the accumulated output; the exit code is cached at poll()
	-- time because poll() reaps the child (POSIX) / closes the process handle
	-- (Windows), so wait() must not touch the process state a second time.
	local outStream = isWindows and result.stdoutHandle or result.stdoutFd
	local errStream = isWindows and result.stderrHandle or result.stderrFd
	local stdoutBuf, stderrBuf = buffer.new(), buffer.new()
	local outDone, errDone = outStream == nil, errStream == nil
	local exitCode ---@type number?

	--- Drain whatever output is currently available from one pipe; returns
	--- true once it hit EOF (the stream is closed after that).
	---@param stream number|ffi.cdata*?
	---@param buf string.buffer
	---@return boolean
	local function drain(stream, buf)
		if stream == nil then return true end
		return raw.readAvailable(stream, buf) == "eof"
	end

	---@type process.Child
	local child = { pid = result.pid }

	function child:kill(force) killHandle(result, force) end

	function child:poll()
		outDone = drain(outStream, stdoutBuf) or outDone
		errDone = drain(errStream, stderrBuf) or errDone
		local code = pollHandle(result)
		if code ~= nil then exitCode = code end
		return code
	end

	function child:wait()
		-- Block until both pipes are drained to EOF and the process exited.
		if isWindows then
			while not (outDone and errDone) do
				outDone = drain(outStream, stdoutBuf) or outDone
				errDone = drain(errStream, stderrBuf) or errDone
				if outDone and errDone then break end
				-- Poll the process with a short timeout while keeping the pipes
				-- flowing; WAIT_FAILED (handle closed by an earlier poll()) just
				-- loops until the broken-pipe EOFs show up.
				if raw.waitTimeout(result.handle, 25) then break end
			end
		else
			while not (outDone and errDone) do
				outDone = drain(outStream, stdoutBuf) or outDone
				errDone = drain(errStream, stderrBuf) or errDone
				if outDone and errDone then break end
				-- POSIX-only branch: the streams are fds here, not handles.
				raw.waitPipe(outDone and nil or outStream --[[@as number?]],
					errDone and nil or errStream --[[@as number?]])
			end
		end

		-- Final drain: pick up bytes written just before the child exited.
		outDone = drain(outStream, stdoutBuf) or outDone
		errDone = drain(errStream, stderrBuf) or errDone

		local code = exitCode or waitHandle(result)
		-- Non-piped streams (null/inherit) return nil output, matching the
		-- pre-buffering contract; piped streams return the captured bytes.
		local stdout = outStream ~= nil and stdoutBuf:tostring() or nil
		local stderr = errStream ~= nil and stderrBuf:tostring() or nil
		return code, stdout, stderr
	end

	return child
end

--- Execute a process and block until it exits.
---@param name string
---@param args string[]?
---@param opts process.Options?
---@return number? exitCode
---@return string? stdout
---@return string? stderr
function process.exec(name, args, opts)
	opts = opts or {}
	local child, err = process.spawn(name, args or {}, {
		cwd    = opts.cwd,
		env    = opts.env,
		stdin  = opts.stdin,
		stdout = opts.stdout or "pipe",
		stderr = opts.stderr or "pipe",
		unsafe = opts.unsafe,
	})
	if not child then return nil, nil, err end
	return child:wait()
end

return process
