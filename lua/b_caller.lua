-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua): `caller`.

-- caller [N]: the call-stack frame N as "LINE FUNC FILE" (from BASH_LINENO[N],
-- FUNCNAME[N+1], BASH_SOURCE[N+1]; status 1 when there is no such frame), or with no
-- argument the current call's "LINE FILE" (a missing piece prints NULL), as bash's
-- caller.def.
return function(sh, cmd, args)
	local function at(name, k) -- ${name[k]}, or nil
		return sh:array_values(name)[k + 1]
	end
	local j = 2
	if args[j] == "--" then
		j = j + 1
	end
	local a = args[j]
	if a == nil then
		if not at("BASH_LINENO", 0) then -- (no frames at all: -c's top level)
			sh.status = 1
			return
		end
		sh:echo((at("BASH_LINENO", 0) or "NULL") .. " " .. (at("BASH_SOURCE", 1) or "NULL"))
		sh.status = 0
		return
	end
	local n = a:match("^%s*[+-]?%d+%s*$") and tonumber(a)
	if not n then
		io.stderr:write("curse: caller: " .. a .. ": invalid number\n")
		io.stderr:write("caller: usage: caller [expr]\n")
		sh.status = 2
		return
	end
	local line, fn, src = at("BASH_LINENO", n), at("FUNCNAME", n + 1), at("BASH_SOURCE", n + 1)
	if n < 0 or not (line and fn and src) then
		sh.status = 1
		return
	end
	sh:echo(line .. " " .. fn .. " " .. src)
	sh.status = 0
end
