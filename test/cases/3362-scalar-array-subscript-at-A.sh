# `${w[@]@A}` / `${w[*]@A}` on a plain scalar: bash's `w[@]` names the variable itself,
# so the transform is `${w@A}`'s `w='value'` (with `declare -X ` for its attributes), not
# the `declare -p` form curse printed (fuzz F122).
w='hello world'
echo "${w[*]@A}"
echo "${w[@]@A}"
echo "${w@A}"
echo ${w[@]@A}
declare -i n=5; echo "${n[@]@A}"
export ex=1; echo "${ex[@]@A}"
declare -r q; echo "[${q[@]@A}]"
echo "[${u[@]@A}]" "[${u[*]@A}]"
readonly ro='a b'; echo "${ro[*]@A}"
a=(1 2); echo "${a[@]@A}"
declare -A h=([k]=v); echo "${h[*]@A}"
declare -n r=w; echo "${r[@]@A}"
f() { local l='x y'; echo "${l[@]@A}" "${l[0]@A}"; }
f
eval 'echo "${w[@]@A}"'
trap 'echo "trap: ${w[*]@A}"' USR1
kill -USR1 $$
s=
for ((i = 0; i < 150; i++)); do v=$i; t=${v[@]@A}; s=$t; done
echo "$s"
