# A `(( ))` condition that is no expression (`((0 0))`) reports bash's syntax error each
# time it runs, its status 1 (the loop/if goes on as for a false condition). The compiled
# tier failed to compile such a while/until/if, fatally: `emit: value position not
# supported for node matherr` (fuzz F27).
while ((0 0)); do :; done; echo "while $?"
until ((1 +)); do break; done; echo "until $?"
if ((0 0)); then echo yes; else echo "if $?"; fi
if false; then :; elif ((2 2)); then echo no; else echo "elif $?"; fi
((0 0)) && :; echo "and $?"
i=0; while ((i++ < 3 3)); do :; done; echo "while2 $?"
f() { while ((0 0)); do :; done; echo "function $?"; }; f
eval 'if ((1 1)); then :; fi; echo "eval $?"'
printf 'until ((4 4)); do break; done\necho "source $?"\n' > s2723.sh; . ./s2723.sh; rm -f s2723.sh
trap 'while ((5 5)); do :; done; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
n=0; k=; while ((n++ < 150)); do if ((0 0)) 2>/dev/null; then :; else k=$?; fi; done; echo "hot $k $n"
for ((j = 0; j < 150; j++)); do while ((0 0)); do :; done; done 2>&1 | sort | uniq -c
