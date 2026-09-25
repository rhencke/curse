# Declaration builtins compiled natively (rt.simple_run): flags, NAME=(…) literals,
# assignment-context values, in and out of functions, with redirections.
f() {
	local -a arr=(1 "two three" "$1")
	declare -p arr
	local -i n=3+4 m
	declare -p n
	typeset -r q=5 z
	declare -p q
	local -A m2=([k]=v ["a b"]=c)
	declare -p m2
	local x=~/sub y=a:~:b
	echo "$x $y" | sed "s#$HOME#HOME#g"
	declare -l low=MiXeD; declare -u up=MiXeD
	echo "$low $up"
	local -n ref=arr
	echo "ref: ${ref[1]}"
	declare -g gl=global
}
f hi
echo "gl=$gl arr=${arr-unset}"
declare -A m=([a]=1 [b]=2) other=x
declare -p m other
readonly r=1 s=$HOME:~
declare -p r
export e=~/x w="$e"
echo "$e $w" | sed "s#$HOME#HOME#g"
g() {
	local a=(x y) b=(1 2 3)
	echo "${#a[@]} ${#b[@]}"
	declare -a c=(1 2) 2>/dev/null
	echo "${c[1]}"
	declare -ai nums=(1+1 2*3)
	echo "${nums[@]}"
}
g
h() { local -A d=([one]=1); d[two]=2; for k in one two; do echo "$k=${d[$k]}"; done; }
h
v=outer
k() { local v=(inner); local -p v; }
k
echo "$v"
declare -a e1=( $(echo 1 2) "${m[a]}" )
declare -p e1
