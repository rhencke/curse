-- External commands: captured stdout -> sh.out, $? from the command's exit,
-- interp and compiled agree.
package.path = "lua/?.lua;" .. package.path
local T = require("tier")
local function I(src) local sh=T.rt.Shell.new(); local b={}; sh.out=function(s) b[#b+1]=s end; T.interp.run(sh,T.parser.parse(src)); return (table.concat(b):gsub("\n","|"):gsub("|$","")) end
local function C(src) local sh=T.rt.Shell.new(); local b={}; sh.out=function(s) b[#b+1]=s end; T.compile(T.parser.parse(src)).run(sh,nil); return (table.concat(b):gsub("\n","|"):gsub("|$","")) end
local ok = true
local function ck(d, src, e) local i,c=I(src),C(src); local p=(i==e and c==e); ok=ok and p
  print(("  %-24s interp=%-14s compiled=%-14s %s"):format(d, i, c, p and "OK" or ("*** want ["..e.."]"))) end
ck("printf",  "printf 'a=%s\\n' hi", "a=hi")
ck("seq",     "seq 1 3", "1|2|3")
ck("exit status", "false\necho $?\ntrue\necho $?", "1|0")
ck("expr",    "expr 6 - 2", "4")
ck("cmd + arith var", "n=$((2*3))\nseq 1 $n", "1|2|3|4|5|6")
if not ok then os.exit(1) end
print("ALL external-command tests pass")
