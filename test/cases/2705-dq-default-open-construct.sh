# In a "…" ${NAME-WORD} (also :- + :+ = := ? :?), `'` is literal, so a `${` inside quotes
# that are no longer quotes is left open when the word is expanded: bash reports "bad
# substitution: no closing `}' in WORD" (`]' for $[; a backquote: no closing "`" in `…;
# an open $( is a substitution's syntax error), fails the command and discards the rest
# of its line. curse's re-read of the word raised the parser's EOF error as a raw Lua
# error that killed the script (fuzz F5).
echo "${u-'${'}"
echo "after $?"
echo "${u-a"b"c'${'}"; echo not reached
echo "${u-x$y'${'}"
echo "${u-'${'x}"
echo "${u-'${x'}"
echo "${u-'$('}"; echo "not reached"
echo "st=$?"
echo "${u-'`'}"
echo "${u-'$['}"
echo "${u:-'${'}" "${u:='${'}"
x=1; echo "${x:+'${'}"
echo "${x-'${'}" "${u-ok}"
f() { echo "${u-'${'}"; echo "in"; }; f; echo "fn not reached"
echo "fn st=$?"
eval 'echo "${u-'"'"'${'"'"'}"; echo ev'; echo "eval st=$?"
trap 'echo "${u-'"'"'${'"'"'}"; echo t' USR1; kill -USR1 $$; echo "trap st=$?"
n=0; for ((i = 0; i < 150; i++)); do eval 'echo "${u-'"'"'${'"'"'}"' 2>/dev/null || n=$((n + 1)); done; echo "loop $n"
