# Array literals the compiled tier now builds natively: dynamic subscripts (expanded in
# element order, indexed arithmetic later), side-effecting keys/values, a brace-expanding
# `[k]=` value (de-keyed for an indexed array), a bare word after a keyed first word in an
# assoc literal (reported unexpanded), a[i]=(…) and a nameref to an element.
exec 2>&1
for n in 1 2; do
	i=0; k=x
	a=([$((i+=1))]=one [i+2]=$((i*10)) ["$k$n"]=two)
	declare -p a
	declare -A m
	m=([$k$n]=v1 [$((i++))]=v2 ["q $n"]=v3)
	declare -p m
	unset b; b=([1]={x,y} z)
	declare -p b
	unset c; declare -A c; c=([1]={x,y} z)
	declare -p c 2>&1 | sed 's/^.*line [0-9]*: //'
	c=([a]=1 $(echo side >&2) [b]=2) 2>&1 | sed 's/^.*line [0-9]*: //'
	arr=(q r); declare -n ref=arr
	ref=(s t); declare -p arr
	declare -n eref='arr[1]'
	eref=(u v) 2>&1 | sed 's/^.*line [0-9]*: //'; echo "st=$?"
	unset -n ref eref
	( arr[1]=(w); echo notreached ) 2>&1 | sed 's/^.*line [0-9]*: //'
done
