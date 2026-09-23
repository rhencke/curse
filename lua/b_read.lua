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
					local function takearg()
						local r = a:sub(k + 1)
						if r ~= "" then
							k = #a + 1
							return r
						else
							advance = 2
							k = #a + 1
							return args[j + 1]
						end
					end
					if f == "r" then
						raw = true
						k = k + 1
					elseif f == "d" then
						delim = takearg() or "\n"
					elseif f == "n" or f == "N" then -- char count; a non-numeric arg is an error (not a hang)
						local v = takearg()
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
						arr = takearg()
					elseif f == "u" then
						ufd = tonumber(takearg()) or 0
					elseif f == "p" then
						takearg() -- prompt: consume + ignore (non-interactive)
					elseif f == "t" then
						tmout = takearg() -- timeout (only -t 0 is honored below)
					else
						k = k + 1
					end -- -s etc.: ignore
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
		local timed_out = false
		local function getc()
			if deadline and not rt.fd_wait(ufd, deadline) then
				timed_out = true
				return nil
			end
			return fd_getc(ufd)
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
			while true do
				if nchars and #buf >= nchars then
					had_nl = true
					break
				end -- -n/-N char limit reached
				local c = getc()
				if c == nil then
					had_nl = false
					break
				end
				got = true
				if not raw and c == "\\" then
					-- \<newline> is a line continuation (splice); other \x escapes the char
					-- (marked with \1 so IFS splitting treats it as literal, bash's CTLESC).
					local d = getc()
					if d == nil then
						if not timed_out then
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
						local d = getc()
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
			line = (got or timed_out) and table.concat(buf) or nil
		end
		do
			-- EOF with nothing read still assigns (empty values) and returns 1 (bash)
			line = line or ""
			local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
			local aref = arr and sh.vars[arr] and sh.vars[arr].ref and sh:deref_elem(arr)
			if aref then -- (-a through a nameref to an ELEMENT: not an array name — bash)
				io.stderr:write("curse: read: `" .. aref .. "': not a valid identifier\n")
				sh.status = 1
				return
			elseif arr then
				sh:array_assign(arr, rt.ifs_split(ifs, line), false)
			elseif ndelim then -- -N: no IFS processing; first var gets everything, rest empty
				local plain = line:gsub("\1(.)", "%1") -- \1x -> x (unescape); \1\1 -> \1 (literal CTLESC)
				if #vars == 0 then
					sh:set_str("REPLY", plain)
				else
					rt.assign_ref(sh, "read", vars[1], plain)
					for k = 2, #vars do
						rt.assign_ref(sh, "read", vars[k], "")
					end
				end
			elseif #vars == 0 then
				sh:set_str("REPLY", (line:gsub("\1(.)", "%1"))) -- REPLY: raw line, unescape CTLESC markers
			else
				local fields = read_split(ifs, line, #vars)
				local ok = true
				for k = 1, #vars do
					ok = rt.assign_ref(sh, "read", vars[k], fields[k] or "") and ok
				end
				if not ok then
					return -- (status 1: a name that isn't a variable reference)
				end
			end
			sh.status = had_nl and 0 or 1
		end
		if timed_out then
			sh.status = 142
		end
		if sh.coprocs and next(sh.coprocs) then -- (a blocking read is where bash has seen a
			local st = sh.status -- finished coproc's SIGCHLD and reaped it)
			rt.coproc_poll(sh)
			sh.status = st
		end
	end
end
