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
local logical_canon = I.logical_canon

local statbuf = I.statbuf

-- lib/sh/spell.c (cdspell): spdist — 0 identical, 1 two characters transposed, 2 one
-- character wrong, added or deleted, 3 otherwise
local function spdist(cur, new)
	local i = 1
	while cur:byte(i) == new:byte(i) do
		if i > #cur then
			return 0
		end
		i = i + 1
	end
	cur, new = cur:sub(i), new:sub(i)
	if cur ~= "" then
		if new ~= "" then
			if #cur > 1 and #new > 1 and cur:byte(1) == new:byte(2) and cur:byte(2) == new:byte(1)
				and cur:sub(3) == new:sub(3) then
				return 1
			end
			if cur:sub(2) == new:sub(2) then
				return 2
			end
		end
		if cur:sub(2) == new then
			return 2
		end
	end
	if new ~= "" and cur == new:sub(2) then
		return 2
	end
	return 3
end
-- mindist: the entry of DIR nearest GUESS (a later one as near wins; never `.`)
local function mindist(dir, guess)
	local d = C.opendir(dir == "" and "." or dir)
	if d == nil then
		return 3
	end
	local dist, best = 3, nil
	while true do
		local e = C.readdir(d)
		if e == nil then
			break
		end
		local name = ffi.string(ffi.cast("const char *", e) + 19) -- d_name @ 19 (glibc x86-64)
		local x = spdist(name, guess)
		if x <= dist and x ~= 3 then
			best, dist = name, x
			if x == 0 then
				break
			end
		end
	end
	C.closedir(d)
	if best == "." then
		dist = 3
	end
	return dist, best
