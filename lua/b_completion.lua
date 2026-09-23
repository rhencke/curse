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
			elseif a == "--" then
				if prefix == nil then
					prefix = args[j + 1]
				end
				break
			elseif a:sub(1, 1) == "-" and #a > 1 then
				local badl = a:match("[^abcdefgjksuvoAGWFCXPS]", 2)
				if badl then
					return rt.bad_option(sh, "compgen", "-" .. badl)
				end
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
					local ifs = (rt.ifs(sh) or " \t\n")
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
		-- complete [-abcdefgjksuv] [-pr] [-DEI] [-o opt] [-A action] [-G/-W/-F/-C/-X/-P/-S arg]
		-- [name …]: register, print (-p / no args) or remove (-r) completion specs. Specs
		-- are listed in bash's hash-table order (512 FNV-1 buckets, newest first per bucket)
		-- and printed as print_one_completion does.
		local ACT_LETTER = {
			a = "alias", b = "builtin", c = "command", d = "directory", e = "export", f = "file",
			g = "group", j = "job", k = "keyword", s = "service", u = "user", v = "variable",
		}
		local ACTIONS = {
			alias = 1, arrayvar = 1, binding = 1, builtin = 1, command = 1, directory = 1, disabled = 1,
			enabled = 1, export = 1, file = 1, ["function"] = 1, group = 1, helptopic = 1, hostname = 1,
			job = 1, keyword = 1, running = 1, service = 1, setopt = 1, shopt = 1, signal = 1,
			stopped = 1, user = 1, variable = 1,
		}
		local COPTS = { "bashdefault", "default", "dirnames", "filenames", "noquote", "nosort", "nospace", "plusdirs" }
		local COPT_OK = {}
		for _, o in ipairs(COPTS) do
			COPT_OK[o] = true
		end
		local spec = { opts = {}, acts = {} }
		local pflag, rflag, any = false, false, false
		local k = 2
		while args[k] and args[k]:sub(1, 1) == "-" and args[k] ~= "-" do
			local a = args[k]
			k = k + 1
			if a == "--" then
				break
			end
			local i = 2
			while i <= #a do
				local f = a:sub(i, i)
				i = i + 1
				if ACT_LETTER[f] then
					spec.acts[ACT_LETTER[f]] = true
					any = true
				elseif f == "p" then
					pflag = true
				elseif f == "r" then
					rflag = true
				elseif f == "D" or f == "E" or f == "I" then
					spec[f] = true
					any = true
				elseif f == "o" or f == "A" or f == "G" or f == "W" or f == "F" or f == "C" or f == "X"
					or f == "P" or f == "S" then
					local v = a:sub(i)
					if v == "" then
						v = args[k]
						k = k + 1
					end
					i = #a + 1
					if v == nil then
						io.stderr:write("curse: complete: -" .. f .. ": option requires an argument\n")
						sh.status = 2
						return
					end
					if f == "o" then
						if not COPT_OK[v] then
							io.stderr:write("curse: complete: " .. v .. ": invalid option name\n")
							sh.status = 2
							return
						end
						spec.opts[v] = true
					elseif f == "A" then
						if not ACTIONS[v] then
							io.stderr:write("curse: complete: " .. v .. ": invalid action name\n")
							sh.status = 2
							return
						end
						spec.acts[v] = true
					else
						spec[f] = v
					end
					any = true
				else
					return rt.bad_option(sh, "complete", "-" .. f)
				end
			end
		end
		local names = {}
		for j = k, #args do
			names[#names + 1] = args[j]
		end
		sh.complete = sh.complete or {}
		local tab = sh.complete
		local function sq1(v)
			return "'" .. v:gsub("'", "'\\''") .. "'"
		end
		local function line(name, cs)
			local o = { "complete" }
			for _, c in ipairs(COPTS) do
				if cs.opts[c] then
					o[#o + 1] = "-o " .. c
				end
			end
			for _, l in ipairs({ "a", "b", "c", "d", "e", "f", "g", "j", "k", "s", "u", "v" }) do
				if cs.acts[ACT_LETTER[l]] then
					o[#o + 1] = "-" .. l
				end
			end
			for _, act in ipairs({ "arrayvar", "binding", "disabled", "enabled", "function", "helptopic",
				"hostname", "running", "setopt", "shopt", "signal", "stopped" }) do
				if cs.acts[act] then
					o[#o + 1] = "-A " .. act
				end
			end
			for _, f in ipairs({ "G", "W", "P", "S", "X", "C" }) do
				if cs[f] then
					o[#o + 1] = "-" .. f .. " " .. sq1(cs[f])
				end
			end
			if cs.F then
				o[#o + 1] = "-F " .. cs.F
			end
			for _, f in ipairs({ "D", "E", "I" }) do
				if cs[f] then
					o[#o + 1] = "-" .. f
				end
			end
			o[#o + 1] = name
			return table.concat(o, " ")
		end
		local function listing()
			local ns = {}
			for n, cs in pairs(tab) do
				ns[#ns + 1] = { n = n, b = rt.assoc_bucket(n, 512), seq = cs.seq }
			end
			table.sort(ns, function(x, y)
				if x.b ~= y.b then
					return x.b < y.b
				end
				return x.seq > y.seq
			end)
			return ns
		end
		sh.status = 0
		if rflag then
			if #names == 0 then
				sh.complete = {}
			end
			for _, n in ipairs(names) do
				if tab[n] then
					tab[n] = nil
				else
					io.stderr:write("curse: complete: " .. n .. ": no completion specification\n")
					sh.status = 1
				end
			end
		elseif pflag or (#names == 0 and not any) then
			if #names == 0 then
				for _, e in ipairs(listing()) do
					sh:echo(line(e.n, tab[e.n]))
				end
			end
			for _, n in ipairs(names) do
				if tab[n] then
					sh:echo(line(n, tab[n]))
				else
					io.stderr:write("curse: complete: " .. n .. ": no completion specification\n")
					sh.status = 1
				end
			end
		elseif #names == 0 and not (spec.D or spec.E or spec.I) then
			io.stderr:write("curse: complete: usage error\n")
			sh.status = 2
		else
			for _, n in ipairs(names) do
				local old = tab[n]
				rt.complete_seq = (rt.complete_seq or 0) + 1
				local cs = { opts = spec.opts, acts = spec.acts, seq = old and old.seq or rt.complete_seq }
				for _, f in ipairs({ "G", "W", "P", "S", "X", "C", "F", "D", "E", "I" }) do
					cs[f] = spec[f]
				end
				tab[n] = cs
			end
		end
	elseif cmd == "compopt" then
		-- compopt [-o|+o OPT] [-DEI] [NAME …]: change a spec's options. Outside a completion
		-- function (curse never runs one) it needs a NAME with a spec (bash's compopt.def).
		local OK = { bashdefault = 1, default = 1, dirnames = 1, filenames = 1, noquote = 1, nosort = 1,
			nospace = 1, plusdirs = 1 }
		local on, off, special = {}, {}, {}
		local k = 2
		while args[k] and args[k]:match("^[-+].") do
			local a = args[k]
			k = k + 1
			if a == "--" then
				break
			end
			local i = 2
			while i <= #a do
				local f = a:sub(i, i)
				i = i + 1
				if f == "o" then
					local v = a:sub(i) ~= "" and a:sub(i) or args[k]
					if a:sub(i) == "" then
						k = k + 1
					end
					if v == nil then
						io.stderr:write("curse: compopt: -o: option requires an argument\n" .. rt.usage("compopt"))
						sh.status = 2
						return
					end
					if not OK[v] then
						io.stderr:write("curse: compopt: " .. v .. ": invalid option name\n")
						sh.status = 2
						return
					end
					if a:sub(1, 1) == "+" then
						off[#off + 1] = v
					else
						on[#on + 1] = v
					end
					break
				elseif a:sub(1, 1) == "-" and (f == "D" or f == "E" or f == "I") then
					special[#special + 1] = f == "D" and "_DefaultCmD_" or f == "E" and "_EmptycmD_" or "_InitialWorD_"
				else
					return rt.bad_option(sh, "compopt", a:sub(1, 1) .. f)
				end
			end
		end
		local names = special
		for j = k, #args do
			names[#names + 1] = args[j]
		end
		if #names == 0 then
			io.stderr:write("curse: compopt: not currently executing completion function\n")
			sh.status = 1
			return
		end
		sh.status = 0
		local tab = sh.complete or {}
		for _, n in ipairs(names) do
			local cs = tab[n]
			if not cs then
				io.stderr:write("curse: compopt: " .. n .. ": no completion specification\n")
				sh.status = 1
			else
				local opts = {}
				for o in pairs(cs.opts) do
					opts[o] = true
				end
				for _, o in ipairs(on) do
					opts[o] = true
				end
				for _, o in ipairs(off) do
					opts[o] = nil
				end
				cs.opts = opts
			end
		end
		return
	end
end
