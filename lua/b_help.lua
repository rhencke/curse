-- Lazily-loaded `help` builtin (see BUILTIN_LAZY in interp.lua), as bash's help.def over
-- bash's own help texts (helpdata.lua, loaded only here).
local ffi = require("ffi")
local rt = require("runtime")

local function version()
	return rt.L1("GNU bash, version %s (%s)\n", "5.2.37(1)-release", "x86_64-pc-linux-gnu")
end

-- bash's _() of a help text (lua/l10n.lua; only under a message locale with a catalog)
local loc
local function tx(sh, s)
	return loc and loc.text(sh, s) or s
end
-- a topic's long description: bash's msgid is its lines joined by "\n    " — translated,
-- the whole text (its own line breaks); else nil
local function longdoc(sh, t)
	return loc and loc.longdoc(sh, t[3]) or nil
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
	-- (returns the cell and its display columns, which pad the left one)
	local function cell(k, right)
		local t = topics[k]
		local doc = tx(sh, t[2])
		local m = disabled(sh, t[1]) and "*" or " "
		if wide and doc:find("[\128-\255]") then -- (wdispcolumn, by characters and wcwidth)
			local ch = rt.mb_chars(doc)
			for _, c in ipairs(ch) do
				if not c.wc then -- (mbstowcs fails: dispcolumn's bytes; the right one whole)
					ch = nil
					break
				end
			end
			if ch then
				local slen = #ch
				if slen >= width then
					slen = width - 2
				end
				local max, len, disp = width - 2, 0, 0
				for j = 1, slen do
					local c = ch[j]
					local l = (c.wc == 10 or c.wc == 9) and 1 or tonumber(ffi.C.wcwidth(c.wc))
					if l == max - len then
						disp = j
						break
					elseif l > max - len then
						disp = j - 1
						break
					end
					len = len + l
					disp = j
				end
				local cols = 1
				for j = 1, disp do
					local c = ch[j]
					cols = cols + ((c.wc == 10 or c.wc == 9) and 1 or tonumber(ffi.C.wcwidth(c.wc)))
				end
				local o = { m }
				local last = math.min(#ch, slen + 1)
				if cols >= width - 2 then
					last = right and disp - 2 or disp - 1
				end
				for j = 1, last do
					local c = ch[j]
					o[#o + 1] = (c.wc == 10 or c.wc == 9) and " " or c.s
				end
				if cols >= width - 2 then
					o[#o + 1] = ">"
				end
				return table.concat(o), cols
			elseif right then
				return m .. doc, 0
			end
		end
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
		return m .. doc, #m + #doc
	end
	for i = 1, height do
		local left, cols = cell(i, false)
		local i0 = i - 1
		if (i0 * 2) >= n or (i0 + height) >= n then
			sh:echo(left)
		else
			sh:echo(left .. (" "):rep(width - cols) .. cell(i + height, true))
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
		elseif a == "--help" then -- (GETOPT_HELP: the builtin's help, status 2)
			return rt.builtin_help(sh, "help")
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
	loc = rt.l10n_active() and require("l10n") or nil
	if not args[j] and loc then
		sh:echo(version())
		sh.out(tx(sh, "These shell commands are defined internally.  Type `help' to see this list.\n"
			.. "Type `help name' to find out more about the function `name'.\n"
			.. "Use `info bash' to find out more about the shell in general.\n"
			.. "Use `man -k' or `info' to find out more about commands not in this list.\n\n"
			.. "A star (*) next to a name means that the command is disabled.\n\n"))
		show_list(sh, topics)
		sh.status = 0
		return
	elseif not args[j] then
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
		if loc then
			sh.out(loc.ntext(sh, "Shell commands matching keyword `", "Shell commands matching keywords `", #pats)
				.. table.concat(pats, ", ") .. tx(sh, "'\n\n"))
		else
			sh:echo((#pats > 1 and "Shell commands matching keywords `" or "Shell commands matching keyword `")
				.. table.concat(pats, ", ") .. "'")
			sh:echo("")
		end
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
						local ld = longdoc(sh, t)
						sh:echo("NAME")
						sh:echo("    " .. name .. " - " .. (ld and ld:match("^[^\n]*") or t[3][1] or ""))
						sh:echo("")
						sh:echo("SYNOPSIS")
						sh:echo("    " .. tx(sh, t[2]))
						sh:echo("")
						sh:echo("DESCRIPTION")
						if ld then
							sh:echo("    " .. ld)
						else
							for _, l in ipairs(t[3]) do
								sh:echo(l == true and "" or "    " .. l)
							end
						end
						sh:echo("")
						sh:echo("SEE ALSO")
						sh:echo("    bash(1)")
						sh:echo("")
						sh:echo("IMPLEMENTATION")
						sh:echo("    " .. version())
						sh:echo("    " .. tx(sh, "Copyright (C) 2022 Free Software Foundation, Inc."))
						sh.out("    " .. tx(sh, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>\n"))
						sh:echo("")
					else
						sh:echo(name .. ": " .. tx(sh, t[2]))
						local ld = not sflag and longdoc(sh, t)
						if ld then
							sh:echo("    " .. ld)
						elseif not sflag then
							for _, l in ipairs(t[3]) do
								sh:echo(l == true and "" or "    " .. l)
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
