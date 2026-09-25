-- Localized diagnostics: bash's own messages under a message locale that has a bash
-- catalog (/usr/share/locale/<lang>/LC_MESSAGES/bash.mo — GNU gettext's _() in bash's
-- sources). Loaded only when the LC_MESSAGES locale in force isn't C/POSIX.
--
-- Diagnostics are written in English as "curse: msg" and pass through ONE place, the
-- stderr proxy in runtime.lua, which calls M.diag: the message is matched against the
-- catalog's msgids — each printf-style msgid (%s %d %c %lu …) compiled once into an
-- anchored Lua pattern — its arguments extracted and substituted into the msgstr
-- (positional %2$s respected), and the prefix built as bash's prologs build it:
--   error_prolog (error.c)            NAME:<_(" line ")>N:            (report/internal errors)
--   builtin_error_prolog (common.c)   NAME: <_("line %d: ")>BUILTIN:  (builtin_error)
--   notify_of_job_status (jobs.c)     <_("%s: line %d: ")>            (a killed job's note)
-- Messages written outside the proxy (type's descriptions, help texts, usage lines, job
-- states) translate at their site through rt.L / M.fmt. A trailing strerror / strsignal
-- text is libc's (domain "libc"), translated the same way glibc's strerror would.
-- As glibc's gettext does, the msgstr is converted to LC_CTYPE's codeset (//TRANSLIT).
local ffi = require("ffi")
local rt = require("runtime")
local gt = require("gettext")
local C = ffi.C
local M = {}

pcall(ffi.cdef, [[
typedef void *iconv_t;
iconv_t iconv_open(const char *tocode, const char *fromcode);
size_t iconv(iconv_t cd, char **inbuf, size_t *inbytesleft, char **outbuf, size_t *outbytesleft);
]])
pcall(ffi.cdef, "char *nl_langinfo(int item);")
pcall(ffi.cdef, "const char *strerrordesc_np(int errnum);")

local LOCALEDIR = "/usr/share/locale" -- (bash's LOCALEDIR: its own messages, never $TEXTDOMAINDIR)

-- ---- the catalogs in force -------------------------------------------------------------
-- dcigettext: $LANGUAGE's list (bash's getenv: an EXPORTED shell variable) unless the
-- LC_MESSAGES locale is C, then that locale; each name as its glibc variants. A message
-- is looked up in each catalog found, in order, until one translates it.
local st_key, st_val = nil, nil
local convs = {} -- "to\0from" -> converter (iconv descriptors are kept for the process)

local function converter(from)
	local okc, cs = pcall(function()
		return ffi.string(C.nl_langinfo(14)) -- (CODESET)
	end)
	if not okc or cs == "" then
		return nil
	end
	local norm = function(x)
		return x:upper():gsub("[^%w]", "")
	end
	if norm(cs) == norm(from) then
		return nil
	end
	local key = cs .. "\0" .. from
	local f = convs[key]
	if f == nil then
		f = false
		local okd, cd = pcall(C.iconv_open, cs .. "//TRANSLIT", from)
		if okd and cd ~= ffi.cast("iconv_t", -1) then
			f = function(s)
				local n = #s
				local inb = ffi.new("char[?]", n + 1, s)
				local inp = ffi.new("char*[1]", inb)
				local inl = ffi.new("size_t[1]", n)
				local cap = n * 4 + 16
				local out = ffi.new("char[?]", cap)
				local outp = ffi.new("char*[1]", out)
				local outl = ffi.new("size_t[1]", cap)
				C.iconv(cd, nil, nil, nil, nil)
				if C.iconv(cd, inp, inl, outp, outl) == ffi.cast("size_t", -1) then
					return nil
				end
				return ffi.string(out, cap - outl[0])
			end
		end
		convs[key] = f
	end
	return f or nil
end

local function load(names, domain)
	local list = {}
	for _, nm in ipairs(names) do
		if nm == "C" then
			break
		end
		local map, c = gt.catalog(LOCALEDIR .. "/" .. nm .. "/LC_MESSAGES/" .. domain .. ".mo")
		if map then
			list[#list + 1] = c
		end
	end
	return list
end

local function state(sh)
	local lc = rt.lc_state[5]
	if lc == "C" or lc == "POSIX" then
		return nil
	end
	local lang
	local b = sh and sh.vars.LANGUAGE
	if b and b.exported then
		lang = sh:get("LANGUAGE")
	end
	local key = rt.locale_gen .. "\0" .. lc .. "\0" .. (lang or "")
	if key == st_key then
		return st_val
	end
	local names = {}
	if lang and lang ~= "" then
		for l in lang:gmatch("[^:]+") do
			gt.variants(l, names)
		end
	end
	gt.variants(lc, names)
	local bash = load(names, "bash")
	local val = false
	if #bash > 0 then
		val = { bash = bash, libc = load(names, "libc"), memo = {}, lmemo = {} }
		local hdr = bash[1].map[""] or ""
		val.conv = converter(hdr:match("charset=([%w%-_]+)") or "UTF-8")
	end
	st_key, st_val = key, val
	return val
end
function M.active(sh)
	return state(sh) and true or false
end

-- the translation of msgid in the catalogs `list` (converted), or nil
local function lookup(st, list, memo, id)
	local t = memo[id]
	if t == nil then
		t = false
		for _, c in ipairs(list) do
			local s = c.map[id]
			if s and s ~= "" then
				t = s
				if st.conv then
					t = st.conv(s) or false
				end
				break
			end
		end
		memo[id] = t
	end
	return t or nil
end
local function gettext(st, id)
	return lookup(st, st.bash, st.memo, id) or id
end

-- ---- printf-format msgids as patterns ------------------------------------------------
local pat_cache = setmetatable({}, { __mode = "k" }) -- first catalog -> compiled list

local function compile(id)
	local pat, lits, longest, alpha = { "^" }, 0, "", false
	local i, n = 1, #id
	local ncap, kinds, nc = 0, {}, 0
	while true do
		local p = id:find("%", i, true)
		local lit = id:sub(i, (p or n + 1) - 1)
		if lit ~= "" then
			pat[#pat + 1] = lit:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
			lits = lits + #lit
			if #lit > #longest then
				longest = lit
			end
			if lit:find("%a") then
				alpha = true
			end
		end
		if not p then
			break
		end
		local flags, conv = id:match("^%%([%-+ #0-9%.]*)[hlzjtL]*([%a%%])", p)
		if not conv then
			return nil
		end
		local len = #id:match("^%%[%-+ #0-9%.]*[hlzjtL]*[%a%%]", p)
		if conv == "%" then
			pat[#pat + 1] = "%%"
			lits = lits + 1
		elseif conv == "s" or conv == "p" then
			pat[#pat + 1] = "(.-)"
		elseif conv == "d" or conv == "i" or conv == "u" then
			pat[#pat + 1] = flags:find("%d") and "( *%-?%d+)" or "(%-?%d+)"
		elseif conv == "x" or conv == "o" or conv == "X" then
			pat[#pat + 1] = "(%w+)"
		elseif conv == "c" then
			pat[#pat + 1] = "(.)"
		else
			return nil
		end
		if conv ~= "%" then
			ncap = ncap + 1
			kinds[ncap] = conv
			if conv == "c" then
				nc = nc + 1
			end
		end
		i = p + len
	end
	if not alpha or id:find("\n", 1, true) then
		return nil
	end
	pat[#pat + 1] = "$"
	local e = { pat = table.concat(pat), lits = lits, key = longest, id = id, ncap = ncap, kinds = kinds, nc = nc,
		tailcap = id:find("%%[%-+ #0-9%.]*[hlzjtL]*[%a]$") ~= nil } -- (it ends with an argument)
	-- (evalerror's "%s%s%s: %s (…)": NAME, ": " or both empty, the expression, then the
	-- message — adjacent %s and an expression's own `: ' can't split by pattern alone)
	if e.pat:sub(1, 15) == "^(.-)(.-)(.-): " then
		e.evalerror = true
		e.pat = "^(.*): " .. e.pat:sub(16)
	end
	return e
end

-- bash 5.2 msgids an older catalog may lack whose English text another, more general
-- msgid would match (`%s: cannot execute: %s' for `…: required file not found'): kept as
-- patterns so the message stays untranslated, as bash leaves it (from po/bash.pot)
local SHADOWED = {
	"%s: %s out of range",
	"`%s': invalid variable name for name reference",
	"%s: cannot execute: required file not found",
	"setlocale: LC_ALL: cannot change locale (%s)",
	"setlocale: LC_ALL: cannot change locale (%s): %s",
	"syntax error: `;' unexpected",
	"unexpected token `%c' in conditional command",
	"file descriptor out of range",
	"%c%c: invalid option",
	"%s: %s: compatibility value out of range",
}

local strerr -- set of C strerror texts
local function is_strerror(s)
	if not strerr then
		strerr = {}
		for e = 1, 200 do
			local ok, p = pcall(C.strerrordesc_np, e)
			if ok and p ~= nil then
				strerr[ffi.string(p)] = true
			end
		end
	end
	return strerr[s]
end

local function patterns(st)
	local list = pat_cache[st.bash[1]]
	if list and #st.bash == 1 then
		return list
	end
	list = {}
	local seen = {}
	local function add(id)
		seen[id] = true
		-- (not `%s: Is a directory': a `NAME: strerror' is libc's text, below)
		local se = id:match("^%%s: (.*)$")
		local e = not (se and is_strerror(se)) and compile(id)
		if e then
			list[#list + 1] = e
		end
	end
	for _, c in ipairs(st.bash) do
		for id, s in pairs(c.map) do
			if s ~= "" and not seen[id] and id:find("%", 1, true) then
				add(id)
			end
		end
	end
	for _, id in ipairs(SHADOWED) do
		if not seen[id] then
			add(id)
		end
	end
	table.sort(list, function(a, b)
		if a.lits ~= b.lits then
			return a.lits > b.lits
		end
		if a.nc ~= b.nc then -- (`%s: invalid option' over getopt's `%c%c: invalid option')
			return a.nc < b.nc
		end
		return a.id < b.id
	end)
	if #st.bash == 1 then
		pat_cache[st.bash[1]] = list
	end
	return list
end

-- msgstr with the arguments put in: printf's directives, %N$ positional or in order
local function subst(str, args)
	local k = 0
	return (str:gsub("%%(%d*)(%$?)([%-+ #0-9%.]*)[hlzjtL]*([%a%%])", function(num, dollar, flags, conv)
		if conv == "%" then
			return "%"
		end
		local idx
		if dollar == "$" and num ~= "" then
			idx = tonumber(num)
		else
			flags = num .. dollar .. flags
			k = k + 1
			idx = k
		end
		local v = args[idx] or ""
		if flags ~= "" then
			if conv == "s" or conv == "c" or conv == "p" then
				return ("%" .. flags .. "s"):format(v)
			end
			local nv = tonumber(v)
			if nv then
				return ("%" .. flags .. "d"):format(nv)
			end
		end
		return v
	end))
end

-- libc's own messages: a C strerror / strsignal text -> its translation
-- an exact msgid bash also prints through a %c one (parse.y: `matching `%c'' for `)')
local AMBIGUOUS = { ["unexpected EOF while looking for matching `)'"] = true }
local evalerror_split

local function libc(st, s)
	return lookup(st, st.libc, st.lmemo, s)
end

-- evalerror's captures { "NAME: EXPR" or "EXPR", MSG, TOKEN } split at the `: ' whose
-- remainder is one of expr.c's messages (left to right), NAME only a word before `: '.
-- Its _() ones translate; a few it prints as they are.
local EVAL_MSG = {
	["attempted assignment to non-variable"] = true, ["bug: bad expassign token"] = true,
	["division by 0"] = true, ["`:' expected for conditional expression"] = true,
	["exponent less than 0"] = true, ["expression expected"] = true,
	["expression recursion level exceeded"] = true,
	["identifier expected after pre-increment or pre-decrement"] = true,
	["invalid arithmetic base"] = true, ["invalid integer constant"] = true, ["invalid number"] = true,
	["missing `)'"] = true, ["recursion stack underflow"] = true, ["syntax error in expression"] = true,
	["syntax error: invalid arithmetic operator"] = true, ["syntax error in variable assignment"] = true,
	["syntax error: operand expected"] = true, ["value too great for base"] = true,
	["bad array subscript"] = false, ["++: assignment requires lvalue"] = false,
	["--: assignment requires lvalue"] = false,
}
evalerror_split = function(st, caps)
	local head, tok = caps[1], caps[#caps]
	local body = head .. ": " .. caps[2]
	local p = 1
	while true do
		local q = body:find(": ", p, true)
		if not q then
			return { "", "", head, caps[2], tok, done = true }
		end
		local left, m = body:sub(1, q - 1), body:sub(q + 2)
		local tr = EVAL_MSG[m]
		if tr ~= nil then
			m = tr and gettext(st, m) or m
			local name, expr = left:match("^([^ ]+): (.*)$")
			if name then
				return { name, ": ", expr, m, tok, done = true }
			end
			return { "", "", left, m, tok, done = true }
		end
		p = q + 1
	end
end

-- an argument bash translated itself before formatting (`_("invalid number")', a
-- strerror): its translation, else nil
local function xarg(st, v)
	if is_strerror(v) then
		return libc(st, v)
	end
	local head, se = v:match("^(.*): ([^:]+)$") -- (`FILE: strerror' — dlerror's, file_error's)
	if se and is_strerror(se) then
		local t = libc(st, se)
		return t and (head .. ": " .. t) or nil
	end
	if v:find("%a") and not v:find("%", 1, true) then
		return lookup(st, st.bash, st.memo, v)
	end
	return nil
end

-- the translation of one whole message, arguments substituted; nil when none matches.
-- Second result: a msgid matched (an entry, or true), not just a trailing strerror
local function xlate(st, msg)
	local tailerr = msg:match(": ([^:]+)$")
	if tailerr and not is_strerror(tailerr) then
		tailerr = nil
	end
	if not msg:find("%", 1, true) and not AMBIGUOUS[msg] then
		local t = lookup(st, st.bash, st.memo, msg)
		if t then
			return t, true
		end
	end
	local find, match = string.find, string.match
	for _, e in ipairs(patterns(st)) do
		if e.key == "" or find(msg, e.key, 1, true) then
			local caps = { match(msg, e.pat) }
			if caps[1] ~= nil and e.evalerror then
				caps = evalerror_split(st, caps)
			end
			-- (a trailing strerror is libc's text: inside the last argument, never part of a
			-- longer msgid's literal — `ab: Numerical result out of range')
			if caps and caps[1] ~= nil and tailerr and not e.tailcap then
				caps = nil
			end
			if caps and caps[1] ~= nil then
				if e.ncap == 0 then
					caps = {}
				end
				for j, v in ipairs(caps) do
					if e.kinds[j] == "s" and not caps.done then
						caps[j] = xarg(st, v) or v
					end
				end
				return subst(gettext(st, e.id), caps), e
			end
		end
	end
	-- (`NAME: text': report_error ("%s: %s", …, strerror / _("…")) — the text translates)
	local head, err = msg:match("^(.*): ([^:]+)$")
	if err then
		local t = xarg(st, err)
		if t then
			return head .. ": " .. t
		end
	end
	return nil
end

-- builtin_usage's lines (`NAME: usage: SYNOPSIS`, written by the builtins themselves)
local function usage_lines(st, text)
	if not text:find(": usage: ", 1, true) then
		return text
	end
	return (text:gsub("([^\n]+)", function(l)
		local b, syn = l:match("^([^:]+): usage: (.*)$")
		if b and require("interp")._int.BUILTINS[b] then
			return subst(gettext(st, "%s: usage: "), { b }) .. gettext(st, syn)
		end
	end))
end
function M.plain(sh, a)
	local st = state(sh)
	return st and usage_lines(st, a) or nil
end

-- ---- the stderr proxy's rewrite ------------------------------------------------------
-- does a "warning: …" text match a msgid that has the prefix itself? (printf.def's
-- `warning: %s: %s' is only ever its ERANGE strerror)
local function warn_msgid(st, text)
	local _, m = xlate(st, text)
	if type(m) == "table" and m.id == "warning: %s: %s" then
		return is_strerror(text:match(": ([^:]+)$") or "") and true or false
	end
	return m and true or false
end

-- a = "curse: msg[\nmore]"; returns the whole text localized, or nil (no catalog)
function M.diag(sh, a)
	local st = state(sh)
	if not st then
		return nil
	end
	-- (the message may span lines — an argument with a newline — up to a line of its own:
	-- `NAME: usage: …', already in the locale's words)
	local text = a:sub(8)
	local u = text:find("\n[^\n:]+: ")
	local body, tail
	if u then
		body, tail = text:sub(1, u - 1), usage_lines(st, text:sub(u))
	elseif text:byte(-1) == 10 then
		body, tail = text:sub(1, -2), "\n"
	else
		body, tail = text, ""
	end
	local name, ln = rt.err_where(sh)
	if body:byte(1) == 1 then -- (runtime's job note: its own prolog)
		body = body:sub(2)
		local pre = ln > 0 and subst(gettext(st, "%s: line %d: "), { name, tostring(ln) }) or (name .. ": ")
		return pre .. body .. tail
	end
	local where = ln > 0 and (name .. ":" .. gettext(st, " line ") .. ln .. ": ") or (name .. ": ")
	-- (internal_warning's _("warning: ") prefix — unless the msgid has it: `warning: -F …',
	-- printf's `warning: %s: %s')
	local warn = ""
	local msg = body
	if msg:sub(1, 9) == "warning: " then
		local t, m = xlate(st, msg:sub(10))
		if m or not warn_msgid(st, msg) then
			return where .. gettext(st, "warning: ") .. (t or msg:sub(10)) .. tail
		end
	else
		local b, rest = msg:match("^([^:]+): (.*)$")
		-- (builtin_error's this_command_name: a builtin, `((`/`[[`, or — for a declaration
		-- builtin's assignment inside one — the function running)
		if b and (require("interp")._int.BUILTINS[b] or b == "((" or b == "[[" or sh.functions[b]) then
			local w, t
			if rest:sub(1, 9) == "warning: " then -- (builtin_warning)
				local m
				t, m = xlate(st, rest:sub(10))
				if m or not warn_msgid(st, rest) then
					w, rest = gettext(st, "warning: "), rest:sub(10)
				else
					t = nil
				end
			end
			t = t or xlate(st, rest)
			local t2, e2 = xlate(st, msg)
			if e2 and e2.evalerror then -- (evalerror's own `let: EXPR: …' is internal_error's)
				return where .. t2 .. tail
			end
			if t or not t2 then
				where = ln > 0 and (name .. ": " .. subst(gettext(st, "line %d: "), { tostring(ln) }))
					or (name .. ": ")
				return where .. b .. ": " .. (w or "") .. (t or rest) .. tail
			end
		end
	end
	return where .. warn .. (xlate(st, msg) or msg) .. tail
end

-- ---- sites outside the proxy ----------------------------------------------------------
-- _(id) formatted with the arguments (as printf would the English): rt.L's l10n half
function M.fmt(sh, id, ...)
	local st = state(sh)
	local args = { ... }
	local k = 0
	for conv in id:gmatch("%%[%-+ #0-9%.]*[hlzjtL]*([%a%%])") do -- (a %c's number: its byte)
		if conv ~= "%" then
			k = k + 1
			if conv == "c" and type(args[k]) == "number" then
				args[k] = string.char(args[k])
			end
		end
	end
	for j = 1, #args do
		args[j] = tostring(args[j])
	end
	return subst(st and gettext(st, id) or id, args)
end
-- _(id) as-is (not a format: help texts)
function M.text(sh, id)
	local st = state(sh)
	return st and gettext(st, id) or id
end
-- a help topic's long description (helpdata's lines): bash's msgid is the lines joined
-- by "\n    " (a trailing blank line: a final "\n"); its translation, else nil
function M.longdoc(sh, lines)
	local st = state(sh)
	if not st then
		return nil
	end
	local parts = {}
	for i, l in ipairs(lines) do
		parts[i] = l == true and "" or l
	end
	local id = table.concat(parts, "\n    ")
	local t = lookup(st, st.bash, st.memo, id)
	if not t and parts[#parts] == "" then
		t = lookup(st, st.bash, st.memo, table.concat(parts, "\n    ", 1, #parts - 1) .. "\n")
	end
	return t
end
-- ngettext (help's `Shell commands matching keyword[s]'): form 1 for n == 1, else 2
function M.ntext(sh, id1, id2, n)
	local st = state(sh)
	if st then
		for _, c in ipairs(st.bash) do
			local f = c.plural[id1]
			if f then
				local s = f[n == 1 and 1 or math.min(2, #f)]
				if s and s ~= "" then
					return st.conv and st.conv(s) or s
				end
			end
		end
	end
	return n == 1 and id1 or id2
end
-- libc's translation of a strsignal / strerror text
function M.libc(sh, s)
	local st = state(sh)
	return st and libc(st, s) or s
end

return M
