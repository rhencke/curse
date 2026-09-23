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
local sherr = I.sherr

-- pushd / popd / dirs — a port of bash's builtins/pushd.def. The model is bash's: the
-- current directory is always the top of the stack (implicit), and sh.dirstack holds the
-- entries BELOW it, bottom first (bash's pushd_directory_list[0 .. offset-1]).
local PUSHD_USAGE = "pushd: usage: pushd [-n] [+N | -N | dir]\n"
local POPD_USAGE = "popd: usage: popd [-n] [+N | -N]\n"
local DIRS_USAGE = "dirs: usage: dirs [-clpv] [+N] [-N]\n"

local function legal_number(s)
	return s:match("^%s*[+-]?%d+%s*$") and tonumber(s) or nil
end

return function(sh, cmd, args, hook, tcb)
	sh.dirstack = sh.dirstack or {}
	local pd = sh.dirstack
	-- a path with a leading $HOME shown as ~ (bash's polite_directory_format)
	local function polite(p)
		local h = sh:get("HOME")
		if h ~= "" and p:sub(1, #h) == h and (#p == #h or p:sub(#h + 1, #h + 1) == "/") then
			return "~" .. p:sub(#h + 1)
		end
		return p
	end
	local function usage(msg)
		io.stderr:write(msg)
		sh.status = 2
	end
	local function pushd_error(arg)
		if #pd == 0 then
			sh:errmsg("curse: " .. cmd .. ": directory stack empty\n")
		else
			sh:errmsg("curse: " .. cmd .. ": " .. arg .. ": directory stack index out of range\n")
		end
		sh.status = 1
	end
	local function cd_to(dir) -- through the cd builtin (PWD/OLDPWD, errors) — `cd -- dir`
		require("b_cd")(sh, "cd", { "cd", "--", dir }, hook, nil, cmd)
		return sh.status == 0
	end
	local function dirs(argl)
		local long, clear, vflag, index_flag, desired, w = false, false, 0, 0, -1, ""
		for _, a in ipairs(argl) do
			if a == "-l" then
				long = true
			elseif a == "-c" then
				clear = true
			elseif a == "-v" then
				vflag = bit.bor(vflag, 2)
			elseif a == "-p" then
				vflag = bit.bor(vflag, 1)
			elseif a == "--" then
				break
			elseif a:sub(1, 1) == "+" or a:sub(1, 1) == "-" then
				w = a:sub(2)
				local n = legal_number(w)
				if not n then
					io.stderr:write("curse: dirs: " .. a .. ": invalid number\n")
					return usage(DIRS_USAGE)
				end
				local sign = a:sub(1, 1) == "+" and 1 or -1
				-- bash's get_dirstack_index
				index_flag = sign > 0 and 1 or 2
				if n == 0 and sign > 0 then
					desired = 0
				elseif n == #pd then
					index_flag = sign > 0 and 2 or 1
					desired = 0
				elseif n >= 0 and n <= #pd then
					desired = sign > 0 and (#pd - n) or n
				else
					desired = -1
				end
			else
				io.stderr:write("curse: dirs: " .. a .. ": invalid option\n")
				return usage(DIRS_USAGE)
			end
		end
		if clear then
			sh.dirstack = {}
			sh.status = 0
			return
		end
		if index_flag ~= 0 and (desired < 0 or desired > #pd) then
			return pushd_error(w)
		end
		local function fmt(p)
			return long and p or polite(p)
		end
		local out = {}
		if index_flag == 0 or (index_flag == 1 and desired == 0) then
			local cwd = fmt(sh:pwd())
			out[#out + 1] = bit.band(vflag, 2) ~= 0 and ("%2d  %s"):format(0, cwd) or cwd
			if index_flag ~= 0 then
				sh:echo(table.concat(out))
				sh.status = 0
				return
			end
		end
		if index_flag ~= 0 then -- desired is a C index into the list (0 = bottom)
			local e = fmt(pd[desired + 1])
			out[#out + 1] = bit.band(vflag, 2) ~= 0 and ("%2d  %s"):format(#pd - desired, e) or e
		else
			for i = #pd, 1, -1 do
				local e = fmt(pd[i])
				if vflag >= 2 then
					out[#out + 1] = ("\n%2d  %s"):format(#pd - (i - 1), e)
				else
					out[#out + 1] = (bit.band(vflag, 1) ~= 0 and "\n" or " ") .. e
				end
			end
		end
		sh:echo(table.concat(out))
		sh.status = 0
	end
	local function change_to_temp(temp)
		if temp and cd_to(temp) then
			dirs({})
			return
		end
		sh.status = 1
	end

	if cmd == "dirs" then
		return dirs({ unpack(args, 2) })
	elseif cmd == "pushd" then
		local list, skipopt = { unpack(args, 2) }, false
		if list[1] == "--" then
			table.remove(list, 1)
			skipopt = true
		end
		if #list == 0 then -- swap the current directory and the top of the list
			if #pd == 0 then
				sh:errmsg("curse: pushd: no other directory\n")
				sh.status = 1
				return
			end
			local temp = pd[#pd]
			pd[#pd] = sh:pwd()
			return change_to_temp(temp)
		end
		local nocd, rotate, num = false, false, 0
		local i = 1
		while not skipopt and i <= #list do
			local w = list[i]
			if w == "-n" then
				nocd = true
			elseif w == "--" then
				i = i + 1
				break
			elseif w == "-" then
				break -- `pushd -` works like it used to
			elseif w:sub(1, 1) == "+" or w:sub(1, 1) == "-" then
				local n = legal_number(w:sub(2))
				if not n then
					io.stderr:write("curse: pushd: " .. w .. ": invalid number\n")
					return usage(PUSHD_USAGE)
				end
				num = w:sub(1, 1) == "-" and (#pd - n) or n
				if num > #pd or num < 0 then
					return pushd_error(w)
				end
				rotate = true
			elseif w:sub(1, 1) == "-" then
				io.stderr:write("curse: pushd: " .. w .. ": invalid option\n")
				return usage(PUSHD_USAGE)
			else
				break
			end
			i = i + 1
		end
		if rotate then -- rotate num times; the current directory counts as part of the stack
			local temp = sh:pwd()
			if num == 0 then
				if nocd then
					sh.status = 0
					return
				end
				return change_to_temp(temp)
			end
			repeat
				local top = pd[#pd]
				for j = #pd - 1, 1, -1 do
					pd[j + 1] = pd[j]
				end
				pd[1] = temp
				temp = top
				num = num - 1
			until num == 0
			if nocd then -- (bash drops the new top entry here: it is neither kept nor cd'd to)
				sh.status = 0
				return
			end
			return change_to_temp(temp)
		end
		if i > #list then
			sh.status = 0
			return
		end
		local cur = sh:pwd()
		local dir = list[i]
		if list[i + 1] ~= nil then -- (bash hands the rest to cd, which takes one directory)
			sh:errmsg("curse: pushd: too many arguments\n")
			sh.status = 1
			return
		end
		if nocd or cd_to(dir) then
			pd[#pd + 1] = nocd and dir or cur
			dirs({})
			return
		end
		sh.status = 1
	else -- popd
		local nocd, which, direction, which_word = false, 0, "+", nil
		for _, w in ipairs({ unpack(args, 2) }) do
			if w == "-n" then
				nocd = true
			elseif w == "--" then
				break
			elseif w:sub(1, 1) == "+" or w:sub(1, 1) == "-" then
				direction = w:sub(1, 1)
				local n = legal_number(w:sub(2))
				if not n then
					io.stderr:write("curse: popd: " .. w .. ": invalid number\n")
					return usage(POPD_USAGE)
				end
				which, which_word = n, w
			elseif w:sub(1, 1) == "-" then
				io.stderr:write("curse: popd: " .. w .. ": invalid option\n")
				return usage(POPD_USAGE)
			elseif w ~= "" then
				io.stderr:write("curse: popd: " .. w .. ": invalid argument\n")
				return usage(POPD_USAGE)
			else
				break
			end
		end
		if which > #pd or which < -#pd or (#pd == 0 and which == 0) then
			return pushd_error(which_word or "")
		end
		if (direction == "+" and which == 0) or (direction == "-" and which == #pd) then
			if not nocd and not cd_to(pd[#pd]) then
				return
			end
			pd[#pd] = nil
		else
			local ci = direction == "+" and (#pd - which) or which -- C index
			if ci < 0 or ci > #pd then
				return pushd_error(which_word or "")
			end
			table.remove(pd, ci + 1)
		end
		dirs({})
	end
end
