-- Lazily-loaded builtin feature module (see BUILTIN_LAZY in interp.lua). Its own
-- module -- no grab bags -- so a script loads only the builtin it uses. Internals
-- aliased to interp's names so the branch body is a verbatim copy.
local ffi = require("ffi")
local rt = require("runtime")
local M = require("interp")
local I = M._int
local exec_simple, expand_part_str, tilde_word_initial, file_test, sq =
	I.exec_simple, I.expand_part_str, I.tilde_word_initial, I.file_test, I.sq
local BUILTINS, KEYWORDS, SETOPTS, SHOPT_ORDER = I.BUILTINS, I.KEYWORDS, I.SETOPTS, I.SHOPT_ORDER
local parse_umask, umask_symbolic = I.parse_umask, I.umask_symbolic
local job_reap, block_sig, canon_sig, sig_order = I.job_reap, I.block_sig, I.canon_sig, I.sig_order
local find_all_in_path, name_type, SIGNUM, NUMSIG = I.find_all_in_path, I.name_type, I.SIGNUM, I.NUMSIG
local array_key, sh_printf, fd_getc, fd_ready, read_split =
	I.array_key, I.sh_printf, I.fd_getc, I.fd_ready, I.read_split
local do_arrayassign, eval, fmt_decl, fmt_set_var = I.do_arrayassign, I.eval, I.fmt_decl, I.fmt_set_var
local C, P = I.C, I.P

