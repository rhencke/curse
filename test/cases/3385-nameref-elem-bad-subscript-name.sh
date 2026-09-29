# Pinned bash behaviour: an element read through a nameref resolves to the target; a bad
# (negative, out of range) subscript is reported under the TARGET's name when the target
# exists, but under the nameref's own name when the target is unset (bash's INDEX_ERROR).
declare -n zz=rz
echo "[${zz[-1]}]"
echo "st=$?"
declare -n ar=arr
arr=(a b c)
declare -A as=([k]=v [x]=y)
declare -n rs=as
echo "${ar[1]} ${ar[-1]} ${rs[k]} ${rs[x]}"
echo "[${ar[-5]}]"
f() {
	local -n lz=nope
	echo "[${lz[-2]}]"
	echo "[${ar[-9]}]"
}
f
for ((i = 0; i < 150; i++)); do
	s+=${ar[i % 3]}
	t=${zz[-1]}
done 2>&1 | sort | uniq -c
echo "${#s}"
