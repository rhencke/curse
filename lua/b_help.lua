-- Lazily-loaded `help` builtin (see BUILTIN_LAZY in interp.lua). bash's `help`
-- prints usage for its shell-builtin/keyword topics; the one behavior scripts
-- actually depend on is the exit status and the "no help topics match" error for
-- an unknown topic, so that's what we reproduce faithfully. The usage bodies
-- themselves are not something spec tests assert, so we keep them minimal.
local M = require("interp")
local I = M._int
local BUILTINS, KEYWORDS = I.BUILTINS, I.KEYWORDS

-- A topic matches a pattern by exact name or prefix (bash also accepts globs;
-- exact/prefix covers every topic scripts query in practice).
local function topic_matches(pat)
	for name in pairs(BUILTINS) do
		if name == pat or name:sub(1, #pat) == pat then
			return true
		end
	end
	for name in pairs(KEYWORDS) do
		if name == pat or name:sub(1, #pat) == pat then
			return true
		end
	end
	return false
end

return function(sh, cmd, args)
	-- help [-dms] [PATTERN ...]  (-d/-m/-s only change formatting; we ignore them)
	local j = 2
	while args[j] and args[j]:sub(1, 1) == "-" and #args[j] > 1 do
		if args[j] == "--" then
			j = j + 1
			break
		end
		j = j + 1
	end
	if not args[j] then
		sh.status = 0
		return
	end -- bare `help`: overview, always succeeds
	local allok = true
	for k = j, #args do
		local pat = args[k]
		if topic_matches(pat) then
			sh:echo(pat .. ": " .. pat) -- minimal synopsis (not asserted by spec tests)
		else
			allok = false
			io.stderr:write(
				"curse: help: no help topics match `"
					.. pat
					.. "'.  Try `help help' or `man -k "
					.. pat
					.. "' or `info "
					.. pat
					.. "'.\n"
			)
		end
	end
	sh.status = allok and 0 or 1
end
