package.path = "lua/?.lua;" .. package.path
local T = require("tier")
local script = arg[1] or error("usage: demo_background.lua <script.sh>")
local luajit = os.getenv("CURSE_LUAJIT") or "luajit"
local poll = tonumber(os.getenv("POLL") or "2048")
local t0 = os.clock()
local sh, how, count = T.run_background(script, { luajit = luajit, poll_every = poll })
io.stderr:write(("[tier: %s, %.3fs]\n"):format(how, os.clock() - t0))
