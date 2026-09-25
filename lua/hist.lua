-- Command history for scripts (`set -o history`) and `!` history expansion (`set -H`):
-- the history list with bash's HISTCONTROL / HISTIGNORE / HISTSIZE rules, the per-line
-- recording of bashhist.c (maybe_add_history / bash_add_history, with cmdhist joining a
-- multi-line command into one entry), and a port of readline's histexpand.c. Loaded only
-- when a script turns history on (interp's line reader) or runs `history`/`fc`.
local rt = require("runtime")

local M = {}

-- ---- the list ---------------------------------------------------------------------
-- sh.history[k] is entry number sh.hist_base + k - 1 (bash's history_base); sh.hist_ts[k]
-- its timestamp as readline keeps it: the history comment char, then the epoch ("\0…"
-- when there was no comment char, as hist_inittime's `ret[0] = history_comment_char`).
function M.list(sh)
	local h = sh.history
	if not h then
		h = {}
		sh.history, sh.hist_ts = h, sh.hist_ts or {}
	end
	sh.hist_base = sh.hist_base or 1
	return h
end
local function tslist(sh)
	local t = sh.hist_ts
	if not t then
		t = {}
		sh.hist_ts = t
	end
	return t
end
M.tslist = tslist

-- readline's history_comment_char for timestamps: none in a script until HISTTIMEFORMAT
-- is set (sv_histtimefmt makes it `#`, for good) or $histchars names one
function M.tscc(sh)
	if sh.hist_cc == nil and sh.vars.HISTTIMEFORMAT then
		sh.hist_cc = "#"
	end
	local hc = sh.vars.histchars and sh:get("histchars")
	if hc and #hc >= 3 then
		return hc:sub(3, 3)
	end
	return sh.hist_cc or "\0"
end

-- history_get_time: the entry's epoch, or nil (not a timestamp under the comment char)
function M.get_time(sh, k)
	local ts = tslist(sh)[k]
	if not ts or ts:sub(1, 1) ~= M.tscc(sh) then
		return nil
	end
	local t = tonumber(ts:match("^%d+", 2))
	return t ~= 0 and t or nil
end

function M.enabled(sh) -- bash's remember_on_history
	return sh.opt_history == true or (sh.opt_history == nil and sh.opt_i == true)
end

function M.expanding(sh) -- bash's history_expansion (set -H), active only while recording
	return (sh.opt_H == true or (sh.opt_H == nil and sh.opt_i == true)) and M.enabled(sh)
end

-- $histchars: expansion char, quick-substitution char, comment char
function M.chars(sh)
	local hc = sh.vars.histchars and sh:get("histchars")
	if hc == nil then
		return "!", "^", "#"
	end
	local function c(k)
		local x = hc:sub(k, k)
		return x ~= "" and x or nil
	end
	return c(1), c(2), c(3)
end

-- $HISTSIZE as the stifle limit (nil: not stifled)
local function histmax(sh)
	local hs = sh.vars.HISTSIZE and sh:get("HISTSIZE")
	return hs and hs:match("^%s*%d+%s*$") and tonumber(hs)
end

-- remove entry K (and its timestamp)
function M.remove(sh, k)
	table.remove(M.list(sh), k)
	table.remove(tslist(sh), k)
end

-- readline's stifle_history, on a HISTSIZE assignment: the oldest entries go and
-- history_base becomes the number removed (not the old base plus it)
function M.stifle(sh)
	local h = M.list(sh)
	local max = histmax(sh)
	if not max then
		return
	end
	local extra = #h - max
	if extra > 0 then
		local t = tslist(sh)
		table.move(h, extra + 1, #h, 1)
		table.move(t, extra + 1, #h, 1)
		for k = #h, #h - extra + 1, -1 do
			h[k], t[k] = nil, nil
		end
		sh.hist_base = extra
	end
end

-- readline's add_history (+ add_history_time's TS): a full stifled list drops its oldest
-- entry and history_base moves on by one
function M.add_history(sh, line, ts)
	local h, t = M.list(sh), tslist(sh)
	local max = histmax(sh)
	if max and #h >= max then
		if max == 0 then
			return
		end
		while #h >= max do
			M.remove(sh, 1)
			sh.hist_base = sh.hist_base + 1
		end
	end
	h[#h + 1] = line
	t[#h] = ts or (M.tscc(sh) .. os.time())
end

local function really_add(sh, line)
	if histmax(sh) == 0 and #M.list(sh) == 0 then -- (bash_add_history: HISTSIZE=0 keeps none)
		return
	end
	M.add_history(sh, line)
	sh.hist_session = (sh.hist_session or 0) + 1
	sh.hist_last_added = true
	sh.hist_pushed = false
end
M.really_add = really_add

-- readline's read_history_range over TEXT (a history file's contents): the entries after
-- the first FROM lines are added; returns the count of lines read (history_lines_read_from_
-- file). `#<digit>` lines (under the comment char, or when the file starts with one) are
-- timestamps for the next entry; with HISTTIMEFORMAT set, once a timestamped file was read
-- a line without one continues the previous entry (history_multiline_entries); CR-LF ends
-- are stripped, empty lines skipped, and an unterminated last line isn't read.
function M.read_text(sh, text, from)
	local cc = M.tscc(sh)
	if cc == "\0" and text:match("^#%d") then
		cc = "#"
	end
	local function isstamp(l)
		return l:sub(1, 1) == cc and l:sub(2, 2):match("%d") ~= nil
	end
	if isstamp(text) and sh.vars.HISTTIMEFORMAT then
		sh.hist_multiline = true
	end
	local cur, last_ts = 0, nil
	local pos, n = 1, #text
	-- (skip FROM lines, not counting timestamps)
	while cur < from and pos <= n do
		local e = text:find("\n", pos, true)
		if not e then
			pos = n + 1
			break
		end
		local l = text:sub(pos, e - 1)
		if isstamp(l) then
			last_ts = l
		else
			cur = cur + 1
			last_ts = nil
		end
		pos = e + 1
	end
	while pos <= n do
		local e = text:find("\n", pos, true)
		if not e then
			break
		end
		local l = text:sub(pos, e - 1)
		pos = e + 1
		if l:sub(-1) == "\r" then
			l = l:sub(1, -2)
		end
		if l ~= "" then
			if not isstamp(l) then
				local h = M.list(sh)
				if last_ts == nil and #h > 0 and sh.hist_multiline then
					h[#h] = h[#h] .. "\n" .. l
				else
					M.add_history(sh, l, cc .. os.time())
				end
				if last_ts then
					tslist(sh)[#h] = last_ts
					last_ts = nil
				end
			else
				last_ts = l
				cur = cur - 1
			end
		end
		cur = cur + 1
	end
	return cur
end

-- the history lines as a file holds them (history_do_write): each entry preceded by its
-- timestamp line when HISTTIMEFORMAT is set; entries FROM..#h
function M.file_text(sh, from)
	local h, t, o = M.list(sh), tslist(sh), {}
	local stamps = sh.vars.HISTTIMEFORMAT ~= nil
	for k = from or 1, #h do
		local ts = t[k]
		if stamps and ts and ts:sub(1, 1) ~= "\0" then
			o[#o + 1] = ts
		end
		o[#o + 1] = h[k]
	end
	o[#o + 1] = ""
	return #h >= (from or 1) and table.concat(o, "\n") or ""
end

-- the history file `history -a/-w/-r/-n` use: $HISTFILE, or readline's $HOME/.history
function M.filename(sh)
	if sh.vars.HISTFILE then
		return sh:get("HISTFILE") or ""
	end
	local home = sh.vars.HOME and sh:get("HOME") or ""
	return home .. "/.history"
end

-- HISTCONTROL: ignorespace / ignoredups / ignoreboth / erasedups
local function control(sh)
	local v = sh.vars.HISTCONTROL and sh:get("HISTCONTROL") or ""
	local c = {}
	for w in v:gmatch("[^:]+") do
		if w == "ignoreboth" then
			c.space, c.dups = true, true
		elseif w == "ignorespace" then
			c.space = true
		elseif w == "ignoredups" then
			c.dups = true
		elseif w == "erasedups" then
			c.erase = true
		end
	end
	return c
end

-- HISTIGNORE: `:`-separated patterns matched against the whole line; `&` is the previous
-- history line (bash's expand_histignore_pattern)
local function should_ignore(sh, line)
	local v = sh.vars.HISTIGNORE and sh:get("HISTIGNORE") or ""
	if v == "" then
		return false
	end
	local h = M.list(sh)
	local prev = h[#h]
	local pats, cur, i = {}, {}, 1
	while i <= #v do
		local c = v:sub(i, i)
		if c == "\\" and i < #v then
			cur[#cur + 1] = v:sub(i, i + 1)
			i = i + 2
		elseif c == ":" then
			pats[#pats + 1] = table.concat(cur)
			cur = {}
			i = i + 1
		else
			cur[#cur + 1] = c
			i = i + 1
		end
	end
	pats[#pats + 1] = table.concat(cur)
	for _, p in ipairs(pats) do
		if p ~= "" then
			if prev and p:find("&", 1, true) then
				p = p:gsub("\\?&", function(t)
					return #t == 2 and "&" or (prev:gsub("[%*%?%[%]\\]", "\\%0"))
				end)
			end
			if rt.glob_match(line, p) then
				return true
			end
		end
	end
	return false
end

-- bash's check_add_history: HISTCONTROL + HISTIGNORE, then add. True if it was saved.
function M.check_add(sh, line)
	local c = control(sh)
	local h = M.list(sh)
	if c.space and line:sub(1, 1) == " " then
		return false
	end
	if c.dups and h[#h] == line then
		return false
	end
	if should_ignore(sh, line) then
		return false
	end
	if c.erase then
		for k = #h, 1, -1 do
			if h[k] == line then
				M.remove(sh, k)
			end
		end
	end
	really_add(sh, line)
	return true
end

local function member(c, set)
	return c ~= "" and set:find(c, 1, true) ~= nil
end

-- Is LINE a shell comment? 1: the first non-blank is `#`; 2: a `#` comment follows text.
local function shell_comment(line)
	local p = line:match("^[ \t]*()")
	if line:sub(p, p) == "#" then
		return 1
	end
	local q, i = nil, 1
	while i <= #line do
		local ch = line:sub(i, i)
		if q then
			if ch == q then
				q = nil
			elseif ch == "\\" and q == '"' then
				i = i + 1
			end
		elseif ch == "\\" then
			i = i + 1
		elseif ch == "'" or ch == '"' or ch == "`" then
			q = ch
		elseif ch == "#" and (i == 1 or line:sub(i - 1, i - 1):match("[ \t;&|()<>]")) then
			return 2
		end
		i = i + 1
	end
	return 0
end

-- The text joining a multi-line command's next line onto its entry (parse.y's
-- history_delimiting_chars, from the previous line's last token).
local NO_SEMI = { ["{"] = 1, ["("] = 1, [";"] = 1, ["&"] = 1, ["|"] = 1, ["&&"] = 1, ["||"] = 1,
	[";;"] = 1, [";&"] = 1, [";;&"] = 1, case = 1, ["do"] = 1, ["else"] = 1, ["if"] = 1, ["then"] = 1,
	["until"] = 1, ["while"] = 1, ["in"] = 1, ["elif"] = 1, ["!"] = 1 }
local function delimiting_chars(prev, line)
	if line:match("^%s*$") then
		return ""
	end
	local t = prev:gsub("%s+$", "")
	if t == "" then
		return ""
	end
	if t:match("%(%s*%)$") then
		return " " -- `f()` then its body: a function definition
	end
	local op = t:match("([;&|]+)$")
	if op and NO_SEMI[op] then
		return " "
	end
	local last = t:match("([%w_!{(]+)$")
	if last and NO_SEMI[last] and (#t == #last or t:sub(-#last - 1, -#last - 1):match("[%s;&|()]")) then
		return " "
	end
	if t:sub(-1) == "{" or t:sub(-1) == "(" or t:sub(-1) == "|" then
		return " "
	end
	return "; "
end

-- The lexer state at the end of a line, carried in STK across a command's lines: bash's
-- dstack (an open '…', $'…', "…", `…`, $(…), <(…), >(…) or extglob @(…), whose newlines
-- go into the history literally) and PST_COMPASSIGN (inside `name=(…`, joined with a
-- space). "A" marks a compound assignment, "(" a paren nested inside one of these.
local QSTART = { ["'"] = 1, ['"'] = 1, ["`"] = 1 }
local function lex_scan(line, stk, extglob)
	local i, n = 1, #line
	while i <= n do
		local top, c = stk[#stk], line:sub(i, i)
		if top == "'" then
			if c == "'" then
				stk[#stk] = nil
			end
		elseif top == "$'" then
			if c == "\\" then
				i = i + 1
			elseif c == "'" then
				stk[#stk] = nil
			end
		elseif top == '"' or top == "`" then
			if c == "\\" then
				i = i + 1
			elseif c == top then
				stk[#stk] = nil
			elseif top == '"' and c == "`" then
				stk[#stk + 1] = "`"
			elseif top == '"' and c == "$" and line:sub(i + 1, i + 1) == "(" then
				stk[#stk + 1] = ")"
				i = i + 1
			end
		else -- (the top level, or inside $(…) / a compound assignment)
			local nx = line:sub(i + 1, i + 1)
			if c == "\\" then
				i = i + 1
			elseif c == "#" and (i == 1 or member(line:sub(i - 1, i - 1), " \t;&|()<>")) then
				break
			elseif QSTART[c] then
				stk[#stk + 1] = (c == "'" and line:sub(i - 1, i - 1) == "$") and "$'" or c
			elseif nx == "(" and (c == "$" or c == "<" or c == ">" or (extglob and member(c, "@?*+!"))) then
				stk[#stk + 1] = ")"
				i = i + 1
			elseif c == "(" then
				if top then
					stk[#stk + 1] = "("
				else
					local p = line:sub(1, i - 1):match("()[%a_][%w_]*%b[]%+?=$")
						or line:sub(1, i - 1):match("()[%a_][%w_]*%+?=$")
					if p and (p == 1 or member(line:sub(p - 1, p - 1), " \t;&|(")) then
						stk[#stk + 1] = "A"
					end
				end
			elseif c == ")" and top then
				stk[#stk] = nil
			end
		end
		i = i + 1
	end
end

-- bash's dstack.delimiter_depth != 0, and PST_COMPASSIGN, for the lexer state STK
local function lex_state(stk)
	local comp = false
	for k = 1, #stk do
		local e = stk[k]
		if e == "A" then
			comp = true
		elseif e ~= "(" then
			return true, false
		end
	end
	return false, comp
end

-- Recording, one physical line at a time (bash's maybe_add_history): ST is the state of
-- the command being read ({ count, first_saved, comment, heredoc_started, prev, stk }),
-- reset by the reader at each new command.
function M.read_line(sh, st, line, in_heredoc)
	sh.hist_last_added = false
	local h = M.list(sh)
	local isc = shell_comment(line)
	st.count = (st.count or 0) + 1
	if st.count > 1 then
		local delim, comp = lex_state(st.stk)
		local lit = sh.shopt.lithist == true
		if st.first_saved and (in_heredoc or lit or delim or isc ~= 1) and #h > 0 then
			if sh.shopt.cmdhist == false then -- (each physical line its own entry)
				really_add(sh, in_heredoc and line .. "\n" or line)
			else
				local cur = h[#h]
				local add
				if in_heredoc then
					add = st.heredoc_started and "" or "\n"
					st.heredoc_started = true
					line = line .. "\n"
				elseif st.comment == st.count - 1 or lit or delim then
					add = "\n"
				elseif comp then
					add = " "
				else
					add = delimiting_chars(st.prev or "", line)
				end
				if not delim and not in_heredoc and cur:sub(-1) == "\\" and cur:sub(-2, -2) ~= "\\" then
					cur = cur:sub(1, -2)
					add = ""
				end
				if not delim and cur:sub(-1) == "\n" and add:sub(1, 1) == ";" then
					add = add:sub(2)
				end
				-- (a joined line isn't "added": hist_last_line_added stays 0, so `fc`
				-- inside a multi-line compound sees the compound itself)
				h[#h] = cur .. add .. line
			end
		end
		st.comment = isc ~= 0 and st.count or -2
		if not in_heredoc then
			st.prev = line
			lex_scan(line, st.stk, sh.shopt.extglob)
		end
		return
	end
	st.comment = isc ~= 0 and st.count or -2
	st.prev = line
	st.stk = {}
	lex_scan(line, st.stk, sh.shopt.extglob)
	st.first_saved = M.check_add(sh, line)
	sh.hist_first_saved = st.first_saved -- (current_command_first_line_saved)
end

-- Delete the last entry (`history -s` / `-p` drop the line that ran them, bash).
function M.delete_last(sh)
	local h = M.list(sh)
	if #h > 0 then
		M.delete_histent(sh, #h)
	end
end

-- bash_delete_histent: remove entry K, one less line this session
function M.delete_histent(sh, k)
	M.remove(sh, k)
	sh.hist_session = (sh.hist_session or 0) - 1
end

-- load_history (bash, at `set -o history` before any line was added): default HISTSIZE
-- and HISTFILESIZE, then read $HISTFILE.
function M.load(sh)
	if (sh.hist_session or 0) > 0 then
		return
	end
	if sh.vars.HISTSIZE == nil then
		sh:set_str("HISTSIZE", "500")
	end
	if sh.vars.HISTFILESIZE == nil then
		sh:set_str("HISTFILESIZE", sh:get("HISTSIZE"))
	end
	local hf = sh.vars.HISTFILE and sh:get("HISTFILE") or ""
	if hf ~= "" then
		local f = io.open(hf, "r")
		if f then
			local text = f:read("*a") or ""
			f:close()
			sh.hist_file_lines = M.read_text(sh, text, 0)
		end
	end
end

-- ---- tokenizing (history_tokenize) ------------------------------------------------
local WORD_DELIMS = " \t\n;&()|<>"
local QUOTES = "\"'`"
local SLASHIFY = "\\\"$`\n"

local function tokenize_word(s, i) -- 1-based start; returns the index just past the word
	local n = #s
	local delimiter, nestdelim, delimopen = nil, 0, nil
	local c = s:sub(i, i)
	if member(c, "()\n") then
		return i + 1
	end
	local goto_word = false
	if c:match("%d") then
		local j = i
		while j <= n and s:sub(j, j):match("%d") do
			j = j + 1
		end
		if j > n then
			return j
		end
		local cj = s:sub(j, j)
		if cj == "<" or cj == ">" then
			i = j
		else
			i = j
			goto_word = true
		end
	end
	c = s:sub(i, i)
	if not goto_word and member(c, "<>;&|") then
		local peek = s:sub(i + 1, i + 1)
		if peek == c then
			if peek == "<" and s:sub(i + 2, i + 2) == "-" then
				i = i + 1
			elseif peek == "<" and s:sub(i + 2, i + 2) == "<" then
				i = i + 1
			end
			return i + 2
		elseif peek == "&" and (c == ">" or c == "<") then
			local j = i + 2
			while j <= n and s:sub(j, j):match("%d") do
				j = j + 1
			end
			if s:sub(j, j) == "-" then
				j = j + 1
			end
			return j
		elseif (peek == ">" and c == "&") or (peek == "|" and c == ">") then
			return i + 2
		elseif peek == "(" and (c == ">" or c == "<") then
			i = i + 2
			delimopen, delimiter, nestdelim = "(", ")", 1
			goto_word = true
		else
			return i + 1
		end
	end
	if not delimiter and member(s:sub(i, i), QUOTES) then
		delimiter = s:sub(i, i)
		i = i + 1
	end
	while i <= n do
		local ch = s:sub(i, i)
		if ch == "\\" and s:sub(i + 1, i + 1) == "\n" then
			i = i + 2
		elseif ch == "\\" and delimiter ~= "'" and (delimiter ~= '"' or member(ch, SLASHIFY)) then
			i = i + 2
		elseif nestdelim > 0 and ch == delimopen then
			nestdelim = nestdelim + 1
			i = i + 1
		elseif nestdelim > 0 and ch == delimiter then
			nestdelim = nestdelim - 1
			if nestdelim == 0 then
				delimiter = nil
			end
			i = i + 1
		elseif delimiter and ch == delimiter then
			delimiter = nil
			i = i + 1
		elseif nestdelim == 0 and not delimiter and member(ch, "<>$!@?+*") and s:sub(i + 1, i + 1) == "(" then
			i = i + 2
			delimopen, delimiter, nestdelim = "(", ")", 1
		elseif not delimiter and member(ch, WORD_DELIMS) then
			break
		else
			if not delimiter and member(ch, QUOTES) then
				delimiter = ch
			end
			i = i + 1
		end
	end
	return i
end

-- the words of a history line; with WIND, also the index of the word containing it
local function tokenize(s, wind, comment)
	local out, idx = {}, nil
	local i, n = 1, #s
	while i <= n do
		while i <= n and member(s:sub(i, i), " \t\n") do
			i = i + 1
		end
		if i > n or (comment and s:sub(i, i) == comment) then
			break
		end
		local start = i
		i = tokenize_word(s, start)
		if i == start then
			i = i + 1
			while i <= n and member(s:sub(i, i), WORD_DELIMS) do
				i = i + 1
			end
		end
		if wind and wind >= start and wind < i then
			idx = #out + 1
		end
		out[#out + 1] = s:sub(start, i - 1)
	end
	return out, idx
end
M.tokenize = tokenize

-- words FIRST..LAST of STRING, space-joined (history_arg_extract); `$` is the last
local function arg_extract(first, last, s, comment)
	local list = tokenize(s, nil, comment)
	local len = #list
	if last == "$" then
		last = len - 1
	elseif last < 0 then
		last = len + last - 1
	end
	if first == "$" then
		first = len - 1
	elseif first < 0 then
		first = len + first - 1
	end
	last = last + 1
	if first >= len or last > len or first < 0 or last < 0 or first > last then
		return nil
	end
	local r = {}
	for k = first + 1, last do
		r[#r + 1] = list[k]
	end
	return table.concat(r, " ")
end

-- ---- expansion (history_expand) ----------------------------------------------------
local ERR = {
	event = "event not found", word = "bad word specifier", subst = "substitution failed",
	modifier = "unrecognized history modifier", noprev = "no previous substitution",
}
local function herror(s, from, to, kind) -- `TEXT: message`, TEXT = s[from..to-1]
	return s:sub(from, to - 1) .. ": " .. ERR[kind]
end

-- The single-quoted run starting after the opening quote at I: index of the closing quote
local function skip_single(s, i, dollar)
	local n = #s
	while i <= n and s:sub(i, i) ~= "'" do
		if dollar and s:sub(i, i) == "\\" and i < n then
			i = i + 1
		end
		i = i + 1
	end
	return i
end

-- bash's skip_to_histexp (subst.c): the index of the first history-expansion char at or
-- after START that isn't quoted or inside a command/process substitution, else the end.
local function skip_to_histexp(s, start, hx, posix)
	local i, n = start, #s
	local pass_next, backq, dquote = false, false, false
	local comsub, old_dquote = 0, false
	while i <= n do
		local c = s:sub(i, i)
		if pass_next then
			pass_next = false
			i = i + 1
		elseif c == "\\" then
			pass_next = true
			i = i + 1
		elseif backq and c == "`" then
			backq = false
			dquote = old_dquote
			i = i + 1
		elseif c == "`" then
			backq = true
			old_dquote = dquote
			dquote = false
			i = i + 1
		elseif dquote and c == hx and s:sub(i + 1, i + 1) == '"' then
			i = i + 1
		elseif c == hx then
			return i
		elseif dquote and c == "'" then
			i = i + 1
		elseif c == "'" then
			i = skip_single(s, i + 1, false) + 1
		elseif not posix and c == '"' then
			dquote = not dquote
			i = i + 1
		elseif c == '"' then -- (posix: a double-quoted string is skipped whole)
			i = i + 1
			while i <= n and s:sub(i, i) ~= '"' do
				if s:sub(i, i) == "\\" then
					i = i + 1
				end
				i = i + 1
			end
			i = i + 1
		elseif (c == "$" or c == "<" or c == ">") and s:sub(i + 1, i + 1) == "(" and s:sub(i + 2, i + 2) ~= "(" then
			if i + 2 > n then
				return i + 2
			end
			i = i + 2
			comsub = comsub + 1
			old_dquote = dquote
			dquote = false
		elseif comsub > 0 and c == ")" then
			comsub = comsub - 1
			dquote = old_dquote
			i = i + 1
		else
			i = i + 1
		end
	end
	return n + 1 -- (none: the end of the string, as bash's CQ_RETURN(i))
end

-- bash_history_inhibit_expansion: `!` inside [...], ${!…}, $!, extglob !(…), or where
-- skip_to_histexp says it's quoted/substituted, is not an expansion.
local function inhibit(sh, s, i, hx)
	if i > 1 and s:sub(i - 1, i - 1) == "[" and s:find("]", i + 1, true) then
		return true
	elseif i > 2 and s:sub(i - 1, i - 1) == "{" and s:sub(i - 2, i - 2) == "$" and s:find("}", i + 1, true) then
		return true
	elseif i > 1 and s:sub(i - 1, i - 1) == "$" then
		return true
	elseif sh.shopt.extglob and i > 2 and s:sub(i + 1, i + 1) == "(" and s:find(")", i + 2, true) then
		return true
	end
	local t = skip_to_histexp(s, 1, hx, sh.opt_posix)
	if t > 0 then
		while t < i do
			t = skip_to_histexp(s, t + 1, hx, sh.opt_posix)
			if t <= 0 then
				return false
			end
		end
		return t > i
	end
	return false
end

-- search the list backwards for STR (anywhere, or as a prefix); returns entry, offset
local function search(sh, str, anywhere)
	if str == "" then -- (history_search_internal: an empty string is never found — `!;`)
		return nil
	end
	local h = M.list(sh)
	for k = #h, 1, -1 do
		local e = h[k]
		local p -- (a substring search scans each line from its END, as readline's does)
		if anywhere then
			local q = e:find(str, 1, true)
			while q do
				p = q
				q = e:find(str, q + 1, true)
			end
		elseif e:sub(1, #str) == str then
			p = 1
		end
		if p then
			return e, p
		end
	end
end

-- get_history_event: the line an event spec at S[I] (the expansion char) names.
local function get_event(sh, s, i, qc)
	local h = M.list(sh)
	local hx = M.chars(sh)
	i = i + 1
	local c = s:sub(i, i)
	if c == hx then
		return h[#h], i + 1
	end
	local sign = 1
	if c == "-" and s:sub(i + 1, i + 1):match("%d") then
		sign = -1
		i = i + 1
	end
	if s:sub(i, i):match("%d") then
		local d = s:match("^%d+", i)
		i = i + #d
		local which = tonumber(d)
		local base = sh.hist_base or 1
		if sign < 0 then
			which = (#h + base) - which
		end
		return h[which - base + 1], i
	end
	local substring = false
	if s:sub(i, i) == "?" then
		substring = true
		i = i + 1
	end
	local from = i
	while i <= #s do
		local ch = s:sub(i, i)
		if (not substring and (ch:match("[ \t]") or ch == ":" or (i > from and ch == "-")
			or (ch ~= "-" and member(ch, "^$*%-")) or member(ch, ";&()|<>") or (qc and ch == qc)))
			or ch == "\n" or (substring and ch == "?") then
			break
		end
		i = i + 1
	end
	local str = s:sub(from, i - 1)
	if substring and s:sub(i, i) == "?" then
		i = i + 1
	end
	if str == "" and substring then
		if not sh.hist_search then
			return nil, i
		end
		str = sh.hist_search
	end
	local e, off = search(sh, str, substring)
	if not e then
		return nil, i
	end
	if substring then
		sh.hist_search = str
		local _, idx = tokenize(e, off)
		local words = tokenize(e)
		sh.hist_match = idx and words[idx] or nil
	end
	return e, i
end

-- get_history_word_specifier: returns text (or nil = none, false = error), next index
local function word_spec(sh, s, from, i)
	local _, _, cc = M.chars(sh)
	local i0 = i
	local expecting = false
	if s:sub(i, i) == ":" then
		i = i + 1
		expecting = true
	end
	local c = s:sub(i, i)
	if c == "%" then
		return sh.hist_match or "", i + 1
	elseif c == "*" then
		return arg_extract(1, "$", from, cc) or "", i + 1
	elseif c == "$" then
		return arg_extract("$", "$", from, cc), i + 1 -- (none: the whole event, as bash)
	end
	local first, last
	if c == "-" then
		first = 0
	elseif c == "^" then
		first = 1
		i = i + 1
	elseif c:match("%d") and expecting then
		local d = s:match("^%d+", i)
		first = tonumber(d)
		i = i + #d
	else
		return nil, i0 -- (no word spec: a `:` here starts the modifiers)
	end
	c = s:sub(i, i)
	if c == "^" or c == "*" then
		last = c == "^" and 1 or "$"
		i = i + 1
	elseif c ~= "-" then
		last = first
	else
		i = i + 1
		c = s:sub(i, i)
		if c:match("%d") then
			local d = s:match("^%d+", i)
			last = tonumber(d)
			i = i + #d
		elseif c == "$" then
			i = i + 1
			last = "$"
		elseif c == "^" then
			i = i + 1
			last = 1
		else
			last = -1 -- `x-` abbreviates x-$ without the last word
		end
	end
	local r
	if last == "$" or last < 0 or last >= first then
		r = arg_extract(first, last, from, cc)
	end
	if r == nil then
		return false, i
	end
	return r, i
end

local function quote_breaks(s)
	local o = { "'" }
	for k = 1, #s do
		local ch = s:sub(k, k)
		if ch == "'" then
			o[#o + 1] = "'\\''"
		elseif ch:match("[ \t\n]") then
			o[#o + 1] = "'" .. ch .. "'"
		else
			o[#o + 1] = ch
		end
	end
	o[#o + 1] = "'"
	return table.concat(o)
end
local function single_quote(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- the delimited `:s` pattern at I: text (nil if empty and not rhs), next index
local function subst_pattern(s, i, delim, is_rhs)
	local j = i
	while j <= #s and s:sub(j, j) ~= delim do
		if s:sub(j, j) == "\\" and s:sub(j + 1, j + 1) == delim then
			j = j + 1
		end
		j = j + 1
	end
	local r
	if j > i or is_rhs then
		r = s:sub(i, j - 1):gsub("\\" .. delim:gsub("%p", "%%%0"), delim)
	end
	if j <= #s then
		j = j + 1
	end
	return r, j
end

-- history_expand_internal: expand the spec at S[START]; returns code (-1 error, 0 ok,
-- 1 print-only), text, next index
local function expand_one(sh, s, start, qc, current)
	local event, i
	local c1 = s:sub(start + 1, start + 1)
	if member(c1, ":$*%^") then
		local h = M.list(sh)
		event, i = h[#h], start + 1
	elseif c1 == "#" then
		event, i = current, start + 2
	else
		event, i = get_event(sh, s, start, qc)
	end
	if event == nil then
		return -1, herror(s, start, i, "event")
	end
	local si = i
	local ws
	ws, i = word_spec(sh, s, event, i)
	if ws == false then
		return -1, herror(s, si, i, "word")
	end
	local temp = ws or event
	local want_quotes, print_only = nil, false
	si = i
	while s:sub(i, i) == ":" do
		local c = s:sub(i + 1, i + 1)
		local global, bywords = false, false
		if c == "g" or c == "a" then
			global = true
			i = i + 1
			c = s:sub(i + 1, i + 1)
		elseif c == "G" then
			bywords = true
			i = i + 1
			c = s:sub(i + 1, i + 1)
		end
		local advanced = false
		if c == "q" then
			want_quotes = "q"
		elseif c == "x" then
			want_quotes = "x"
		elseif c == "p" then
			print_only = true
		elseif c == "t" then
			temp = temp:match("([^/]*)$")
		elseif c == "h" then
			local p = temp:match(".*()/")
			if p then
				temp = temp:sub(1, p - 1)
			end
		elseif c == "r" then
			local p = temp:match(".*()%.")
			if p then
				temp = temp:sub(1, p - 1)
			end
		elseif c == "e" then
			local p = temp:match(".*()%.")
			if p then
				temp = temp:sub(p)
			end
		elseif c == "s" or c == "&" then
			if c == "s" then
				if i + 2 > #s then
					break
				end
				local delim = s:sub(i + 2, i + 2)
				i = i + 3
				local lhs, rhs
				lhs, i = subst_pattern(s, i, delim, false)
				if lhs then
					sh.hist_lhs = lhs
				elseif not sh.hist_lhs then
					sh.hist_lhs = (sh.hist_search and sh.hist_search ~= "") and sh.hist_search or nil
				end
				rhs, i = subst_pattern(s, i, delim, true)
				if rhs:find("&", 1, true) then
					local lhsv = sh.hist_lhs or ""
					rhs = rhs:gsub("\\?&", function(t)
						return #t == 2 and "&" or lhsv
					end)
				end
				sh.hist_rhs = rhs
			else
				i = i + 2
			end
			advanced = true
			local lhs, rhs = sh.hist_lhs, sh.hist_rhs or ""
			if not lhs or lhs == "" then
				return -1, herror(s, si, i, "noprev")
			end
			if #lhs > #temp then
				return -1, herror(s, si, i, "subst")
			end
			local failed, p, we = true, 1, 0
			while p + #lhs - 1 <= #temp do
				if bywords and p > we then
					while p <= #temp and temp:sub(p, p):match("[ \t\n]") do
						p = p + 1
					end
					we = tokenize_word(temp, p)
				end
				if temp:sub(p, p + #lhs - 1) == lhs then
					temp = temp:sub(1, p - 1) .. rhs .. temp:sub(p + #lhs)
					failed = false
					if global then
						p = p + #rhs
					elseif bywords then
						p = we + (#rhs - #lhs)
						we = p - 1
					else
						break
					end
				else
					p = p + 1
				end
			end
			if failed then
				return -1, herror(s, si, i, "subst")
			end
		else
			return -1, herror(s, i + 1, i + 2, "modifier")
		end
		if not advanced then
			i = i + 2
		end
	end
	if want_quotes == "q" then
		temp = single_quote(temp)
	elseif want_quotes == "x" then
		temp = quote_breaks(temp)
	end
	return print_only and 1 or 0, temp, i
end

-- history_expand: returns code, text. code: -1 error (text = message), 0 no expansion,
-- 1 expanded, 2 expanded with :p (print, don't run).
function M.expand(sh, hstring)
	local hx, subc, comc = M.chars(sh)
	if not hx then
		return 0, hstring
	end
	local s = hstring
	if subc and s:sub(1, 1) == subc then
		s = hx .. hx .. ":s" .. s
	else
		-- a quick scan: is there an expansion at all?
		local i, n, dquote = 1, #s, false
		local found = false
		while i <= n do
			local c, cc = s:sub(i, i), s:sub(i + 1, i + 1)
			if comc and c == comc and not dquote and (i == 1 or member(s:sub(i - 1, i - 1), WORD_DELIMS)) then
				break
			elseif c == hx then
				if cc == "" or member(cc, " \t\n\r=") or (dquote and cc == '"') or inhibit(sh, s, i, hx) then
					-- not an expansion
				else
					found = true
					break
				end
			elseif dquote and c == "\\" and cc == '"' then
				i = i + 1
			elseif c == '"' then
				dquote = not dquote
			elseif not dquote and c == "'" then
				local dollar = i > 1 and s:sub(i - 1, i - 1) == "$"
				i = skip_single(s, i + 1, dollar)
			elseif c == "\\" then
				if cc == "'" or cc == hx then
					i = i + 1
				end
			end
			i = i + 1
		end
		if not found then
			return 0, hstring
		end
	end
	local out, i, n = {}, 1, #s
	local dquote, passc, modified, printing = false, false, 0, false
	while i <= n do
		local c = s:sub(i, i)
		if passc then
			passc = false
			out[#out + 1] = c
		elseif c == "\\" then
			passc = true
			out[#out + 1] = c
		elseif c == '"' then
			dquote = not dquote
			out[#out + 1] = c
		elseif c == "'" and not dquote then
			local dollar = i > 1 and s:sub(i - 1, i - 1) == "$"
			local q = i
			i = skip_single(s, i + 1, dollar)
			out[#out + 1] = s:sub(q, i)
		elseif comc and c == comc and not dquote and (i == 1 or member(s:sub(i - 1, i - 1), WORD_DELIMS)) then
			out[#out + 1] = s:sub(i)
			i = n
		elseif c == hx then
			local cc = s:sub(i + 1, i + 1)
			local cur = table.concat(out)
			if cc == "" or member(cc, " \t\n\r=") or (dquote and cc == '"')
				or inhibit(sh, cur .. c .. cc, #cur + 1, hx) then
				out[#out + 1] = c
			else
				local code, text, ni = expand_one(sh, s, i, dquote and '"' or nil, cur)
				if code < 0 then
					return -1, text
				end
				modified = modified + 1
				out[#out + 1] = text
				printing = printing or code == 1
				i = ni - 1
			end
		else
			out[#out + 1] = c
		end
		i = i + 1
	end
	local res = table.concat(out)
	if printing then
		return 2, res
	end
	return modified > 0 and 1 or 0, res
end

return M
