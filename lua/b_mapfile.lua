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
pcall(ffi.cdef, "long curse_mf_lseek(int fd, long off, int whence) asm(\"lseek\");")

return function(sh, cmd, args, hook, tcb)
	if cmd == "mapfile" or cmd == "readarray" then
		-- a port of bash's builtins/mapfile.def: mapfile [-d delim] [-n count] [-O origin]
		-- [-s count] [-t] [-u fd] [-C callback [-c quantum]] [array]
		local function berr(msg, code)
			io.stderr:write("curse: " .. cmd .. ": " .. msg .. "\n")
			sh.status = code or 1
		end
		-- (legal_number, then mapfile.def's range: an unsigned int, or an int for -u)
		local function legal(v, max)
			local n = v and rt.legal_number(v)
			return n and n <= (max or 4294967295) and n or nil
		end
		if args[2] == "--help" then -- (CASE_HELPOPT)
			return rt.builtin_help(sh, cmd)
		end
		local fd, lines, origin, nskip, quantum, callback = 0, 0, 0, 0, 5000, nil
		local clear, chop, dch = true, false, "\n"
		local j = 2
		while args[j] do
			local a = args[j]
			if a == "--" then
				j = j + 1
				break
			elseif a == "--help" then -- (GETOPT_HELP: the builtin's help, status 2)
				return rt.builtin_help(sh, cmd)
			end
			if a:sub(1, 1) ~= "-" or #a < 2 then
				break
			end
			local k = 2
			while k <= #a do
				local o = a:sub(k, k)
				if o == "t" then
					chop = true
					k = k + 1
				elseif o:match("[dunOCcs]") then
					local v = a:sub(k + 1)
					if v == "" then
						j = j + 1
						v = args[j]
						if v == nil then
							berr("-" .. o .. ": option requires an argument", 2)
							io.stderr:write(cmd .. ": usage: " .. cmd .. " [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]\n")
							return
						end
					end
					local n = legal(v, o == "u" and 2147483647 or nil)
					if o == "d" then
						dch = v:sub(1, 1)
						if dch == "" then
							dch = "\0"
						end
					elseif o == "u" then
						if not n or n < 0 then
							return berr(v .. ": invalid file descriptor specification")
						end
						if C.fcntl(n, 1) == -1 then -- F_GETFD
							return berr(n .. ": invalid file descriptor: Bad file descriptor")
						end
						fd = n
					elseif o == "n" then
						if not n or n < 0 then
							return berr(v .. ": invalid line count")
						end
						lines = n
					elseif o == "O" then
						if not n or n < 0 then
							return berr(v .. ": invalid array origin")
						end
						origin, clear = n, false
					elseif o == "C" then
						callback = v
					elseif o == "c" then
						if not n or n <= 0 then
							return berr(v .. ": invalid callback quantum")
						end
						quantum = n
					elseif o == "s" then
						if not n or n < 0 then
							return berr(v .. ": invalid line count")
						end
						nskip = n
					end
					k = #a + 1
				else
					berr("-" .. o .. ": invalid option", 2)
					io.stderr:write(cmd .. ": usage: " .. cmd .. " [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]\n")
					return
				end
			end
			j = j + 1
		end
		local arr = args[j] or "MAPFILE"
		if arr == "" then
			return berr("empty array variable name", 2)
		end
		if not arr:match("^[%a_][%w_]*$") then
			return berr("`" .. arr .. "': not a valid identifier")
		end
		local aref = sh.vars[arr] and sh.vars[arr].ref and sh:deref_elem(arr)
		if aref then -- (through a nameref to an ELEMENT: not an array name — bash)
			return berr("`" .. aref .. "': not a valid identifier")
		end
		if sh:is_assoc(arr) then
			return berr(arr .. ": not an indexed array")
		end
		-- Lines come off `fd` one at a time, leaving the rest unread for whoever reads next
		-- (bash's zgetline): a seekable fd reads ahead in chunks then seeks back to just past
		-- the last line taken; a pipe reads unbuffered. A pipeline stage yields while blocked.
		local seekable = C.curse_mf_lseek(fd, 0, 1) >= 0
		local buf, bpos, eof = "", 1, false
		local rbuf = ffi.new("char[?]", seekable and 65536 or 1)
		local consumed = 0 -- bytes handed out (to seek back to on a seekable fd)
		local function getline()
			while true do
				local e = buf:find(dch, bpos, true)
				if e then
					local l = buf:sub(bpos, e)
					consumed = consumed + (e - bpos + 1)
					bpos = e + 1
					return l
				end
				if eof then
					if bpos <= #buf then
						local l = buf:sub(bpos)
						consumed = consumed + #l
						bpos = #buf + 1
						return l
					end
					return nil
				end
				rt.co_block(fd, 1)
				rt.rd_gen = rt.rd_gen + 1 -- (see rt.pipe_cache)
				local nr = tonumber(C.read(fd, rbuf, seekable and 65536 or 1))
				if not nr or nr <= 0 then
					eof = true
				else
					buf = buf:sub(bpos) .. ffi.string(rbuf, nr)
					bpos = 1
				end
			end
		end
		if rt.ro_refuse(sh, arr) then
			sh.status = 1
			return
		end
		local start = seekable and C.curse_mf_lseek(fd, 0, 1) or 0
		for _ = 1, nskip do
			if not getline() then
				break
			end
		end
		if clear then
			sh:array_assign(arr, {}, false)
		end
		local idx, count = origin, 1
		while true do
			local l = getline()
			if l == nil then
				break
			end
			if chop and l:sub(-1) == dch then
				l = l:sub(1, -2)
			end
			if callback and count % quantum == 0 then -- (the index as C's %d of an unsigned int)
				rt.eval_run(sh, { "eval", callback .. " " .. (idx >= 2147483648 and idx - 4294967296 or idx) .. " " .. sq(l) })
			end
			sh:array_set(arr, idx, l, false)
			idx = (idx + 1) % 4294967296 -- (bash's array_index is an unsigned int: it wraps)
			count = count + 1
			if lines ~= 0 and count > lines then
				break
			end
		end
		if seekable then
			C.curse_mf_lseek(fd, start + consumed, 0) -- (the unread rest stays for the next reader)
		end
		sh.status = 0
	end
end
