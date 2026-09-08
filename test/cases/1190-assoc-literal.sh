# associative-array literals: quoted keys are unquoted, and a [key]=value
# element's value is not brace-expanded or word-split (it's an assignment word).

# quoted keys with special characters
declare -A a=([aa]=b [foo]=bar ['a+1']=c ["k k"]=spaced)
echo "1:${a[aa]} ${a[foo]} ${a["a+1"]} [${a["k k"]}]"

# a braced value stays literal in an assoc array
declare -A m=([k1]=v [k2]=-{a,b}- [k3]='one two')
echo "2:${m[k1]} / ${m[k2]} / [${m[k3]}]"

# append into an assoc array keeps existing keys
declare -A d=([a]=1)
d+=([b]=2 [c]=3)
echo "4:${d[a]} ${d[b]} ${d[c]} n=${#d[@]}"

# indexed arrays still brace-expand and split plain words
idx=(p{1,2}q [5]=end)
echo "5:${idx[0]} ${idx[1]} ${idx[5]}"

# a value containing a glob character is not expanded against the filesystem
declare -A g=([key]='*.nomatch')
echo "6:${g[key]}"
