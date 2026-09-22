-- Lazily-loaded feature module: the completion builtins (compgen / complete /
-- compopt). Extracted from interp.lua's exec_simple so a script that never
-- completes doesn't pay to load ~180 lines of completion machinery. Loaded on
-- demand via exec_simple's BUILTIN_LAZY table; require caches it (loaded once).
-- Internals are aliased to the SAME names interp uses, so the branch bodies below
-- are verbatim copies.
local I = require("interp")._int
local exec_simple, expand_part_str, tilde_word_initial = I.exec_simple, I.expand_part_str, I.tilde_word_initial
local file_test, sq = I.file_test, I.sq
local BUILTINS, KEYWORDS, SETOPTS, SHOPT_ORDER = I.BUILTINS, I.KEYWORDS, I.SETOPTS, I.SHOPT_ORDER
local C, P, rt = I.C, I.P, I.rt

return function(sh, cmd, args, hook)
	if cmd == "compgen" then
		-- compgen [-A action|-f|-d|-c|…] [-W wl] [-F func] [-P pre] [-S suf] [-X filt] [word]
		local actions, wordlist, prefix, bad, cpre, csuf, xfilter, funcname = {}, nil, nil, false, "", "", nil, nil
		local cmdname = nil
		local VALID = {
			["function"] = 1,
			alias = 1,
			builtin = 1,
			keyword = 1,
			variable = 1,
			command = 1,
			file = 1,
			directory = 1,
			setopt = 1,
			shopt = 1,
			arrayvar = 1,
			export = 1,
			helptopic = 1,
			user = 1,
			hostname = 1,
			group = 1,
			job = 1,
			service = 1,
			signal = 1,
			disabled = 1,
			enabled = 1,
			running = 1,
			stopped = 1,
		}
		local SHORT = {
			f = "file",
			d = "directory",
			c = "command",
			a = "alias",
			b = "builtin",
			k = "keyword",
			v = "variable",
			e = "export",
			g = "group",
			u = "user",
			j = "job",
			s = "service",
		}
		local j = 2
		while args[j] do
			local a = args[j]
			if a == "-A" then
				local act = args[j + 1]
				if not VALID[act] then
					bad = true
				end
				actions[#actions + 1] = act
				j = j + 2
			elseif a == "-W" then
				wordlist = args[j + 1]
				j = j + 2
			elseif a == "-P" then
				cpre = args[j + 1] or ""
				j = j + 2
			elseif a == "-S" then
				csuf = args[j + 1] or ""
				j = j + 2
			elseif a == "-X" then
				xfilter = args[j + 1]
				j = j + 2
			elseif a == "-F" then
				funcname = args[j + 1]
				j = j + 2
			elseif a == "-C" then
				cmdname = args[j + 1]
				j = j + 2
			elseif a == "-G" or a == "-o" then
				j = j + 2 -- take+ignore
			elseif a:match("^-[fdcabkvegujs]+$") then
				for ch in a:sub(2):gmatch(".") do
					actions[#actions + 1] = SHORT[ch]
				end
				j = j + 1
			elseif a:sub(1, 1) == "-" and #a > 1 then
				j = j + 1
			else
				if prefix == nil then
					prefix = a
				end
				j = j + 1
			end -- the word is the first operand
		end
		if bad then
			io.stderr:write("curse: compgen: invalid action\n")
			sh.status = 2
		else
			local out, seen, werr = {}, {}, false
			local function emit(x)
				if (not prefix or x:sub(1, #prefix) == prefix) and not seen[x] then
					seen[x] = true
					out[#out + 1] = x
				end
			end
			if cmdname then
				-- -C CMD: run the completion command; each line of its stdout is a candidate
				-- (verbatim — not prefix-filtered, like -F; -X/-P/-S still post-process).
				sh:set_str("COMP_LINE", prefix or "")
				sh:set_str("COMP_POINT", tostring(#(prefix or "")))
				local ok, res = pcall(function()
					return sh:capture_src(cmdname)
				end)
				if ok and res then
					for line in (res .. "\n"):gmatch("(.-)\n") do
						if line ~= "" then
							out[#out + 1] = line
						end
					end
				end
			elseif funcname then
				-- -F NAME: set the completion context vars bash exposes, call the function,
				-- and take its COMPREPLY verbatim. bash does NOT prefix-filter -F results —
				-- the function itself is responsible for that; only -X/-P/-S post-process.
				sh:array_assign("COMP_WORDS", {}, false)
				sh:set_str("COMP_CWORD", "-1")
				sh:set_str("COMP_LINE", "")
				sh:set_str("COMP_POINT", "0")
				if sh.functions[funcname] then
					local ok, err = pcall(exec_simple, sh, { funcname, "compgen", prefix or "", "" }, hook)
					if ok then
						for _, v in ipairs(sh:array_values("COMPREPLY")) do
							out[#out + 1] = v
						end
					elseif not (type(err) == "table" and err.__curse_matherr) then
						error(err) -- exit/return/real errors propagate; only a math fault is caught
					end -- fatal arith error in the function: no candidates, status 1 (below)
				else
					for _, v in ipairs(sh:array_values("COMPREPLY")) do
						out[#out + 1] = v
					end
				end
			else
				-- -W words keep their insertion order; each -A action is sorted within itself,
				-- and actions emit in the order given (bash does not globally merge-sort them).
				if wordlist then
					-- -W EXPANDS the whole list (params/$()/arith) — atomically: a fatal
					-- expansion (bad ${…}, 1/0) yields NO candidates and status 1 — then splits
					-- on IFS. Unlike normal word-splitting, -W splits UNQUOTED LITERALS too
					-- (`a:b` on IFS=: → a b), but QUOTED/backslash-escaped chars are protected
					-- (`a\:b`, `'a:b'` → one word); it never globs. Build the string with a
					-- per-char "protected" mask (chars from a quoted part), then split where the
					-- mask is clear; empty fields are dropped.
					local ifs = sh.vars["IFS"] and sh:get("IFS") or " \t\n"
					local ifsset = {}
					for k = 1, #ifs do
						ifsset[ifs:sub(k, k)] = true
					end
					local ok, str, prot = pcall(function()
						local w, buf, mask = P.parse_word(wordlist), {}, {}
						for pi, p in ipairs(w.parts) do
							local s = expand_part_str(sh, p)
							if pi == 1 and p.lit ~= nil and not p.q then
								s = tilde_word_initial(sh, s)
							end
							buf[#buf + 1] = s
							local q = p.q and true or false -- quoted part: protected from splitting
							for _ = 1, #s do
								mask[#mask + 1] = q
							end
						end
						return table.concat(buf), mask
					end)
					if ok then
						local cur, started = {}, false
						for i = 1, #str do
							local c = str:sub(i, i)
							if not prot[i] and ifsset[c] then
								if started then
									emit(table.concat(cur))
									cur = {}
									started = false
								end
							else
								cur[#cur + 1] = c
								started = true
							end
						end
						if started then
							emit(table.concat(cur))
						end
					else
						werr = true
					end
				end
				for _, act in ipairs(actions) do
					local acc, nosort = {}, false
					local function add(x)
						acc[#acc + 1] = x
					end
					if act == "user" then -- users in /etc/passwd order (bash does NOT sort these)
						nosort = true
						for _, n in ipairs(rt.pw_names()) do
							add(n)
						end
					elseif act == "function" then
						for n in pairs(sh.functions) do
							add(n)
						end
					elseif act == "alias" then
						for n in pairs(sh.aliases) do
							add(n)
						end
					elseif act == "builtin" then
						for n in pairs(BUILTINS) do
							add(n)
						end
					elseif act == "keyword" then
						for n in pairs(KEYWORDS) do
							add(n)
						end
					elseif act == "variable" or act == "arrayvar" then
						for n in pairs(sh.vars) do
							add(n)
						end
						-- always-set dynamic specials bash reports too (PWD etc.)
						for _, n in ipairs({
							"PWD",
							"OLDPWD",
							"PPID",
							"UID",
							"EUID",
							"RANDOM",
							"SECONDS",
							"LINENO",
							"HOSTNAME",
						}) do
							if sh.vars[n] == nil and sh:special_get(n) ~= "" then
								add(n)
							end
						end
					elseif act == "export" then
						for n in pairs(sh.vars) do
							if os.getenv(n) ~= nil then
								add(n)
							end
						end
						for _, n in ipairs({ "PWD", "OLDPWD" }) do
							if sh.vars[n] == nil and os.getenv(n) ~= nil then
								add(n)
							end
						end
					elseif act == "setopt" then
						for _, e in ipairs(SETOPTS) do
							add(e[1])
						end
					elseif act == "shopt" then
						for _, n in ipairs(SHOPT_ORDER) do
							add(n)
						end
					elseif act == "helptopic" then
						for n in pairs(BUILTINS) do
							add(n)
						end
						for n in pairs(KEYWORDS) do
							add(n)
						end
					elseif act == "file" or act == "directory" then
						local matches = rt.glob_expand((prefix or "") .. "*", { dotglob = false }) or {}
						for _, m in ipairs(matches) do
							if act == "file" or file_test("-d", m) then
								add(m)
							end
						end
					elseif act == "command" then -- aliases, keywords, builtins, functions + PATH externals
						for n in pairs(BUILTINS) do
							add(n)
						end
						for n in pairs(sh.functions) do
							add(n)
						end
						for n in pairs(sh.aliases) do
							add(n)
						end
						for n in pairs(KEYWORDS) do
							add(n)
						end
						local pfx = prefix or ""
						for dir in (sh:get("PATH") .. ":"):gmatch("([^:]*):") do
							local d = (dir == "" and "." or dir)
							for _, name in ipairs(rt.dir_names(d)) do
								if name:sub(1, #pfx) == pfx and C.access(d .. "/" .. name, 1) == 0 then
									add(name)
								end
							end
						end
					end
					if not nosort then
						table.sort(acc)
					end
					for _, n in ipairs(acc) do
						emit(n)
					end
				end
			end
			if xfilter and xfilter ~= "" then -- -X PAT removes matches; -X !PAT keeps only matches
				local neg = xfilter:sub(1, 1) == "!"
				local pat = neg and xfilter:sub(2) or xfilter
				local kept = {}
				for _, x in ipairs(out) do
					local m = rt.glob_match(x, pat)
					if (neg and m) or (not neg and not m) then
						kept[#kept + 1] = x
					end
				end
				out = kept
			end
			for _, x in ipairs(out) do
				sh:echo(cpre .. x .. csuf)
			end
			sh.status = (not werr and #out > 0) and 0 or 1
		end
	elseif cmd == "complete" then
		-- complete [-p] [opts] [name…]: store/print completion specs (registration only)
		if args[2] == nil or args[2] == "-p" then
			local ns = {}
			for n in pairs(sh.complete or {}) do
				ns[#ns + 1] = n
			end
			table.sort(ns)
			for _, n in ipairs(ns) do
				sh:echo(sh.complete[n] .. " " .. n)
			end
			sh.status = 0
		else
			-- split trailing NAMEs from the option part; -F/-C etc. with no name is a
			-- usage error UNLESS -D/-E/-I (default/empty/initial-word) is given.
			local opts, cmds, catchall = { "complete" }, {}, false
			local k = 2
			while args[k] do
				local a = args[k]
				if
					a == "-F"
					or a == "-C"
					or a == "-W"
					or a == "-A"
					or a == "-o"
					or a == "-P"
					or a == "-S"
					or a == "-X"
					or a == "-G"
				then
					opts[#opts + 1] = a
					opts[#opts + 1] = sq(args[k + 1] or "")
					k = k + 2
				elseif a == "-D" or a == "-E" or a == "-I" then
					catchall = true
					opts[#opts + 1] = a
					k = k + 1
				elseif a:sub(1, 1) == "-" then
					opts[#opts + 1] = a
					k = k + 1
				else
					cmds[#cmds + 1] = a
					k = k + 1
				end
			end
			if #cmds == 0 and not catchall then
				io.stderr:write("curse: complete: usage error\n")
				sh.status = 2
			else
				sh.complete = sh.complete or {}
				for _, c in ipairs(cmds) do
					sh.complete[c] = table.concat(opts, " ")
				end
				sh.status = 0
			end
		end
	elseif cmd == "compopt" then
		-- only valid inside a completion function; we don't run those, so: usage-error
		-- on a bad -o value (2), else "not in completion function" (1).
		for k = 2, #args do
			if args[k] == "-o" or args[k] == "+o" then
				local v = args[k + 1]
				local OK =
					{ default = 1, nospace = 1, filenames = 1, dirnames = 1, bashdefault = 1, plusdirs = 1, nosort = 1 }
				if not OK[v] then
					io.stderr:write("curse: compopt: invalid option name\n")
					sh.status = 2
					return
				end
			end
		end
		sh.status = 1
	end
end
