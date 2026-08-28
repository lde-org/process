local ffi = require("ffi")
local sb  = require("string.buffer")

ffi.cdef([[
	typedef int pid_t;
	pid_t fork(void);
	int   execvp(const char* file, const char* const argv[]);
	pid_t waitpid(pid_t pid, int* status, int options);
	int   kill(pid_t pid, int sig);
	int   pipe(int pipefd[2]);
	long  read(int fd, void* buf, size_t count);
	long  write(int fd, const void* buf, size_t count);
	int   close(int fd);
	int   dup2(int oldfd, int newfd);
	int   open(const char* path, int flags, ...);
	int   setenv(const char* name, const char* value, int overwrite);
	int   chdir(const char* path);
	void  _exit(int status);
	struct pollfd { int fd; short events; short revents; };
	int   poll(struct pollfd* fds, unsigned long nfds, int timeout);
]])

local WNOHANG  = 1
local SIGTERM  = 15
local SIGKILL  = 9
local O_WRONLY = 1
local POLLIN   = 1
local POLLHUP  = 16
local EINTR    = 4

---@diagnostic disable: assign-type-mismatch # Ignore incessant ffi type cast annoyance

---@class process.ffi.IntBox: ffi.cdata*
---@field [0] number

---@type fun(): process.ffi.IntBox
local IntBox   = ffi.typeof("int[1]")

---@class process.ffi.PipeFds: ffi.cdata*
---@field [0] number
---@field [1] number

---@type fun(): process.ffi.PipeFds
local PipeFds  = ffi.typeof("int[2]")

---@type fun(size: number): ffi.cdata*
local PollFds  = ffi.typeof("struct pollfd[?]")

---@class process.ffi.Argv: ffi.cdata*
---@field [0] string?

---@type fun(size: number): process.ffi.Argv
local Argv     = ffi.typeof("const char*[?]")

---@class process.raw
local M        = {}

---@param status number
---@return number?
local function decodeExit(status)
	if bit.band(status, 0x7f) == 0 then
		return bit.rshift(bit.band(status, 0xff00), 8)
	end
	return nil
end

---@param name string
---@param args string[]
---@return process.ffi.Argv
local function makeArgv(name, args)
	local argv = Argv(#args + 2)
	argv[0] = name
	for i, a in ipairs(args) do argv[i] = a end
	argv[#args + 1] = nil
	return argv
end

--- Spawn a child process.
---@param name string
---@param args string[]
---@param opts { cwd: string?, env: table<string,string>?, stdin: string?, stdout: "pipe"|"inherit"|"null"?, stderr: "pipe"|"inherit"|"null"?, unsafe: boolean? }?
---@return { pid: number, stdoutFd: number?, stderrFd: number? }?, string?
function M.spawn(name, args, opts)
	opts             = opts or {}
	local stdoutMode = opts.stdout or "pipe"
	local stderrMode = opts.stderr or "pipe"
	local hasStdin   = opts.stdin ~= nil

	local pIn        = PipeFds()
	local pOut       = PipeFds()
	local pErr       = PipeFds()

	if hasStdin and ffi.C.pipe(pIn) ~= 0 then return nil, "pipe() failed" end
	if stdoutMode == "pipe" and ffi.C.pipe(pOut) ~= 0 then return nil, "pipe() failed" end
	if stderrMode == "pipe" and ffi.C.pipe(pErr) ~= 0 then return nil, "pipe() failed" end

	local pid = ffi.C.fork()
	if pid < 0 then return nil, "fork() failed" end

	if pid == 0 then
		if hasStdin then
			ffi.C.dup2(pIn[0], 0); ffi.C.close(pIn[0]); ffi.C.close(pIn[1])
		end
		if stdoutMode == "pipe" then
			ffi.C.dup2(pOut[1], 1); ffi.C.close(pOut[0]); ffi.C.close(pOut[1])
		elseif stdoutMode == "null" then
			local fd = ffi.C.open("/dev/null", O_WRONLY); ffi.C.dup2(fd, 1); ffi.C.close(fd)
		end
		if stderrMode == "pipe" then
			ffi.C.dup2(pErr[1], 2); ffi.C.close(pErr[0]); ffi.C.close(pErr[1])
		elseif stderrMode == "null" then
			local fd = ffi.C.open("/dev/null", O_WRONLY); ffi.C.dup2(fd, 2); ffi.C.close(fd)
		end
		if opts.cwd then ffi.C.chdir(opts.cwd) end
		if opts.env then for k, v in pairs(opts.env) do ffi.C.setenv(k, v, 1) end end
		ffi.C.execvp(name, makeArgv(name, args))
		ffi.C._exit(1)
	end

	if hasStdin then ffi.C.close(pIn[0]) end
	if stdoutMode == "pipe" then ffi.C.close(pOut[1]) end
	if stderrMode == "pipe" then ffi.C.close(pErr[1]) end

	if hasStdin then
		ffi.C.write(pIn[1], opts.stdin, #opts.stdin)
		ffi.C.close(pIn[1])
	end

	return {
		pid      = tonumber(pid),
		stdoutFd = stdoutMode == "pipe" and tonumber(pOut[0]) or nil,
		stderrFd = stderrMode == "pipe" and tonumber(pErr[0]) or nil
	}
end

--- Read whatever output is currently available from a pipe fd into buf
--- without blocking. Returns "eof" once the writer has closed (the fd is
--- closed by this call); "open" while more data may still arrive.
---@param fd number
---@param buf string.buffer
---@return "eof"|"open"
function M.readAvailable(fd, buf)
	while true do
		local fds = PollFds(1)
		fds[0].fd = fd
		fds[0].events = POLLIN
		-- poll(0) never blocks: 0 = nothing available, >0 = readable (or HUP), -1 = error
		if ffi.C.poll(fds, 1, 0) <= 0 then return "open" end
		if bit.band(fds[0].revents, POLLIN) ~= 0 then
			local ptr, len = buf:reserve(4096)
			local n = ffi.C.read(fd, ptr, len)
			if n > 0 then
				buf:commit(n)
			elseif n < 0 and ffi.errno() == EINTR then
				-- Interrupted by a signal; retry the read
			else
				buf:commit(0)
				ffi.C.close(fd)
				return "eof"
			end
		else
			-- POLLHUP/POLLERR with nothing more to read: drain any residual
			-- bytes (read returns what remains, then 0) and treat as EOF.
			local ptr, len = buf:reserve(4096)
			local n = ffi.C.read(fd, ptr, len)
			if n > 0 then buf:commit(n) end
			ffi.C.close(fd)
			return "eof"
		end
	end
end

--- Block until either pipe has data or hits EOF. Used by Child:wait to drain
--- both pipes without busy-waiting. Fds already drained to EOF may be nil.
---@param outFd number?
---@param errFd number?
function M.waitPipe(outFd, errFd)
	local fds = PollFds(2)
	fds[0].fd = outFd or -1
	fds[0].events = POLLIN
	fds[1].fd = errFd or -1
	fds[1].events = POLLIN
	ffi.C.poll(fds, 2, -1)
end

---@param pid number
---@return number?
function M.wait(pid)
	local st = IntBox()
	ffi.C.waitpid(pid, st, 0)
	return decodeExit(st[0])
end

---@param pid number
---@return number?
function M.poll(pid)
	local st = IntBox()
	if ffi.C.waitpid(pid, st, WNOHANG) == 0 then return nil end
	return decodeExit(st[0])
end

---@param pid number
---@param force boolean?
function M.kill(pid, force)
	ffi.C.kill(pid, force and SIGKILL or SIGTERM)
end

return M
