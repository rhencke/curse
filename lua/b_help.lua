-- Lazily-loaded `help` builtin (see BUILTIN_LAZY in interp.lua), as bash's help.def over
-- bash's own help texts (helpdata.lua, loaded only here).
local rt = require("runtime")

local function version()
	return "GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)"
end

-- is the builtin/keyword NAME disabled (`enable -n`)? (a `*` in the topic list)
local function disabled(sh, name)
	return sh.disabled_builtins and sh.disabled_builtins[name] or false
end

-- the two-column topic list (show_builtin_command_help / dispcolumn)
local function show_list(sh, topics)
	local cols = tonumber(sh.vars.COLUMNS and sh:get("COLUMNS") or "")
	local width = math.floor(((cols and cols > 0) and cols or 80) / 2)
	if width > 128 then
		width = 128
	end
	if width <= 3 then
		width = 40
	end
	local n = #topics
	local height = math.floor((n + 1) / 2)
	-- the `>` truncation of dispcolumn (single-byte locales: strncpy then a `>` at a fixed
	-- spot) and wdispcolumn (multibyte: the last shown character becomes the `>`)
	local wide = rt.lc_mb_cur_max() > 1
	local function cell(k, right)
		local t = topics[k]
		local doc = t[2]
		local m = disabled(sh, t[1]) and "*" or " "
		if wide then
			local shown = math.min(#doc >= width and width - 2 or #doc, width - 2)
			if shown + 1 >= width - 2 then
				doc = doc:sub(1, shown - (right and 2 or 1)) .. ">"
			end
		else
			local keep = right and width - 4 or width - 3
			if #doc >= keep then
				doc = doc:sub(1, keep) .. ">"
			end
		end
		return m .. doc
	end
	for i = 1, height do
		local left = cell(i, false)
		local i0 = i - 1
		if (i0 * 2) >= n or (i0 + height) >= n then
			sh:echo(left)
		else
			sh:echo(left .. (" "):rep(width - #left) .. cell(i + height, true))
		end
	end
end

return function(sh, cmd, args)
	local dflag, mflag, sflag = false, false, false
	local j = 2
	while args[j] and args[j]:sub(1, 1) == "-" and args[j] ~= "-" do
		local a = args[j]
		j = j + 1
		if a == "--" then
			break
		end
		for k = 2, #a do
			local f = a:sub(k, k)
			if f == "d" then
				dflag = true
			elseif f == "m" then
				mflag = true
			elseif f == "s" then
				sflag = true
			else
				io.stderr:write("curse: help: -" .. f .. ": invalid option\n")
				io.stderr:write("help: usage: help [-dms] [pattern ...]\n")
				sh.status = 2
				return
			end
		end
	end
	local topics = require("helpdata")
	if not args[j] then
		sh:echo(version())
		sh:echo("These shell commands are defined internally.  Type `help' to see this list.")
		sh:echo("Type `help name' to find out more about the function `name'.")
		sh:echo("Use `info bash' to find out more about the shell in general.")
		sh:echo("Use `man -k' or `info' to find out more about commands not in this list.")
		sh:echo("")
		sh:echo("A star (*) next to a name means that the command is disabled.")
		sh:echo("")
		show_list(sh, topics)
		sh.status = 0
		return
	end
	local pats = {}
	for k = j, #args do
		pats[#pats + 1] = args[k]
	end
	-- (bash's glob_pattern_p: `*`, `?`, or a `[` with a `]` after it)
	local p1 = pats[1]
	if p1:find("[*?]") or (p1:find("[", 1, true) and p1:find("]", p1:find("[", 1, true) + 1, true)) then
		sh:echo((#pats > 1 and "Shell commands matching keywords `" or "Shell commands matching keyword `")
			.. table.concat(pats, ", ") .. "'")
		sh:echo("")
	end
	local found, last = 0, nil
	for _, pat in ipairs(pats) do
		last = pat
		for pass = 1, 2 do
			local this = false
			for _, t in ipairs(topics) do
				local name = t[1]
				local m
				if pass == 1 then
					m = pat == name or rt.glob_match(name, pat)
				else
					m = name:sub(1, #pat) == pat
				end
				if m then
					this = true
					found = found + 1
					if dflag then
						sh:echo(name .. " - " .. (t[3][1] or ""))
					elseif mflag then
						sh:echo("NAME")
						sh:echo("    " .. name .. " - " .. (t[3][1] or ""))
						sh:echo("")
						sh:echo("SYNOPSIS")
						sh:echo("    " .. t[2])
						sh:echo("")
						sh:echo("DESCRIPTION")
						for _, l in ipairs(t[3]) do
							sh:echo("    " .. l)
						end
						sh:echo("")
						sh:echo("SEE ALSO")
						sh:echo("    bash(1)")
						sh:echo("")
						sh:echo("IMPLEMENTATION")
						sh:echo("    " .. version())
						sh:echo("    Copyright (C) 2022 Free Software Foundation, Inc.")
						sh:echo("    License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>")
						sh:echo("")
					else
						sh:echo(name .. ": " .. t[2])
						if not sflag then
							for _, l in ipairs(t[3]) do
								sh:echo("    " .. l)
							end
						end
					end
				end
			end
			if pass == 1 and this then
				break
			end
		end
	end
	if found == 0 then
		io.stderr:write("curse: help: no help topics match `" .. last .. "'.  Try `help help' or `man -k "
			.. last .. "' or `info " .. last .. "'.\n")
		sh.status = 1
		return
	end
	sh.status = 0
end
