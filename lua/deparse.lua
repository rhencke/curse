-- Print a function the way bash does (print_cmd.c) — for `declare -f`, `type NAME` and
-- `command -V NAME`. Loaded lazily, only when a function body is actually printed.
--
-- bash prints each WORD as it was written, with two rewrites: `$'…'` becomes '…' (the
-- parser decodes it), and a `$(…)` body is re-printed canonically. Everything around the
-- words is re-laid out: one command per line inside a function, `;` terminators, bodies
-- indented by 4, redirections spaced (`> file`, `2>&1`, `1>&2`), elif as a nested
-- else-if, case clauses on their own lines, heredoc bodies after the command line.
--
-- The curse AST keeps what that needs: each word's source text (w.src; false for the
-- 2nd+ expansion of a brace word), the text of (( )) and for (( )) slots, heredoc bodies.
-- The printer below is a direct port of print_cmd.c's state machine (skip_this_indent,
-- deferred heredocs, semicolon()) over bash's command tree, which conv() rebuilds from
-- the curse AST. Any construct it doesn't know makes M.func return nil (callers fall
-- back to the verbatim definition text).
local P = require("parser")
local rt = require("runtime")

local M = {}

local UNSUPPORTED = {}
local function unsupported()
	error(UNSUPPORTED, 0)
end

