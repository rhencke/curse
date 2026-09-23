-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua): `enable`.
local rt = require("runtime")
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
	local all, disable, special, delete, file = false, false, false, false, nil
	local j = 2
	while args[j] and args[j]:match("^%-.") and args[j] ~= "--" do
		local a = args[j]
		j = j + 1
		local ci = 2
		while ci <= #a do
			local f = a:sub(ci, ci)
			ci = ci + 1
			if f == "a" then
				all = true
			elseif f == "n" then
				disable = true
			elseif f == "s" then
				special = true
			elseif f == "d" then
				delete = true
			elseif f == "p" then -- (printing is the default with no names)
			elseif f == "f" then -- -f FILE: a loadable builtin (curse can't load one)
				file = a:sub(ci) ~= "" and a:sub(ci) or args[j]
				if a:sub(ci) == "" then
					j = j + 1
				end
				if file == nil then
					io.stderr:write("curse: enable: -f: option requires an argument\n" .. rt.usage("enable"))
					sh.status = 2
					return
				end
				break
			else
				return rt.bad_option(sh, "enable", "-" .. f)
			end
		end
	end
	if args[j] == "--" then
		j = j + 1
	end
	if file and args[j] then
		-- (dlopen's own words; this static binary can't load one at all)
		local f = io.open(file, "r")
		local err = f and "only ELF shared objects built for bash can be loaded, and curse loads none"
			or "cannot open shared object file: No such file or directory"
		if f then
			f:close()
		end
		io.stderr:write("curse: enable: cannot open shared object " .. file .. ": " .. file .. ": " .. err .. "\n")
		sh.status = 1
		return
	end
	if delete and args[j] then
		for k = j, #args do
			io.stderr:write("curse: enable: " .. args[k] .. ": not dynamically loaded\n")
		end
		sh.status = 1
		return
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
				sh.out((off[n] and "enable -n " or "enable ") .. n .. "\n")
			elseif disable == (off[n] ~= nil) then -- -n lists the disabled ones
				sh.out((disable and "enable -n " or "enable ") .. n .. "\n")
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
