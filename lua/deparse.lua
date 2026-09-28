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

-- A word as bash prints it: its source text as parse.y read it (read_token_word and
-- parse_matched_pair), with the text rewrites that reading does — `$'…'` translated and
-- each $(…) body re-printed:
--   - unquoted, `$'…'` becomes '…' and `$"…"` "…"; inside "…" both are literal;
--   - inside a ${…} / $((…)) / $[…] (a grouping construct), `$'…'` is translated too
--     (extquote), then single-quoted — unless the group is itself inside "…" and, for a
--     ${…}, its operator is not a pattern one (# % ^ , / — DOLBRACE_QUOTE/QUOTE2): then the
--     translated text goes in bare (`"${x-$'a\tb'}"` prints `"${x-a<TAB>b}"`); `$"…"` in a
--     group becomes "…". A "…" nested in a ${…} is a plain double-quoted string again.
local DB_OPS = "#%^,~:-=?+/"
local CUT = {} -- (a word cut short at a translated NUL)
local function norm_word(s)
	if not s:find("[$<>]") then
		return s
	end
	local out, n = {}, #s
	local dqpair, group
	local function put(x)
		out[#out + 1] = x
	end
	local function bq(i) -- a `…` from s[i]: as written
		local j = P.quote_end(s, i, true)
		put(s:sub(i, j - 1))
		return j
	end
	-- s[i] is `$`, `<` or `>`, s[i+1] == "(" (not `$((`): parse_comsub's body, re-printed
	local function comsub(i)
		local ok, e = pcall(P.scan_cmdsub, s, i + 2)
		if not ok then
			P.trap_flow(e)
		end
		local body = ok and e and deparse_list(s:sub(i + 2, e - 2))
		if body then -- (parse_comsub: a space keeps `$( (` from reading as `$((`)
			put(s:sub(i, i) .. (body:sub(1, 1) == "(" and "( " or "(") .. body .. ")")
			return e
		end
		put(s:sub(i, i))
		return i + 1
	end
	-- a `$` construct at s[i] (s[i] == "$") that nests: returns the index past it, or nil
	local function dollar(i, dq)
		local c2 = s:sub(i + 1, i + 1)
		if c2 == "(" and s:sub(i + 2, i + 2) ~= "(" then
			return comsub(i)
		elseif c2 == "(" then
			put("$(")
			return group(i + 2, "(", ")", false, dq)
		elseif c2 == "{" then
			put("${")
			return group(i + 2, "{", "}", true, dq)
		elseif c2 == "[" then
			put("$[")
			return group(i + 2, "[", "]", false, dq)
		end
		return nil
	end
	dqpair = function(i) -- inside "…" (just past the opening quote): through the closing one
		while i <= n do
			local c = s:sub(i, i)
			if c == "\\" then
				put(s:sub(i, i + 1))
				i = i + 2
			elseif c == '"' then
				put(c)
				return i + 1
			elseif c == "`" then
				i = bq(i)
			elseif c == "$" and s:sub(i + 1, i + 1) == "$" then
				put("$$")
				i = i + 2
			else
				local j = c == "$" and dollar(i, true)
				if j then
					i = j
				else
					put(c)
					i = i + 1
				end
			end
		end
		return i
	end
	-- a grouping construct's text from s[i] (past its opener) through its closer
	group = function(i, open, close, dolbrace, dq)
		local count, st, nread, wasdol = 1, dolbrace and "param" or nil, 0, false
		while i <= n do
			local c = s:sub(i, i)
			nread = nread + 1
			if st then -- (parse.y's dolbrace_state, advanced by each character read)
				if st == "param" and nread > 1 and (c == "%" or c == "#" or c == "^" or c == ",") then
					st = "quote"
				elseif st == "param" and nread > 1 and c == "/" then
					st = "quote2"
				elseif st == "param" and DB_OPS:find(c, 1, true) then
					st = "op"
				elseif st == "op" and not DB_OPS:find(c, 1, true) then
					st = "word"
				end
			end
			if c == "\\" then
				put(s:sub(i, i + 1))
				i = i + 2
				wasdol = false
			elseif c == close then
				put(c)
				i = i + 1
				count = count - 1
				if count == 0 then
					return i
				end
				wasdol = false
			elseif c == open and not dolbrace then -- (P_FIRSTCLOSE: only a `${` nests a ${…})
				put(c)
				i = i + 1
				count = count + 1
				wasdol = false
			elseif c == "'" and wasdol then -- $'…': translated here (extquote)
				out[#out] = nil -- (the `$` put before it)
				local j = P.quote_end(s, i, true)
				if not dq or st == "quote" or st == "quote2" then
					put(sq(rt.ansi_unescape(s:sub(i + 1, j - 2), true)))
				else -- (bare: a NUL in it ends the WORD's C string — the rest of it is gone)
					local t = rt.ansi_unescape(s:sub(i + 1, j - 2), "z")
					local z = t:find("\0", 1, true)
					put(z and t:sub(1, z - 1) or t)
					if z then
						error(CUT, 0)
					end
				end
				i, wasdol = j, false
			elseif c == "'" then
				local j = P.quote_end(s, i, false)
				put(s:sub(i, j - 1))
				i, wasdol = j, false
			elseif c == '"' then
				if wasdol then -- $"…": its (untranslated) text double-quoted
					out[#out] = nil
				end
				put(c)
				i, wasdol = dqpair(i + 1), false
			elseif c == "`" then
				i, wasdol = bq(i), false
			elseif c == "$" and s:sub(i + 1, i + 1) == "$" then
				put("$$")
				i, wasdol = i + 2, false
			else
				local j = c == "$" and (dolbrace or s:sub(i + 1, i + 1) == "(") and dollar(i, dq)
				if j then
					i, wasdol = j, false
				else
					put(c)
					i, wasdol = i + 1, c == "$"
				end
			end
		end
		return i
	end
	local ok, e = pcall(function()
		local i = 1
		while i <= n do
			local c = s:sub(i, i)
			if c == "\\" then
				put(s:sub(i, i + 1))
				i = i + 2
			elseif c == "'" then
				local j = P.quote_end(s, i, false)
				put(s:sub(i, j - 1))
				i = j
			elseif c == "`" then
				i = bq(i)
			elseif c == '"' then
				put(c)
				i = dqpair(i + 1)
			elseif c == "$" and s:sub(i + 1, i + 1) == "$" then -- `$$` (read_token_word: one token —
				put("$$") -- `$$'x'` is $$ then 'x', never $'…')
				i = i + 2
			elseif c == "$" and s:sub(i + 1, i + 1) == "'" then
				local j = P.quote_end(s, i + 1, true)
				put(sq(rt.ansi_unescape(s:sub(i + 2, j - 2), true)))
				i = j
			elseif c == "$" and s:sub(i + 1, i + 1) == '"' then
				i = i + 1 -- $"…": the parser drops the $ (the translated text stays double-quoted)
			elseif (c == "<" or c == ">") and s:sub(i + 1, i + 1) == "(" then -- <(…) >(…): as $(…)
				i = comsub(i)
			else
				local j = c == "$" and dollar(i, false)
				if j then
					i = j
				else
					put(c)
					i = i + 1
				end
			end
		end
	end)
	if not ok and e ~= CUT then
		error(e, 0)
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
	local s = P.strip_contin(w.src) -- (the lexer removes \<newline>s; not inside '…')
	if s == "" then
		return nil -- only a line continuation
	end
	return norm_word(s)
end

-- ---- curse AST -> bash's command tree --------------------------------------------
local conv, conv_list
local comsub_nl = false -- (a $(…) body: its top-level newlines stay `\n` connectors)

local function assign_text(a)
	if a.t == "arrayassign" then
		if not a.raw then
			unsupported()
		end
		return a.name .. (a.index and ("[" .. a.index .. "]") or "") .. (a.append and "+=" or "=") .. norm_word(a.raw)
	end
	local rhs = a.rhs and wtext(a.rhs) or (a.rhssrc and norm_word(a.rhssrc)) or ""
	return a.name .. (a.index and ("[" .. a.index .. "]") or "") .. (a.append and "+=" or "=") .. rhs
end

-- a statement list: `;` (or `&` after a background job) connections, left-nested
conv_list = function(stmts)
	local acc, bg, semi = nil, false, false
	for _, st in ipairs(stmts or {}) do
		local c, isbg
		if st.t == "background" then
			c, isbg = conv(st.cmd), true
		else
			c = conv(st)
		end
		if c then
			if acc then
				acc = { k = "conn", first = acc, second = c,
					-- (a $(…) body's lists, nested ones too, keep their newline connectors:
					-- parse.y's list1 '\n' under PST_CMDSUBST)
					op = bg and "&" or (comsub_nl and not semi and "\n") or ";" }
			else
				acc = c
			end
			bg, semi = isbg, st.semi
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
				ws[#ws + 1] = aa[ai].src and norm_word(aa[ai].src) or unsupported()
				ai = ai + 1
			end
			ws[#ws + 1] = wtext(w)
		end
		while aa and aa[ai] do
			ws[#ws + 1] = aa[ai].src and norm_word(aa[ai].src) or unsupported()
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
		local b = st.body
		if #b == 1 and b[1].tw then -- (`time ( … )`: parser.untail's timed group is the body)
			b = b[1].body
		end
		c = { k = "subshell", body = conv_list(b) }
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
			local s = (st.src[k] or ""):gsub("^[ \t]+", "") -- (make_arith_for_expr skips blanks only)
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
	elseif t == "noop" or t == "warn" then -- (a parse-time warning: no command)
		return nil
	else
		unsupported()
	end
	c.redirs = c.redirs or st.redirs
	if st.timed then
		c.time, c.time_p = true, st.timed_p
	elseif st.ttimed then
		c.time, c.time_p = true, st.ttimed == "p" or nil
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
		cprintf(p, redir_fd(r, 1) .. "<> " .. tgt) -- (print_cmd.c: r_input_output omits only fd 1)
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
		elseif tgt:match("^%d+%-?$") and tonumber(tgt:match("^%d+")) <= 2147483647 then
			-- (a NUMBER token — one that fits an int — is printed as %d: `>&007` is `1>&7`;
			-- a bigger one is a WORD, printed as written)
			cprintf(p, fd .. arrow .. string.format("%d", tonumber(tgt:match("^%d+"))) .. (tgt:match("%-$") or ""))
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
		p.was_hd = false -- (not printing any here-documents now: the `;` after it prints)
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
		else -- `;` or (a comsub body's) `\n`
			local nl = op == "\n"
			local was_nl = nl and not p.deferred and not p.was_hd
			if not p.deferred then
				if not p.was_hd then
					cprintf(p, op)
				else
					p.was_hd = false
				end
			else
				print_deferred(p, p.infunc > 0 and "" or ";")
			end
			if p.infunc > 0 then
				cprintf(p, "\n")
			elseif nl and not was_nl then
				cprintf(p, "\n") -- (preserve newlines in comsubs but don't double them)
			else
				if not nl then
					cprintf(p, " ")
				end
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
	elseif k == "coproc" then -- (print_cmd.c: the command follows unindented. bash 5.2.21 always
		-- prints the name — `coproc COPROC cat` for a simple command, which can't be re-read as
		-- input; patch 5.2-032 later printed it only for a compound one. curse is 5.2.21.)
		cprintf(p, "coproc " .. c.name .. " ")
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

-- A $(…) body, re-printed as bash's print_comsub does (`a; b`, newlines kept); nil if it
-- doesn't parse or holds something unprintable (the caller keeps the text as is).
deparse_list = function(src)
	-- (noalias: parse_comsub only checks the body's syntax — no alias it defines, or turns
	-- expand_aliases on for, is applied to the printed tree; cs: a $(…) body)
	local ok, ast = pcall(P.parse, src, nil, nil, true, nil, nil, nil, nil, nil, true)
	if not ok then
		P.trap_flow(ast)
	end
	if not ok or type(ast) ~= "table" or ast.perr then
		return nil
	end
	local pok, r = pcall(function()
		local p = new_printer()
		local sv = comsub_nl
		comsub_nl = true
		local cok, c = pcall(conv_list, ast.stmts)
		comsub_nl = sv
		if not cok then
			error(c, 0)
		end
		make(p, c)
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

M.comsub = deparse_list -- (parser.comsub_text: the text a $(…) runs)
M.norm_word = norm_word -- (a compound-literal word in an error: rt.compound_word_src)
return M
