# Recursion that ENDS runs as deep as bash's own stack allows: with the default 8 MiB
# stack bash 5.2.21 reaches ~6780 function levels, ~5460 of eval, ~5560 of source before
# its C stack overflows (SIGSEGV: docs/bash-ub.md); a subshell or $(…) recursion is bounded
# by processes. curse stopped with "stack overflow" a function ~700 deep, eval/source/
# subshell ~500, $(…) ~400 (stress-attack S10): LuaJIT's 65500-slot Lua stack. Each probe
# runs in a subshell of its own.
f() { local n=$1; if ((n > 0)); then f $((n - 1)); else echo "function bottom"; fi; }
(f 6000); echo "function 6000: $?"
e() { if (($1 > 0)); then eval "e $(($1 - 1))"; else echo "eval bottom"; fi; }
(e 5000); echo "eval 5000: $?"
echo 'if (($1 > 0)); then . ./rs3367.sh $(($1 - 1)); else echo "source bottom"; fi' > rs3367.sh
(. ./rs3367.sh 5000); echo "source 5000: $?"
rm -f rs3367.sh
s() { if (($1 > 0)); then (s $(($1 - 1))); return $?; else return 7; fi; }
(s 400); echo "subshell 400: $?"
g() { if (($1 > 0)); then echo $(($(g $(($1 - 1))) + 1)); else echo 0; fi; }
echo "comsub 400: $(g 400)"
m() { if (($1 > 0)); then case $(($1 % 3)) in 0) m $(($1 - 1)) ;; 1) eval "m $(($1 - 1))" ;; 2) (m $(($1 - 1))) ;; esac; else echo "mixed bottom"; fi; }
(m 900); echo "mixed 900: $?"
trap '(f 4000)' USR1
kill -USR1 $$
echo "trap: $?"
t=0
for ((i = 0; i < 150; i++)); do x=$(f 100); [ "$x" = "function bottom" ] && t=$((t + 1)); done
echo "loop $t"
