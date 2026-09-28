# A bad (negative, before the start) subscript read through a nameref names the variable
# the lookup landed on — bash's `w: bad array subscript` for `declare -n ref=w` — in
# arithmetic, ${ref[-N]}, test -v and [[ -v ]]; curse named the nameref (fuzz F100).
w=x; declare -n ref=w
e='ref[-10]'; echo "$(( $e ))"
echo "$(( ref[-10] ))"
echo "[${ref[-10]}]"
(( ref[-10] )); echo "arith $?"
a=(1 2); declare -n ra=a
echo "$(( ra[-10] ))"; echo "[${ra[-10]}]"
test -v 'ref[-10]'; echo "test $?"
[[ -v ref[-10] ]]; echo "cond $?"
f() { local -n lr=$1; echo "$(( lr[-5] ))"; }; f w; f a
eval 'echo "$(( ref[-3] ))"'
printf 'echo "[${ra[-9]}]"\n' > s3041.sh; . ./s3041.sh
trap 'echo "$(( ra[-4] ))"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do echo "$(( ref[-2] + ra[-7] ))"; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s3041.sh
