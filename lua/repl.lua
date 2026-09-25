-- Interactive REPL. Uses GNU readline (the same library bash links) via FFI for
-- line editing, history, and completion — no need to reimplement any of it. Falls
-- back to plain line reading when readline or a tty isn't available.
local ffi = require("ffi")
local parser = require("parser")
local interp = require("interp")
local rt = require("runtime")

ffi.cdef([[
  char *readline(const char *prompt);
  void add_history(const char *line);
  int read_history(const char *filename);
  int write_history(const char *filename);
  void using_history(void);
  int isatty(int fd);
  void free(void *ptr);
]])

-- Try to load readline by the names it ships under (there's often no unversioned
-- libreadline.so symlink, so probe the versioned soname too).
local RL
for _, name in ipairs({ "readline", "libreadline.so.8", "libreadline.so.7", "libreadline.so" }) do
	local ok, lib = pcall(ffi.load, name)
	if ok then
		RL = lib
		break
	end
end
local istty = ffi.C.isatty(0) == 1
local interactive = istty -- becomes true for `-i` too once run() sees opt_i

-- One line of input. With readline: full editing + history. Otherwise plain read.
-- (echo: line editing is on but stdin isn't a terminal — bash's readline still echoes
-- each line it reads after the prompt, on stderr)
local function read_line(prompt, echo)
	if RL and istty then -- readline only on a real tty; piped stdin prompts to stderr
		local c = RL.readline(prompt)
		if c == nil then
			return nil
		end -- EOF (Ctrl-D)
		local s = ffi.string(c)
		ffi.C.free(c)
		return s
	end
	-- The prompt goes to STDERR (bash), terminal or not
	if interactive then
		io.stderr:write(prompt)
	end
	if not istty then
		-- piped/redirected program text: read fd 0 RAW, one byte at a time (like bash on a
		-- non-seekable input), so a command the script runs — `read`, `cat`, a child — sees
		-- exactly the input after the current line (stdio would have buffered it away)
		local buf = {}
		while true do
			local ch = interp._int.fd_getc(0)
			if ch == nil or ch == "\n" then
				if ch == nil and #buf == 0 then
					return nil
				end
				local l = table.concat(buf)
				if echo and (l ~= "" or prompt ~= "") then -- (a blank display line gets no newline)
					io.stderr:write(l, "\n")
				end
				return l
			end
			if ch ~= "\0" then -- (shell_getc drops NUL bytes from the input)
				buf[#buf + 1] = ch
			end
		end
	end
	return io.read("*l")
end

-- Does `buf` have an obviously-unterminated construct, so the REPL should keep
-- reading (PS2) instead of running it? Shared with interp.source_file (rc-file
-- completeness). See interp.incomplete_input.
local function needs_more(buf)
	if interp.incomplete_input(buf) then
		return true
	end
	-- the real parser decides the rest (`f() {`, `{ echo`, `echo $(ls`, …)
	local ok, r = pcall(require("parser").parse, buf)
	local perr = (not ok and tostring(r)) or (r and r.stmts and r.stmts[1] and r.stmts[1].t == "parse_error"
		and tostring(r.stmts[1].msg)) or ""
	if perr:find("unexpected end of file", 1, true) ~= nil or perr:find("unexpected EOF", 1, true) ~= nil then
		return true
	end
	-- a here-document whose body hasn't all been read yet (`cat <<E` and no `E` line)
	for _, st in ipairs(ok and r and r.stmts or {}) do
		if st.t == "warn" and tostring(st.msg):find("delimited by end-of-file", 1, true) then
			return true
		end
	end
	return false
end

-- Expand PS1/PS2 escapes for the prompt via the shared, full prompt decoder.
local function prompt_of(sh, var, default)
	return interp.prompt_string(sh, sh.vars[var] and sh:get(var) or default, true)
end

local M = {}
function M.run(sh)
	-- re-probe the tty state per run: a resident daemon worker serves many callers' fds
	istty = ffi.C.isatty(0) == 1
	interactive = istty or (sh and sh.opt_i) or false -- prompts print for `-i` even off a tty
	-- Persist $HISTFILE across the session (load now, write at exit) — but only when
	-- it was EXPLICITLY set (env/script), never the ~/.bash_history default, so a
	-- piped `-i` run never clobbers the user's real history. On a real tty, readline
	-- also loads its editing history from the same file.
	local histfile = sh:get("HISTFILE")
	if histfile == "" or sh.histfile_default then
		histfile = nil
	end
	local H = require("hist")
	-- load_history: HISTSIZE/HISTFILESIZE default to 500, then an explicit $HISTFILE is read
	if histfile then
		H.load(sh)
	else
		local hf = sh.vars.HISTFILE
		sh.vars.HISTFILE = nil
		H.load(sh)
		sh.vars.HISTFILE = hf
	end
	if interactive then -- (shell.c: an interactive shell remembers its mailboxes' dates)
		require("mailcheck").init(sh)
	end
	if RL and istty then
		RL.using_history()
		pcall(function()
			RL.read_history(histfile or os.getenv("HISTFILE") or ((os.getenv("HOME") or ".") .. "/.curse_history"))
		end)
	end
	local buf = ""
	-- (a script read from stdin: each command runs with its real line numbers — lno is
	-- the lines read so far, bline the line the command in `buf` starts on)
	local lno, bline, eofs = 0, 1, 0
	local hst, hdq = {}, {} -- (history recording state for the command being read)
	sh.defer_exit_trap = true -- the EXIT trap fires once, when the session ends
	while true do
		if buf == "" then -- before each PRIMARY prompt, bash runs $PROMPT_COMMAND
			local ok, err = pcall(interp.run_prompt_command, sh)
			if not ok and type(err) == "table" and err.__curse_exit then
				io.flush()
				break
			end
			if sh.mailcheck then -- (then yylex checks the mailboxes)
				pcall(require("mailcheck").prompt, sh)
			end
			io.flush()
		end
		local prompt = buf == "" and prompt_of(sh, "PS1", "curse\\$ ") or prompt_of(sh, "PS2", "> ")
		local line = read_line(prompt, interactive and not istty and rt.line_editing(sh))
		if line == nil then -- EOF
			if buf:match("%S") then -- an unfinished command at EOF: run it so the syntax error shows
				-- (shell_getc ends the input with a newline: a final `\` is a continuation)
				pcall(interp.run_lazy, sh, buf .. "\n", nil, not interactive and bline or nil)
				io.flush()
				buf = ""
			elseif interactive and sh.opt_ignoreeof and buf == "" then
				-- (bash's handle_eof_input_unit: $IGNOREEOF EOFs in a row are refused)
				local lim = sh.vars.IGNOREEOF and sh:get("IGNOREEOF") or ""
				lim = lim:match("^%d+$") and tonumber(lim) or 10
				if eofs < lim then
					eofs = eofs + 1
					io.stderr:write('Use "' .. (sh.login_shell and "logout" or "exit") .. '" to leave the shell.\n')
					goto continue
				end
			end
			if interactive then -- (EOF runs `exit`: exit.def says so)
				require("runtime").exit_note(sh)
			end
			break
		end
		eofs = 0
		lno = lno + 1
		if buf == "" then
			bline, hst, hdq = lno, {}, {}
		end
		-- (history: `!` expansion and recording, one physical line at a time)
		line = interp.history_line(sh, hst, hdq, line, buf ~= "", lno)
		if line == nil then
			if buf == "" then
				goto continue
			end
			line = ""
		end
		buf = (buf == "") and line or (buf .. "\n" .. line)
		if buf:match("%S") and (#hdq > 0 or needs_more(buf)) then
		-- keep reading this logical command on the next line (PS2)
		else
			if buf:match("%S") then
				if RL and istty and require("hist").enabled(sh) then
					RL.add_history(buf)
				end
				-- (eval.c: $PS0 after reading a command, before running it)
				local ps0 = interactive and sh.vars.PS0 and prompt_of(sh, "PS0", "")
				if ps0 and ps0 ~= "" then
					io.stderr:write(ps0)
				end
				sh.exit_requested = nil
				-- (a hot loop typed here runs compiled — the tier's fragment hook — and a hot
				-- function compiles standalone: tier.fn_hot)
				require("tier")
				local ok, err = pcall(interp.run_lazy, sh, buf, interp.SUBHOOK, not interactive and bline or nil)
				if sh.exit_requested or (not ok and type(err) == "table" and err.__curse_exit) then
					io.flush()
					break -- `exit` in the REPL
				elseif not ok then
					io.stderr:write("curse: " .. tostring(type(err) == "table" and "error" or err) .. "\n")
				end
				io.flush()
			end
			buf = ""
		end
		::continue::
	end
	sh.defer_exit_trap = nil
	pcall(interp.run_exit_trap, sh)
	io.flush()
	if histfile then -- write the session's history back to an explicit $HISTFILE
		-- `shopt -s histappend` appends the session's list to the file; otherwise it
		-- overwrites (bash). (HISTSIZE has already trimmed the in-memory list.)
		local f = io.open(histfile, (sh.shopt and sh.shopt.histappend) and "a" or "w")
		if f then
			for _, h in ipairs(sh.history or {}) do
				f:write(h, "\n")
			end
			f:close()
		end
	elseif RL and istty then
		pcall(function()
			RL.write_history((os.getenv("HOME") or ".") .. "/.curse_history")
		end)
	end
end

return M
