-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- it needs are aliased from interp's _int under their interp names.
local rt = require("runtime")
local I = require("interp")._int
local eval = I.eval
local P = I.P

return function(sh, cmd, args, hook, tcb)
	if cmd == "let" then
		-- let EXPR…: evaluate each as arithmetic (assignments take effect). Status is
		-- 0 if the LAST expression is non-zero, else 1; a bad/empty expression or no
		-- args is also status 1 (an arith error is non-fatal, like `(( ))`).
		if args[2] == "--" then -- (a leading `--` is skipped: ISOPTION)
			table.remove(args, 2)
		end
		if #args < 2 then
			io.stderr:write("curse: let: expression expected\n")
			sh.status = 1
		else
			local last, failed = 0, false
			local sv, sl = P.arith_cmd, sh.arith_let
			P.arith_cmd = "let" -- (bash's this_command_name in the error text)
			sh.arith_let = true -- (its text is already expanded: see arith_key)
			for k = 2, #args do
				local ok, v = pcall(function()
					local pok, ast = pcall(P.arith, args[k], "let") -- (args are already expanded)
					if not pok then
						I.arith_pre(sh, ast) -- (what bash evaluated before the error sticks)
						io.stderr:write("curse: " .. P.arith_errmsg(args[k], ast) .. "\n")
						error({ __curse_exit = 1, __curse_matherr = true })
					end
					return eval(sh, ast)
				end)
				if not ok then
					if not (type(v) == "table" and v.__curse_matherr) then
						P.arith_cmd, sh.arith_let = sv, sl
						error(v)
					end
					failed = true -- an arith error ends let (status 1), like bash's longjmp
					break
				end
				last = tonumber(rt.i64_to_str(v)) or 0
			end
			P.arith_cmd, sh.arith_let = sv, sl
			sh.status = (not failed and last ~= 0) and 0 or 1
		end
	end
end
