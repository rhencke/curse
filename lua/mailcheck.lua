-- Mail checking for an interactive shell (bash's mailcheck.c), loaded by the REPL only.
-- The mailboxes come from $MAILPATH (`file?msg` / `file%msg` entries, colon-separated)
-- or else $MAIL; before each primary prompt, when $MAILCHECK allows, each one whose
-- modification time moved is announced on stdout. State lives in sh.mailcheck:
-- { files = { {name, msg, atime, mtime, size} … }, last = time of the last check }.
local ffi = require("ffi")
local rt = require("runtime")
local C = ffi.C

local M = {}

local stbuf = ffi.new("uint8_t[144]")
-- mailstat: atime, mtime, size — nil when the file can't be stat'ed (glibc x86-64 struct
-- stat: st_size@48, st_atime@72, st_mtime@88; see rt.file_test)
local function mstat(path)
	local ok, rc = pcall(C.curse_rt_stat, path, stbuf)
	if not ok or rc ~= 0 then
		return nil
	end
	local q = ffi.cast("int64_t *", stbuf)
	return tonumber(q[9]), tonumber(q[11]), tonumber(q[6])
end

local function update(f) -- update_mail_file (RESET_MAIL_FILE when it's gone)
	local a, m, z = mstat(f.name)
	if a then
		f.atime, f.mtime, f.size = a, m, z
	else
		f.atime, f.mtime, f.size = 0, 0, 0
	end
end

-- add_mail_file: the name made absolute; a known one is refreshed, a new one starts at the
-- last check (or the shell's start) with size 0
local function add(sh, st, file, msg)
	if file:sub(1, 1) ~= "/" then
		local pwd = sh.vars.PWD and sh:get("PWD") or ""
		file = (pwd:sub(-1) == "/" and pwd or pwd .. "/") .. file
	end
	for _, f in ipairs(st.files) do
		if f.name == file then
			if mstat(file) then
				update(f)
			end
			return
		end
	end
	local t = st.last or sh.start_time or os.time()
	st.files[#st.files + 1] = { name = file, msg = msg, atime = t, mtime = t, size = 0 }
end

-- remember_mail_dates: $MAILPATH's entries, else $MAIL (no default mail directory)
local function remember(sh, st)
	local mp = sh.vars.MAILPATH and sh:get("MAILPATH")
	if not mp then
		local m = sh.vars.MAIL and sh:get("MAIL")
		if m then
			add(sh, st, m, nil)
		end
		return
	end
	for unit in (mp .. ":"):gmatch("([^:]*):") do -- (extract_colon_unit)
		-- parse_mailpath_spec: the first unquoted `?` or `%` starts the message
		local i, msg = 1, nil
		while i <= #unit do
			local c = unit:sub(i, i)
			if c == "\\" then
				i = i + 1
			elseif c == "?" or c == "%" then
				msg = unit:sub(i + 1)
				unit = unit:sub(1, i - 1)
				break
			end
			i = i + 1
		end
		if unit ~= "" then
			add(sh, st, unit, msg)
		end
	end
end

function M.init(sh) -- the shell's start (shell.c: reset_mail_timer, init_mail_dates)
	local st = { files = {}, last = os.time() }
	sh.mailcheck = st
	remember(sh, st)
end

-- sv_mail: assigning MAILCHECK restarts the timer, MAIL/MAILPATH rebuild the list
function M.sv(sh, name)
	local st = sh.mailcheck
	if name == "MAILCHECK" then
		st.last = os.time()
	else
		st.files = {}
		remember(sh, st)
	end
end

-- time_to_check_mail: MAILCHECK a number >= 0, and that many seconds since the last check
local function due(sh, st)
	local v = sh.vars.MAILCHECK and sh:get("MAILCHECK")
	local n = v and rt.legal_i64(v)
	if not n then
		return false
	end
	n = tonumber(n)
	return n == 0 or (n > 0 and os.time() - st.last >= n)
end

-- Before a primary prompt (parse.y yylex): check_mail, then reset_mail_timer.
function M.prompt(sh)
	local st = sh.mailcheck
	if not st or not due(sh, st) then
		return
	end
	local ub = sh.vars._
	local under = ub and sh:get("_")
	local warn = sh.shopt.mailwarn
	for _, f in ipairs(st.files) do
		local a, m, z = mstat(f.name)
		-- file_mod_date_changed: a non-empty file modified since; an emptied one is re-read
		local changed = false
		if a then
			if z > 0 then
				changed = f.mtime < m
			elseif f.size > 0 then
				f.atime, f.mtime, f.size = a, m, z
			end
		end
		if changed then
			local msg = f.msg or rt.L("You have mail in $_")
			sh:set_str("_", f.name)
			local bigger = z > f.size -- (file_has_grown, before the update)
			update(f)
			if f.atime < f.mtime or bigger then
				if not f.msg and f.atime < f.mtime and bigger then
					msg = rt.L("You have new mail in $_")
				end
				local I = require("interp")._int
				local ok, out = pcall(I.expand_word, sh, require("parser").parse_heredoc(msg, false))
				io.write((ok and out or ""), "\n")
			end
		end
		if warn and a then -- file_access_date_changed
			local a2, _, z2 = mstat(f.name)
			if a2 and z2 > 0 and f.atime < a2 then
				update(f)
				io.write(rt.L("The mail in %s has been read\n", f.name))
			end
		end
	end
	if under then
		sh:set_str("_", under)
	else
		sh.vars._ = nil
	end
	io.flush()
	st.last = os.time()
end

return M
