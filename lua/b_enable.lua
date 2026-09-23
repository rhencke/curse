-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua): `enable`.
local I = require("interp")._int
local BUILTINS = I.BUILTINS

-- bash's SPECIAL_BUILTIN set, as `enable -s` lists it
local SPECIAL = {
	["."] = 1, [":"] = 1, ["break"] = 1, ["continue"] = 1, eval = 1, exec = 1, exit = 1,
	export = 1, readonly = 1, ["return"] = 1, set = 1, shift = 1, source = 1, times = 1,
	trap = 1, unset = 1,
}

-- enable [-a] [-n] [-p] [-s] [NAME …]: list the builtins (bash order: by name), or
-- disable (-n) / re-enable NAMEs — a disabled builtin is looked up on $PATH instead.
return function(sh, cmd, args)
	local all, disable, special = false, false, false
	local j = 2
	while args[j] and args[j]:match("^%-%a+$") do
		for f in args[j]:sub(2):gmatch(".") do
			if f == "a" then
				all = true
			elseif f == "n" then
				disable = true
			elseif f == "s" then
				special = true
			elseif f == "p" then -- (printing is the default with no names)
			else
				io.stderr:write("curse: enable: -" .. f .. ": invalid option\n")
				io.stderr:write("enable: usage: enable [-a] [-dnps] [-f filename] [name ...]\n")
				sh.status = 2
				return
			end
		end
		j = j + 1
	end
	sh.disabled_builtins = sh.disabled_builtins or {}
	local off = sh.disabled_builtins
	if not args[j] then
		local names = {}
		for n in pairs(BUILTINS) do
			if not special or SPECIAL[n] then
				names[#names + 1] = n
			end
		end
		table.sort(names)
		for _, n in ipairs(names) do
			if all then
				io.write(off[n] and "enable -n " or "enable ", n, "\n")
			elseif disable == (off[n] ~= nil) then -- -n lists the disabled ones
				io.write("enable ", n, "\n")
			end
		end
		sh.status = 0
		return
	end
	sh.status = 0
	for k = j, #args do
		local n = args[k]
		if not BUILTINS[n] then
			io.stderr:write("curse: enable: " .. n .. ": not a shell builtin\n")
			sh.status = 1
		elseif disable then
			off[n] = true
		else
			off[n] = nil
		end
	end
end