end
-- spname/dirspell: correct each component of NAME, or nil when one is hopeless
local function dirspell(name)
	local out, i, n = {}, 1, #name
	while true do
		local s, e = name:find("^/+", i)
		if s then
			out[#out + 1] = name:sub(s, e)
			i = e + 1
		end
		if i > n then
			local new = table.concat(out)
			if #name == 1 and #new == 1 and name ~= "." and new == "." then
				return nil
			end
			return new
		end
		local e2 = (name:find("/", i, true) or (n + 1)) - 1
		local dist, best = mindist(table.concat(out), name:sub(i, e2))
		if dist >= 3 then
			return nil
		end
		out[#out + 1] = best
		i = e2 + 1
	end
end

-- lib/sh/pathcanon.c's _path_isdir
local function isdir(path)
	return C.curse_stat(path, statbuf) == 0
		and bit.band(ffi.cast("uint32_t *", statbuf + 24)[0], 0xF000) == 0x4000
end

-- sh_canonpath(PATH, PATH_CHECKDOTDOT|PATH_CHECKEXISTS): collapse `//`, drop `.`, let
-- `..` pop the previous name — textually, but every prefix built must name an existing
-- directory (else nil: canonicalization failed). A leading `//` (exactly two) survives.
-- A relative PATH (no internal cwd: getcwd failed) stays relative — a `..` with nothing
-- to pop is kept, and an empty result is `.`.
local function canonpath(path)
	local rooted = path:byte(1) == 47
	local root = not rooted and "" or (path:byte(2) == 47 and path:byte(3) ~= 47) and "//" or "/"
	local parts, n, dd = {}, 0, 0 -- (dd: the `..`s kept up front can't be popped)
	for seg in path:gmatch("[^/]+") do
		if seg == "." then -- (drop)
		elseif seg == ".." then
			if n > dd then
				parts[n] = nil
				n = n - 1
			elseif not rooted then
				n = n + 1
				parts[n] = ".."
				dd = n
			end
		else
			n = n + 1
			parts[n] = seg
			if not isdir(root .. table.concat(parts, "/")) then
				return nil
			end
		end
	end
	local r = root .. table.concat(parts, "/")
	return r ~= "" and r or "."
end

-- resetpwd: forget the internal cwd and ask getcwd (get_working_directory's complaint
-- when it can't); nil on failure.
local function resetpwd(sh, who)
	sh.tcwd = nil
	local p = sh:phys_cwd()
	if p == "" then
		local e = ffi.errno()
		io.stderr:write(rt.L("%s: error retrieving current directory: %s: %s\n", who,
			rt.L("getcwd: cannot access parent directories"), ffi.string(C.strerror(e))))
		return nil
	end
	sh.tcwd = p
	return p
end

-- cd.def's change_to_directory: chdir to NEWDIR and set the internal cwd (sh.tcwd,
-- bash's the_current_working_directory). Logically (-L) the canonicalized absolute path
-- is tried first; if canonicalizing fails, the uncanonicalized one, and when that chdir
-- fails, the operand verbatim (not in posix mode) -- each fallback re-deriving the cwd
-- from getcwd. Returns ok, errno, canon_failed.
local function change_to(sh, newdir, nolinks)
	local cur = sh.tcwd or resetpwd(sh, "chdir")
	local t = (newdir:byte(1) == 47 or not cur) and newdir
		or (cur:byte(-1) == 47 and cur .. newdir or cur .. "/" .. newdir)
	local tdir = not nolinks and canonpath(t) or nil
	local canon_failed = not nolinks and tdir == nil
	if canon_failed then
		tdir = t
		if sh.opt_posix then
			local e = ffi.errno()
			return false, (e == 2 or e == 36) and e or 20 -- (ENOENT/ENAMETOOLONG, else ENOTDIR)
		end
	end
	if C.chdir(nolinks and newdir or tdir) == 0 then
		if nolinks then -- (sh_physpath of the new directory: getcwd, `//` kept; failing
			if sh:phys_cwd() == "" then -- that, the path as built)
				resetpwd(sh, "cd")
				sh.tcwd, canon_failed = t, true
			else
				sh.tcwd = rt.phys_under(sh, t)
			end
		elseif canon_failed then
			if not resetpwd(sh, "cd") then
				sh.tcwd = tdir
			end
		else
			sh.tcwd = tdir
		end
		return true, 0, canon_failed
	end
	local err = ffi.errno()
	if nolinks then
		return false, err
	end
	if not sh.opt_posix and C.chdir(newdir) == 0 then
		if not resetpwd(sh, "cd") then
			sh.tcwd = tdir
		end
		return true, 0, canon_failed
	end
	return false, err
end

-- Bind NAME (OLDPWD/PWD) to VAL (nil: declared without a value) as bind_variable does:
-- attributes kept, the environment updated only when it is exported. false: readonly.
local function bindvar(sh, name, val)
	local b = sh.vars[name]
	if b and b.ro then
		io.stderr:write("curse: " .. name .. ": readonly variable\n")
		return false
	end
	if val then
		sh:set_str(name, val)
	elseif b and not b.arr then
		b.s, b.n = nil, nil
		if b.exported then
			C.unsetenv(name)
		end
	else
		sh:set_str(name, "")
		b = sh.vars[name]
		b.s, b.n = nil, nil
	end
	return true
end

-- cd.def's bindpwd: OLDPWD gets $PWD's value (whatever it is now -- the internal cwd
-- is what cd used), PWD the new internal cwd. Either readonly: a failure, but the
-- directory change stands.
local function bindpwd(sh, eflag, canon_failed)
	local r = 0
	local b = sh.vars["PWD"]
	local pwdvar = b and (b.s or (b.n and sh:get("PWD"))) or nil
	if b and b.arr then
		pwdvar = sh:get("PWD")
	end
	if not bindvar(sh, "OLDPWD", pwdvar) then
		r = 1
	end
	if not bindvar(sh, "PWD", sh.tcwd) then
		r = 1
	end
	if canon_failed and eflag then
		r = 1
	end
	return r
end

return function(sh, cmd, args, hook, tcb, as)
	if cmd == "cd" then
		local who = as or "cd" -- (pushd/popd run cd under their own name in its errors)
		if rt.restricted(sh, "cd: restricted") then
			return
		end
		-- options (internal_getopt "eLP": no O_XATTR here, so -@ is invalid), a `--`,
		-- then the directory operand.
		local operands, j, nolinks, eflag = {}, 2, sh.opt_P or false, false
		while args[j] do
			local a = args[j]
			if a == "--" then
				j = j + 1
				break
			elseif a:match("^%-[LPe]+$") then
				for f in a:gmatch("[LPe]") do -- (the last of -L/-P wins)
					if f == "e" then
						eflag = true
					else
						nolinks = f == "P"
					end
				end
				j = j + 1
			elseif a:match("^%-.") and who == "cd" then
				return rt.bad_option(sh, "cd", "-" .. a:match("^%-[LPe]*(.)"))
			else
				break
			end
		end
		for k = j, #args do
			operands[#operands + 1] = args[k]
		end
		eflag = eflag and nolinks
		local dovars = sh.shopt.cdable_vars
		local dir, print_dir = operands[1], false
		if dir == nil then -- `cd` is `cd $HOME` (an unset HOME is the error; an empty one stays)
			local hb = sh.vars[sh:deref("HOME")]
			if not hb or (hb.s == nil and hb.n == nil and not hb.arr) then
				io.stderr:write("curse: " .. who .. ": HOME not set\n")
				sh.status = 1
				return
			end
			dir, dovars = sh:get("HOME"), false
		elseif #operands > 1 then
			io.stderr:write("curse: " .. who .. ": too many arguments\n")
			sh.status = 1
			return
		elseif dir == "-" then -- `cd $OLDPWD`, printed (SUSv3) as given
			local ob = sh.vars[sh:deref("OLDPWD")]
			if not ob or (ob.s == nil and ob.n == nil and not ob.arr) then
				io.stderr:write("curse: " .. who .. ": OLDPWD not set\n")
				sh.status = 1
				return
			end
			dir, print_dir = sh:get("OLDPWD"), true
		elseif not sh.opt_p and dir:byte(1) ~= 47 and not (dir:byte(1) == 46
			and (dir == "." or dir == ".." or dir:byte(2) == 47 or dir:sub(2, 3) == "./")) then
			-- CDPATH: a relative operand (not absolute_pathname's `.`, `..`, `./…`, `../…`)
			-- is looked up under each entry (tilde-expanded; an
			-- empty one is `.`). A hit through a non-empty entry prints where it went:
			-- the path as built with -P, else the new logical cwd.
			local cb = sh.vars[sh:deref("CDPATH")]
			local cdpath = cb and sh:get("CDPATH")
			if cdpath and cdpath ~= "" then
				for entry in (cdpath .. ":"):gmatch("([^:]*):") do
					local temp
					if entry == "" then
						temp = "./" .. dir
					else
						if entry:byte(1) == 126 then
							entry = rt.tilde_prefix(sh, entry) or entry
						end
						temp = entry:byte(-1) == 47 and entry .. dir or entry .. "/" .. dir
					end
					local ok, _, cf = change_to(sh, temp, nolinks)
					if ok then
						if entry ~= "" then
							sh:echo(nolinks and temp or sh.tcwd)
						end
						sh.status = bindpwd(sh, eflag, cf)
						return
					end
				end
			end
		end
		local ok, err, cf = change_to(sh, dir, nolinks)
		if ok then
			if print_dir then
				sh:echo(dir)
			end
			sh.status = bindpwd(sh, eflag, cf)
			return
		end
		-- cdable_vars: a variable whose value is the directory to change to
		if dovars and dir:match("^[%a_][%w_]*$") then
			local vb = sh.vars[sh:deref(dir)]
			if vb and (vb.s or vb.n or vb.arr) then
				local val = sh:get(dir)
				ok, err, cf = change_to(sh, val, nolinks)
				if ok then
					sh:echo(val)
					sh.status = bindpwd(sh, eflag, cf)
					return
				end
			end
		end
		-- cdspell (an interactive shell only): a directory a simple typo away
		if sh.opt_i and sh.shopt.cdspell then
			local g = dirspell(dir)
			if g then
				local gok, _, gcf = change_to(sh, g, nolinks)
				if gok then
					sh:echo(g)
					sh.status = bindpwd(sh, eflag, gcf)
					return
				end
			end
		end
		io.stderr:write("curse: " .. who .. ": " .. rt.err_name(dir) .. ": "
			.. (err ~= 0 and ffi.string(C.strerror(err)) or "No such file or directory") .. "\n")
		sh.status = 1
	end
end
