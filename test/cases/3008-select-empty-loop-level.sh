# bash 5.2's execute_select_command counts a loop level (loop_level++) before it expands
# the list and returns without uncounting it when the list is empty: a break or continue
# later outside every loop then "breaks" — each command after it is skipped to the end of
# the input. A function, a subshell and $( ) start with no loop level (fuzz leftover M6:
# copied, bug-for-bug; it is deterministic, not UB).
select x in; do :; done; echo "st=$?"
f() { break; echo in-f; }; f
( break; echo in-sub )
x=$(break; echo in-cs); echo "[$x]"
g() { select y in $empty; do :; done; }; g
for i in 1 2 3; do echo "i$i"; break; done
j=0; while [ $j -lt 150 ]; do j=$((j + 1)); [ $j -eq 149 ] && break; done; echo "j=$j"
echo before
break
echo after-break
echo not-reached
