-- Lazily-loaded `fc` builtin (see BUILTIN_LAZY in interp.lua), a port of bash's fc.def over
-- the history list kept by hist.lua: list (-l), re-execute with substitutions (-s), or
-- edit a range with $FCEDIT/$EDITOR and run the result.
local ffi = require("ffi")
local rt = require("runtime")
local H = require("hist")
local P = require("parser")
local I = require("interp")._int

local HIST_INVALID, HIST_ERANGE, HIST_NOTFOUND = -1000001, -1000002, -1000003 -- (INT_MIN-ish)

-- run CODE in the current shell, as bash's parse_and_execute (a logical line at a time)
local function exec_string(sh, code, hook)
	-- (its lines count from the fc command's own: errors in it report that line, bash)
	local nextf = P.open(code, sh, rt.current_line(sh))
	while true do
		local lg = nextf()
		if lg == nil then
			break
		end
		if lg.perr then
			local pok, perr = pcall(I.exec_stmt, sh, lg.perr, hook)
			if not pok and not (type(perr) == "table" and perr.__curse_parseerr) then
				error(perr)
			end
			sh.status = 2
			return
		end
		for _, st in ipairs(lg.stmts) do
			local ne0 = sh.noerr
			local sok, serr = pcall(I.exec_list, sh, { st }, hook, false)
			if not sok then
				if type(serr) == "table" and serr.__curse_lineabort and not serr.__curse_discard then
					if rt.lineabort_exits(sh, serr) then
						error(serr)
					end
					sh.status, sh.noerr = 1, ne0
					break
				end
				error(serr)
			end
		end
	end
end

-- a number for fc's use: an optional `-`, then a legal number
local function fc_number(w)
	if w == nil then
		return false
	end
	local s = w:sub(1, 1) == "-" and w:sub(2) or w
	return s:match("^%s*[+-]?%d+%s*$") ~= nil
end

-- the history position (0-based, as bash's hlist index) the spec names (fc_gethnum)
local function gethnum(sh, h, command, listing, first)
	local i = #h
	local rh = H.enabled(sh) and 1 or 0
	local last_hist = i - rh - (sh.hist_last_added and 1 or 0)
	if i == last_hist and h[last_hist + 1] == nil then
		while last_hist >= 0 and h[last_hist + 1] == nil do
			last_hist = last_hist - 1
		end
	end
	if last_hist < 0 then
		return -1
	end
	local real_last = i
	i = last_hist
	if command == nil then
		return i
	end
	while h[real_last + 1] == nil and real_last > 0 do
		real_last = real_last - 1
	end
	local sign, s = 1, command
	if s:sub(1, 1) == "-" then
		sign, s = -1, s:sub(2)
	end
	if s:match("^%d") then
		local n = tonumber(s:match("^%d+")) * sign -- (atoi)
		if n < 0 then
			n = n + i + 1
			return n < 0 and 0 or n
		elseif n == 0 then
			return sign == -1 and (listing and real_last or HIST_INVALID) or i
		else
			n = n - sh.hist_base
			if n < 0 or n >= i then
				return first and 0 or i
			end
			return n
		end
	end
	for j = i, 0, -1 do
		if h[j + 1] and h[j + 1]:sub(1, #command) == command then
			return j
		end
	end
	return HIST_NOTFOUND
end

local function range_error(sh, a, b)
	if a == HIST_INVALID or b == HIST_INVALID or a == HIST_ERANGE or b == HIST_ERANGE then
		io.stderr:write("curse: fc: history specification out of range\n")
		sh.status = 1
		return true
	elseif a == HIST_NOTFOUND or b == HIST_NOTFOUND then
		io.stderr:write("curse: fc: no command found\n")
		sh.status = 1
		return true
	end
	return false
end

return function(sh, cmd, args, hook)
	local h = H.list(sh)
	local numbering, reverse, listing, execute, ename = true, false, false, false, nil
	local j = 2
	while args[j] and not fc_number(args[j]) and args[j]:match("^%-.") do
		local a = args[j]
		j = j + 1
		if a == "--" then
			break
		end
		local k = 2
		while k <= #a do
			local f = a:sub(k, k)
			k = k + 1
			if f == "n" then
				numbering = false
			elseif f == "l" then
				listing = true
			elseif f == "r" then
				reverse = true
			elseif f == "s" then
				execute = true
			elseif f == "e" then
				ename = a:sub(k) ~= "" and a:sub(k) or args[j]
				if a:sub(k) == "" then
					j = j + 1
				end
				if ename == nil then
					io.stderr:write("curse: fc: -e: option requires an argument\n" .. rt.usage("fc"))
					sh.status = 2
					return
				end
				break
			else
				return rt.bad_option(sh, "fc", "-" .. f, a)
			end
		end
	end
	if ename == "-" then
		execute = true
	end

	if execute then -- fc -s [pat=rep …] [command]: re-run, with substitutions
		local subs = {}
		while args[j] and args[j]:find("=", 1, true) do
			local pat, rep = args[j]:match("^(.-)=(.*)$")
			subs[#subs + 1] = { pat, rep }
			j = j + 1
		end
		local n = gethnum(sh, h, args[j], false, false)
		local command = n >= 0 and h[n + 1] or nil
		if command == nil then
			io.stderr:write("curse: fc: no command found\n")
			sh.status = 1
			return
		end
		for _, r in ipairs(subs) do -- (bash's strsub, global: every occurrence, left to right)
			if r[1] == "" then -- (an empty pattern matches at every character, eating it)
				command = r[2]:rep(#command)
			else
				local parts, p = {}, 1
				while true do
					local s = command:find(r[1], p, true)
					if not s then
						break
					end
					parts[#parts + 1] = command:sub(p, s - 1) .. r[2]
					p = s + #r[1]
				end
				parts[#parts + 1] = command:sub(p)
				command = table.concat(parts)
			end
		end
		io.stderr:write(command, "\n")
		-- the re-executed command replaces `fc -s` in the history (fc_replhist)
		local c = command:gsub("\n$", "")
		if c ~= "" then
			H.delete_last(sh)
			H.check_add(sh, c)
		end
		-- (run with history recording off, as parse_and_execute's SEVAL_NOHIST)
		local so = sh.opt_history
		sh.opt_history = false
		local ok, err = pcall(exec_string, sh, command, hook)
		sh.opt_history = so
		if not ok then
			error(err, 0)
		end
		return
	end

	if #h == 0 then
		sh.status = 0
		return
	end
	local i = #h
	local rh = H.enabled(sh) and 1 or 0
	local last_hist = i - rh - (sh.hist_last_added and 1 or 0)
	local real_last = i
	while h[real_last + 1] == nil and real_last > 0 do
		real_last = real_last - 1
	end
	if i == last_hist and h[last_hist + 1] == nil then
		while last_hist >= 0 and h[last_hist + 1] == nil do
			last_hist = last_hist - 1
		end
	end
	if last_hist < 0 then
		last_hist = 0
	end

	local histbeg, histend
	if args[j] then
		histbeg = gethnum(sh, h, args[j], listing, true)
		if args[j + 1] then
			histend = gethnum(sh, h, args[j + 1], listing, false)
		elseif histbeg == real_last then
			histend = listing and real_last or histbeg
		else
			histend = listing and last_hist or histbeg
		end
	elseif listing then -- the last 16
		histend = last_hist
		histbeg = math.max(0, histend - 16 + 1)
	else
		histbeg, histend = last_hist, last_hist
	end
	if range_error(sh, histbeg, histend) then
		return
	end
	histbeg, histend = math.max(histbeg, 0), math.max(histend, 0)

	-- not listing: the `fc` that asked for the edit isn't kept in the history
	if not listing and sh.hist_last_added then
		H.delete_last(sh)
		if histbeg == histend and histend == last_hist and h[last_hist + 1] == nil then
			histend = histend - 1
			last_hist, histbeg = histend, histend
		end
		if h[last_hist + 1] == nil then
			last_hist = last_hist - 1
		end
		if histend >= last_hist then
			histend = last_hist
		elseif histbeg >= last_hist then
			histbeg = last_hist
		end
	end
	histbeg, histend = math.max(histbeg, 0), math.max(histend, 0)
	if histend < histbeg then
		histbeg, histend = histend, histbeg
		reverse = true
	end

	local out = {}
	local from, to, step = histbeg, histend, 1
	if reverse then
		from, to, step = histend, histbeg, -1
	end
	for k = from, to, step do
		local line = h[k + 1]
		if line then
			local num = (listing and numbering) and tostring(k + sh.hist_base) or ""
			local mark = listing and (sh.opt_posix and "\t" or "\t ") or ""
			out[#out + 1] = num .. mark .. line .. "\n"
		end
	end
	if listing then
		sh.status = 0
		sh.out(table.concat(out))
		if sh.out == io.write then
			rt.chkwrite(sh, "fc") -- (a failed write is reported, status 1)
		end
		return
	end

	-- edit: the commands go to a temp file, the editor runs on it, then its lines run
	local tmpdir = (sh.vars.TMPDIR and sh:get("TMPDIR") or "")
	if tmpdir == "" then
		tmpdir = "/tmp"
	end
	local fn = ("%s/bash-fc.%d%d"):format(tmpdir, tonumber(ffi.C.getpid()), math.random(100000, 999999))
	local f = io.open(fn, "w")
	if not f then
		io.stderr:write("curse: fc: " .. fn .. ": cannot open temp file: No such file or directory\n")
		sh.status = 1
		return
	end
	f:write(table.concat(out))
	f:close()
	local editor
	if ename then
		editor = ename
	elseif sh.opt_posix then
		editor = "${FCEDIT:-${EDITOR:-ed}}"
	else
		editor = "${FCEDIT:-${EDITOR:-vi}}"
	end
	exec_string(sh, editor .. " " .. fn, hook)
	if sh.status ~= 0 then
		os.remove(fn)
		sh.status = 1
		return
	end
	f = io.open(fn, "r")
	local text = f and f:read("*a") or ""
	if f then
		f:close()
	end
	os.remove(fn)
	-- run it as bash's fc_execute_file: each line echoed as it's read (set -v style) and
	-- recorded in the history
	-- (diagnostics are labelled with the temp file's name: `/tmp/bash-fc.N: line 1: …`)
	local sv, so, ss = sh.opt_v, sh.opt_history, sh.cur_source
	sh.opt_v, sh.opt_history, sh.cur_source = true, true, fn
	sh.status = 0
	local ok, err = pcall(I.run_history_lines, sh, text, 1, hook, 0)
	sh.opt_v, sh.opt_history, sh.cur_source = sv, so, ss
	if not ok then
		error(err, 0)
	end
end
