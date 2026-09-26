-- The libc (and curse C) symbols curse's Lua code reaches through ffi.C, and whether
-- they RESOLVE. A fully-static binary has no working dlsym, so ffi.C there falls back
-- to the hand-listed table in subprojects/packagefiles/luajit/src/lib_cursesys.c
-- (lj_clib.c -> curse_static_sym). A symbol missing from that table only fails at
-- the call ("undefined symbol"), and only in the static build — the daemon/dev
-- luajit resolves everything via dlsym — so drift stays invisible to the corpora.
--   <luajit> tools/ffi-syms.lua names [luadir]         the declared names ffi.C resolves (via dlsym)
--   <luajit> tools/ffi-syms.lua links [luadir]         their LINK names: what the table must hold
--   <curse>  tools/ffi-syms.lua check [luadir] [NAMES] resolve each of NAMES (a `names` output;
--            default every declared one) here; list the misses and exit 1 if any
-- (Declared-but-not-ffi.C names — readline's, reached through an ffi.load handle — don't
-- resolve under dlsym either, so `names` from the dynamic luajit leaves them out.)
-- The declarations are found by scanning every string literal in lua/*.lua and
-- ffi.cdef'ing each top-level C declaration in it (non-C strings just fail to parse),
-- so a cdef in any form — [[…]], "…" .. "…", a table of strings — is covered.
local ffi = require("ffi")
local mode, dir, want = arg[1] or "check", arg[2] or "lua", arg[3]

-- every Lua string literal of a source file (long brackets, '…', "…"; comments skipped)
local function strings(src)
	local out, i, n = {}, 1, #src
	while i <= n do
		local c = src:sub(i, i)
		if c == "-" and src:sub(i + 1, i + 1) == "-" then
			local eq = src:match("^%[(=*)%[", i + 2)
			if eq then
				local _, e = src:find("]" .. eq .. "]", i + 4 + #eq, true)
				i = (e or n) + 1
			else
				i = (src:find("\n", i, true) or n) + 1
			end
		elseif c == "[" and src:match("^%[=*%[", i) then
			local eq = src:match("^%[(=*)%[", i)
			local s = i + 2 + #eq
			local _, e = src:find("]" .. eq .. "]", s, true)
			out[#out + 1] = src:sub(s, (e or n + #eq + 2) - 2 - #eq)
			i = (e or n) + 1
		elseif c == '"' or c == "'" then
			local j, buf = i + 1, {}
			while j <= n do
				local d = src:sub(j, j)
				if d == "\\" then
					local e = src:sub(j + 1, j + 1)
					buf[#buf + 1] = (e == "n" and "\n") or (e == "t" and "\t") or e
					j = j + 2
				elseif d == c or d == "\n" then
					break
				else
					buf[#buf + 1] = d
					j = j + 1
				end
			end
			out[#out + 1] = table.concat(buf)
			i = j + 1
		else
			i = i + 1
		end
	end
	return out
end

-- top-level C declarations (split at ';' outside braces), comments stripped
local function decls(s)
	s = s:gsub("/%*.-%*/", " "):gsub("//[^\n]*", " ")
	local out, depth, start = {}, 0, 1
	for k = 1, #s do
		local c = s:sub(k, k)
		if c == "{" then
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
		elseif c == ";" and depth == 0 then
			out[#out + 1] = s:sub(start, k)
			start = k + 1
		end
	end
	return out
end

-- the ffi.C name a declaration introduces, and the link name it resolves to
local function declared(d)
	local body = d:gsub("%b{}", " ")
	if body:match("^%s*typedef%s") or body:match("^%s*struct%s+[%w_]+%s*;") or body:match("^%s*union%s")
		or body:match("^%s*enum%s") then
		return nil
	end
	local real = body:match('asm%s*%(%s*"([^"]+)"%s*%)')
	body = body:gsub('asm%s*%b()', " ")
	local name = body:match("([%a_][%w_]*)%s*%b()%s*;%s*$") -- a function
		or body:match("([%a_][%w_]*)%s*%[?[^%[%]]*%]?%s*;%s*$") -- an object (extern T name[;])
	if not name or name == "void" or name:match("^%d") then
		return nil
	end
	return name, real or name
end

local pending, seen = {}, {}
local p = io.popen("ls " .. dir .. "/*.lua")
for f in p:lines() do
	local h = assert(io.open(f, "rb"))
	local src = h:read("*a")
	h:close()
	for _, s in ipairs(strings(src)) do
		if s:find("[;]") and s:find("[%(%]]") then
			for _, d in ipairs(decls(s)) do
				if not seen[d] then
					seen[d] = true
					pending[#pending + 1] = d
				end
			end
		end
	end
end
p:close()

-- cdef each declaration; repeat so one that needs a type declared later still lands
local names, real = {}, {}
local progress = true
while progress do
	progress = false
	local left = {}
	for _, d in ipairs(pending) do
		local ok = pcall(ffi.cdef, d)
		local nm, rn = declared(d)
		if ok then
			progress = true
			if nm and not real[nm] then
				names[#names + 1] = nm
				real[nm] = rn
			end
		elseif nm and not real[nm] then
			left[#left + 1] = d -- (a real C declaration that doesn't parse YET)
		end
	end
	pending = left
end
table.sort(names)

if want then
	local h = assert(io.open(want, "rb"))
	local only = {}
	for l in h:lines() do
		only[l] = true
	end
	h:close()
	local keep = {}
	for _, nm in ipairs(names) do
		if only[nm] then
			keep[#keep + 1] = nm
			only[nm] = nil
		end
	end
	for nm in pairs(only) do -- (a wanted name this build doesn't even declare)
		keep[#keep + 1] = nm
	end
	names = keep
end

local bad, good, links = {}, {}, {}
for _, nm in ipairs(names) do
	local ok, e = pcall(function() return ffi.C[nm] end)
	if ok then
		good[#good + 1] = nm
		links[real[nm] or nm] = true
	else
		bad[#bad + 1] = nm .. (real[nm] and real[nm] ~= nm and (" (asm " .. real[nm] .. ")") or "")
			.. (tostring(e):find("undefined symbol", 1, true) and "" or ": " .. tostring(e))
	end
end

if mode == "names" or mode == "links" then
	local l = good
	if mode == "links" then
		l = {}
		for k in pairs(links) do
			l[#l + 1] = k
		end
	end
	table.sort(l)
	io.write(table.concat(l, "\n"), "\n")
	os.exit(0)
end
io.write(("ffi-syms: %d ffi.C symbols checked, %d unresolved\n"):format(#names, #bad))
if #bad > 0 then
	io.stderr:write("ffi-syms: UNRESOLVED (add to subprojects/packagefiles/luajit/src/lib_cursesys.c):\n  "
		.. table.concat(bad, "\n  ") .. "\n")
	os.exit(1)
end
