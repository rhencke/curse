-- $"…" translation (bash's locale.c localetrans / locale_expand), done by the PARSER as it
-- reads the line — so the locale and $TEXTDOMAIN in force are those when the line is read
-- (`LC_ALL=C; echo $"x"` on one line still translates with the previous locale).
-- The lookup is GNU gettext's dgettext($TEXTDOMAIN, text), reading the message catalog
-- $TEXTDOMAINDIR/<lang>/LC_MESSAGES/$TEXTDOMAIN.mo here in Lua rather than through libc:
-- glibc caches every catalog (and every miss) for the life of the process, which a daemon
-- serving many scripts can't have — this re-reads a catalog whose bytes changed.
local rt = require("runtime")
local M = {}

local cats = {} -- path -> { data = <the file's bytes>, map = { msgid = msgstr } }

-- Parse a GNU .mo file: magic 0x950412de in either byte order, then N, the offset of the
-- original-strings table and of the translations table (each entry: length, offset).
-- A plural entry's msgid is "singular\0plural": dgettext matches (and returns) the part
-- before the NUL.
local function u32(s, o, le)
	local a, b, c, d = s:byte(o + 1, o + 4)
	if not d then
		return nil
	end
	if le then
		return a + b * 256 + c * 65536 + d * 16777216
	end
	return d + c * 256 + b * 65536 + a * 16777216
end
local function parse_mo(s)
	local le
	if s:sub(1, 4) == "\222\018\004\149" then
		le = true
	elseif s:sub(1, 4) == "\149\004\018\222" then
		le = false
	else
		return nil
	end
	local n, oo, to = u32(s, 8, le), u32(s, 12, le), u32(s, 16, le)
	if not (n and oo and to) then
		return nil
	end
	local map, plural = {}, {}
	for k = 0, n - 1 do
		local ol, oof = u32(s, oo + 8 * k, le), u32(s, oo + 8 * k + 4, le)
		local tl, tof = u32(s, to + 8 * k, le), u32(s, to + 8 * k + 4, le)
		if not (ol and oof and tl and tof) then
			break
		end
		local raw = s:sub(oof + 1, oof + ol)
		local id = raw:match("^[^%z]*")
		if map[id] == nil then
			local tr = s:sub(tof + 1, tof + tl)
			map[id] = tr:match("^[^%z]*")
			if #id < #raw then -- (ngettext: every plural form, for l10n.lua)
				local forms = {}
				for f in (tr .. "\0"):gmatch("([^%z]*)%z") do
					forms[#forms + 1] = f
				end
				plural[id] = forms
			end
		end
	end
	return map, plural
end
local function catalog(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	local c = cats[path]
	if not (c and c.data == data) then
		local map, plural = parse_mo(data or "")
		c = { data = data, map = map or false, plural = plural }
		cats[path] = c
	end
	return c.map or nil, c
end
M.catalog = catalog

-- glibc's _nl_explode_name + _nl_make_l10nflist: language[_territory][.codeset][@modifier],
-- most specific first (the codeset as written, or normalized — lowercase alphanumerics,
-- "iso" before an all-digit one — never both)
local function variants(name, out)
	local lang, rest = name:match("^([^_.@]*)(.*)$")
	local terr = rest:match("^_([^.@]*)")
	local cs = rest:match("%.([^@]*)")
	local mod = rest:match("@(.*)$")
	local norm
	if cs then
		norm = cs:lower():gsub("[^%w]", "")
		if norm:match("^%d+$") then
			norm = "iso" .. norm
		end
		if norm == cs then
			norm = nil
		end
	end
	local mask = (norm and 1 or 0) + (cs and 2 or 0) + (terr and 4 or 0) + (mod and 8 or 0)
	for cnt = mask, 0, -1 do
		if bit.band(cnt, bit.bnot(mask)) == 0 and not (bit.band(cnt, 3) == 3) then
			out[#out + 1] = lang
				.. (bit.band(cnt, 4) ~= 0 and ("_" .. terr) or "")
				.. (bit.band(cnt, 2) ~= 0 and ("." .. cs) or "")
				.. (bit.band(cnt, 1) ~= 0 and ("." .. norm) or "")
				.. (bit.band(cnt, 8) ~= 0 and ("@" .. mod) or "")
		end
	end
end

M.variants = variants

local function var(sh, name)
	local v = sh.vars[name] and sh:get(name)
	return v ~= "" and v or nil
end

-- The translation of `s` (the raw text between the quotes of $"…"), or nil to keep it
function M.translate(sh, s)
	if s == "" then
		return nil
	end
	-- (localetrans: no translation under a C/POSIX LC_MESSAGES, by the shell's variables)
	local loc = var(sh, "LC_ALL") or var(sh, "LC_MESSAGES") or var(sh, "LANG")
	if not loc or loc == "C" or loc == "POSIX" then
		return nil
	end
	local domain = var(sh, "TEXTDOMAIN")
	if not domain then
		return nil
	end
	-- (dgettext: the LC_MESSAGES locale in force; $LANGUAGE's list first unless that's C)
	local cur = rt.lc_state[5]
	if cur == "C" or cur == "POSIX" then
		return nil
	end
	local names = {}
	local language = os.getenv("LANGUAGE")
	if language and language ~= "" then
		for l in language:gmatch("[^:]+") do
			variants(l, names)
		end
	end
	variants(cur, names)
	local dir = var(sh, "TEXTDOMAINDIR") or "/usr/share/locale"
	for _, nm in ipairs(names) do
		if nm == "C" then
			return nil
		end
		local map = catalog(dir .. "/" .. nm .. "/LC_MESSAGES/" .. domain .. ".mo")
		if map then
			local t = map[s]
			if t and t ~= "" then
				return t
			end
		end
	end
	return nil
end

return M
