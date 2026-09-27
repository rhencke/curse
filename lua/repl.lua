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
local sh_cur -- (the shell read_line serves: M.run's)
local rl_readline -- (below)
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
	if not istty and echo and not sh_cur.opt_vi then
		local l = rl_readline(sh_cur, function()
			return interp._int.fd_getc(0)
		end)
		if l then
			io.stderr:write(l, "\n")
		end
		return l
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

-- bash's readline on a stdin that is NOT a terminal (`bash -i < file`, a pipe): with line
-- editing on (emacs mode), readline still reads the input byte by byte and runs its
-- default emacs bindings on it, so control characters in the input are editing commands
-- (history recall, incremental search, operate-and-get-next, kills and yanks, cursor
-- motion) — what bash's own tests (history4.sub) feed it. The line is edited here as
-- readline would; the display readline draws on stderr is reduced to the accepted line.
-- (Not modelled: completion — TAB inserts nothing, as a completion that finds no unique
-- match —, undo, keyboard macros, numeric arguments, the mark, vi mode, inputrc/bind.)
local rl_kill = {} -- the kill ring (most recent last)
rl_readline = function(sh, getc)
	local H = require("hist")
	local hl = H.list(sh)
	local base = sh.hist_base or 1
	local mb = rt.lc_mb_cur_max() > 1
	local line, pt = "", 0 -- the buffer, and the byte count before point
	local pos = #hl + 1 -- the history entry being edited (#hl + 1: the new line)
	local newline_text -- the new line's text while browsing the history
	local last_cmd, eof_seen
	local edits = {} -- history lines edited while browsing (readline's undo lists)
	local function cont(b) -- a UTF-8 continuation byte (moves step over whole chars)
		return mb and b and b >= 0x80 and b < 0xC0
	end
	local function left(p)
		if p <= 0 then
			return 0
		end
		p = p - 1
		while p > 0 and cont(line:byte(p + 1)) do
			p = p - 1
		end
		return p
	end
	local function right(p)
		if p >= #line then
			return #line
		end
		p = p + 1
		while p < #line and cont(line:byte(p + 1)) do
			p = p + 1
		end
		return p
	end
	local function isword(c) -- rl_alphabetic
		return c ~= nil and (c:match("%w") ~= nil or c:byte() >= 0x80)
	end
	local function fwd_word(p)
		while p < #line and not isword(line:sub(p + 1, p + 1)) do
			p = p + 1
		end
		while p < #line and isword(line:sub(p + 1, p + 1)) do
			p = p + 1
		end
		return p
	end
	local function back_word(p)
		while p > 0 and not isword(line:sub(p, p)) do
			p = p - 1
		end
		while p > 0 and isword(line:sub(p, p)) do
			p = p - 1
		end
		return p
	end
	local function insert(t)
		line = line:sub(1, pt) .. t .. line:sub(pt + 1)
		pt = pt + #t
	end
	local function kill(a, b, cmd) -- kill line[a+1..b]; consecutive kills accumulate
		if a >= b then
			return
		end
		local t = line:sub(a + 1, b)
		if last_cmd == "kill" and #rl_kill > 0 then
			rl_kill[#rl_kill] = (a < pt) and (t .. rl_kill[#rl_kill]) or (rl_kill[#rl_kill] .. t)
		else
			rl_kill[#rl_kill + 1] = t
		end
		line = line:sub(1, a) .. line:sub(b + 1)
		pt = a
		cmd.kill = true
	end
	local function goto_hist(k) -- rl_get_previous/next_history: replace the line
		if k < 1 or k > #hl + 1 or k == pos then
			return false
		end
		if pos == #hl + 1 then
			newline_text = line
		elseif line ~= hl[pos] then -- (an edited history line stays edited until accepted)
			edits[pos] = line
		end
		pos = k
		line = (k == #hl + 1) and (newline_text or "") or edits[k] or hl[k]
		pt = #line
		return true
	end
	-- a pending operate-and-get-next: the history entry after the one accepted
	if sh.rl_next_logical then
		local k = sh.rl_next_logical - base + 1
		sh.rl_next_logical = nil
		if k <= #hl then
			goto_hist(math.max(k, 1))
		end
	end
	local pushed = {}
	local function key()
		if #pushed > 0 then
			return table.remove(pushed)
		end
		return getc()
	end
	local search_last = ""
	-- rl_search_history: incremental search (dir -1: C-r, 1: C-s) over the history lines
	-- plus the line being edited; returns the key that ended it (to run) or nil
	local function isearch(dir)
		local lines = {}
		for k = 1, #hl do
			lines[k] = edits[k] or hl[k]
		end
		lines[#hl + 1] = pos == #hl + 1 and line or (newline_text or "")
		local save_pos, save_line, save_pt = pos, line, pt
		if pos ~= #hl + 1 then
			lines[pos] = line
		end
		local str = ""
		local hp, idx = pos, dir < 0 and pt or pt -- where the search is (line, byte index 0-based)
		local found_line, prev_found = pos, nil
		local function search(again)
			if again then
				idx = idx + dir
			end
			local sline = lines[hp]
			while true do
				local limit = #sline - #str + 1
				if dir < 0 and idx > #sline - #str then
					idx = #sline - #str
				end
				while (dir < 0 and idx >= 0) or (dir > 0 and idx < limit) do
					if sline:sub(idx + 1, idx + #str) == str then
						prev_found, found_line, pt = sline, hp, idx
						return true
					end
					idx = idx + dir
				end
				repeat
					hp = hp + dir
					if hp < 1 or hp > #lines then
						hp = found_line
						return false
					end
					sline = lines[hp]
				until not ((prev_found and prev_found == sline) or #str > #sline)
				idx = dir < 0 and (#sline - #str) or 0
			end
		end
		local c
		while true do
			c = key()
			if c == nil then
				break
			end
			local b = c:byte()
			if c == "\18" or c == "\19" then -- C-r / C-s: again (the last string when empty)
				dir = c == "\18" and -1 or 1
				if str == "" then
					str = search_last
				end
				if str ~= "" then
					search(true)
				end
			elseif c == "\7" then -- C-g: abort, the line as it was
				pos, line, pt = save_pos, save_line, save_pt
				return nil
			elseif c == "\8" or c == "\127" then
				if #str > 0 then
					str = str:sub(1, -2)
				end
			elseif c == "\27" or c == "\n" then -- the terminators; ESC is then a prefix
				if c == "\27" then
					pushed[#pushed + 1] = c
				end
				c = nil
				break
			elseif b >= 32 then
				str = str .. c
				search(false)
			else
				break -- any other key ends the search, then runs
			end
		end
		search_last = str ~= "" and str or search_last
		-- _rl_isearch_fini: the line found (moving the history there), point at the match
		local fp = pt
		line, pos = save_line, save_pos
		if found_line ~= save_pos then
			goto_hist(found_line)
			line = lines[found_line]
		end
		pt = math.min(found_line == save_pos and (str ~= "" and fp or save_pt) or fp, #line)
		return c
	end
	while true do
		local c = key()
		local cmd = {}
		if c == nil then -- end of input: a non-blank line is accepted, else EOF
			if line == "" then
				return nil
			end
			eof_seen = true
			break
		end
		if c == "\18" or c == "\19" then
			c = isearch(c == "\18" and -1 or 1)
			if c then
				pushed[#pushed + 1] = c
			end
		elseif c == "\n" or c == "\r" then
			break
		elseif c == "\15" then -- C-o operate-and-get-next: accept, then the next entry
			sh.rl_next_logical = pos + base
			break
		elseif c == "\1" then
			pt = 0
		elseif c == "\5" then
			pt = #line
		elseif c == "\2" then
			pt = left(pt)
		elseif c == "\6" then
			pt = right(pt)
		elseif c == "\4" then -- C-d: EOF on an empty line, else delete-char
			if line == "" then
				return nil
			end
			line = line:sub(1, pt) .. line:sub(right(pt) + 1)
		elseif c == "\8" or c == "\127" then
			local l = left(pt)
			line = line:sub(1, l) .. line:sub(pt + 1)
			pt = l
		elseif c == "\11" then
			kill(pt, #line, cmd)
		elseif c == "\21" then
			kill(0, pt, cmd)
		elseif c == "\23" then -- unix-word-rubout: whitespace-delimited
			local p = pt
			while p > 0 and line:sub(p, p):match("%s") do
				p = p - 1
			end
			while p > 0 and not line:sub(p, p):match("%s") do
				p = p - 1
			end
			kill(p, pt, cmd)
		elseif c == "\25" then
			if #rl_kill > 0 then
				insert(rl_kill[#rl_kill])
			end
		elseif c == "\20" then -- transpose-chars
			if pt > 0 and #line >= 2 then
				local p = pt == #line and left(pt) or pt
				local a = left(p)
				local e = right(p)
				line = line:sub(1, a) .. line:sub(p + 1, e) .. line:sub(a + 1, p) .. line:sub(e + 1)
				pt = e
			end
		elseif c == "\16" then
			goto_hist(pos - 1)
		elseif c == "\14" then
			goto_hist(pos + 1)
		elseif c == "\17" or c == "\22" then -- quoted-insert
			local q = key()
			if q then
				insert(q)
			end
		elseif c == "\29" then -- character-search
			local q = key()
			local f = q and line:find(q, pt + 2, true)
			if f then
				pt = f - 1
			end
		elseif c == "\24" then -- C-x prefix: its commands aren't modelled
			key()
		elseif c == "\27" then -- ESC: the meta prefix (arrow keys: ESC [ X / ESC O X)
			local m = key()
			if m == "[" or m == "O" then
				local k = key()
				if k == "A" then
					goto_hist(pos - 1)
				elseif k == "B" then
					goto_hist(pos + 1)
				elseif k == "C" then
					pt = right(pt)
				elseif k == "D" then
					pt = left(pt)
				elseif k == "H" then
					pt = 0
				elseif k == "F" then
					pt = #line
				elseif k and k:match("%d") then
					local t = key()
					if k == "3" and t == "~" then
						line = line:sub(1, pt) .. line:sub(right(pt) + 1)
					end
				end
			elseif m then
				m = m:lower()
				if m == "b" then
					pt = back_word(pt)
				elseif m == "f" then
					pt = fwd_word(pt)
				elseif m == "d" then
					kill(pt, fwd_word(pt), cmd)
				elseif m == "\127" or m == "\8" then
					kill(back_word(pt), pt, cmd)
				elseif m == "<" then
					goto_hist(1)
				elseif m == ">" then
					goto_hist(#hl + 1)
				elseif m == "u" or m == "l" or m == "c" then
					local e = fwd_word(pt)
					local w = line:sub(pt + 1, e)
					if m == "u" then
						w = w:upper()
					elseif m == "l" then
						w = w:lower()
					else
						w = w:lower():gsub("%w", string.upper, 1)
					end
					line = line:sub(1, pt) .. w .. line:sub(e + 1)
					pt = e
				elseif m == "\\" then
					local a, e = pt, pt
					while a > 0 and line:sub(a, a):match("[ \t]") do
						a = a - 1
					end
					while e < #line and line:sub(e + 1, e + 1):match("[ \t]") do
						e = e + 1
					end
					line = line:sub(1, a) .. line:sub(e + 1)
					pt = a
				elseif m == "#" then -- insert-comment: `#` at the start, then accept
					line = "#" .. line
					break
				end
			end
		elseif c == "\t" or c == "\0" or c == "\3" or c == "\26" or c == "\28" or c == "\30"
			or c == "\31" or c == "\12" or c == "\7" then
			-- complete (nothing unique), set-mark, unbound keys, clear-screen, undo, abort
		else
			insert(c)
		end
		last_cmd = cmd.kill and "kill" or nil
	end
	return line, eof_seen
end

-- Does `buf` have an obviously-unterminated construct, so the REPL should keep
-- reading (PS2) instead of running it? Shared with interp.source_file (rc-file
-- completeness). See interp.incomplete_input.
local function needs_more(buf)
	-- the real parser decides the rest (`f() {`, `{ echo`, `echo $(ls`, …)
	local ok, r = pcall(require("parser").parse, buf)
	local perr = (not ok and tostring(r)) or (r and r.stmts and r.stmts[1] and r.stmts[1].t == "parse_error"
		and tostring(r.stmts[1].msg)) or ""
	if perr:find("unexpected end of file", 1, true) ~= nil or perr:find("unexpected EOF", 1, true) ~= nil then
		return true
	end
	-- (a syntax error before the unterminated part — `right)"` — is reported at once)
	if perr ~= "" then
		return false
	end
	if interp.incomplete_input(buf) then
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
	sh_cur = sh
	interactive = istty or (sh and sh.opt_i) or false -- prompts print for `-i` even off a tty
	-- Persist $HISTFILE across the session (load now, write at exit) — but only when
	-- it was EXPLICITLY set (env/script), never the ~/.bash_history default, so a
	-- piped `-i` run never clobbers the user's real history. On a real tty, readline
	-- also loads its editing history from the same file.
	local histfile = sh:get("HISTFILE")
	local histfile0 = histfile
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
		H.load(sh, true)
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
	local n, h = sh.hist_session or 0, H.list(sh)
	-- (shell.c exit_shell: `if (remember_on_history) maybe_save_shell_history ()`, which
	-- reads $HISTFILE THEN — so `set +o history`, `unset HISTFILE`, `HISTFILE=` or a new
	-- HISTFILE mid-session all count. The ~/.bash_history default stays unwritten.)
	histfile = H.enabled(sh) and sh.vars.HISTFILE and sh:get("HISTFILE") or ""
	if histfile == "" or (sh.histfile_default and histfile == histfile0) then
		histfile = nil
	end
	if histfile then
		-- (bash's maybe_save_shell_history: this session's lines are appended, with their
		-- timestamps, as `history -a` — or, when HISTSIZE left fewer of them in the list and
		-- histappend is off, the list rewritten as `history -w` — then cut to HISTFILESIZE)
		local append = n <= #h or (sh.shopt and sh.shopt.histappend)
		local f = n > 0 and io.open(histfile, append and "a" or "w")
		if f then
			f:write(H.file_text(sh, append and #h - math.min(n, #h) + 1 or 1))
			f:close()
			rt.hist_resize(sh, "HISTFILESIZE")
		end
	elseif RL and istty then
		pcall(function()
			RL.write_history((os.getenv("HOME") or ".") .. "/.curse_history")
		end)
	end
end

return M
