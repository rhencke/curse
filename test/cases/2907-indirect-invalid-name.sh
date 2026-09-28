# ${!x} whose value isn't a valid variable reference — its `[` doesn't close at the end as
# skipsubscript reads it (quotes nest: `A["]` never closes) — is "NAME: invalid variable
# name", status 1, the line abandoned (leftover L8).
x='A["]'; echo ${!x}; echo "st $?"
x="A['x]"; echo "${!x}"; echo "st $?"
A=(p q); x='A[1]'; echo ${!x}; x='A[1]x'; echo ${!x}; echo "st $?"
x='A["1"]'; echo ${!x}; x='A[$((0))]'; echo ${!x}
f() { local x='B["]'; echo ${!x}; echo "f $?"; }; f; echo "st $?"
eval 'x="C[\"]"; echo ${!x}'; echo "eval $?"
printf 'x=D["]; echo ${!x}\necho "src $?"\n' > s2907.sh; . ./s2907.sh
trap 'x="E[\"]"; echo ${!x}; echo no' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do x='F["]'; y=${!x}; i=$((i + 1)); done 2>&1 | sort | uniq -c
i=0; while [ $i -lt 150 ]; do x='A[1]'; y=${!x}; i=$((i + 1)); done; echo "$y"
rm -f s2907.sh
