# A $(…) body is a subshell: reading a nameref whose target is an element with an
# arithmetic subscript (`declare -n r='a[i++]'`) evaluates that arithmetic IN the
# subshell — the increment must not leak into the parent, however simple the body.
a=(x y z w)
i=0
declare -n r='a[i++]'
x=$(echo $r); echo "$x i=$i"
y=$(echo "$r"); echo "$y i=$i"
z="$(printf %s $r)"; echo "$z i=$i"
w=`echo $r`; echo "$w i=$i"
v=$(echo ${r:-d} ${#r}); echo "$v i=$i"
echo $r $i
declare -n q='a[j=2]'
v=$(echo $q); echo "$v j=${j-unset}"
declare -n r2=r
v=$(echo $r2); echo "$v i=$i"
f() { local -n lr='a[k++]'; echo "$(echo $lr) k=$k"; }
k=1; f; echo "k=$k"
n=0
for ((c = 0; c < 160; c++)); do
	s=$(echo $r); t=$(echo $q)
	[ "$s$t" = "yz" ] && n=$((n + 1))
done
echo "n=$n i=$i j=${j-unset}"
g() { echo "$(echo $r)"; }
for ((c = 0; c < 160; c++)); do g; done | uniq -c
echo "i=$i"
