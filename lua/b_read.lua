-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- aliased to interp's names so the branch body is a verbatim copy.
local ffi = require("ffi")
local rt = require("runtime")
local M = require("interp")
local I = M._int
local exec_simple, expand_part_str, tilde_word_initial, file_test, sq =
	I.exec_simple, I.expand_part_str, I.tilde_word_initial, I.file_test, I.sq
local BUILTINS, KEYWORDS, SETOPTS, SHOPT_ORDER = I.BUILTINS, I.KEYWORDS, I.SETOPTS, I.SHOPT_ORDER
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic
local job_reap, block_sig, canon_sig, sig_order = I.job_reap, I.block_sig, I.canon_sig, I.sig_order
local find_all_in_path, name_type, SIGNUM, NUMSIG = I.find_all_in_path, I.name_type, I.SIGNUM, I.NUMSIG
local array_key, sh_printf, fd_getc, fd_ready, read_split =
	I.array_key, I.sh_printf, I.fd_getc, I.fd_ready, I.read_split
local do_arrayassign, eval, fmt_decl, fmt_set_var = I.do_arrayassign, I.eval, I.fmt_decl, I.fmt_set_var
local C, P = I.C, I.P

local RDBUF = 4096
local rdbuf = ffi.new("char[?]", RDBUF)

-- (module-level helpers, not per-call closures: closure creation / upvalue closing is
-- NYI for the JIT, and `read` runs once per line of a `while read` loop)
-- An arg-taking flag at a[k] takes the attached rest of the word, else the next word
-- (then the option word advances by 2); either way it ends the bundle.
local function takearg(a, k, args, j, advance)
	local r = a:sub(k + 1)
	if r ~= "" then
		return r, #a + 1, advance
	end
	return args[j + 1], #a + 1, 2
end
-- One byte of input for `read`, per its state `st` (see the builtin): a regular file
-- is read in chunks (rewound past the line by unread); a deadline waits for input;
-- otherwise a byte at a time, without a readiness poll per byte while FIONREAD says
-- bytes are waiting. nil at EOF / timeout / error (st.timed_out / st.rerr say which).
local function getc(st)
	local ufd = st.ufd
	local chunk = st.chunk
	if chunk then
		local ci = st.ci
		if ci > #chunk then
			local n = C.read(ufd, rdbuf, RDBUF)
			if n <= 0 then
				if n < 0 then
					local e = ffi.errno()
					if e ~= 4 and e ~= 11 then
						st.rerr = e
					end
				end
				st.chunk, st.ci = "", 1
				return nil
			end
			chunk, ci = ffi.string(rdbuf, n), 1
			st.chunk = chunk
		end
		st.ci = ci + 1
		return chunk:sub(ci, ci)
	end
	local deadline = st.deadline
	if deadline and not rt.fd_wait(ufd, deadline) then
		st.timed_out = true
		return nil
	end
	if not deadline then
		if st.avail <= 0 then
			st.avail = rt.fd_avail(ufd)
		end
		if st.avail > 0 then
			local n = C.read(ufd, rdbuf, 1)
			if n == 1 then
				st.avail = st.avail - 1
				return string.char(rdbuf[0] % 256)
			end
			st.avail = 0 -- (someone else drained it: take the careful path)
		end
	end
	local c, e = fd_getc(ufd)
	if e and e ~= 4 and e ~= 11 then
		st.rerr = e
	end
	return c
