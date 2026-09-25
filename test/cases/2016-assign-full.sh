# Assignments the specialized compiled paths don't cover, via rt.assign_full: nameref
# element/append/arith writes, unrenderable values/subscripts, a[]=, HISTSIZE, SHELLOPTS.
declare -n r=arr
r[1]=x; r+=(y); echo "${arr[@]}"
declare -n s=v
s+=abc; s+=def; echo "$v"
i=3; s=$((i*2)); echo "$v"
declare -n e='a[2]'
e=elem; echo "${a[2]}"
x=${u:-$(echo dflt)}; echo "$x"
k=${#arr[@]}; echo $k
b[$(echo 1)]=one; echo "${b[1]}"
b[]=bad; echo "st=$?"
HISTSIZE=5; echo "hs=$HISTSIZE"
SHELLOPTS=x
echo after-line
c=$(( n++ )) ; echo "c=$c n=$n"
