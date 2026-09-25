-- smatch: a faithful port of bash's pattern matcher (lib/glob/sm_loop.c GMATCH /
-- BRACKMATCH / EXTMATCH / PATSCAN, smatch.c's charcmp/rangecmp/collequiv/is_cclass),
-- run over arrays of character codes (wide chars in a multibyte locale, else bytes).
-- The runtime matches most globs through one cached POSIX ERE (glob_conv); what an ERE
-- can't express goes here: `!(…)` negation, collation-ordered ranges (globasciiranges
-- off / non-ASCII endpoints), [=c=] equivalence, char classes under case folding,
-- trailing-backslash quirks, FNM_PATHNAME matching (GLOBIGNORE), and a multibyte
-- locale whose trail bytes can be `\` (Big5-HKSCS). Loaded lazily (rt.sm_match).
local ffi = require("ffi")
local bit = require("bit")
local rt = require("runtime")
local band, bnot = bit.band, bit.bnot
local C = ffi.C
ffi.cdef([[
	unsigned long curse_sm_wctype(const char *name) asm("wctype");
	int curse_sm_iswctype(uint32_t wc, unsigned long desc) asm("iswctype");
	int curse_sm_iswupper(uint32_t wc) asm("iswupper");
	uint32_t curse_sm_towlower(uint32_t wc) asm("towlower");
	int curse_sm_wcscoll(const int32_t *a, const int32_t *b) asm("wcscoll");
]])

local S = {}
-- bash's FNM_* flags (lib/glob/strmatch.h)
S.PATHNAME, S.NOESCAPE, S.PERIOD, S.LEADING_DIR, S.CASEFOLD, S.EXTMATCH, S.DOTDOT = 1, 2, 4, 8, 16, 32, 128
local PATHNAME, NOESCAPE, PERIOD, LEADING_DIR, CASEFOLD, EXTMATCH, DOTDOT = 1, 2, 4, 8, 16, 32, 128
local NOTPD = bnot(PERIOD + DOTDOT)
local INVALID = -1
local SLASH, DOT, BSL, LBR, RBR, LP, RP, BAR = 47, 46, 92, 91, 93, 40, 41, 124
local STAR, QM, PLUS, AT, BANG, CARET, DASH, COLON, EQ = 42, 63, 43, 64, 33, 94, 45, 58, 61

local P, Pn, Sa, Sn -- the pattern / string code arrays of the match in progress
local function pg(i) -- *p (0 past the end, like the C string's NUL)
	return (i <= Pn and P[i]) or 0
end
local function sg(i)
	return (i >= 1 and i <= Sn and Sa[i]) or 0
end

local mb = false -- decoding a multibyte locale (wide-char matcher)
local wa, wb = ffi.new("int32_t[2]"), ffi.new("int32_t[2]")
-- charcmp: rt.glob_asciirange (shopt globasciiranges) compares code points, else collation
local function charcmp(c1, c2, forcecoll)
	if c1 == c2 then
		return 0
	end
	if not forcecoll and rt.glob_asciirange and (not mb or (c1 <= 255 and c2 <= 255)) then
		return c1 - c2
	end
	wa[0], wb[0] = c1, c2
	return C.curse_sm_wcscoll(wa, wb)
end
local function rangecmp(c1, c2, forcecoll)
	local r = charcmp(c1, c2, forcecoll)
	if r ~= 0 or forcecoll then
		return r
	end
	return c1 - c2 -- (a total ordering)
end
local function collequiv(c, equiv)
	return charcmp(c, equiv, true) == 0
end
local function fold(c, flags)
	if band(flags, CASEFOLD) ~= 0 and c > 0 and C.curse_sm_iswupper(c) ~= 0 then
		return C.curse_sm_towlower(c)
	end
	return c
end
local wctypes = {}
local function is_cclass(c, name) -- 1/0, or -1 for an unknown class name
	if name == "ascii" then
		return c <= 0x7F and 1 or 0
	end
	local word = name == "word"
	if word then
		name = "alnum"
	end
	local d = wctypes[name]
	if d == nil then
		d = C.curse_sm_wctype(name)
		wctypes[name] = d
	end
	if d == 0 then
		return -1
	end
	if C.curse_sm_iswctype(c, d) ~= 0 or (word and c == 95) then
		return 1
	end
	return 0
end
local function sdot(s) -- SDOT_OR_DOTDOT
	return sg(s) == DOT and (sg(s + 1) == 0 or (sg(s + 1) == DOT and sg(s + 2) == 0))
end
local function pathsep(c)
	return c == SLASH or c == 0
end
local function pdot(s) -- PDOT_OR_DOTDOT
	return sg(s) == DOT and (pathsep(sg(s + 1)) or (sg(s + 1) == DOT and pathsep(sg(s + 2))))
end

local function collsym(p, len)
	if len == 1 then
		return pg(p)
	end
	local t = {}
	for k = p, p + len - 1 do
		local c = pg(k)
		if c > 127 then
			return INVALID
		end
		t[#t + 1] = string.char(c)
	end
	local ch = rt.COLLSYM[table.concat(t)]
	return ch and ch:byte() or INVALID
end
local function parse_collsym(p) -- p at the `.` of `[.`; returns the new p and the value
	p = p + 1
	local pc = 0
	while pg(p + pc) ~= 0 and not (pg(p + pc) == DOT and pg(p + pc + 1) == RBR) do
		pc = pc + 1
	end
	if pg(p + pc) == 0 then
		return p + pc, INVALID
	end
	return p + pc + 2, collsym(p, pc)
end

-- BRACKMATCH: p is just past the `[`; the index past the closing `]` on a match, else nil
local function brackmatch(p, test, flags)
	local orig_test = test
	test = fold(orig_test, flags)
	local savep = p
	local nt = pg(p) == BANG or pg(p) == CARET
	if nt then
		p = p + 1
	end
	local c = pg(p)
	p = p + 1
	local cstart, cend, forcecoll, isrange, pc
	local matched = false
	while true do
		cstart, cend, forcecoll = c, c, false
		if c == LBR and pg(p) == EQ and pg(p + 2) == EQ and pg(p + 3) == RBR then -- [=c=]
			pc = fold(pg(p + 1), flags)
			p = p + 4
			if collequiv(test, pc) then
				p = p + 1
				matched = true
				break
			end
			c = pg(p)
			p = p + 1
			if c == 0 then
				return test == LBR and savep or nil
			end
			c = fold(c, flags)
			goto continue
		end
		if c == LBR and pg(p) == COLON then -- [:class:]
			pc = 0
			local close = p + 1
			while pg(close) ~= 0 and not (pg(close) == COLON and pg(close + 1) == RBR) do
				close = close + 1
			end
			if pg(close) ~= 0 then
				local t = {}
				for k = p + 1, close - 1 do
					local ch = pg(k)
					if ch ~= BSL then -- (DEQUOTE_PATHNAME)
						t[#t + 1] = ch < 256 and string.char(ch) or "?"
					end
				end
				pc = is_cclass(orig_test, table.concat(t))
				if pc == -1 then
					pc = 0
				end
				p = close + 2
			end
			if pc ~= 0 then
				p = p + 1
				matched = true
				break
			end
			c = pg(p)
			p = p + 1
			if c == 0 then
				return test == LBR and savep or nil
			elseif c == RBR then
				break
			end
			c = fold(c, flags)
			goto continue
		end
		if c == LBR and pg(p) == DOT then -- [.sym.]
			p, pc = parse_collsym(p)
			cstart = (pc == INVALID) and test + 1 or pc
			forcecoll = true
		end
		if band(flags, NOESCAPE) == 0 and c == BSL then
			if pg(p) == 0 then
				return nil
			end
			cstart = pg(p)
			p = p + 1
		end
		cstart = fold(cstart, flags)
		cend = cstart
		isrange = false
		if c == 0 then
			return test == LBR and savep or nil
		end
		c = fold(pg(p), flags)
		p = p + 1
		if c == 0 then
			return test == LBR and savep or nil
		end
		if band(flags, PATHNAME) ~= 0 and c == SLASH then
			return nil -- ([/] never matches a pathname)
		end
		if c == DASH and pg(p) ~= RBR then -- a range
			cend = pg(p)
			p = p + 1
			if band(flags, NOESCAPE) == 0 and cend == BSL then
				cend = pg(p)
				p = p + 1
			end
			if cend == 0 then
				return nil
			end
			if cend == LBR and pg(p) == DOT then
				p, pc = parse_collsym(p)
				cend = (pc == INVALID) and test - 1 or pc
				forcecoll = true
			end
			cend = fold(cend, flags)
			c = pg(p)
			p = p + 1
			if rangecmp(cstart, cend, forcecoll) > 0 then -- (an invalid range matches nothing)
				if c == RBR then
					break
				end
				c = fold(c, flags)
				goto continue
			end
			isrange = true
		end
		if not isrange and test == cstart then
			matched = true
			break
		end
		if isrange and rangecmp(test, cstart, forcecoll) >= 0 and rangecmp(test, cend, forcecoll) <= 0 then
			matched = true
			break
		end
		if c == RBR then
			break
		end
		::continue::
	end
	if not matched then
		if nt then
			return p
		end
		return nil
	end
	-- skip the rest of the [...] that already matched
	p = p - 1
	c = pg(p)
	local brcnt, brchrp = 1, nil
	while brcnt > 0 do
		if c == 0 then -- (a `[` without a matching `]` is just another character)
			return test == LBR and savep or nil
		end
		local oc = c
		c = pg(p)
		p = p + 1
		if c == LBR and (pg(p) == EQ or pg(p) == COLON or pg(p) == DOT) then
			brcnt = brcnt + 1
			brchrp = p
			p = p + 1
			c = pg(p)
			if c == 0 then
				return test == LBR and savep or nil
			end
		elseif c == RBR and brcnt > 1 and brchrp and oc == pg(brchrp) then
			brcnt = brcnt - 1
			brchrp = nil
		elseif c == RBR and (brchrp == nil or pg(brchrp) ~= DOT) and brcnt >= 1 then
			brcnt = 0
		elseif band(flags, NOESCAPE) == 0 and c == BSL then
			if pg(p) == 0 then
				return nil
			end
			p = p + 1
		end
	end
	return (not nt) and p or nil
end

-- PATSCAN: from i, the index just past the `)` closing the group (delim 0) or past the
-- next top-level `|` (delim BAR); nil if the pattern is empty or unterminated
local function patscan(i, e, delim)
	local pnest, bnest, skip, cchar, bfirst = 0, 0, false, 0, nil
	if i == e then
		return nil
	end
	local s = i
	while true do
		local c = pg(s)
		if c == 0 then
			return nil
		end
		if s >= e then
			return s
		end
		if skip then
			skip = false
		elseif c == BSL then
			skip = true
		elseif c == LBR then
			if bnest == 0 then
				bfirst = s + 1
				if pg(bfirst) == BANG or pg(bfirst) == CARET then
					bfirst = bfirst + 1
				end
				bnest = bnest + 1
			elseif pg(s + 1) == COLON or pg(s + 1) == DOT or pg(s + 1) == EQ then
				cchar = pg(s + 1)
			end
		elseif c == RBR then
			if bnest > 0 then
				if cchar ~= 0 and pg(s - 1) == cchar then
					cchar = 0
				elseif s ~= bfirst then
					bnest = bnest - 1
					bfirst = nil
				end
			end
		elseif c == LP then
			if bnest == 0 then
				pnest = pnest + 1
			end
		elseif c == RP then
			if bnest == 0 then
				pnest = pnest - 1
				if pnest < 0 then
					return s + 1
				end
			end
		elseif c == BAR then
			if bnest == 0 and pnest == 0 and delim == BAR then
				return s + 1
			end
		end
		s = s + 1
	end
end

local gmatch
local function strcompare(p, pe, s, se)
	if pe - p ~= se - s then
		return false
	end
	for k = 0, pe - p - 1 do
		if pg(p + k) ~= sg(s + k) then
			return false
		end
	end
	return true
end
local function extmatch(xc, s, se, p, pe, flags)
	local prest = patscan(p + (pg(p) == LP and 1 or 0), pe, 0)
	if not prest then -- (not a valid group: compare as plain strings)
		return strcompare(p - 1, pe, s, se)
	end
	local psub, pnext, xflags
	if xc == PLUS or xc == STAR then
		if xc == STAR and gmatch(s, se, prest, pe, false, flags) then
			return true
		end
		psub = p + 1
		while true do
			pnext = patscan(psub, pe, BAR)
			if not pnext then
				return false
			end
			for srest = s, se do
				if gmatch(s, srest, psub, pnext - 1, false, flags) then
					xflags = srest > s and band(flags, NOTPD) or flags
					if gmatch(srest, se, prest, pe, false, xflags)
						or (s ~= srest and gmatch(srest, se, p - 1, pe, false, xflags)) then
						return true
					end
				end
			end
			if pnext == prest then
				break
			end
			psub = pnext
		end
		return false
	elseif xc == QM or xc == AT then
		if xc == QM and gmatch(s, se, prest, pe, false, flags) then
			return true
		end
		psub = p + 1
		while true do
			pnext = patscan(psub, pe, BAR)
			if not pnext then
				return false
			end
			for srest = (prest == pe) and se or s, se do
				xflags = srest > s and band(flags, NOTPD) or flags
				if gmatch(s, srest, psub, pnext - 1, false, flags) and gmatch(srest, se, prest, pe, false, xflags) then
					return true
				end
			end
			if pnext == prest then
				break
			end
			psub = pnext
		end
		return false
	elseif xc == BANG then
		for srest = s, se do
			local m1 = false
			psub = p + 1
			while true do
				pnext = patscan(psub, pe, BAR)
				if not pnext then
					break
				end
				m1 = gmatch(s, srest, psub, pnext - 1, false, flags)
				if m1 or pnext == prest then
					break
				end
				psub = pnext
			end
			-- nothing matched, but a leading `.` must still be matched explicitly
			if not m1 and band(flags, PERIOD) ~= 0 and sg(s) == DOT then
				return false
			end
			if not m1 and band(flags, DOTDOT) ~= 0
				and (sdot(s) or (band(flags, PATHNAME) ~= 0 and sg(s - 1) == SLASH and pdot(s))) then
				return false
			end
			xflags = srest > s and band(flags, NOTPD) or flags
			if not m1 and gmatch(srest, se, prest, pe, false, xflags) then
				return true
			end
		end
		return false
	end
	return false
end

local function isextop(c)
	return c == PLUS or c == STAR or c == QM or c == AT or c == BANG
end
-- GMATCH: does the string [n, se) match the pattern [p, pe)? With `ends`, a `*` stops
-- the match and reports where (true, pattern index, string index): glibc's trick to
-- avoid backtracking to an earlier `*`.
gmatch = function(n, se, p, pe, ends, flags)
	local string0 = n
	local c, sc
	while p < pe do
		c = fold(pg(p), flags)
		p = p + 1
		sc = n < se and sg(n) or 0
		if band(flags, EXTMATCH) ~= 0 and pg(p) == LP and isextop(c) then
			-- (past the string's start, a leading `.` needs no explicit match)
			return extmatch(c, n, se, p, pe, n == string0 and flags or band(flags, NOTPD))
		end
		if c == QM then
			if sc == 0 then
				return false
			elseif band(flags, PATHNAME) ~= 0 and sc == SLASH then
				return false
			elseif band(flags, PERIOD) ~= 0 and sc == DOT
				and (n == string0 or (band(flags, PATHNAME) ~= 0 and sg(n - 1) == SLASH)) then
				return false
			end
			if band(flags, DOTDOT) ~= 0 and ((n == string0 and sdot(n))
				or (band(flags, PATHNAME) ~= 0 and sg(n - 1) == SLASH and pdot(n))) then
				return false
			end
		elseif c == BSL then
			if p == pe and sc == BSL and n + 1 == se then
				-- (a trailing `\' matches a backslash ending the string)
			elseif p == pe then
				return false
			else
				if band(flags, NOESCAPE) == 0 then
					c = pg(p)
					p = p + 1
					if p > pe then
						return false -- (a trailing `\' cannot match)
					end
					c = fold(c, flags)
				end
				if fold(sc, flags) ~= c then
					return false
				end
			end
		elseif c == STAR then
			if ends then
				return true, p - 1, n
			end
			if band(flags, PERIOD) ~= 0 and sc == DOT
				and (n == string0 or (band(flags, PATHNAME) ~= 0 and sg(n - 1) == SLASH)) then
				return false
			end
			if band(flags, DOTDOT) ~= 0 and ((n == string0 and sdot(n))
				or (band(flags, PATHNAME) ~= 0 and sg(n - 1) == SLASH and pdot(n))) then
				return false
			end
			if p == pe then
				return true -- (a final `*` matches the rest — even across `/`)
			end
			-- collapse consecutive `*`/`?`; each `?` consumes one character
			c = pg(p)
			p = p + 1
			while c == QM or c == STAR do
				if band(flags, PATHNAME) ~= 0 and sc == SLASH then
					return false
				elseif band(flags, EXTMATCH) ~= 0 and c == QM and pg(p) == LP then
					if extmatch(c, n, se, p, pe, flags) then
						return true
					end
					p = patscan(p + 1, pe, 0) or pe
				elseif c == QM then
					if sc == 0 then
						return false
					end
					n = n + 1
					sc = n < se and sg(n) or 0
				end
				if band(flags, EXTMATCH) ~= 0 and c == STAR and pg(p) == LP then
					for newn = n, se - 1 do
						if extmatch(c, newn, se, p, pe, flags) then
							return true
						end
					end
					p = patscan(p + 1, pe, 0) or pe
				end
				if p == pe then
					break
				end
				c = pg(p)
				p = p + 1
			end
			if c == 0 then -- (the wildcards were the pattern's last element)
				if band(flags, PATHNAME) == 0 or band(flags, LEADING_DIR) ~= 0 then
					return true
				end
				for k = n, se - 1 do
					if sg(k) == SLASH then
						return false
					end
				end
				return true
			end
			if p == pe and (c == QM or c == STAR) then
				return true
			end
			if n == se and band(flags, EXTMATCH) ~= 0 and (c == BANG or c == QM) and pg(p) == LP then
				p = p - 1
				local r = extmatch(c, n, se, p, pe, flags)
				if c == BANG then
					return not r
				end
				return r
			end
			if c == SLASH and band(flags, PATHNAME) ~= 0 then
				while n < se and sg(n) ~= SLASH do
					n = n + 1
				end
				return n < se and sg(n) == SLASH and (gmatch(n + 1, se, p, pe, false, flags)) or false
			end
			-- the general case: recurse at each candidate position
			local endp = se
			if band(flags, PATHNAME) ~= 0 then
				for k = n, se - 1 do
					if sg(k) == SLASH then
						endp = k
						break
					end
				end
			end
			local c1 = (band(flags, NOESCAPE) == 0 and c == BSL) and pg(p) or c
			c1 = fold(c1, flags)
			p = p - 1
			local ext = band(flags, EXTMATCH) ~= 0
			local ep, en
			while n < endp do
				local try = true
				if not ext then
					try = c == LBR or fold(sg(n), flags) == c1
				elseif pg(p + 1) ~= LP and not (isextop(pg(p)) or pg(p) == 0) and c ~= LBR
					and fold(sg(n), flags) ~= c1 then
					try = false
				end
				if try then
					local ok, e1, e2 = gmatch(n, se, p, pe, true, band(flags, NOTPD))
					if ok then
						if not e1 then
							return true
						end
						ep, en = e1, e2
						break
					end
				end
				n = n + 1
			end
			if not ep then
				return false
			end
			p, n = ep, en
			goto next
		elseif c == LBR then
			if sc == 0 or n == se then
				return false
			end
			if band(flags, PERIOD) ~= 0 and sc == DOT
				and (n == string0 or (band(flags, PATHNAME) ~= 0 and sg(n - 1) == SLASH)) then
				return false
			end
			if band(flags, DOTDOT) ~= 0 and ((n == string0 and sdot(n))
				or (band(flags, PATHNAME) ~= 0 and sg(n - 1) == SLASH and pdot(n))) then
				return false
			end
			p = brackmatch(p, sc, flags)
			if not p then
				return false
			end
		elseif c ~= fold(sc, flags) then
			return false
		end
		n = n + 1
		::next::
	end
	if n == se then
		return true
	end
	return band(flags, LEADING_DIR) ~= 0 and sg(n) == SLASH
end

-- Decode to character codes: bytes, or (multibyte locale) wide chars — an invalid byte
-- stands for itself. Patterns are cached (per locale generation).
local pcache, pcache_n, pcache_gen = {}, 0, -1
local function decode(s)
	local t, n = {}, #s
	if not mb or not s:find("[\128-\255]") then
		for i = 1, n do
			t[i] = s:byte(i)
		end
		return t, n
	end
	local k = 0
	for _, ch in ipairs(rt.mb_chars(s)) do
		k = k + 1
		t[k] = ch.wc or ch.s:byte(1)
	end
	return t, k
end

-- Does `str` match the shell pattern `pat` (bash strmatch with FNM_* `flags`)?
function S.match(str, pat, flags)
	mb = rt.lc_mb_cur_max() > 1
	if pcache_gen ~= rt.locale_gen or pcache_n >= 512 then
		pcache, pcache_n, pcache_gen = {}, 0, rt.locale_gen
	end
	local key = mb and pat or ("\0" .. pat)
	local pe = pcache[key]
	if not pe then
		local a, n = decode(pat)
		pe = { a, n }
		pcache[key] = pe
		pcache_n = pcache_n + 1
	end
	local sP, sPn, sSa, sSn = P, Pn, Sa, Sn
	P, Pn = pe[1], pe[2]
	Sa, Sn = decode(str)
	local r = gmatch(1, Sn + 1, 1, Pn + 1, false, flags) and true or false
	P, Pn, Sa, Sn = sP, sPn, sSa, sSn
	return r
end

return S
