-- Lazily-loaded feature module: the completion builtins (compgen / complete /
-- compopt), after bash's builtins/complete.def + pcomplete.c + pcomplib.c. Loaded on
-- demand via exec_simple's BUILTIN_LAZY table; require caches it (loaded once).
-- Only the non-interactive half exists: compgen evaluates a compspec right here
-- (gen_compspec_completions), complete/compopt keep the spec table.
local ffi = require("ffi")
local IM = require("interp")
local I = IM._int
local exec_simple = I.exec_simple
local file_test, sq = I.file_test, I.sq
local BUILTINS, SETOPTS, SHOPT_ORDER, NUMSIG = I.BUILTINS, I.SETOPTS, I.SHOPT_ORDER, I.NUMSIG
local P, rt = I.P, I.rt

-- the compspec actions (pcomplib.c's compacts) and their option letters
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
-- compopts, in table order (print_compoptions)
local COPTS = { "bashdefault", "default", "dirnames", "filenames", "noquote", "nosort", "nospace", "plusdirs" }
local COPT_OK = {}
for _, o in ipairs(COPTS) do
	COPT_OK[o] = true
end
-- the options taking an argument (internal_getopt's "o:A:G:W:P:S:X:F:C:")
local ARGOPT = { o = 1, A = 1, G = 1, W = 1, P = 1, S = 1, X = 1, F = 1, C = 1 }
-- complete/compopt -D/-E/-I store their spec under these names (pcomplete.h)
local SPECIAL_NAME = { D = "_DefaultCmD_", E = "_EmptycmD_", I = "_InitialWorD_" }
local SPECIAL_FLAG = { _DefaultCmD_ = "-D", _EmptycmD_ = "-E", _InitialWorD_ = "-I" }

-- The item-list actions, in gen_action_completions's fixed order (the order they are
-- output in, whatever order the options came in).
local ITEM_ORDER = {
	"alias", "arrayvar", "binding", "builtin", "disabled", "enabled", "export", "function",
	"helptopic", "hostname", "job", "keyword", "running", "setopt", "shopt", "signal",
	"stopped", "variable",
}
-- parse.y's word_token_alist, in table order (-k)
local KW_ORDER = {
	"if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do",
	"done", "in", "function", "time", "{", "}", "!", "[[", "]]", "coproc",
}
-- readline's bindable function names (funmap.c's default_funmap; rl_funmap_names sorts them)
local FUNMAP = {
	"abort", "accept-line", "arrow-key-prefix", "backward-byte", "backward-char", "backward-delete-char",
	"backward-kill-line", "backward-kill-word", "backward-word", "beginning-of-history", "beginning-of-line",
	"bracketed-paste-begin", "call-last-kbd-macro", "capitalize-word", "character-search",
	"character-search-backward", "clear-display", "clear-screen", "complete", "copy-backward-word",
	"copy-forward-word", "copy-region-as-kill", "delete-char", "delete-char-or-list", "delete-horizontal-space",
	"digit-argument", "do-lowercase-version", "downcase-word", "dump-functions", "dump-macros", "dump-variables",
	"emacs-editing-mode", "end-kbd-macro", "end-of-history", "end-of-line", "exchange-point-and-mark",
	"fetch-history", "forward-backward-delete-char", "forward-byte", "forward-char", "forward-search-history",
	"forward-word", "history-search-backward", "history-search-forward", "history-substring-search-backward",
	"history-substring-search-forward", "insert-comment", "insert-completions", "kill-line", "kill-region",
	"kill-whole-line", "kill-word", "menu-complete", "menu-complete-backward", "next-history",
	"next-screen-line", "non-incremental-forward-search-history", "non-incremental-forward-search-history-again",
	"non-incremental-reverse-search-history", "non-incremental-reverse-search-history-again",
	"old-menu-complete", "operate-and-get-next", "overwrite-mode", "possible-completions", "previous-history",
	"previous-screen-line", "print-last-kbd-macro", "quoted-insert", "re-read-init-file", "redraw-current-line",
	"reverse-search-history", "revert-line", "self-insert", "set-mark", "skip-csi-sequence", "start-kbd-macro",
	"tab-insert", "tilde-expand", "transpose-chars", "transpose-words", "tty-status", "undo",
	"universal-argument", "unix-filename-rubout", "unix-line-discard", "unix-word-rubout", "upcase-word",
	"vi-append-eol", "vi-append-mode", "vi-arg-digit", "vi-bWord", "vi-back-to-indent", "vi-backward-bigword",
	"vi-backward-word", "vi-bword", "vi-change-case", "vi-change-char", "vi-change-to", "vi-char-search",
	"vi-column", "vi-complete", "vi-delete", "vi-delete-to", "vi-eWord", "vi-editing-mode", "vi-end-bigword",
	"vi-end-word", "vi-eof-maybe", "vi-eword", "vi-fWord", "vi-fetch-history", "vi-first-print",
	"vi-forward-bigword", "vi-forward-word", "vi-fword", "vi-goto-mark", "vi-insert-beg", "vi-insertion-mode",
	"vi-match", "vi-movement-mode", "vi-next-word", "vi-overstrike", "vi-overstrike-delete", "vi-prev-word",
	"vi-put", "vi-redo", "vi-replace", "vi-rubout", "vi-search", "vi-search-again", "vi-set-mark", "vi-subst",
	"vi-tilde-expand", "vi-undo", "vi-unix-word-rubout", "vi-yank-arg", "vi-yank-pop", "vi-yank-to", "yank",
	"yank-last-arg", "yank-nth-arg", "yank-pop",
}