-- bash's printable_filename(S, 1): $'…' for a non-printable, '…' for a shell metachar
local function pfn(s)
	return (rt.ansic_shouldquote(s) or rt.shell_metas(s)) and rt.shell_quote(s) or s
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "hash" then
		-- hash [-r] [NAME…] : the command-location cache. bare = list; NAME = look up
		-- and cache; -r = forget all. (bash keeps a cached path until -r, ignoring a
		-- later PATH change — see Shell:resolve_cmd.)
		sh.hashcache = sh.hashcache or {}
		do -- (the table belongs to the $PATH it was built for: assigning PATH empties it)
			local cur = sh:get("PATH")
			if sh.hashpath ~= nil and sh.hashpath ~= cur then
				sh.hashcache = {}
			end
			sh.hashpath = cur
		end
		-- (internal_getopt "dlp:rt": -p takes the rest of its word or the next one)
		local rflag, names, j = false, {}, 2
		local ppath
		local dflag, tflag, lflag = false, false, false
		while args[j] and args[j]:sub(1, 1) == "-" and #args[j] > 1 do
			local w = args[j]
			j = j + 1
			if w == "--" then
				break
			elseif w == "--help" then -- (GETOPT_HELP: the builtin's help, status 2)
				return rt.builtin_help(sh, "hash")
			end
			local k = 2
			while k <= #w do
				local f = w:sub(k, k)
				if f == "r" then
					rflag = true
				elseif f == "d" then
					dflag = true
				elseif f == "t" then
					tflag = true
				elseif f == "l" then
					lflag = true
				elseif f == "p" then -- -p PATH NAME: remember NAME at PATH (unchecked)
					if k < #w then
						ppath = w:sub(k + 1)
					else
						ppath = args[j]
						j = j + 1
					end
					if ppath == nil then
						io.stderr:write("curse: hash: -p: option requires an argument\n" .. rt.usage("hash"))
						sh.status = 2
						return
					end
					break
				else
					io.stderr:write("curse: hash: -" .. f .. ": invalid option\n")
					io.stderr:write("hash: usage: hash [-lr] [-p pathname] [-dt] [name ...]\n")
					sh.status = 2
					return
				end
				k = k + 1
			end
		end
		if args[j] == nil and (dflag or tflag) then -- (-d/-t need names)
			io.stderr:write("curse: hash: -" .. (dflag and "d" or "t") .. ": option requires an argument\n")
			sh.status = 1
			return
		end
		if args[j] == nil and not rflag then
			ppath = nil -- (`hash -p PATH` alone lists the table)
		end
		if sh.opt_h == false then -- set +h: no command hashing at all
			io.stderr:write("curse: hash: hashing disabled\n")
			sh.status = 1
			return
		end
		if ppath then
			if not rt.restricted_hash_ok(sh, "hash: ", ppath) then
				return
			end
			if file_test("-d", ppath) then -- (bash: EISDIR, status 1)
				io.stderr:write("curse: hash: " .. ppath .. ": Is a directory\n")
				sh.status = 1
				return
			end
			local cur = sh:get("PATH")
			if sh.hashpath ~= cur then -- (the table belongs to the current $PATH)
				sh.hashcache = {}
				sh.hashpath = cur
			end
			for k = j, #args do
				rt.hash_seq = rt.hash_seq + 1
				sh.hashcache[args[k]] = { path = ppath, hits = 0, seq = rt.hash_seq }
			end
			sh.status = 0
			return
		end
		for k = j, #args do
			names[#names + 1] = args[k]
		end
		if rflag then
			rt.path_cache_forget()
			for k in pairs(sh.hashcache) do
				sh.hashcache[k] = nil
			end
		end
		if #names > 0 and (dflag or tflag) then
			sh.status = 0
			if dflag and not tflag and not next(sh.hashcache) then -- (bash: nothing to remove from, quietly)
				return
			end
			for _, nm in ipairs(names) do
				local e = sh.hashcache[nm]
				if tflag then -- (phash_search: counts a hit; a relative entry shown as ./…)
					e = rt.phash_search(sh, nm)
				end
				if not e then
					io.stderr:write("curse: hash: " .. nm .. ": not found\n")
					sh.status = 1
				elseif not tflag then
					sh.hashcache[nm] = nil
				elseif lflag then -- -lt: as reusable input
					sh:echo("builtin hash -p " .. e .. " " .. nm)
				else -- -t: the remembered path (NAME<TAB>PATH for several — bash)
					sh:echo((#names > 1 and (nm .. "\t") or "") .. e)
				end
			end
		elseif #names > 0 then
			sh.status = 0
			for _, nm in ipairs(names) do -- (add_hashed_command: a function or builtin is skipped;
				-- a name is looked up afresh, its count starting over at 0)
				if not nm:find("/", 1, true) and not sh.functions[nm]
					and not (BUILTINS[nm] and not (sh.disabled_builtins and sh.disabled_builtins[nm])) then
					sh.hashcache[nm] = nil
					rt.path_cache_forget(nm)
					if sh:resolve_cmd(nm) then
						rt.hash_hit(sh.hashcache, nm).hits = 0
					else
						io.stderr:write("curse: hash: " .. nm .. ": not found\n")
						sh.status = 1
					end
				end
			end
		elseif not rflag then -- bare `hash`: print the cache (bash format)
			-- (bash lists its 256-bucket hash table: by bucket, newest first within one)
			local ks = {}
			for k in pairs(sh.hashcache) do
				ks[#ks + 1] = k
			end
			local hc = sh.hashcache
			table.sort(ks, function(a, z)
				local ba, bz = rt.assoc_bucket(a, 256), rt.assoc_bucket(z, 256)
				if ba ~= bz then
					return ba < bz
				end
				return (hc[a].seq or 0) > (hc[z].seq or 0)
			end)
			if lflag then -- (reusable input; nothing at all for an empty table)
				for _, k in ipairs(ks) do
					sh:echo("builtin hash -p " .. pfn(sh.hashcache[k].path) .. " " .. pfn(k))
				end
			elseif #ks > 0 then
				sh.out(rt.L("hits\tcommand\n"))
				for _, k in ipairs(ks) do
					sh:echo(("%4d\t%s"):format(sh.hashcache[k].hits, sh.hashcache[k].path))
				end
			elseif not sh.opt_posix then
				sh.out(rt.L("%s: hash table empty\n", "hash")) -- (bash says so on stdout)
			end
			sh.status = 0
		else
			sh.status = 0
		end
	end
end
