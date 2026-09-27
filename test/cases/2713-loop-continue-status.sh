# A `while`/`until` loop's status is its last body command's — a `continue` (status 0) when
# the loop's re-test ends it after a continue. The compiled tier kept the status of an
# earlier iteration's last command: continue jumped past the body's status save (fuzz F16).
i=0; while ((i++ < 2)); do [ $i = 2 ] && continue; done; echo "while arith $?"
i=0; until ((i++ >= 2)); do [ $i = 2 ] && continue; done; echo "until $?"
i=0; while [ $i -lt 2 ]; do i=$((i+1)); [ $i = 2 ] && continue; done; echo "while [ $?"
i=0; while test $i -lt 2; do i=$((i+1)); [ $i = 2 ] && continue; false; done; echo "while test $?"
i=0; while read -r l <<<x && ((i++ < 2)); do [ $i = 2 ] && continue; done; echo "while cmd $?"
for j in 1 2; do i=0; while ((i++ < 2)); do [ $i = 2 ] && continue 2; done; done; echo "continue 2 $?"
i=0; while ((i++ < 3)); do if ((i == 3)); then continue; fi; false; done; echo "last continue $?"
i=0; while ((i++ < 3)); do [ $i = 1 ] && continue; false; done; echo "last false $?"
i=0; while ((i++ < 2)); do eval '[ $i = 2 ] && continue'; done; echo "eval $?"
f() { local i=0; while ((i++ < 2)); do [ $i = 2 ] && continue; done; return; }; f; echo "function $?"
printf 'i=0; while ((i++ < 2)); do [ $i = 2 ] && continue; done\n' > s2713.sh; . ./s2713.sh; echo "source $?"; rm -f s2713.sh
trap 'i=0; while ((i++ < 2)); do [ $i = 2 ] && continue; done; echo "trap $?"' USR1; kill -USR1 $$; trap - USR1
i=0; until ((i++ > 105)); do [[ i -gt 104 ]] && continue; false; done && echo True
n=0; i=0; while ((i++ < 150)); do ((i % 2 == 0)) && continue; n=$((n + 1)); false; done; echo "hot $? $n"
f2() { local i=0; while ((i++ < 150)); do ((i % 2 == 0)) && continue; false; done; echo "hot fn $?"; }; f2
