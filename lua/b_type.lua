-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local rt = require("runtime")
local I = require("interp")._int
local P = I.P

return function(sh, cmd, args, hook, tcb)
	if cmd == "type" then
		-- type [-afptP] NAME… (bash's type.def): -t the kind, -p a file's path, -P a forced
		-- $PATH search, -a every location, -f no functions; the last of -t/-p/-P decides the
		-- output. The obsolete -type/--type, -path/--path, -all/--all are rewritten first —
		-- over the whole leading run of dash words, so `type -- -type` asks for `-t`.
		local words = {}
		for k = 2, #args do
			words[#words + 1] = args[k]
		end
		for k = 1, #words do
			local w = words[k]
			if w:sub(1, 1) ~= "-" then
				break
			end
			local f = w:sub(2)
			if f == "type" or f == "-type" then
				words[k] = "-t"
			elseif f == "path" or f == "-path" then
				words[k] = "-p"
			elseif f == "all" or f == "-all" then
				words[k] = "-a"
			end
		end
		local fl = { short = true }
		local j0, sp, c, _ = 1
		repeat
			c, _, j0, sp = rt.getopt(sh, "type", words, "afptP", j0, sp)
			if c == "?" then -- (an unknown option: nothing looked up)
				return
			elseif c == "a" then
				fl.all = true
			elseif c == "f" then
				fl.nofunc = true
			elseif c == "p" then
				fl.path_only, fl.type, fl.short = true, false, false
			elseif c == "t" then
				fl.type, fl.path_only, fl.short = true, false, false
			elseif c == "P" then
				fl.path_only, fl.force, fl.type, fl.short = true, true, false, false
			end
		until not c
		local allok = true
		sh.write_err = nil
		for j = j0, #words do
			local nm = words[j]
			if not I.describe(sh, nm, fl) then
				allok = false
				if not (fl.path_only or fl.type) then
					io.stderr:write("curse: type: " .. nm .. ": not found\n")
				end
			end
		end
		sh.status = allok and 0 or 1
		if sh.out == io.write then -- (sh_chkwrite: a failed write is reported, status 1)
			if sh.write_err then
				rt.chkwrite_report(sh, "type", sh.write_errmsg)
				sh.status = 1
			elseif not rt.chkwrite(sh, "type") then
				sh.status = 1
			end
		end
	end
end