end
local function unread(st) -- give back what a chunked read took past the line
	local chunk, ci = st.chunk, st.ci
	if chunk and ci <= #chunk then
		rt.fd_rewind(st.ufd, #chunk - ci + 1)
		st.chunk, st.ci = "", 1
	end
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "read" then
		-- read [-r] [-a arr] [-p prompt] VAR...  (line from stdin, split on IFS)
		local raw, arr, j, nchars, ndelim, ufd = false, nil, 2, nil, false, 0
		local delim, tmout
		while j <= #args do
			local a = args[j]
			if a == "--" then
				j = j + 1
				break
			elseif a:sub(1, 1) == "-" and #a > 1 then
				-- parse a bundle like -rd, -rN 6; an arg-taking flag takes the attached
				-- rest of the word or the next word, and ends the bundle.
				local k, advance = 2, 1
				while k <= #a do
					local f = a:sub(k, k)
					if f:match("[adinNptu]") and k == #a and args[j + 1] == nil then
						io.stderr:write("curse: read: -" .. f .. ": option requires an argument\n" .. rt.usage("read"))
						sh.status = 2
						return
					end
					if f == "r" then
						raw = true
						k = k + 1
					elseif f == "d" then
						local v0
						v0, k, advance = takearg(a, k, args, j, advance)
						delim = v0 or "\n"
					elseif f == "n" or f == "N" then -- char count; a non-numeric arg is an error (not a hang)
						local v
						v, k, advance = takearg(a, k, args, j, advance)
						nchars = v and v:match("^%s*[+-]?%d+%s*$") and tonumber(v) or nil
						if not nchars or nchars < 0 then -- (bash: legal_number, and not negative)
							io.stderr:write("curse: read: " .. tostring(v) .. ": invalid number\n")
							sh.status = 1
							return
						end
						if f == "N" then
							ndelim = true
						end
					elseif f == "a" then
						arr, k, advance = takearg(a, k, args, j, advance)
					elseif f == "u" then
						local v
						v, k, advance = takearg(a, k, args, j, advance)
						ufd = v:match("^%s*[+-]?%d+%s*$") and tonumber(v)
						if not ufd or ufd < 0 then
							io.stderr:write("curse: read: " .. v .. ": invalid file descriptor specification\n")
							sh.status = 1
							return
						end
						if C.fcntl(ufd, 1) < 0 then -- F_GETFD: not open
							io.stderr:write("curse: read: " .. v .. ": invalid file descriptor: Bad file descriptor\n")
							sh.status = 1
							return
						end
					elseif f == "i" then
						local _
						_, k, advance = takearg(a, k, args, j, advance) -- (the readline default text: no readline here)
					elseif f == "p" then
						local _
						_, k, advance = takearg(a, k, args, j, advance) -- prompt: consume + ignore (non-interactive)
					elseif f == "t" then
						tmout, k, advance = takearg(a, k, args, j, advance) -- timeout (only -t 0 is honored below)
					elseif f == "s" or f == "e" then -- (no echo / readline: no terminal editing here)
						k = k + 1
					else
						return rt.bad_option(sh, "read", "-" .. f)
					end
				end
				j = j + advance
			else
				break
			end
		end
		-- `read -t 0`: don't read anything — just report whether input is available
		-- on the fd (bash: status 0 if a read wouldn't block, non-zero otherwise).
		if tmout and tonumber(tmout) == 0 then
			sh.status = fd_ready(ufd) and 0 or 1
			return
		end
		-- -t SECS (or a positive $TMOUT): give up at the deadline with status 128+ALRM,
		-- keeping whatever partial input arrived (bash)
		local deadline
		if tmout == nil and sh.vars["TMOUT"] then
			local tm = tonumber(sh:get("TMOUT"))
			if tm and tm > 0 then
				tmout = tm
			end
		end
		if tmout ~= nil then
			local secs = tonumber(tmout)
			if not secs or secs < 0 or tostring(tmout):match("^%s*0[xX]") then
				io.stderr:write("curse: read: " .. tostring(tmout) .. ": invalid timeout specification\n")
				sh.status = 1
				return
			end
			deadline = rt.wall_secs() + secs
		end
		-- (no deadline) a regular file: chunked reads; a pipe: peeked for the line end
		local st = { ufd = ufd, chunk = nil, ci = 1, avail = 0, deadline = deadline, timed_out = false, rerr = nil }
		local fifo = false
		if not deadline then
			local kind = rt.fd_kind(ufd)
			if kind == "reg" then
				st.chunk = ""
			elseif kind == "fifo" then
				fifo = true -- (peek for the line end: rt.pipe_peek)
			end
		end
		local vars = {}
		for k = j, #args do
			vars[#vars + 1] = args[k]
		end
		local line, had_nl = nil, true
		-- Read from `ufd` one byte at a time (never over-reading past the terminator),
		-- honoring -r (backslash escaping), -d DELIM, and -n/-N char counts. `dch` is
		-- the record delimiter: the line terminator (\n) unless -d overrode it; -N
		-- ignores the delimiter entirely.
		local dch = delim == nil and "\n" or (delim == "" and "\0" or delim:sub(1, 1))
		do
			local buf, got = {}, false
			local plainpat = raw and "[%z\1]" or "[%z\1\\]"
			while true do
				-- a chunked (regular-file) read: take the run up to the delimiter at once
				-- when it needs no per-char handling (no backslash, NUL, CTLESC)
				local bulk = false
				if st.chunk and not nchars then
					if st.ci > #st.chunk then -- (a short first read: lines are usually short, and
						-- whatever is past the line is read again by the next `read`)
						local n = C.read(ufd, rdbuf, st.chunk == "" and #buf == 0 and 128 or RDBUF)
						if n > 0 then
							st.chunk, st.ci = ffi.string(rdbuf, n), 1
						end
					end
					if st.ci <= #st.chunk then
						local e = st.chunk:find(dch, st.ci, true)
						local stop = e and e - 1 or #st.chunk
						local seg = st.chunk:sub(st.ci, stop)
						if not seg:find(plainpat) then
							bulk = true
							if #seg > 0 then
								buf[#buf + 1] = seg
								got = true
							end
							st.ci = stop + 1
							if e then
								st.ci, got, had_nl = e + 1, true, true
								break
							end
						end
					end
				end
				if fifo and not nchars then
					local data = rt.pipe_peek(ufd, rdbuf, RDBUF)
					if data == false then
						fifo = false
					elseif data and data ~= "" then -- (nil: empty for now, "" EOF: the byte path)
						local e = data:find(dch, 1, true)
						local seg = e and data:sub(1, e - 1) or data
						if seg:find(plainpat) then
							fifo = false -- (escapes/NULs on this line: byte at a time)
						elseif rt.read_exact(ufd, rdbuf, e or #data) then
							bulk = true
							if #seg > 0 then
								buf[#buf + 1] = seg
								got = true
							end
							if e then
								got, had_nl = true, true
								break
							end
						else
							fifo = false
						end
					end
				end
				if not bulk then
				if nchars and #buf >= nchars then
					had_nl = true
					break
				end -- -n/-N char limit reached
				local c = getc(st)
				if c == nil then
					had_nl = false
					if st.rerr then
						unread(st)
						io.stderr:write("curse: read: read error: " .. ufd .. ": " .. ffi.string(C.strerror(st.rerr)) .. "\n")
						sh.status = 1
						return
					end
					break
				end
				got = true
				if not raw and c == "\\" then
					-- \<newline> is a line continuation (splice); other \x escapes the char
					-- (marked with \1 so IFS splitting treats it as literal, bash's CTLESC).
					local d = getc(st)
					if d == nil then
						if not st.timed_out then
							buf[#buf + 1] = "\\"
						end
						had_nl = false
						break
					end
					if d == "\n" then -- swallow both (continuation), unless -N counts raw
					else
						buf[#buf + 1] = "\1" .. d
					end
				elseif not ndelim and c == dch then
					had_nl = true
					break -- -N ignores the delimiter
				elseif c == "\0" then -- bash strips NUL bytes from read input (keeps the rest)
				elseif c == "\1" then
					buf[#buf + 1] = "\1\1" -- DOUBLE a real CTLESC byte so it
					-- survives the \1-marker unescape below
				elseif nchars and c:byte() >= 0xC0 and rt.lc_mb_cur_max() > 1 then
					-- -n/-N count CHARACTERS in a multibyte locale: take the rest of a UTF-8
					-- sequence along with its lead byte (one buf entry = one character)
					local b = c:byte()
					local more = (b >= 0xF0 and 3) or (b >= 0xE0 and 2) or 1
					local ch = { c }
					for _ = 1, more do
						local d = getc(st)
						if d == nil then
							break
						end
						ch[#ch + 1] = d
					end
					buf[#buf + 1] = table.concat(ch)
				else
					buf[#buf + 1] = c
				end
				end
			end
			unread(st)
			line = (got or st.timed_out) and table.concat(buf) or nil
		end
		do
			-- EOF with nothing read still assigns (empty values) and returns 1 (bash)
			line = line or ""
			local ifs = (rt.ifs(sh) or " \t\n")
			local aref = arr and (not arr:match("^[%a_][%w_]*$") and arr
				or sh.vars[arr] and sh.vars[arr].ref and sh:deref_elem(arr))
			if aref then -- (-a through a nameref to an ELEMENT: not an array name — bash)
				io.stderr:write("curse: read: `" .. aref .. "': not a valid identifier\n")
				sh.status = 1
				return
			elseif arr and rt.ro_refuse(sh, arr) then
				sh.status = 1
				return
			elseif arr then
				sh:array_assign(arr, rt.ifs_split(ifs, line), false)
			elseif ndelim then -- -N: no IFS processing; first var gets everything, rest empty
				local plain = line:gsub("\1(.)", "%1") -- \1x -> x (unescape); \1\1 -> \1 (literal CTLESC)
				if #vars == 0 then
					sh:set_str("REPLY", plain)
				else
					for k = 1, #vars do
						if not rt.assign_ref(sh, "read", vars[k], k == 1 and plain or "") then
							return
						end
					end
				end
			elseif #vars == 0 then
				sh:set_str("REPLY", (line:gsub("\1(.)", "%1"))) -- REPLY: raw line, unescape CTLESC markers
			else
				local fields = read_split(ifs, line, #vars)
				for k = 1, #vars do -- (the first refused name ends it, status 1 — bash)
					if not rt.assign_ref(sh, "read", vars[k], fields[k] or "") then
						return
					end
				end
			end
			sh.status = had_nl and 0 or 1
		end
		if st.timed_out then
			sh.status = 142
		end
		if sh.coprocs and next(sh.coprocs) then -- (a blocking read is where bash has seen a
			local st = sh.status -- finished coproc's SIGCHLD and reaped it)
			rt.coproc_poll(sh)
			sh.status = st
		end
	end
end
