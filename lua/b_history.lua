-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua): `history`, as
-- bash's history.def over the history list kept by hist.lua.
local H = require("hist")

local USAGE = "history: usage: history [-c] [-d offset] [n] or history -anrw [filename] or history -ps arg [arg...]\n"

local function erange(sh, arg)
	io.stderr:write("curse: history: " .. arg .. ": history position out of range\n")
	sh.status = 1
end

-- an integer argument (bash's legal_number)
local function num(s)
	return s and s:match("^%s*[+-]?%d+%s*$") and tonumber(s) or nil
end

local function read_file(file)
	local f = file and file ~= "" and io.open(file, "r")
	if not f then
		return nil
	end
	local lines = {}
	for l in f:lines() do
		lines[#lines + 1] = l
	end
	f:close()
	return lines
end

return function(sh, cmd, args)
	local h = H.list(sh)
	local flags, delete_arg = {}, nil
	local j = 2
	while args[j] and args[j]:sub(1, 1) == "-" and args[j] ~= "-" do
		local a = args[j]
		j = j + 1
		if a == "--" then
			break
		end
		if a:match("^%-%d") then -- (`history -5`: not an option letter)
			io.stderr:write("curse: history: " .. a:sub(1, 2) .. ": invalid option\n" .. USAGE)
			sh.status = 2
			return
		end
		local k = 2
		while k <= #a do
			local f = a:sub(k, k)
			k = k + 1
			if f == "d" then
				flags.d = true
				delete_arg = a:sub(k)
				if delete_arg == "" then
					delete_arg = args[j]
					j = j + 1
				end
				k = #a + 1
				if delete_arg == nil then
					io.stderr:write("curse: history: -d: option requires an argument\n" .. USAGE)
					sh.status = 2
					return
				end
			elseif f:match("[acnpsrw]") then
				flags[f] = true
			else
				io.stderr:write("curse: history: -" .. f .. ": invalid option\n" .. USAGE)
				sh.status = 2
				return
			end
		end
	end
	local rest = {}
	for k = j, #args do
		rest[#rest + 1] = args[k]
	end
	local nfile = (flags.a and 1 or 0) + (flags.n and 1 or 0) + (flags.r and 1 or 0) + (flags.w and 1 or 0)
	if nfile > 1 then
		io.stderr:write("curse: history: cannot use more than one of -anrw\n")
		sh.status = 1
		return
	end
	sh.status = 0
	if flags.c then
		for k = #h, 1, -1 do
			h[k] = nil
		end
		if #rest == 0 then
			return
		end
	end
	if flags.s then
		if #rest > 0 then
			-- the `history -s` line itself goes (bash's push_history), then the args as one
			if H.enabled(sh) and sh.hist_last_added then
				H.delete_last(sh)
			end
			H.check_add(sh, table.concat(rest, " "))
			sh.hist_last_added = false
		end
		return
	elseif flags.p then
		if H.enabled(sh) and sh.hist_last_added then
			H.delete_last(sh)
			sh.hist_last_added = false
		end
		for _, a in ipairs(rest) do
			local code, out = H.expand(sh, a)
			if code < 0 then
				io.stderr:write("curse: history: " .. a .. ": history expansion failed\n")
				sh.status = 1
			else
				sh:echo(out)
			end
		end
		return
	elseif flags.d then
		local base, len = sh.hist_base, #h
		local neg = delete_arg:sub(1, 1) == "-"
		local dash = delete_arg:find("-", neg and 2 or 1, true)
		if dash then -- `-d START-END`
			local sa, ea = delete_arg:sub(1, dash - 1), delete_arg:sub(dash + 1)
			local s, e = num(sa), num(ea)
			if not s or not e then
				return erange(sh, delete_arg)
			end
			if neg and s < 0 then
				s = s + len
			elseif s > 0 then
				s = s - base
			end
			if s < 0 or s >= len then
				return erange(sh, sa)
			end
			if ea:sub(1, 1) == "-" and e < 0 then
				e = e + len
			elseif e > 0 then
				e = e - base
			end
			if e < 0 or e >= len then
				return erange(sh, ea)
			end
			for k = e + 1, s + 1, -1 do
				table.remove(h, k)
			end
			return
		end
		local off = num(delete_arg)
		if not off then
			return erange(sh, delete_arg)
		end
		local idx
		if neg and off < 0 then
			idx = len + off
			if idx < 0 then
				return erange(sh, delete_arg)
			end
		elseif off < base or off >= base + len then
			return erange(sh, delete_arg)
		else
			idx = off - base
		end
		table.remove(h, idx + 1)
		return
	elseif nfile == 0 then -- list (all, or the last N)
		local limit
		if rest[1] then
			limit = num(rest[1])
			if not limit then
				io.stderr:write("curse: history: " .. rest[1] .. ": numeric argument required\n")
				sh.status = 1
				return
			end
			if rest[2] then
				io.stderr:write("curse: history: too many arguments\n")
				sh.status = 1
				return
			end
			limit = math.abs(limit)
		end
		local from = 1
		if limit and limit < #h then
			from = #h - limit + 1
		end
		for k = from, #h do
			sh:echo(("%5d  %s"):format(k + sh.hist_base - 1, h[k]))
		end
		return
	end
	local file = rest[1] or (sh.vars.HISTFILE and sh:get("HISTFILE")) or ""
	if flags.a then -- append this session's new lines
		local n = sh.hist_session or 0
		if n > 0 then
			local f = io.open(file, "a")
			if not f then
				local _, err = io.open(file, "a")
				io.stderr:write("curse: history: " .. file .. ": cannot create: "
					.. ((err or ""):match(": ([^:]+)$") or "Permission denied") .. "\n")
				sh.status = 1
				return
			end
			for k = math.max(1, #h - n + 1), #h do
				f:write(h[k], "\n")
			end
			f:close()
		end
		sh.hist_session = 0
	elseif flags.w then
		local f = file ~= "" and io.open(file, "w")
		if not f then
			sh.status = 1
			return
		end
		for _, l in ipairs(h) do
			f:write(l, "\n")
		end
		f:close()
	elseif flags.r or flags.n then
		local lines = read_file(file)
		if not lines then
			sh.status = 1
			return
		end
		local from = flags.n and ((sh.hist_file_lines or 0) + 1) or 1
		for k = from, #lines do
			h[#h + 1] = lines[k]
		end
		sh.hist_file_lines = #lines
		H.stifle(sh)
	end
end