-- sh_single_quote: always quoted (the -C command's arguments)
local function sq1(v)
	return "'" .. v:gsub("'", "'\\''") .. "'"
end

-- bash_dequote_text: the word's quotes and backslashes removed (the item-list and -W
-- prefix compare against this). As bash, an opening quote char starts out "open", so
-- the loop's first step closes it again.
local function dequote_text(text)
	local c1 = text:sub(1, 1)
	local quoted = (c1 == '"' or c1 == "'") and c1 or nil
	if not text:find("[\\'\"]") then
		return text
	end
	local out, i, n = {}, 1, #text
	while i <= n do
		local c = text:sub(i, i)
		if c == "\\" then
			local nx = text:sub(i + 1, i + 1)
			if quoted == "'" or (quoted == '"' and not nx:find('^[$`"\\\n]')) then
				out[#out + 1] = c
			end
			if nx == "" then
				break
			end
			out[#out + 1] = nx
			i = i + 2
		elseif quoted and c == quoted then
			quoted = nil
			i = i + 1
		elseif not quoted and (c == "'" or c == '"') then
			quoted = c
			i = i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- a set variable (a declared-but-unset one is bash's att_invisible: not listed)
local function visible(b)
	return b and not (b.s == nil and b.n == nil and b.arr == nil) and not (b.empty_decl and b.arr and next(b.arr) == nil)
end
-- the dynamic specials that exist without a stored binding (listed while they have a
-- value), and the special arrays bash always has
local DYN = {
	"PWD", "OLDPWD", "PPID", "UID", "EUID", "RANDOM", "SECONDS", "LINENO", "HOSTNAME", "BASHPID",
	"BASH_ARGV0", "BASH_COMMAND", "BASH_SUBSHELL", "EPOCHREALTIME", "EPOCHSECONDS", "HISTCMD",
	"HOSTTYPE", "MACHTYPE", "OSTYPE", "SRANDOM", "_",
}
local DYN_ARR = { "BASH_ARGC", "BASH_ARGV", "BASH_LINENO", "BASH_SOURCE", "DIRSTACK", "GROUPS" }
-- all_visible_variables (sorted, as vapply's sort_variables), filtered by pred(binding)
local function var_list(sh, pred)
	local names = {}
	for n, b in pairs(sh.vars) do
		if visible(b) and pred(b, n) then
			names[#names + 1] = n
		end
	end
	local gone = sh.unset_specials or {}
	for _, n in ipairs(DYN) do
		if sh.vars[n] == nil and not gone[n] and pred(nil, n) and sh:get(n) ~= "" then
			names[#names + 1] = n
		end
	end
	for _, n in ipairs(DYN_ARR) do
		if sh.vars[n] == nil and not gone[n] and pred(DYN_ARR, n) then
			names[#names + 1] = n
		end
	end
	if sh.vars.FUNCNAME == nil and sh:in_function() and pred(DYN_ARR, "FUNCNAME") then
		names[#names + 1] = "FUNCNAME" -- (visible only while a function runs)
	end
	for _, n in ipairs({ "SHELLOPTS", "BASHOPTS" }) do -- (derived live, but variables all the same)
		if sh.vars[n] == nil and pred(nil, n) then
			names[#names + 1] = n
		end
	end
	table.sort(names)
	return names
end
local function sorted_keys(t)
	local o = {}
	for k in pairs(t or {}) do
		o[#o + 1] = k
	end
	table.sort(o)
	return o
end
-- shell_builtins in table order (help's topic table, minus the help-only keyword entries)
local function builtin_list(sh, want) -- want: nil = all, true = enabled, false = disabled
	local o, off = {}, sh.disabled_builtins or {}
	for _, t in ipairs(require("helpdata")) do
		local n = t[1]
		if BUILTINS[n] and (want == nil or want == not off[n]) then
			o[#o + 1] = n
		end
	end
	return o
end
-- the job table, newest slot first (it_init_joblist); state: nil any, "run", "stop"
local function job_list(sh, state)
	local o, jobs = {}, sh.jobs or {}
	for k = #jobs, 1, -1 do
		local j = jobs[k]
		if not j.waited and (state == nil or (state == "run" and not j.done and not j.stopped)
			or (state == "stop" and not j.done and j.stopped)) then
			o[#o + 1] = (j.cmd or ""):match("^[^ \t\n]*")
		end
	end
	return o
end
-- lines of a system database file
local function file_lines(path)
	local f = io.open(path, "r")
	if not f then
		return {}
	end
	local o = {}
	for l in f:lines() do
		o[#o + 1] = l
	end
	f:close()
	return o
end
-- the hosts file's names, as snarf_hosts_from_file reads them (appended to OUT)
local function snarf_hosts(path, out)
	for _, l in ipairs(file_lines(path)) do
		local s = l:gsub("^[ \t\r\n]+", "")
		if s ~= "" and s:sub(1, 1) ~= "#" then
			local inc = s:match("^%$include[ \t]+([^ \t\r\n]*)")
			if inc then
				snarf_hosts(inc, out)
			else
				if s:find("^%d") then
					s = s:gsub("^[^ \t\r\n]*", "")
				end
				for w in s:gmatch("[^ \t\r\n]+") do
					if w:sub(1, 1) == "#" then
						break
					end
					out[#out + 1] = w
				end
			end
		end
	end
	return out
end
-- bash's hostname list (bashline.c get_hostname_list): read once and kept in sh.hosts
-- ({ list, init, alloc }). Assigning HOSTFILE only marks it stale (sv_hostfile), so the
-- next read APPENDS the file's names; unsetting it clears an initialized list. The list
-- counts as initialized once it was ever non-empty (hostname_list allocated). The file:
-- $HOSTFILE, else $hostname_completion_file, else /etc/hosts. (A new list table per
-- change: a subshell's checkpoint shares the old one.)
local function host_list(sh)
	local h = sh.hosts
	if h and h.init then
		return h.list
	end
	local path = sh.vars[sh:deref("HOSTFILE")] and sh:get("HOSTFILE")
	if not path then
		path = sh.vars[sh:deref("hostname_completion_file")] and sh:get("hostname_completion_file") or "/etc/hosts"
	end
	local list = {}
	for i, x in ipairs(h and h.list or {}) do
		list[i] = x
	end
	snarf_hosts(path, list)
	local alloc = (h and h.alloc) or #list > 0
	sh.hosts = { list = list, init = alloc, alloc = alloc }
	return list
end
local function signal_list()
	local o = { "EXIT" }
	for n = 1, 64 do
		o[#o + 1] = NUMSIG[n] and ("SIG" .. NUMSIG[n]) or ("SIGJUNK(" .. n .. ")")
	end
	o[#o + 1] = "DEBUG"
	o[#o + 1] = "ERR"
	o[#o + 1] = "RETURN"
	return o
end

-- the item lists (pcomplete.c's it_init_*), each in bash's order
local ITEMS = {
	alias = function(sh)
		return sorted_keys(sh.aliases)
	end,
	arrayvar = function(sh)
		return var_list(sh, function(b)
			return b == DYN_ARR or (b and b.arr ~= nil)
		end)
	end,
	binding = function()
		local o = {}
		for k, n in ipairs(FUNMAP) do
			o[k] = n
		end
		table.sort(o, rt.coll_lt) -- (rl_funmap_names: qsort by strcoll)
		return o
	end,
	builtin = function(sh)
		return builtin_list(sh, nil)
	end,
	disabled = function(sh)
		return builtin_list(sh, false)
	end,
	enabled = function(sh)
		return builtin_list(sh, true)
	end,
	export = function(sh)
		return var_list(sh, function(b, n)
			if b == DYN_ARR then
				return false
			elseif b then
				return b.exported
			end
			return (n == "PWD" or n == "OLDPWD") and os.getenv(n) ~= nil
		end)
	end,
	["function"] = function(sh)
		return sorted_keys(sh.functions)
	end,
	helptopic = function()
		local o = {}
		for _, t in ipairs(require("helpdata")) do
			o[#o + 1] = t[1]
		end
		return o
	end,
	hostname = function(sh)
		return host_list(sh)
	end,
	job = function(sh)
		return job_list(sh, nil)
	end,
	keyword = function()
		return KW_ORDER
	end,
	running = function(sh)
		return job_list(sh, "run")
	end,
	setopt = function()
		local o = {}
		for _, e in ipairs(SETOPTS) do
			o[#o + 1] = e[1]
		end
		return o
	end,
	shopt = function()
		return SHOPT_ORDER
	end,
	signal = signal_list,
	stopped = function(sh)
		return job_list(sh, "stop")
	end,
	variable = function(sh)
		return var_list(sh, function()
			return true
		end)
	end,
}

-- a directory's entries in readdir order, dotfiles included (rl_filename_completion_function)
local function readdir_all(path)
	local out = {}
	local d = ffi.C.opendir(path)
	if d == nil then
		return out
	end
	while true do
		local e = ffi.C.readdir(d)
		if e == nil then
			break
		end
		out[#out + 1] = ffi.string(ffi.cast("const char *", e) + 19)
	end
	ffi.C.closedir(d)
	return out
end

-- rl_filename_completion_function over TEXT: the entries of TEXT's directory part
-- starting with its last component (with no component, all but `.`/`..`), each
-- prefixed by the directory as typed.
local function filename_matches(sh, text)
	local slash = text:match("^.*()/")
	local dirname, filename
	if slash then
		dirname, filename = text:sub(1, slash), text:sub(slash + 1)
	else
		dirname, filename = ".", text
	end
	local users = dirname
	if dirname:sub(1, 1) == "~" then
		dirname = rt.tilde_prefix(sh, dirname)
	end
	local out, fl = {}, #filename
	local pre = (dirname ~= ".") and (users:sub(-1) == "/" and users or users .. "/") or ""
	for _, e in ipairs(readdir_all(dirname)) do
		if fl == 0 then
			if e ~= "." and e ~= ".." then
				out[#out + 1] = pre .. e
			end
		elseif e:sub(1, fl) == filename then
			out[#out + 1] = pre .. e
		end
	end
	return out
end
local function expand_tilde(sh, p)
	return p:sub(1, 1) == "~" and rt.tilde_prefix(sh, p) or p
end
local function is_dir(sh, p)
	return file_test("-d", expand_tilde(sh, p))
end
local function exec_file(p)
	return file_test("-f", p) and file_test("-x", p)
end
-- bash_directory_completion_matches: the filename matches that are directories
local function directory_matches(sh, text)
	local out = {}
	for _, m in ipairs(filename_matches(sh, text)) do
		if is_dir(sh, m) then
			out[#out + 1] = m
		end
	end
	return out
end
-- command_word_completion_function: aliases, keywords, functions, enabled builtins, a
-- directory named by TEXT itself, then $PATH's executables (not directories) in each
-- directory's readdir order. A glob TEXT globs; one with a `/` completes as a path.
local function command_matches(sh, text)
	local out = {}
	local function add(x)
		out[#out + 1] = x
	end
	if text:find("[*?]") or text:find("%[.*%]") then
		local m = rt.glob_expand(expand_tilde(sh, text), { nocase = false }) or {}
		for _, x in ipairs(m) do
			if file_test("-d", x) or exec_file(x) then
				add(x)
			end
		end
		return out
	end
	if text:find("/", 1, true) then
		for _, x in ipairs(filename_matches(sh, text)) do
			local f = expand_tilde(sh, x)
			if file_test("-d", f) or exec_file(f) then
				add(x)
			end
		end
		return out
	end
	local tl = #text
	local function pm(n)
		return n:sub(1, tl) == text
	end
	for _, n in ipairs(sorted_keys(sh.aliases)) do
		if pm(n) then
			add(n)
		end
	end
	for _, n in ipairs(KW_ORDER) do
		if pm(n) then
			add(n)
		end
	end
	for _, n in ipairs(sorted_keys(sh.functions)) do
		if pm(n) then
			add(n)
		end
	end
	for _, n in ipairs(builtin_list(sh, true)) do
		if pm(n) then
			add(n)
		end
	end
	-- CMD_IS_DIR: a relative name (not ./, ../, ~) that is a directory here
	local c1 = text:sub(1, 1)
	if text ~= "" and c1 ~= "~" and not (text == "." or text == "..") and file_test("-d", text) then
		add(text)
	end
	local path = sh.vars.PATH and sh:get("PATH") or nil
	if path and path ~= "" then
		for dir in (path .. ":"):gmatch("([^:]*):") do
			local d = dir == "" and "." or expand_tilde(sh, dir)
			local pre = d:sub(-1) == "/" and d or d .. "/"
			for _, name in ipairs(readdir_all(d)) do
				if name ~= "." and name ~= ".." and pm(name) and exec_file(pre .. name) then
					add(name)
				end
			end
		end
	end
	return out
end
-- rl_username_completion_function: passwd order; a `~` prefix is kept on the results
local function user_matches(text)
	local first = text:sub(1, 1) == "~" and "~" or ""
	local u = text:sub(#first + 1)
	local out = {}
	for _, n in ipairs(rt.pw_names()) do
		if n:sub(1, #u) == u then
			out[#out + 1] = first .. n
		end
	end
	return out
end
-- bash_groupname_completion_function (getgrent order: the group file's)
local function group_matches(text)
	local out = {}
	for _, l in ipairs(file_lines("/etc/group")) do
		local n = l:match("^([^:#][^:]*):")
		if n and n:sub(1, #text) == text then
			out[#out + 1] = n
		end
	end
	return out
end
-- bash_servicename_completion_function (getservent order): the service's name, or the
-- first of its aliases that matches
local function service_matches(text)
	local out, tl = {}, #text
	for _, l in ipairs(file_lines("/etc/services")) do
		l = l:gsub("#.*", "")
		local name, rest = l:match("^([^ \t]+)[ \t]+[^ \t]+(.*)$")
		if name then
			if tl == 0 or name:sub(1, tl) == text then
				out[#out + 1] = name
			else
				for a in rest:gmatch("[^ \t]+") do
					if a:sub(1, tl) == text then
						out[#out + 1] = a
						break
					end
				end
			end
		end
	end
	return out
end

-- gen_action_completions: the item lists in their fixed order (prefix-matched against
-- the dequoted word), then commands, files, users, groups, services, directories.
local function gen_actions(sh, acts, text, ret)
	ret = ret or {}
	local ntxt = dequote_text(text)
	local tl = #ntxt
	for _, act in ipairs(ITEM_ORDER) do
		if acts[act] then
			for _, n in ipairs(ITEMS[act](sh)) do
				if tl == 0 or n:sub(1, tl) == ntxt then
					ret[#ret + 1] = n
				end
			end
		end
	end
	local function append(l)
		for _, x in ipairs(l) do
			ret[#ret + 1] = x
		end
	end
	if acts.command then
		append(command_matches(sh, text))
	end
	if acts.file then
		append(filename_matches(sh, text))
	end
	if acts.user then
		append(user_matches(text))
	end
	if acts.group then
		append(group_matches(text))
	end
	if acts.service then
		append(service_matches(text))
	end
	if acts.directory then
		append(directory_matches(sh, text))
	end
	return ret
end

-- skip_to_delim's quoting, for splitting -W's list: past a quoted string / `…` from i
local function skip_quote(s, i)
	local q, n = s:sub(i, i), #s
	i = i + 1
	while i <= n do
		local c = s:sub(i, i)
		if c == q then
			return i + 1
		elseif c == "\\" and q ~= "'" then
			i = i + 2
		else
			i = i + 1
		end
	end
	return i
end
-- past a balanced $( … ) / ${ … } whose opener is at i
local function skip_balanced(s, i, open, close)
	local depth, n = 0, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif c == "'" or c == '"' or c == "`" then
			i = skip_quote(s, i)
		elseif c == open then
			depth = depth + 1
			i = i + 1
		elseif c == close then
			depth = depth - 1
			i = i + 1
			if depth == 0 then
				return i
			end
		else
			i = i + 1
		end
	end
	return i
end
-- split_at_delims(words, IFS): the list cut at unquoted IFS chars (quotes, escapes and
-- expansions kept whole and intact, for the expansion that follows)
local function split_wordlist(s, isd)
	local out, n, i = {}, #s, 1
	while i <= n and isd[s:sub(i, i)] and s:sub(i, i):find("^[ \t\n]") do
		i = i + 1
	end
	if i > n then
		return out
	end
	local ts = i
	while true do
		local te = ts
		while te <= n do
			local c = s:sub(te, te)
			if c == "\\" then
				te = te + 2
			elseif c == "'" or c == '"' or c == "`" then
				te = skip_quote(s, te)
			elseif c == "$" and s:sub(te + 1, te + 1) == "(" then
				te = skip_balanced(s, te + 1, "(", ")")
			elseif c == "$" and s:sub(te + 1, te + 1) == "{" then
				te = skip_balanced(s, te + 1, "{", "}")
			elseif isd[c] then
				break
			else
				te = te + 1
			end
		end
		out[#out + 1] = s:sub(ts, te - 1)
		if te > n then
			break
		end
		i = te
		while i <= n and isd[s:sub(i, i)] do
			i = i + 1
		end
		if i > n then
			break
		end
		ts = i
	end
	return out
end

-- gen_wordlist_matches: split at IFS, then each word gets the shell expansions but
-- pathname expansion (brace, tilde, parameter, command, arithmetic, word splitting,
-- quote removal); the results that start with the dequoted word. An expansion error is
-- an ordinary one (fatal / the line abandoned), not contained by compgen.
local function gen_wordlist(sh, words, text, ret)
	if words == "" then
		return
	end
	local ifs = rt.ifs(sh) or " \t\n"
	local isd = {}
	for k = 1, #ifs do
		isd[ifs:sub(k, k)] = true
	end
	local fields = {}
	local nf = sh.opt_f
	sh.opt_f = true -- (expand_words_shellexp: no pathname expansion)
	local ok, err = pcall(function()
		for _, piece in ipairs(split_wordlist(words, isd)) do
			if piece ~= "" then
				local ws = {}
				local pok = pcall(function()
					if sh.opt_B == false then
						ws[1] = P.parse_word(piece)
					else
						P.add_word(ws, piece)
					end
				end)
				if not pok then -- (an unterminated `${`: the word is a bad substitution, and
					-- like any expansion error here it discards the rest of the line)
					io.stderr:write("curse: " .. piece .. ": bad substitution\n")
					error({ __curse_exit = 1, __curse_experr = true, __curse_lineabort = true })
				end
				for _, w in ipairs(ws) do
					for _, f in ipairs(IM.expand_to_fields(sh, w)) do
						fields[#fields + 1] = f
					end
				end
			end
		end
	end)
	sh.opt_f = nf
	if not ok then
		error(err, 0)
	end
	local ntxt = dequote_text(text)
	local tl = #ntxt
	for _, f in ipairs(fields) do
		if tl == 0 or f:sub(1, tl) == ntxt then
			ret[#ret + 1] = f
		end
	end
end

-- the COMP_* variables around a -F function / -C command (bind/unbind_compfunc_variables)
local COMPVARS = { "COMP_LINE", "COMP_POINT", "COMP_TYPE", "COMP_KEY", "COMP_WORDS", "COMP_CWORD" }
-- unbind_variable_noref: the variable itself goes, silently — a nameref is not followed
-- and readonly doesn't protect it
local function unbind(sh, names)
	local a = { "unset", "-v" }
	for _, n in ipairs(names) do
		local b = sh.vars[n]
		if b then
			b.ro, b.ref, b.outer = nil, nil, nil
		end
		a[#a + 1] = n
	end
	local st = sh.status
	require("b_unset")(sh, "unset", a)
	sh.status = st
end
-- bind_variable / bind_int_variable: through a nameref; a readonly one is reported and
-- keeps its value
local function bindv(sh, name, v, export)
	local dn = sh:deref(name)
	if dn == "" then
		dn = name
	end
	local b = sh.vars[dn]
	if b and b.ro then
		io.stderr:write("curse: " .. dn .. ": readonly variable\n")
	elseif export then
		sh:export_str(dn, v) -- (the variable bound gets the export attribute)
	else
		sh:set_str(dn, v)
	end
end
-- bind_comp_words: COMP_WORDS itself (never through a nameref — the attribute is
-- stripped), made an array; the (empty) word list is assigned over what it holds
local function bind_comp_words(sh)
	local b = sh.vars.COMP_WORDS
	if b and b.ref then
		b.ref, b.outer = nil, nil
	end
	if not (b and b.arr) then
		local v = b and (b.s ~= nil or b.n ~= nil) and sh:get("COMP_WORDS")
		sh:array_assign("COMP_WORDS", v and { v } or {}, false)
	end
end

-- gen_shell_function_matches: run FUNC compgen WORD '' with the COMP_* variables set;
-- its COMPREPLY (not prefix-filtered) is the result. Returns the list and the "found"
-- state: false when the function returned 127, "retry" on 124 (PCOMP_RETRYFAIL).
local function gen_function(sh, fname, text, hook)
	if not sh.functions[fname] then
		io.stderr:write("curse: completion: function `" .. fname .. "' not found\n")
		return nil, nil
	end
	bindv(sh, "COMP_LINE", "")
	bindv(sh, "COMP_POINT", "0")
	bindv(sh, "COMP_TYPE", "0")
	bindv(sh, "COMP_KEY", "0")
	bind_comp_words(sh)
	bindv(sh, "COMP_CWORD", "-1")
	local ok, err = pcall(exec_simple, sh, { fname, "compgen", text, "" }, hook)
	unbind(sh, COMPVARS)
	if not ok then
		error(err, 0) -- (exit/return/errors propagate; a fatal one leaves COMPREPLY set)
	end
	local fval = sh.status
	local found = fval ~= 127 and (fval == 124 and "retry" or true) -- (127: no COMPREPLY taken)
	local sl
	local b = sh.vars[sh:deref("COMPREPLY")]
	if found == true and b and not b.assoc then
		sl = sh:array_values("COMPREPLY")
		if #sl == 0 then
			sl = nil
		end
	end
	unbind(sh, { "COMPREPLY" })
	return sl, found
end

-- gen_command_matches: `CMD 'compgen' 'WORD' ''` run as a command substitution with the
-- COMP_* variables exported; its output split at newlines (a backslash-newline stays in
-- the word, runs of newlines are one break).
local function gen_command(sh, cmd, text)
	bindv(sh, "COMP_LINE", "", true)
	bindv(sh, "COMP_POINT", "0", true)
	bindv(sh, "COMP_TYPE", "0", true)
	bindv(sh, "COMP_KEY", "0", true)
	local ok, res = pcall(sh.capture_src, sh, cmd .. " " .. sq1("compgen") .. " " .. sq1(text) .. " " .. sq1(""))
	unbind(sh, COMPVARS)
	if not ok then
		error(res, 0)
	end
	res = (res or ""):gsub("\n+$", "")
	if res == "" then
		return nil
	end
	local out, ws, n = {}, 1, #res
	while ws <= n do
		local we = ws
		while we <= n and res:sub(we, we) ~= "\n" do
			if res:sub(we, we) == "\\" and res:sub(we + 1, we + 1) == "\n" then
				we = we + 1
			end
			we = we + 1
		end
		out[#out + 1] = res:sub(ws, we - 1)
		while res:sub(we, we) == "\n" do
			we = we + 1
		end
		ws = we
	end
	return out
end

-- quote_globbing_chars: TEXT as a literal inside a pattern
local function glob_quote(s)
	return (s:gsub("[*?%[%]\\+@!()|]", "\\%0"))
end
-- filter_stringlist: drop the matches of PAT (a leading `!` keeps only them; with extglob
-- `!(` is a pattern). An unescaped `&` stands for the word being completed.
local function filter(sh, list, pat, text)
	local p, i, n = {}, 1, #pat
	local exp = false
	do
		local k = 1
		while k <= n do
			local c = pat:sub(k, k)
			if c == "\\" then
				k = k + 2
			elseif c == "&" then
				exp = true
				break
			else
				k = k + 1
			end
		end
	end
	if exp then
		local qt = (text:find("[*?%[\\]") or (text:find("[+@!]%(") and sh.shopt.extglob)) and glob_quote(text) or text
		while i <= n do
			local c = pat:sub(i, i)
			if c == "&" then
				p[#p + 1] = qt
				i = i + 1
			elseif c == "\\" and pat:sub(i + 1, i + 1) == "&" then
				p[#p + 1] = "&"
				i = i + 2
			else
				p[#p + 1] = c
				i = i + 1
			end
		end
		pat = table.concat(p)
	end
	local neg = pat:sub(1, 1) == "!" and not (sh.shopt.extglob and pat:sub(2, 2) == "(")
	local t = neg and pat:sub(2) or pat
	if not sh.shopt.extglob then -- (strmatch without FNM_EXTMATCH: `@(` is literal text)
		t = t:gsub("([?*+@!])%(", "%1\\(")
	end
	local icase = sh.shopt.nocasematch and true or false
	local kept = {}
	for _, x in ipairs(list) do
		local m = rt.glob_match(x, t, icase)
		if neg == m then -- (a match is removed; with `!`, a non-match is)
			kept[#kept + 1] = x
		end
	end
	return kept
end

-- glob.c's glob_pattern_p: an unquoted `*`/`?`, a `[` closed by a `]`, or an extglob
-- operator; a backslash quotes the next char (a backslash-only pattern is not a glob)
local function glob_pat_p(s)
	local bopen, i, n = false, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "*" or c == "?" then
			return true
		elseif c == "[" then
			bopen = true
		elseif c == "]" then
			if bopen then
				return true
			end
		elseif c == "+" or c == "@" or c == "!" then
			if s:sub(i + 1, i + 1) == "(" then
				return true
			end
		elseif c == "\\" then
			if i == n then
				return false
			end
			i = i + 1
		end
		i = i + 1
	end
	return false
end
local function dequote_path(s) -- dequote_pathname
	return (s:gsub("\\(.?)", "%1"))
end
-- glob_vector: DIR's entries matching PAT, in bash's order — each match is pushed on
-- the front of a list, so the reverse of readdir's. Not sorted, no GLOBIGNORE; a dot
-- name needs a leading `.` in PAT unless dotglob was on at the last SHELL glob (bash's
-- noglob_dot_filenames, only synced by shell_glob_filename: sh.glob_dots). nil: DIR
-- isn't a directory.
local function glob_vector(sh, pat, dir)
	if not file_test("-d", dir) then
		return nil
	end
	if pat == "" then
		return { "" }
	end
	if not glob_pat_p(pat) then -- (just see whether DIR/PAT exists)
		local np = dequote_path(pat)
		local f = dir .. "/" .. np
		return (file_test("-e", f) or file_test("-L", f)) and { np } or {}
	end
	local skipdd, dots = sh.shopt.globskipdots ~= false, sh.glob_dots
	local lead = pat:sub(1, 1) == "." or pat:sub(1, 2) == "\\."
	local icase, noext = sh.shopt.nocaseglob and true or false, not sh.shopt.extglob
	local names, out = readdir_all(dir), {}
	for k = #names, 1, -1 do
		local e = names[k]
		local dd = e == "." or e == ".."
		if not ((dd and (skipdd or (dots and not lead))) or (not dots and not lead and e:sub(1, 1) == "."))
			and rt.glob_match(e, pat, icase, noext) then
			out[#out + 1] = e
		end
	end
	return out
end
-- glob_vector under GX_ALLDIRS (globstar's `**` as the last component): every entry of
-- DIR (no pattern test; dot names as above), a directory's own tree (finddirs) ahead of
-- it, all as paths under DIR — built by prepending like glob_vector, so collected here
-- in reverse. ADDCUR: DIR itself first.
local function glob_alldirs(sh, dir, nulldir, addcur)
	local acc = {}
	local names = readdir_all(dir)
	local skipdd, dots = sh.shopt.globskipdots ~= false, sh.glob_dots
	local base = dir
	if nulldir and (base == "." or base == "./") then -- (sh_makepath's MP_IGNDOT / MP_RMDOT)
		base = ""
	elseif base:sub(1, 2) == "./" then
		base = base:sub(3)
	end
	if base ~= "" and base:sub(-1) ~= "/" then
		base = base .. "/"
	end
	for _, e in ipairs(names) do
		local dd = e == "." or e == ".."
		if not ((dd and (skipdd or dots)) or (not dots and e:sub(1, 1) == ".")) then
			local sub = base .. e
			if file_test("-d", sub) and not file_test("-L", sub) then
				-- (finddirs chains the subtree's vector ahead of the rest, reversed)
				for _, x in ipairs(glob_alldirs(sh, sub, nulldir, false)) do
					acc[#acc + 1] = x
				end
			end
			acc[#acc + 1] = sub
		end
	end
	if addcur then
		acc[#acc + 1] = nulldir and "" or dir
	end
	local out = {}
	for k = #acc, 1, -1 do
		out[#out + 1] = acc[k]
	end
	return out
end
-- glob_filename: a glob in the directory part globs that first (recursively), then
-- each directory's glob_vector, joined in order
local function glob_filename(sh, path)
	local slash = path:match("^.*()/")
	local dname, fname = "", path
	if slash then
		dname, fname = path:sub(1, slash), path:sub(slash + 1)
	end
	if dname ~= "" and glob_pat_p(dname) then
		local dirs = glob_filename(sh, dname:sub(1, -2))
		if not dirs or #dirs == 0 then
			return nil
		end
		local out = {}
		local star2 = fname == "**" and sh.shopt.globstar
		for _, d in ipairs(dirs) do
			if star2 then
				if file_test("-d", d == "" and "." or d) then
					for _, x in ipairs(glob_alldirs(sh, d == "" and "." or d, d == "", true)) do
						out[#out + 1] = x
					end
				end
				goto continue
			end
			local r = glob_vector(sh, fname, (d == "" and fname ~= "") and "." or d)
			if r then
				local pre = (d == "" or d:sub(-1) == "/") and d or d .. "/"
				for _, x in ipairs(r) do
					out[#out + 1] = pre .. x
				end
			end
			::continue::
		end
		return out
	end
	if fname == "" then -- (only a directory name: returned as is)
		return { dname }
	end
	dname = dequote_path(dname)
	if fname == "**" and sh.shopt.globstar then
		local dir = dname == "" and "." or dname
		return file_test("-d", dir) and glob_alldirs(sh, dir, dname == "", dname ~= "") or nil
	end
	local r = glob_vector(sh, fname, dname == "" and "." or dname)
	if r and dname ~= "" then
		for k, x in ipairs(r) do
			r[k] = dname .. x
		end
	end
	return r
end

-- gen_compspec_completions: actions, -G, -W, -F, -C, then -X, -P/-S, and the
-- dirnames/plusdirs fallbacks. nil when a -F function asked for none (127/124).
local function gen_compspec(sh, cs, word, hook)
	local ret = gen_actions(sh, cs.acts, word)
	if cs.G then -- (glob_filename: just the pattern — the word isn't used)
		for _, x in ipairs(glob_filename(sh, cs.G) or {}) do
			ret[#ret + 1] = x
		end
	end
	if cs.W then
		gen_wordlist(sh, cs.W, word, ret)
	end
	local found = true
	if cs.F then
		local sl, f = gen_function(sh, cs.F, word, hook)
		if f then -- (a 127 "not found" leaves the other generators' matches alone)
			found = f
		end
		for _, x in ipairs(sl or {}) do
			ret[#ret + 1] = x
		end
	end
	if cs.C then
		for _, x in ipairs(gen_command(sh, cs.C, word) or {}) do
			ret[#ret + 1] = x
		end
	end
	if found ~= true then
		return nil
	end
	if cs.X and #ret > 0 then
		ret = filter(sh, ret, cs.X, word)
	end
	if cs.P or cs.S then
		local p, s = cs.P or "", cs.S or ""
		for k, x in ipairs(ret) do
			ret[k] = p .. x .. s
		end
	end
	if #ret == 0 and cs.opts.dirnames then
		ret = directory_matches(sh, word)
	elseif cs.opts.plusdirs then
		gen_actions(sh, { directory = true }, word, ret)
	end
	return ret
end

-- command_subst_completion_function: past the `$(`, the text after the last blank or
-- command separator completes as a command name (as a filename after a blank), with
-- everything before it kept as the prefix
local function cmdsub_matches(sh, text)
	local ft = text:sub(3)
	local k = #ft
	while k > 1 and not ft:sub(k, k):find("^[ \t;|&{(`]") do
		k = k - 1
	end
	local m, pre
	if k <= 1 then
		pre, m = "$(", command_matches(sh, ft)
	else
		pre = text:sub(1, 2 + k)
		local w = ft:sub(k + 1)
		m = ft:sub(k, k):find("^[ \t]") and filename_matches(sh, w) or command_matches(sh, w)
	end
	for i, x in ipairs(m) do
		m[i] = pre .. x
	end
	return m
end
-- bash_default_completion (compgen -o bashdefault, outside a command position): $var /
-- ${var names, ~user, @host
local function bash_default(sh, text)
	local c1 = text:sub(1, 1)
	if c1 == "$" and text:sub(2, 2) == "(" then -- (command_subst_completion_function)
		local out = cmdsub_matches(sh, text)
		if #out > 0 then
			return out
		end
	elseif c1 == "$" then
		local loc = text:sub(2, 2) == "{" and 2 or 1
		local vn = text:sub(loc + 1)
		local out = {}
		for _, n in ipairs(ITEMS.variable(sh)) do
			if n:sub(1, #vn) == vn then
				out[#out + 1] = text:sub(1, loc) .. n .. (loc == 2 and "}" or "")
			end
		end
		if #out > 0 then
			return out
		end
	end
	if c1 == "~" and not text:find("/", 1, true) then
		local m = user_matches(text)
		if #m > 0 then
			return m
		end
	end
	if c1 == "@" and sh.shopt.hostcomplete ~= false then
		local out = {}
		for _, h in ipairs(host_list(sh)) do
			if h:sub(1, #text - 1) == text:sub(2) then
				out[#out + 1] = "@" .. h
			end
		end
		return out
	end
	return {}
end

-- build_actions: internal_getopt over "abcdefgjko:prsuvA:G:W:P:S:X:F:C:DEI". Returns the
-- spec, the index of the first operand, and whether any option was given; nil when it
-- already reported an error (status set).
local function build_actions(sh, cmd, args, forcomplete)
	local cs = { acts = {}, opts = {} }
	local given = false
	local k = 2
	while true do
		local a = args[k]
		if a == nil or a:sub(1, 1) ~= "-" or a == "-" then
			break
		end
		k = k + 1
		if a == "--" then
			break
		end
		if a == "--help" then
			rt.builtin_help(sh, cmd)
			return nil
		end
		local i = 2
		while i <= #a do
			local f = a:sub(i, i)
			i = i + 1
			given = true
			if ACT_LETTER[f] then
				cs.acts[ACT_LETTER[f]] = true
			elseif f == "p" or f == "r" or f == "D" or f == "E" or f == "I" then
				if not forcomplete then
					return rt.bad_option(sh, cmd, "-" .. f)
				end
				cs[f] = true
			elseif ARGOPT[f] then
				local v = a:sub(i)
				i = #a + 1
				if v == "" then
					v = args[k]
					k = k + 1
				end
				if v == nil then
					io.stderr:write("curse: " .. cmd .. ": -" .. f .. ": option requires an argument\n" .. rt.usage(cmd))
					sh.status = 2
					return nil
				end
				if f == "o" then
					if not COPT_OK[v] then
						io.stderr:write("curse: " .. cmd .. ": " .. v .. ": invalid option name\n")
						sh.status = 2
						return nil
					end
					cs.opts[v] = true
				elseif f == "A" then
					if not ACTIONS[v] then
						io.stderr:write("curse: " .. cmd .. ": " .. v .. ": invalid action name\n")
						sh.status = 2
						return nil
					end
					cs.acts[v] = true
				elseif f == "F" then
					-- (check_identifier — a name, in posix mode — and no shell_break_chars)
					local bad = sh.opt_posix and not v:find("^[%a_][%w_]*$")
					if bad or v:find("[()<>;&| \t\n]") then
						if bad then
							io.stderr:write("curse: `" .. v .. "': not a valid identifier\n")
						end
						io.stderr:write("curse: " .. cmd .. ": `" .. v .. "': not a valid identifier\n")
						sh.status = 2
						return nil
					end
					cs.F = v
				else
					cs[f] = v
				end
			else
				return rt.bad_option(sh, cmd, "-" .. f)
			end
		end
	end
	return cs, k, given
end

-- compgen [option] [word]: evaluate a compspec built from the options for WORD and
-- print the matches, one per line, in generation order (neither sorted nor de-duplicated).
local function compgen(sh, args, hook)
	if args[2] == nil then
		sh.status = 0
		return
	end
	local cs, k, given = build_actions(sh, "compgen", args, false)
	if not cs then
		return
	end
	if not given then
		sh.status = 0
		return
	end
	local word = args[k] or ""
	if cs.F then
		io.stderr:write("curse: compgen: warning: -F option may not work as you expect\n")
	end
	if cs.C then
		io.stderr:write("curse: compgen: warning: -C option may not work as you expect\n")
	end
	local sl = gen_compspec(sh, cs, word, hook)
	if (not sl or #sl == 0) and cs.opts.bashdefault then
		sl = bash_default(sh, word)
	end
	if (not sl or #sl == 0) and cs.opts.default then
		sl = filename_matches(sh, word)
	end
	if sl and #sl > 0 then
		local buf = {}
		for i, x in ipairs(sl) do
			buf[i] = x
		end
		buf[#buf + 1] = ""
		sh.out(table.concat(buf, "\n"))
		sh.status = 0
	else
		sh.status = 1
	end
end

-- print_one_completion
local function spec_line(name, cs)
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
		o[#o + 1] = "-F " .. sq(cs.F)
	end
	o[#o + 1] = SPECIAL_FLAG[name] or sq(name) -- (print_cmd_name)
	return table.concat(o, " ")
end

-- complete [-abcdefgjksuv] [-pr] [-DEI] [-o opt] [-A action] [-G/-W/-F/-C/-X/-P/-S arg]
-- [name …]: register, print (-p / no args) or remove (-r) completion specs. Specs are
-- listed in bash's hash-table order (512 FNV-1 buckets, newest first per bucket).
local function complete(sh, args)
	sh.complete = sh.complete or {}
	local tab = sh.complete
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
		local buf = {}
		for _, e in ipairs(ns) do
			buf[#buf + 1] = spec_line(e.n, tab[e.n]) .. "\n"
		end
		sh.out(table.concat(buf))
	end
	if args[2] == nil then
		listing()
		sh.status = 0
		return
	end
	local spec, k, given = build_actions(sh, "complete", args, true)
	if not spec then
		return
	end
	local names = {}
	for j = k, #args do
		names[#names + 1] = args[j]
	end
	local special = spec.D and SPECIAL_NAME.D or spec.E and SPECIAL_NAME.E or spec.I and SPECIAL_NAME.I
	local wl = special and { special } or nil
	local st = 0
	if spec.p or (#names == 0 and not given) then
		if not wl and #names == 0 then
			listing()
		else
			for _, n in ipairs(wl or names) do
				if tab[n] then
					sh.out(spec_line(n, tab[n]) .. "\n")
				else
					io.stderr:write("curse: complete: " .. n .. ": no completion specification\n")
					st = 1
				end
			end
		end
	elseif spec.r then
		if not wl and #names == 0 then
			sh.complete = {}
		end
		for _, n in ipairs(wl or names) do
			if tab[n] then
				tab[n] = nil
			else
				io.stderr:write("curse: complete: " .. n .. ": no completion specification\n")
				st = 1
			end
		end
	elseif not wl and #names == 0 then
		io.stderr:write(rt.usage("complete"))
		st = 2
	else
		-- (one compspec for all the names — bash's shared COMPSPEC: each name's entry
		-- holds the one opts table, which compopt changes in place)
		for _, n in ipairs(wl or names) do
			local old = tab[n]
			rt.complete_seq = (rt.complete_seq or 0) + 1
			local cs = { opts = spec.opts, acts = spec.acts, seq = old and old.seq or rt.complete_seq }
			for _, f in ipairs({ "G", "W", "P", "S", "X", "C", "F" }) do
				cs[f] = spec[f]
			end
			tab[n] = cs
		end
	end
	sh.status = st
end

-- compopt [-o|+o OPT] [-DEI] [NAME …]: change (or, with no -o/+o, print) a spec's
-- options. Outside a completion function (curse never runs one) it needs a NAME or
-- -D/-E/-I with a spec (bash's compopt.def).
local function compopt(sh, args)
	local on, off, flag = {}, {}, {}
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
				if not COPT_OK[v] then
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
			elseif f == "D" or f == "E" or f == "I" then
				flag[f] = true
			else
				return rt.bad_option(sh, "compopt", a:sub(1, 1) .. f)
			end
		end
	end
	local special = flag.D and SPECIAL_NAME.D or flag.E and SPECIAL_NAME.E or flag.I and SPECIAL_NAME.I
	local names = special and { special } or {}
	if not special then
		for j = k, #args do
			names[#names + 1] = args[j]
		end
	end
	if #names == 0 then
		io.stderr:write("curse: compopt: not currently executing completion function\n")
		sh.status = 1
		return
	end
	local st = 0
	local tab = sh.complete or {}
	for _, n in ipairs(names) do
		local cs = tab[n]
		if not cs then
			io.stderr:write("curse: compopt: " .. n .. ": no completion specification\n")
			st = 1
		elseif #on == 0 and #off == 0 then -- (print_compopts, the full form)
			local o = { "compopt" }
			for _, c in ipairs(COPTS) do
				o[#o + 1] = (cs.opts[c] and "-o " or "+o ") .. c
			end
			o[#o + 1] = SPECIAL_FLAG[n] or sq(n)
			sh.out(table.concat(o, " ") .. "\n")
		else
			-- (in place: the names one `complete` registered share one compspec, and
			-- its options with it)
			local opts = cs.opts
			for _, o in ipairs(on) do
				opts[o] = true
			end
			for _, o in ipairs(off) do
				opts[o] = nil
			end
		end
	end
	sh.status = st
end

return function(sh, cmd, args, hook)
	if cmd == "compgen" then
		return compgen(sh, args, hook)
	elseif cmd == "complete" then
		return complete(sh, args)
	elseif cmd == "compopt" then
		return compopt(sh, args)
	end
end
