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
local rl_capture, rl_lib = I.rl_capture, I.rl_lib

-- readline's state is PROCESS-global, and `bind` changes it in place; a subshell, $(…) or
-- pipeline stage runs in-process here, where bash's would be a forked child whose bindings
-- die with it. So the first change inside such a context snapshots the state — every
-- keymap reachable from the emacs/vi roots (entries copied; a macro's text re-duplicated,
-- since readline frees a macro it rebinds), the variables, the current keymap, the
-- curse-side -x table — and the context's end (rt iso_undo → ctx.rl) puts it back.
pcall(ffi.cdef, [[
  typedef struct { char type; void *function; } curse_kment;
  curse_kment *rl_get_keymap_by_name(const char *);
  curse_kment *rl_get_keymap(void);
  void rl_set_keymap(curse_kment *);
  char *rl_variable_value(const char *);
  int rl_variable_bind(const char *, const char *);
  char *strdup(const char *);
]])
local function deepcopy(t)
	if type(t) ~= "table" then
		return t
	end
	local c = {}
	for k, v in pairs(t) do
		c[k] = deepcopy(v)
	end
	return c
end
local function rl_snapshot(sh, rl)
	local maps, seen = {}, {}
	local function walk(km)
		if km == nil then
			return
		end
		local key = tostring(ffi.cast("uintptr_t", km))
		if seen[key] then
			return
		end
		seen[key] = true
		local copy, macros = ffi.new("curse_kment[257]"), {}
		ffi.copy(copy, km, ffi.sizeof("curse_kment") * 257)
		maps[#maps + 1] = { km = km, copy = copy, macros = macros }
		for i = 0, 256 do
			local e = km[i]
			if e.type == 1 then
				walk(ffi.cast("curse_kment *", e["function"]))
			elseif e.type == 2 and e["function"] ~= nil then
				macros[i] = ffi.string(ffi.cast("const char *", e["function"]))
			end
		end
	end
	for _, n in ipairs({ "emacs-standard", "vi-move", "vi-insert" }) do
		walk(rl.rl_get_keymap_by_name(n))
	end
	local vars = {}
	for _, l in ipairs(rl_capture(function(r)
		r.rl_variable_dumper(1)
	end) or {}) do
		local name, val = l:match("^set (%S+) (.*)$")
		if name then
			vars[#vars + 1] = { name, val }
		end
	end
	local cur, bx = rl.rl_get_keymap(), sh.bind_x
	sh.bind_x = deepcopy(bx) -- (the -x table: the context changes its own copy)
	return function()
		for _, m in ipairs(maps) do
			ffi.copy(m.km, m.copy, ffi.sizeof("curse_kment") * 257)
			for i, txt in pairs(m.macros) do
				m.km[i]["function"] = C.strdup(txt)
			end
		end
		for _, v in ipairs(vars) do
			local now = rl.rl_variable_value(v[1])
			if now == nil or ffi.string(now) ~= v[2] then
				rl.rl_variable_bind(v[1], v[2])
			end
		end
		rl.rl_set_keymap(cur)
		sh.bind_x = bx
	end
end
-- (before a change: in an in-process subshell context, snapshot once per context)
local function rl_touch(sh)
	local ctx = rt.iso_cur(sh)
	if ctx and not ctx.rl then
		local rl = rl_lib()
		if rl then
			ctx.rl = rl_snapshot(sh, rl)
		else
			local bx = sh.bind_x
			sh.bind_x = deepcopy(bx)
			ctx.rl = function()
				sh.bind_x = bx
			end
		end
	end
end

return function(sh, cmd, args, hook, tcb)
	if cmd == "bind" then
		-- readline introspection + binding via FFI (same library bash links ->
		-- identical output, no tty needed). Shell-command bindings (-x/-X) are kept
		-- curse-side, per keymap, in bash's `"keyseq": "cmd"` format.
		if not rt.line_editing(sh) then -- (no_line_editing: bash says so first, whatever the arguments)
			io.stderr:write("curse: bind: warning: line editing not enabled\n")
		end
		do -- bash's getopt "lvpVPsSXf:q:u:m:r:x:": bad letters and missing arguments
			local k = 2
			while args[k] and args[k]:match("^%-.") and args[k] ~= "--" do
				local a = args[k]
				k = k + 1
				for ci = 2, #a do
					local f = a:sub(ci, ci)
					if f:match("[fqumrx]") then
						if ci == #a then
							if args[k] == nil then
								io.stderr:write("curse: bind: -" .. f .. ": option requires an argument\n" .. rt.usage("bind"))
								sh.status = 2
								return
							end
							if f == "x" and not args[k]:match('^%s*"') then
								io.stderr:write("curse: bind: " .. args[k] .. ": first non-whitespace character is not `\"'\n")
								sh.status = 1
								return
							end
							k = k + 1
						end
						break
					elseif not f:match("[lvpVPsSX]") then
						return rt.bad_option(sh, "bind", "-" .. f)
					end
				end
			end
		end
		local j = 2
		local keymap = "emacs" -- -m KEYMAP selects the keymap for -x/-X (default emacs)
		if args[j] == "-m" then
			keymap = args[j + 1] or keymap
			j = j + 2
		end
		local a = args[j]
		local function emit(lines)
			if lines then
				for _, l in ipairs(lines) do
					sh:echo(l)
				end
			end
		end
		if a == "-x" or a == "-r" or (a and a:sub(1, 1) ~= "-") then -- (a change)
			rl_touch(sh)
		end
		if a == "-x" then -- bind a key sequence to a shell command: -x '"KEYSEQ": CMD'
			local seq, command = (args[j + 1] or ""):match('^%s*"(.-)"%s*:%s*(.*)$')
			if seq then
				sh.bind_x = sh.bind_x or {}
				sh.bind_x[keymap] = sh.bind_x[keymap] or {}
				local km = sh.bind_x[keymap]
				for _, e in ipairs(km) do
					if e.seq == seq then
						e.cmd = command
						seq = nil
						break
					end
				end
				if seq then
					km[#km + 1] = { seq = seq, cmd = command }
				end
			end
			sh.status = 0
		elseif a == "-X" then -- list shell-command bindings for the keymap
			local km = sh.bind_x and sh.bind_x[keymap]
			if km then
				for _, e in ipairs(km) do
					sh:echo('"' .. e.seq .. '": "' .. e.cmd .. '"')
				end
			end
			sh.status = 0
		elseif a == "-r" then -- remove the binding for a key sequence
			local seq = args[j + 1]
			if seq then
				local km = sh.bind_x and sh.bind_x[keymap]
				if km then
					for i = #km, 1, -1 do
						if km[i].seq == seq then
							table.remove(km, i)
						end
					end
				end
				local rl = rl_lib()
				if rl then
					pcall(rl.rl_bind_keyseq, seq, nil)
				end -- readline binding
			end
			sh.status = 0
		elseif a == "-l" then
			local rl = rl_lib()
			if rl then
				local names = rl.rl_funmap_names()
				local i = 0
				while names[i] ~= nil do
					sh:echo(ffi.string(names[i]))
					i = i + 1
				end
			end
			sh.status = 0
		elseif a == "-v" or a == "-V" then
			emit(rl_capture(function(rl)
				rl.rl_variable_dumper(a == "-v" and 1 or 0)
			end))
			sh.status = 0
		elseif a == "-p" or a == "-P" then
			emit(rl_capture(function(rl)
				rl.rl_function_dumper(a == "-p" and 1 or 0)
			end))
			sh.status = 0
		elseif a == "-s" or a == "-S" then
			emit(rl_capture(function(rl)
				rl.rl_macro_dumper(a == "-s" and 1 or 0)
			end))
			sh.status = 0
		elseif a == "-q" then
			local name = args[3]
			local rl = rl_lib()
			local fn = rl and name and rl.rl_named_function(name)
			if not rl or fn == nil then
				io.stderr:write("curse: bind: `" .. tostring(name) .. "': unknown function name\n")
				sh.status = 1
			else
				local ks = rl.rl_invoking_keyseqs(fn)
				if ks == nil or ks[0] == nil then
					sh.out(rt.L("%s is not bound to any keys.\n", name))
					sh.status = 1
				else
					local parts, i = {}, 0
					while ks[i] ~= nil do
						parts[#parts + 1] = '"' .. ffi.string(ks[i]) .. '"'
						i = i + 1
					end
					sh:echo(rt.L("%s can be invoked via ", name) .. table.concat(parts, ", ") .. ".")
					sh.status = 0
				end
			end
		elseif a and a:sub(1, 1) ~= "-" then -- a bare inputrc line: `'"KEYSEQ": function'`
			local rl = rl_lib()
			if rl then
				local buf = ffi.new("char[?]", #a + 1, a)
				pcall(rl.rl_parse_and_bind, buf)
			end
			sh.status = 0
		else
			sh.status = 0 -- -u/-f and other accepted-but-unimplemented forms: no-op
		end
	end
end