local function sq(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local deparse_list -- forward: re-print a $(…) body

-- A word as bash prints it: its source text, with $'…' decoded into '…' and each $(…)
-- body re-printed. Quote-aware: $' is literal inside "…", nothing is special in '…'.
local function norm_word(s)
	if not s:find("$", 1, true) then
		return s
	end
	local out, i, n, indq = {}, 1, #s, false
	while i <= n do
		local c = s:sub(i, i)
		if c == "\\" then
			out[#out + 1] = s:sub(i, i + 1)
			i = i + 2
		elseif c == "'" and not indq then
			local j = s:find("'", i + 1, true) or n
			out[#out + 1] = s:sub(i, j)
			i = j + 1
		elseif c == '"' then
			indq = not indq
			out[#out + 1] = c
			i = i + 1
		elseif c == "`" then
			local j = i + 1
			while j <= n and s:sub(j, j) ~= "`" do
				j = j + (s:sub(j, j) == "\\" and 2 or 1)
			end
			out[#out + 1] = s:sub(i, j)
			i = j + 1
		elseif c == "$" and s:sub(i + 1, i + 1) == "'" and not indq then
			local j, buf = i + 2, {}
			while j <= n do
				local c2 = s:sub(j, j)
				if c2 == "\\" then
					buf[#buf + 1] = s:sub(j, j + 1)
					j = j + 2
				elseif c2 == "'" then
					break
				else
					buf[#buf + 1] = c2
					j = j + 1
				end
			end
			out[#out + 1] = sq(rt.ansi_unescape(table.concat(buf), true))
			i = j + 1
		elseif c == "$" and s:sub(i + 1, i + 1) == "(" and s:sub(i + 2, i + 2) ~= "(" then
			local ok, e = pcall(P.scan_cmdsub, s, i + 2)
			local body = ok and e and deparse_list(s:sub(i + 2, e - 2))
			if body then
				out[#out + 1] = "$(" .. body .. ")"
				i = e
			else
				out[#out + 1] = c
				i = i + 1
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- drop \<newline> line continuations (the lexer removes them; not inside '…')
local function strip_contin(s)
	if not s:find("\\\n") then
		return s
	end
	local out, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "'" then
			local j = s:find("'", i + 1, true) or n
			out[#out + 1] = s:sub(i, j)
			i = j + 1
		elseif c == "\\" then
			if s:sub(i + 1, i + 1) ~= "\n" then
				out[#out + 1] = s:sub(i, i + 1)
			end
			i = i + 2
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

local function wtext(w)
	if w.src == false then
		return nil -- a brace expansion's 2nd+ word: the 1st printed the whole `{a,b}`
	end
	if type(w.src) ~= "string" then
		unsupported()
	end
	local s = strip_contin(w.src)
	if s == "" then
		return nil -- only a line continuation
	end
	return norm_word(s)
end

-- ---- curse AST -> bash's command tree --------------------------------------------
local conv, conv_list

local function assign_text(a)
	if a.t == "arrayassign" then
		if not a.raw then
			unsupported()
		end
		return a.name .. (a.append and "+=" or "=") .. a.raw
	end
	local rhs = a.rhs and wtext(a.rhs) or (a.rhssrc and norm_word(a.rhssrc)) or ""
	return a.name .. (a.index and ("[" .. a.index .. "]") or "") .. (a.append and "+=" or "=") .. rhs
end

-- a statement list: `;` (or `&` after a background job) connections, left-nested
conv_list = function(stmts)
	local acc, bg = nil, false
	for _, st in ipairs(stmts or {}) do
		local c, isbg
		if st.t == "background" then
			c, isbg = conv(st.cmd), true
		else
			c = conv(st)
		end
		if c then
			if acc then
				acc = { k = "conn", first = acc, second = c, op = bg and "&" or ";" }
			else
				acc = c
			end
			bg = isbg
		end
	end
	if acc and bg then
		acc = { k = "conn", first = acc, op = "&" }
	end
	return acc
end

local function chain(list, op, f)
	local acc
	for _, x in ipairs(list) do
		local c = f(x)
		acc = acc and { k = "conn", first = acc, second = c, op = op or x.op } or c
	end
	return acc
end

conv = function(st)
	local t, c = st.t, nil
	if t == "simple" then
		local ws = {}
		for _, a in ipairs(st.assigns or {}) do
			ws[#ws + 1] = assign_text(a)
		end
		local aa, ai = st.arrayargs, 1
		for i, w in ipairs(st.words or {}) do
			while aa and aa[ai] and aa[ai].pos == i do
				ws[#ws + 1] = aa[ai].src or unsupported()
				ai = ai + 1
			end
			ws[#ws + 1] = wtext(w)
		end
		while aa and aa[ai] do
			ws[#ws + 1] = aa[ai].src or unsupported()
			ai = ai + 1
		end
		if #ws == 1 and ws[1] == "time" and not st.redirs then
			return { k = "simple", words = {}, time = true } -- a bare `time`: an empty timed pipeline
		end
		return { k = "simple", words = ws, redirs = st.redirs, time = st.timed, time_p = st.timed_p }
	elseif t == "assign" or t == "arrayassign" then
		return { k = "simple", words = { assign_text(st) } }
	elseif t == "assignlist" then
		local ws = {}
		for _, a in ipairs(st.list) do
			ws[#ws + 1] = assign_text(a)
		end
		return { k = "simple", words = ws }
	elseif t == "pipeline" then
		c = chain(st.cmds, "|", conv) or { k = "simple", words = {} } -- (a bare `!` / `time`)
		if st.negate then
			c.invert = not c.invert -- (`! ! cmd` cancels, as bash's parser toggles it)
		end
	elseif t == "andor" then
		c = chain(st.items, nil, function(it)
			return conv(it.cmd)
		end)
	elseif t == "background" then
		c = { k = "conn", first = conv(st.cmd), op = "&" }
	elseif t == "group" then
		c = { k = "group", body = conv_list(st.body) }
	elseif t == "subshell" then
		c = { k = "subshell", body = conv_list(st.body) }
	elseif t == "coproc" then
		c = { k = "coproc", name = st.name or "COPROC", body = conv(st.cmd) }
	elseif t == "if" then
		local function from(k)
			local cl = st.clauses[k]
			if not cl then
				return nil
			end
			if not cl.cond then -- the final `else`
				return conv_list(cl.body)
			end
			return { k = "if", test = conv_list(cl.cond), tcase = conv_list(cl.body), fcase = from(k + 1) }
		end
		c = from(1)
	elseif t == "whilec" then
		c = { k = st.negate and "until" or "while", test = conv_list(st.cond), body = conv_list(st.body) }
	elseif t == "forin" or t == "select" then
		local ws = {}
		for _, w in ipairs(st.words or {}) do
			ws[#ws + 1] = wtext(w)
		end
		c = { k = t == "select" and "select" or "for", name = st.name, words = ws, body = conv_list(st.body) }
	elseif t == "forc" then
		if not st.src then
			unsupported()
		end
		local sl = {}
		for k = 1, 3 do
			local s = (st.src[k] or ""):gsub("^%s+", "")
			sl[k] = s == "" and "1" or s -- an empty slot prints as 1 (bash)
		end
		c = { k = "arith_for", slots = sl, body = conv_list(st.body) }
	elseif t == "case" then
		local cls = {}
		for _, cl in ipairs(st.clauses) do
			local pats = {}
			for _, pt in ipairs(cl.pats) do
				pats[#pats + 1] = norm_word(pt)
			end
			cls[#cls + 1] = {
				pats = pats,
				action = conv_list(cl.body),
				term = cl.term == "fall" and ";&" or cl.term == "test" and ";;&" or ";;",
			}
		end
		c = { k = "case", word = wtext(st.subject), clauses = cls }
	elseif t == "arithcmd" then
		c = { k = "arith", text = st.src or unsupported() }
	elseif t == "dbracket" then
		c = { k = "cond", expr = st.expr }
	elseif t == "funcdef" then
		return { k = "funcdef", name = st.name, body = M.fbody(st), fredirs = not st.subbody and st.redirs or nil }
	elseif t == "noop" then
		return nil
	else
		unsupported()
	end
	c.redirs = c.redirs or st.redirs
	if st.timed then
		c.time, c.time_p = true, st.timed_p
	end
	return c
end

-- ---- the printer (print_cmd.c) -----------------------------------------------------
local function new_printer()
	return { buf = {}, last = "", ind = 0, amt = 4, skip = 0, infunc = 0, pconn = 0, deferred = nil, was_hd = false }
end
local function cprintf(p, s)
	if s ~= "" then
		p.buf[#p.buf + 1] = s
		p.last = s:sub(-1)
	end
end
local function indent(p, n)
	if n > 0 then
		cprintf(p, (" "):rep(n))
	end
end
local function newline(p, s)
	cprintf(p, "\n")
	indent(p, p.ind)
	cprintf(p, s)
end
local function semicolon(p)
	if #p.buf > 0 and (p.last == "&" or p.last == "\n") then
		return
	end
	cprintf(p, ";")
end

local function hd_bodies(p, hds)
	cprintf(p, "\n")
	for _, r in ipairs(hds) do
		cprintf(p, (r.body or "") .. r.delim .. "\n")
	end
	p.was_hd = true
end
local function print_deferred(p, cstr)
	local show = cstr ~= "" and (cstr:sub(1, 1) ~= ";" or #cstr > 1)
	if show then
		cprintf(p, cstr)
	end
	if p.deferred then
		hd_bodies(p, p.deferred)
		if show then
			cprintf(p, " ")
		end
	end
	p.deferred = nil
end
local function deferred_pending(p, s)
	if p.deferred then
		print_deferred(p, s)
	end
end

local function redir_fd(r, dflt)
	if r.fdvar then
		return "{" .. r.fdvar .. "}"
	end
	return r.fd ~= dflt and tostring(r.fd) or ""
end
local function print_redir(p, r)
	local op = r.op
	local tgt = norm_word(r.src or r.target or "")
	if op == "out" then
		cprintf(p, redir_fd(r, 1) .. "> " .. tgt)
	elseif op == "app" then
		cprintf(p, redir_fd(r, 1) .. ">> " .. tgt)
	elseif op == "clobber" then
		cprintf(p, redir_fd(r, 1) .. ">| " .. tgt)
	elseif op == "in" then
		cprintf(p, redir_fd(r, 0) .. "< " .. tgt)
	elseif op == "rw" then
		cprintf(p, redir_fd(r, 0) .. "<> " .. tgt)
	elseif op == "outboth" then
		cprintf(p, "&> " .. tgt)
	elseif op == "appboth" then
		cprintf(p, "&>> " .. tgt)
	elseif op == "herestring" then
		cprintf(p, redir_fd(r, 0) .. "<<< " .. norm_word(r.word or ""))
	elseif op == "dup" or op == "dupin" then
		local fd = r.fdvar and ("{" .. r.fdvar .. "}") or tostring(r.fd)
		local arrow = op == "dup" and ">&" or "<&"
		if tgt == "-" then
			cprintf(p, fd .. ">&-") -- (bash prints every close as >&-)
		elseif tgt:match("^%d+%-?$") then
			cprintf(p, fd .. arrow .. tgt)
		elseif op == "dup" and r.fd == 1 and not r.fdvar and not tgt:match("^[-$`]") then
			cprintf(p, "&> " .. tgt) -- `>&word`: the file form, printed as &>
		else
			cprintf(p, (op == "dup" and redir_fd(r, 1) or redir_fd(r, 0)) .. arrow .. tgt)
		end
	else
		unsupported()
	end
end
local function print_redirs(p, rs)
	local hds = {}
	p.was_hd = false
	for i, r in ipairs(rs) do
		if r.op == "heredoc" then
			local pre = r.fdvar and ("{" .. r.fdvar .. "}") or (r.fd ~= 0 and tostring(r.fd) or "")
			cprintf(p, pre .. "<<" .. (r.strip and "-" or "") .. (r.expand and r.delim or sq(r.delim)))
			hds[#hds + 1] = r
		else
			print_redir(p, r)
		end
		if i < #rs then
			cprintf(p, " ")
		end
	end
	if #hds > 0 and p.pconn > 0 then
		p.deferred = hds
	elseif #hds > 0 then
		hd_bodies(p, hds)
	end
end

local cond_node
cond_node = function(p, e)
	local n = e.paren or 0
	for _ = 1, n do
		cprintf(p, "( ")
	end
	local k = e.kind
	if k == "not" then
		cprintf(p, "! ")
		cond_node(p, e.e)
	elseif k == "and" or k == "or" then
		cond_node(p, e.l)
		cprintf(p, k == "and" and " && " or " || ")
		cond_node(p, e.r)
	elseif k == "unary" then
		cprintf(p, e.op .. " " .. wtext(e.word))
	elseif k == "binary" then
		cprintf(p, wtext(e.l) .. " " .. e.op .. " " .. wtext(e.r))
	elseif k == "str" then
		cprintf(p, "-n " .. wtext(e.word)) -- a lone word is a -n test (bash's parser)
	else
		unsupported()
	end
	for _ = 1, n do
		cprintf(p, " )")
	end
end

local make
local function print_fdef(p, c) -- a function defined inside a printed body
	cprintf(p, (M.posix and "" or "function ") .. c.name .. " () \n")
	indent(p, p.ind)
	cprintf(p, "{ \n")
	p.infunc = p.infunc + 1
	p.ind = p.ind + p.amt
	make(p, c.body)
	deferred_pending(p, "")
	p.ind = p.ind - p.amt
	p.infunc = p.infunc - 1
	if c.fredirs and #c.fredirs > 0 then
		newline(p, "} ")
		print_redirs(p, c.fredirs)
	else
		newline(p, "}")
	end
end

make = function(p, c)
	if c == nil then
		return
	end
	if p.skip > 0 then
		p.skip = p.skip - 1
	else
		indent(p, p.ind)
	end
	if c.time then
		cprintf(p, "time ")
		if c.time_p then
			cprintf(p, "-p ")
		end
	end
	if c.invert then
		cprintf(p, "! ")
	end
	local k = c.k
	if k == "simple" then
		cprintf(p, table.concat(c.words, " "))
		if c.redirs and #c.redirs > 0 then
			if #c.words > 0 then
				cprintf(p, " ")
			end
			print_redirs(p, c.redirs)
		end
		return
	elseif k == "conn" then
		p.skip = p.skip + 1
		p.pconn = p.pconn + 1
		make(p, c.first)
		local op = c.op
		if op == "&" or op == "|" then
			print_deferred(p, " " .. op)
			if op ~= "&" or c.second then
				cprintf(p, " ")
				p.skip = p.skip + 1
			end
		elseif op == "&&" or op == "||" then
			print_deferred(p, " " .. op .. " ")
			if c.second then
				p.skip = p.skip + 1
			end
		else -- `;`
			if not p.deferred then
				if not p.was_hd then
					cprintf(p, ";")
				else
					p.was_hd = false
				end
			else
				print_deferred(p, p.infunc > 0 and "" or ";")
			end
			if p.infunc > 0 then
				cprintf(p, "\n")
			else
				cprintf(p, " ")
				if c.second then
					p.skip = p.skip + 1
				end
			end
		end
		make(p, c.second)
		deferred_pending(p, "")
		p.pconn = p.pconn - 1
	elseif k == "group" then
		cprintf(p, "{ ")
		if p.infunc == 0 then
			p.skip = p.skip + 1
		else
			cprintf(p, "\n")
			p.ind = p.ind + p.amt
		end
		make(p, c.body)
		deferred_pending(p, "")
		if p.infunc > 0 then
			cprintf(p, "\n")
			p.ind = p.ind - p.amt
			indent(p, p.ind)
		else
			semicolon(p)
			cprintf(p, " ")
		end
		cprintf(p, "}")
	elseif k == "coproc" then -- (print_cmd.c: the command follows unindented; bash 5.2.37 names
		-- only a compound one — a simple command's coproc is always the default COPROC)
		cprintf(p, c.body and c.body.k == "simple" and "coproc " or ("coproc " .. c.name .. " "))
		p.skip = p.skip + 1
		make(p, c.body)
	elseif k == "subshell" then
		cprintf(p, "( ")
		p.skip = p.skip + 1
		make(p, c.body)
		deferred_pending(p, "")
		cprintf(p, " )")
	elseif k == "for" or k == "select" then
		cprintf(p, k .. " " .. c.name .. " in " .. table.concat(c.words, " "))
		cprintf(p, ";")
		newline(p, "do\n")
		p.ind = p.ind + p.amt
		make(p, c.body)
		deferred_pending(p, "")
		semicolon(p)
		p.ind = p.ind - p.amt
		newline(p, "done")
	elseif k == "arith_for" then
		cprintf(p, "for ((" .. table.concat(c.slots, "; ") .. "))")
		newline(p, "do\n")
		p.ind = p.ind + p.amt
		make(p, c.body)
		deferred_pending(p, "")
		semicolon(p)
		p.ind = p.ind - p.amt
		newline(p, "done")
	elseif k == "while" or k == "until" then
		cprintf(p, k .. " ")
		p.skip = p.skip + 1
		make(p, c.test)
		deferred_pending(p, "")
		semicolon(p)
		cprintf(p, " do\n")
		p.ind = p.ind + p.amt
		make(p, c.body)
		deferred_pending(p, "")
		p.ind = p.ind - p.amt
		semicolon(p)
		newline(p, "done")
	elseif k == "if" then
		cprintf(p, "if ")
		p.skip = p.skip + 1
		make(p, c.test)
		semicolon(p)
		cprintf(p, " then\n")
		p.ind = p.ind + p.amt
		make(p, c.tcase)
		deferred_pending(p, "")
		p.ind = p.ind - p.amt
		if c.fcase then
			semicolon(p)
			newline(p, "else\n")
			p.ind = p.ind + p.amt
			make(p, c.fcase)
			deferred_pending(p, "")
			p.ind = p.ind - p.amt
		end
		semicolon(p)
		newline(p, "fi")
	elseif k == "case" then
		cprintf(p, "case " .. c.word .. " in ")
		p.ind = p.ind + p.amt
		for _, cl in ipairs(c.clauses) do
			newline(p, "")
			cprintf(p, table.concat(cl.pats, " | "))
			cprintf(p, ")\n")
			p.ind = p.ind + p.amt
			make(p, cl.action)
			p.ind = p.ind - p.amt
			deferred_pending(p, "")
			newline(p, cl.term)
		end
		p.ind = p.ind - p.amt
		newline(p, "esac")
	elseif k == "arith" then
		cprintf(p, "((" .. c.text .. "))")
	elseif k == "cond" then
		cprintf(p, "[[ ")
		cond_node(p, c.expr)
		cprintf(p, " ]]")
	elseif k == "funcdef" then
		print_fdef(p, c)
	else
		unsupported()
	end
	if c.redirs and #c.redirs > 0 then
		cprintf(p, " ")
		print_redirs(p, c.redirs)
	end
end

-- A funcdef's body as bash's command: `f() ( … ) >x` keeps its redirections on the
-- subshell (only a `{ }` body's redirections belong to the function itself).
function M.fbody(st)
	local body = conv_list(st.body)
	if st.subbody and st.redirs and body then
		body.redirs = st.redirs
	end
	return body
end

-- The environment form of an exported function: BASH_FUNC_name%%=<this> — bash prints it
-- with a flat 1-space indent: `() {  cmd;\n cmd\n}`.
function M.export_text(st)
	local ok, r = pcall(function()
		local p = new_printer()
		p.ind, p.amt, p.infunc = 1, 0, 1
		cprintf(p, "() { ")
		make(p, M.fbody(st))
		deferred_pending(p, "")
		cprintf(p, "\n}")
		if st.redirs and #st.redirs > 0 and not st.subbody then
			cprintf(p, " ")
			print_redirs(p, st.redirs)
		end
		return table.concat(p.buf)
	end)
	if ok then
		return r
	end
	if r ~= UNSUPPORTED then
		error(r, 0)
	end
	return nil
end

-- $BASH_COMMAND: the command being run, printed as bash prints it ("" if unprintable)
function M.command_text(st)
	if st.t == "head" then -- (a compound command's head, as its DEBUG trap sees it)
		return st.text
	end
	local ok, r = pcall(function()
		local p = new_printer()
		make(p, conv(st))
		deferred_pending(p, "")
		return table.concat(p.buf)
	end)
	if ok then
		return r or ""
	end
	if r ~= UNSUPPORTED then
		error(r, 0)
	end
	return ""
end

local RESERVED = {}
for w in ("if then else elif fi case esac for select while until do done in function time { } ! [[ ]] coproc"):gmatch("%S+") do
	RESERVED[w] = true
end

-- `declare -f NAME` text for a function with body `body` (a statement list) and any
-- redirections on its definition; nil when some construct can't be printed exactly.
function M.func(name, body, redirs, subbody)
	local ok, r = pcall(function()
		local st = { body = body, redirs = redirs, subbody = subbody }
		local p = new_printer()
		if RESERVED[name] then
			cprintf(p, "function ")
		end
		cprintf(p, name .. " () \n")
		p.ind = p.amt
		p.infunc = 1
		cprintf(p, "{ \n")
		make(p, M.fbody(st))
		deferred_pending(p, "")
		p.ind, p.infunc = 0, 0
		cprintf(p, "\n}")
		if redirs and #redirs > 0 and not subbody then
			cprintf(p, " ")
			print_redirs(p, redirs)
		end
		return table.concat(p.buf)
	end)
	if ok then
		return r
	end
	if r ~= UNSUPPORTED then
		error(r, 0)
	end
	return nil
end

-- A $(…) body, re-printed on one line (bash's comsub printing: `a; b`); nil if it
-- doesn't parse or holds something unprintable (the caller keeps the text as is).
deparse_list = function(src)
	local ok, ast = pcall(P.parse, src)
	if not ok or type(ast) ~= "table" or ast.perr then
		return nil
	end
	local pok, r = pcall(function()
		local p = new_printer()
		make(p, conv_list(ast.stmts))
		deferred_pending(p, "")
		return table.concat(p.buf)
	end)
	if pok then
		return r
	end
	if r ~= UNSUPPORTED then
		error(r, 0)
	end
	return nil
end

M.norm_word = norm_word -- (a compound-literal word in an error: rt.compound_word_src)
return M
