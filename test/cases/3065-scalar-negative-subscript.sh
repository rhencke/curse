# A negative subscript read of a variable that is no array: only an indexed array counts
# back from its end (array_value_internal's INDEX_ERROR) — `${n[-1]}` of a scalar is
# `n: bad array subscript` (expands to nothing; the line goes on), `${#n[-1]}` is
# array_length_reference's `-1]: bad array subscript`, an expansion error. curse gave no
# error at all (fuzz F118). An assignment `n[-1]=x` converts the scalar first: fine.
n=5; echo "[${n[-1]}]"; echo "[${n[-1]:-d}]"; ( echo "[${#n[-1]}]"; echo notreached ); echo "st=$?"
echo "1[${n[-1]#x}]" "[${n[-1]:1}]" "[${n[-1]@Q}]" "[${n[-2]}]" "[${n[-1]:+s}]"
echo "2[${u[-1]}]" "[${#u[-1]}]"
declare d; echo "3[${d[-1]}]"; echo "[${#d[-1]}]"
declare -i ii=3; echo "4[${ii[-1]}]"
declare -n r=n; echo "5[${r[-1]}]"
q='n[-1]'; echo "7[${!q}]"
a=(1 2); declare -n ra=a; echo "16[${ra[-5]}]"
f() { local l=1; echo "8[${l[-1]}]"; }; f
( echo "9[${n[-1]=x}]"; declare -p n )
( n[-1]=y; declare -p n )
x=$(echo "[${n[-1]}]"); echo "10$x"
for k in -1 -2 0; do echo "11[${n[k]}]"; done
( set -u; echo "12[${n[-1]}]"; echo after )
( set -e; echo "13[${n[-1]}]"; echo after )
eval 'echo "e[${n[-1]}]"'
printf 'echo "s[${n[-1]}]"\n' > s3065.sh; . ./s3065.sh
trap 'echo "t[${n[-1]}]"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do echo "[${n[-1]}]"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s3065.sh
