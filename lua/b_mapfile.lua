-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local ffi = require("ffi")
local rt = require("runtime")
local I = require("interp")._int
local sq = I.sq
local eval = I.eval
local C = I.C
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
		local fd, lines, origin, nskip, quantum, callback = 0, 0, 0, 0, 5000, nil
		local clear, chop, dch = true, false, "\n"
		local j, sp, o, v = 2
		repeat
			o, v, j, sp = rt.getopt(sh, cmd, args, "d:u:n:O:tC:c:s:", j, sp)
			local n = v and legal(v, o == "u" and 2147483647 or nil)
			if o == "?" then
				return
			elseif o == "t" then
				chop = true
			elseif o == "d" then
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
		until not o
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
